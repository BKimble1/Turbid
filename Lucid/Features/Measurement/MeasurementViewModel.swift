import Foundation
import Observation
import SwiftUI

/// MainActor-isolated owner of the measurement session.
///
/// Phase 2 drives the session through permission, camera preparation,
/// alignment, warm-up, control locking and torch illumination. It stops at the
/// point where background acquisition would begin, because the frame analyzer
/// arrives in Phase 3A. Everything before that point is real hardware work.
@MainActor
@Observable
final class MeasurementViewModel {
    private var machine = MeasurementStateMachine()

    private(set) var authorization: CameraAuthorization = .notDetermined
    private(set) var mode: MeasurementMode = .screening
    private(set) var hasCheckedAuthorization = false
    private(set) var capture: CaptureSnapshot = .idle

    private let environment: AppEnvironment
    private var snapshotTask: Task<Void, Never>?
    private var flowTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    deinit {
        snapshotTask?.cancel()
        flowTask?.cancel()
    }

    var state: MeasurementState { machine.state }
    var allowsSimulatedData: Bool { environment.allowsSimulatedData }
    var camera: CameraControlling { environment.camera }

    /// Reads authorization without ever raising the system prompt.
    func refreshAuthorization() async {
        let status = await environment.cameraAuthorization.currentStatus()
        authorization = status
        hasCheckedAuthorization = true

        if !status.allowsCapture && machine.state.usesCaptureHardware {
            machine.apply(.interrupted(.permissionRevoked))
            await shutdownCapture()
            LucidLog.permission.notice("Camera access revoked while a session was active.")
        }
    }

    /// Resolves permission, then prepares and starts the capture session.
    func startSetup() async {
        guard machine.apply(.startRequested) else { return }

        let current = await environment.cameraAuthorization.currentStatus()
        let resolved = current.canRequestSystemPrompt
            ? await environment.cameraAuthorization.requestAccess()
            : current

        authorization = resolved
        hasCheckedAuthorization = true
        machine.apply(.permissionResolved(resolved))

        guard machine.state == .preparingCamera else { return }
        observeCaptureSnapshots()

        do {
            let summary = try await environment.camera.prepare()
            try await environment.camera.start()
            LucidLog.camera.info(
                "Selected \(summary.cameraName, privacy: .public) at \(summary.resolution, privacy: .public)"
            )
            machine.apply(.cameraReady)
        } catch let error as CameraError {
            await handleCameraFailure(error, whilePreparing: true)
        } catch {
            await handleCameraFailure(.configurationFailed(error.localizedDescription),
                                      whilePreparing: true)
        }
        capture = await environment.camera.currentSnapshot()
    }

    /// Runs the illumination sequence: warm up, lock the controls, turn the
    /// torch on, then hand over to background acquisition.
    func beginMeasurement() async {
        guard machine.state == .alignment, flowTask == nil else { return }

        // Held in a task so backgrounding or cancelling can interrupt the
        // sequence mid-way; awaited so callers know when it has finished.
        let task = Task { [weak self] in
            await self?.runMeasurementSequence()
        }
        flowTask = task
        await task.value
        flowTask = nil
    }

    private func runMeasurementSequence() async {
        guard machine.apply(.alignmentConfirmed) else { return }

        do {
            // The torch goes on first: focus, exposure and white balance must
            // settle on the *illuminated* scene, not the ambient one, or the
            // lock would be wrong the moment the light comes up.
            let torch = try await environment.camera.setTorch(on: true)
            if !torch.deliveredRequestedLevel {
                LucidLog.camera.notice("Torch is active below the requested maximum level.")
            }

            let settled = try await environment.camera.warmUp()
            if !settled {
                LucidLog.camera.notice("Camera never stopped adjusting during warm-up.")
            }
            guard machine.apply(.warmUpCompleted) else { return }

            let locked = try await environment.camera.lockControls()
            LucidLog.camera.info(
                "Controls locked: focus \(locked.focusModeDescription, privacy: .public), exposure \(locked.exposureModeDescription, privacy: .public)"
            )
            // `.controlsLocked` moves the session to `.acquiringBackground`,
            // which is where the Phase 3A background model will be built.
            guard machine.apply(.controlsLocked) else { return }
            capture = await environment.camera.currentSnapshot()

            // ---- Phase 3A replaces this with background acquisition. ----
            machine.apply(.failed(.analysisUnavailableInThisBuild))
            await shutdownCapture()
        } catch let error as CameraError {
            await handleCameraFailure(error, whilePreparing: false)
        } catch {
            await handleCameraFailure(.controlLockFailed(error.localizedDescription),
                                      whilePreparing: false)
        }
        capture = await environment.camera.currentSnapshot()
    }

    func cancel() async {
        flowTask?.cancel()
        flowTask = nil
        machine.apply(.cancelled)
        await shutdownCapture()
    }

    func openSettings() {
        guard authorization.requiresSettingsChange else { return }
        environment.settingsOpener.openAppSettings()
    }

    /// The hardware-cleanup hook. Leaving the foreground always stops the
    /// session and turns the torch off.
    func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            await refreshAuthorization()
        case .inactive, .background:
            await interruptCapture(reason: .appBackgrounded)
        @unknown default:
            await interruptCapture(reason: .appBackgrounded)
        }
    }

    func interruptCapture(reason: MeasurementInterruption) async {
        guard machine.state.usesCaptureHardware else { return }
        flowTask?.cancel()
        flowTask = nil
        machine.apply(.interrupted(reason))
        LucidLog.measurement.notice("Capture shutdown: \(reason.rawValue, privacy: .public)")
        await shutdownCapture()
    }

    /// Always turns the torch off and stops the session, whatever went wrong.
    private func shutdownCapture() async {
        await environment.camera.stop()
        capture = await environment.camera.currentSnapshot()
    }

    private func handleCameraFailure(_ error: CameraError, whilePreparing: Bool) async {
        LucidLog.camera.error("Camera failure: \(error.message, privacy: .public)")
        if whilePreparing, case .noSuitableCamera(let reasons) = error {
            machine.apply(.cameraUnsupported(reason: reasons.joined(separator: "; ")))
        } else {
            machine.apply(.failed(.cameraUnavailable(error)))
        }
        await shutdownCapture()
    }

    private func observeCaptureSnapshots() {
        guard snapshotTask == nil else { return }
        let stream = environment.camera.snapshots
        snapshotTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.capture = snapshot
                self.reactToHardwareConditions(snapshot)
            }
        }
    }

    /// Thermal limits and interruptions must stop a measurement in progress,
    /// not be discovered afterwards in the result.
    private func reactToHardwareConditions(_ snapshot: CaptureSnapshot) {
        guard machine.state.usesCaptureHardware else { return }

        if !snapshot.thermal.permitsMeasurement || !snapshot.systemPressure.permitsMeasurement {
            machine.apply(.thermalLimitReached)
            Task { await shutdownCapture() }
            return
        }

        if let interruption = snapshot.interruption, interruption.isActive {
            machine.apply(.interrupted(.sessionInterrupted))
            Task { await shutdownCapture() }
        }
    }
}
