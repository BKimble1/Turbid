import Foundation
import Observation
import SwiftUI

/// MainActor-isolated owner of the measurement session.
///
/// Drives the whole run: permission, camera preparation, alignment, torch,
/// warm-up, control locking, background acquisition, the measurement window and
/// the reading. Nothing here computes a measurement quantity; the pipeline does
/// that on its own queue and hands back value types.
///
/// Every exit from a state that holds hardware goes through `shutdownCapture()`,
/// so there is exactly one path that turns the torch off.
@MainActor
@Observable
final class MeasurementViewModel {

    /// How long the run may go without a progress update before it is
    /// abandoned. The pipeline publishes about five times a second while frames
    /// are arriving, so four seconds of silence means they have stopped.
    private let stallAllowance: Duration

    private var machine = MeasurementStateMachine()

    private(set) var authorization: CameraAuthorization = .notDetermined
    private(set) var hasCheckedAuthorization = false
    private(set) var capture: CaptureSnapshot = .idle
    private(set) var progress: MeasurementProgress = .idle
    private(set) var chartSamples: [ScatteringSample] = []
    /// The most recent reading, valid or not. Kept for a rejected window too,
    /// because the evidence for the rejection lives in it.
    private(set) var reading: TurbidityReading?
    /// The instrument as it was when the controls were locked for this run.
    private(set) var liveBinding: CalibrationBinding?
    private(set) var simulatedSample: SimulatedSample = .lightlyLoaded
    /// What the live preview looks like while the user is lining the sample up.
    private(set) var alignment: AlignmentStatus = .unknown
    /// Set by the calibration flow, which describes the fixture itself because
    /// there is no profile yet to take it from.
    var fixtureOverride: FixtureDescription?
    /// True while the calibration workflow owns the camera, so the main screen
    /// does not also try to present its own capture screen on top of it.
    var isCalibrating = false

    /// Screening unless the user deliberately switches.
    private(set) var mode: MeasurementMode = .screening

    let calibrations: CalibrationLibrary

    private let environment: AppEnvironment
    private var pipeline: MeasurementPipeline?
    private var alignmentMonitor: AlignmentMonitor?
    private var snapshotTask: Task<Void, Never>?
    private var flowTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var alignmentTask: Task<Void, Never>?

    private var lastProgressAt: ContinuousClock.Instant?
    private var didStall = false
    private var controlsRemainedLocked = true

    init(environment: AppEnvironment, stallAllowance: Duration = .seconds(4)) {
        self.environment = environment
        self.stallAllowance = stallAllowance
        self.calibrations = CalibrationLibrary(store: environment.calibrationStore)
        self.mode = environment.initialMode
    }

    deinit {
        snapshotTask?.cancel()
        flowTask?.cancel()
        analysisTask?.cancel()
        alignmentTask?.cancel()
    }

    // MARK: - Read-only surface for the interface

    var state: MeasurementState { machine.state }
    var allowsSimulatedData: Bool { environment.allowsSimulatedData }
    var camera: CameraControlling { environment.camera }
    var hasAcknowledgedDisclosure: Bool { environment.disclosure.hasAcknowledged() }
    var analysisRegion: AnalysisRegion { alignmentMonitor?.region ?? .screeningDefault }

    /// The calibration that would be used for a measurement started now, or
    /// `nil` in Screening Mode.
    var activeProfile: CalibrationProfile? {
        mode.permitsNumericNTU ? calibrations.selectedProfile : nil
    }

    /// Why the selected calibration cannot be used with the current setup.
    /// Empty in Screening Mode, which never claims one applies.
    var calibrationMismatches: [String] {
        guard mode.permitsNumericNTU else { return [] }
        return calibrations.mismatches(against: liveBinding)
    }

    /// What the fixture is asserted to be for this run.
    ///
    /// In Calibrated Fixture Mode it is taken from the selected profile: the app
    /// cannot sense a fixture, so the user's choice of profile *is* the claim
    /// that they have reassembled it. Everything the phone can actually verify —
    /// camera, format, focus, exposure, white balance, torch level, every
    /// algorithm version — is still checked against the profile independently.
    var fixture: FixtureDescription {
        // A calibration run has no profile to take the fixture from, so the
        // calibration flow states it explicitly and it wins.
        if let fixtureOverride { return fixtureOverride }
        guard mode.permitsNumericNTU, let profile = calibrations.selectedProfile else {
            return .none
        }
        return FixtureDescription(
            fixtureIdentifier: profile.binding.fixtureIdentifier,
            fixtureGeometryVersion: profile.binding.fixtureGeometryVersion,
            containerIdentifier: profile.binding.containerIdentifier,
            fillVolumeMillilitres: profile.binding.fillVolumeMillilitres,
            workingDistanceMillimetres: profile.binding.workingDistanceMillimetres
        )
    }

