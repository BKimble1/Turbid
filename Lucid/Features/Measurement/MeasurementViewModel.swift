import Foundation
import Observation
import SwiftUI

/// MainActor-isolated owner of the measurement session state.
///
/// Phase 1 drives the session only as far as resolving camera authorization.
/// There is no capture pipeline in this build, so an authorized session stops
/// at an explicit `captureUnavailableInThisBuild` failure rather than showing a
/// spinner that never resolves. Phase 2 replaces that single call site.
@MainActor
@Observable
final class MeasurementViewModel {
    private var machine = MeasurementStateMachine()

    private(set) var authorization: CameraAuthorization = .notDetermined
    private(set) var mode: MeasurementMode = .screening
    private(set) var hasCheckedAuthorization = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var state: MeasurementState { machine.state }

    var allowsSimulatedData: Bool { environment.allowsSimulatedData }

    /// Reads authorization without ever raising the system prompt. Safe to call
    /// on every appearance and on every return to the foreground.
    func refreshAuthorization() async {
        let status = await environment.cameraAuthorization.currentStatus()
        authorization = status
        hasCheckedAuthorization = true

        // Access can be revoked in Settings while the app is backgrounded.
        if !status.allowsCapture && machine.state.usesCaptureHardware {
            machine.apply(.interrupted(.permissionRevoked))
            LucidLog.permission.notice("Camera access revoked while a session was active.")
        }
    }

    /// Begins setup: resolves permission, then hands off to the capture pipeline.
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

        // ---- Phase 2 replaces this block with CameraService configuration. ----
        machine.apply(.failed(.captureUnavailableInThisBuild))
        LucidLog.measurement.notice("Camera authorized; capture pipeline is not present in this build.")
    }

    func cancel() {
        machine.apply(.cancelled)
    }

    func openSettings() {
        guard authorization.requiresSettingsChange else { return }
        environment.settingsOpener.openAppSettings()
    }

    /// The defined hardware-cleanup hook.
    ///
    /// Phase 2 stops the `AVCaptureSession` and turns the torch off inside
    /// `shutdownCaptureIfNeeded(reason:)`; the state handling stays as it is.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await refreshAuthorization() }
        case .inactive, .background:
            shutdownCaptureIfNeeded(reason: .appBackgrounded)
        @unknown default:
            shutdownCaptureIfNeeded(reason: .appBackgrounded)
        }
    }

    private func shutdownCaptureIfNeeded(reason: MeasurementInterruption) {
        guard machine.state.usesCaptureHardware else { return }
        machine.apply(.interrupted(reason))
        LucidLog.measurement.notice("Capture shutdown requested: \(reason.rawValue, privacy: .public)")
    }
}