    // MARK: - Lifecycle

    func acknowledgeDisclosure() {
        environment.disclosure.acknowledge()
    }

    func loadCalibrations() async {
        await calibrations.load()
    }

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
        reading = nil
        progress = .idle
        chartSamples = []

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

            // The torch comes on for alignment, not just for the measurement.
            // A dark preview cannot be aligned, and the quality prompts on the
            // setup screen are meaningless unless the scene is lit the way it
            // will be lit during the run.
            let torch = try await environment.camera.setTorch(on: true)
            if !torch.isActive {
                LucidLog.camera.notice("Torch did not come on for alignment.")
            }
            startAlignmentMonitor()
        } catch let error as CameraError {
            await handleCameraFailure(error, whilePreparing: true)
        } catch {
            await handleCameraFailure(.configurationFailed(error.localizedDescription),
                                      whilePreparing: true)
        }
        capture = await environment.camera.currentSnapshot()
    }

    /// Runs the whole measurement: illumination, control lock, analysis, result.
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

    /// Runs the whole flow again from the beginning, restarting the session
    /// that the previous run shut down.
    func measureAgain() async {
        guard machine.state.isRestartable else { return }
        machine.apply(.reset)
        await startSetup()
    }

    func cancel() async {
        analysisTask?.cancel()
        analysisTask = nil
        flowTask?.cancel()
        flowTask = nil
        machine.apply(.cancelled)
        await shutdownCapture()
    }

    /// Changing mode mid-run is refused: the mode is part of what produced the
    /// reading, and a run that started as screening cannot finish as a
    /// calibrated measurement.
    func setMode(_ newMode: MeasurementMode) {
        guard !machine.state.usesCaptureHardware else { return }
        mode = newMode
    }

    func openSettings() {
        guard authorization.requiresSettingsChange else { return }
        environment.settingsOpener.openAppSettings()
    }

    /// Only meaningful on the Simulator, where the camera is a synthetic feed.
    func selectSimulatedSample(_ sample: SimulatedSample) {
        guard allowsSimulatedData else { return }
        simulatedSample = sample
        (environment.camera as? StubCameraService)?.setSimulatedSample(sample)
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
        analysisTask?.cancel()
        analysisTask = nil
        flowTask?.cancel()
        flowTask = nil
        machine.apply(.interrupted(reason))
        LucidLog.measurement.notice("Capture shutdown: \(reason.rawValue, privacy: .public)")
        await shutdownCapture()
    }

    // MARK: - The run

    private func runMeasurementSequence() async {
        guard machine.apply(.alignmentConfirmed) else { return }
        controlsRemainedLocked = true
        didStall = false
        reading = nil
        chartSamples = []
        progress = .idle

        // Alignment is over; the pipeline takes the frames from here.
        stopAlignmentMonitor()

        do {
            // Confirmed rather than assumed: the torch has been on since
            // alignment, but its level can fall under thermal load and the
            // level is part of the calibration binding.
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
            guard machine.apply(.controlsLocked) else { return }

            capture = await environment.camera.currentSnapshot()
            try Task.checkCancellation()
            await runAnalysis(torchLevel: torch.level, locked: locked)
        } catch is CancellationError {
            // `cancel()` has already moved the machine and shut the torch off.
            return
        } catch let error as CameraError {
            await handleCameraFailure(error, whilePreparing: false)
        } catch {
            await handleCameraFailure(.controlLockFailed(error.localizedDescription),
                                      whilePreparing: false)
        }
        capture = await environment.camera.currentSnapshot()
    }

    /// Attaches the pipeline, follows it to completion, and builds the reading.
    private func runAnalysis(torchLevel: Float, locked: LockedCameraControls) async {
        let pipeline = environment.makePipeline()
        self.pipeline = pipeline

        // Read from the pipeline that will actually run, never written as a
        // literal: a binding that named a region the analyzer did not use would
        // match calibrations it has no right to.
        let algorithmVersions = CalibrationBindingBuilder.algorithmVersions(
            captureProtocol: pipeline.captureProtocol
        )
        liveBinding = CalibrationBindingBuilder.make(
            selection: capture.selection,
            locked: locked,
            torchLevel: torchLevel,
            region: pipeline.region,
            fixture: fixture,
            deviceModelIdentifier: CalibrationBindingBuilder.deviceModelIdentifier(),
            algorithmVersions: algorithmVersions
        )

        // The reading's frame-delivery figures must describe this window, not
        // however long the sample took to line up.
        environment.camera.resetFrameStatistics()
        pipeline.start()
        environment.camera.setFrameConsumer(pipeline)

        let completed = await followRun(of: pipeline)

        // Detached before anything else: no frame may reach a finished run.
        environment.camera.setFrameConsumer(nil)
        pipeline.stop()

        guard completed else {
            if didStall {
                machine.apply(.failed(.frameDeliveryStopped))
                await shutdownCapture()
            }
            self.pipeline = nil
            return
        }

        machine.apply(.measurementWindowCompleted)

        // Read fresh rather than reusing the last published snapshot: that one
        // can be up to a publish interval old, and the frame-delivery figures
        // in the reading have to cover the whole window.
        capture = await environment.camera.currentSnapshot()

        let result = pipeline.makeReading(
            mode: mode,
            profile: activeProfile,
            liveBinding: liveBinding,
            thermal: capture.thermal,
            systemPressure: capture.systemPressure,
            controlsRemainedLocked: controlsRemainedLocked,
            timing: capture.timing,
            timestamp: Date(),
            algorithmVersions: algorithmVersions
        )
        reading = result
        chartSamples = pipeline.chartSamples
        self.pipeline = nil

        // The hardware is released before the result is shown: nobody should
        // have to read a result with the torch still burning.
        await shutdownCapture()

        if result.validity.isValid {
            machine.apply(.calculationFinished)
        } else {
            machine.apply(.qualityFailed(reasons: result.validity.reasons))
        }

        LucidLog.measurement.info(
            "Run finished: \(result.clarity.clarity.rawValue, privacy: .public), confidence \(result.confidence, format: .fixed(precision: 2), privacy: .public)"
        )
    }

    /// - Returns: `true` when the pipeline reached the end of its timeline.
    private func followRun(of pipeline: MeasurementPipeline) async -> Bool {
        lastProgressAt = .now

        let consumer = Task { [weak self] in
            for await update in pipeline.updates {
                guard let self else { return }
                self.lastProgressAt = .now
                self.progress = update
                self.chartSamples = pipeline.chartSamples
                self.advance(to: update.stage)
                if update.stage == .complete { return }
            }
        }
        analysisTask = consumer

        // Frames drive everything, so silence has to be an outcome rather than
        // a wait. Nothing else would ever end the run.
        // Polled rather than scheduled once, so the allowance restarts with
        // every update instead of expiring mid-run.
        let poll = min(Duration.milliseconds(500), stallAllowance / 2)
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard let self, let last = self.lastProgressAt else { return }
                if ContinuousClock.Instant.now - last > self.stallAllowance {
                    self.didStall = true
                    consumer.cancel()
                    return
                }
            }
        }

        await consumer.value
        watchdog.cancel()
        analysisTask = nil
        lastProgressAt = nil

        return pipeline.isComplete
    }

    /// Maps the capture stage onto the session state.
    ///
    /// Torch settling and background acquisition are one state to the user:
    /// both are "getting ready", and neither produces a number.
    private func advance(to stage: CaptureStage) {
        switch stage {
        case .ambientReference, .torchSettling, .backgroundAcquisition:
            break
        case .measurement:
            machine.apply(.backgroundAcquired)
        case .complete:
            break
        }
    }

    // MARK: - Shutdown and failures

    /// Always turns the torch off and stops the session, whatever went wrong.
    private func shutdownCapture() async {
        stopAlignmentMonitor()
        environment.camera.setFrameConsumer(nil)
        pipeline?.stop()
        await environment.camera.stop()
        capture = await environment.camera.currentSnapshot()
    }

    // MARK: - Alignment

    /// Watches the live preview so the setup screen can say what is wrong
    /// before twelve seconds are spent finding out.
    private func startAlignmentMonitor() {
        stopAlignmentMonitor()
        alignment = .unknown

        let monitor = AlignmentMonitor()
        alignmentMonitor = monitor
        monitor.start()
        environment.camera.setFrameConsumer(monitor)

        alignmentTask = Task { [weak self] in
            for await status in monitor.updates {
                guard let self else { return }
                self.alignment = status
            }
        }
    }

    private func stopAlignmentMonitor() {
        guard alignmentMonitor != nil else { return }
        alignmentTask?.cancel()
        alignmentTask = nil
        environment.camera.setFrameConsumer(nil)
        alignmentMonitor?.stop()
        alignmentMonitor = nil
        alignment = .unknown
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

        // Once the controls have been locked for a run, losing them means the
        // frames after that point were captured under different settings.
        if machine.state == .acquiringBackground || machine.state == .measuring,
           snapshot.lockedControls == nil {
            controlsRemainedLocked = false
        }

        if !snapshot.thermal.permitsMeasurement || !snapshot.systemPressure.permitsMeasurement {
            analysisTask?.cancel()
            machine.apply(.thermalLimitReached)
            Task { await shutdownCapture() }
            return
        }

        if let interruption = snapshot.interruption, interruption.isActive {
            analysisTask?.cancel()
            machine.apply(.interrupted(.sessionInterrupted))
            Task { await shutdownCapture() }
        }
    }
}
