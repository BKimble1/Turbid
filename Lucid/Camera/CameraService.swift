import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Owns the one `AVCaptureSession`.
///
/// Threading contract:
///
/// * `sessionQueue` is a dedicated serial queue. Every `AVCaptureSession` and
///   `AVCaptureDevice` access happens on it, and nothing else does.
/// * `processingQueue` is a separate serial queue that receives sample buffers.
///   Frame work must never sit behind session configuration.
/// * The public API is `async` and bridges onto `sessionQueue`, so no caller
///   can block the main thread.
/// * Only value types are published. `CMSampleBuffer` and `CVPixelBuffer` never
///   leave the delegate method.
final class CameraService: NSObject, CameraControlling, @unchecked Sendable {

    // MARK: Queues

    private let sessionQueue = DispatchQueue(label: "com.lucid.camera.session")
    private let processingQueue = DispatchQueue(label: "com.lucid.camera.processing",
                                                qos: .userInitiated)

    // MARK: Session state (sessionQueue only)

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var lifecycle = CaptureLifecycleMachine()
    private var selectionSummary: CameraSelectionSummary?
    private var selectedFormat: CaptureFormatDescriptor?
    private var selectedCapabilities: CameraCapabilities?
    private var lockedControls: LockedCameraControls?
    private var torchStatus: TorchStatus = .off
    private var interruption: CaptureInterruption?
    private var observers: [NSObjectProtocol] = []
    private var torchObservation: NSKeyValueObservation?
    private var pressureObservation: NSKeyValueObservation?
    private var systemPressure: SystemPressureLevel = .unknown
    private var publishTimer: DispatchSourceTimer?

    // MARK: Cross-queue state

    private let timing = FrameTimingRecorder()
    /// Set from any thread; read on the processing queue. Guarded by its own
    /// lock because the analyzer is attached and detached from the MainActor
    /// while frames are already arriving.
    private let consumerLock = NSLock()
    private var frameConsumer: CaptureFrameConsuming?
    private let requirements: CaptureRequirements
    private let continuation: AsyncStream<CaptureSnapshot>.Continuation

    /// Rate limit for UI publishing. The camera runs at 30 fps; the UI needs
    /// roughly five updates a second.
    private static let publishInterval: DispatchTimeInterval = .milliseconds(200)

    /// Bounded waits. Without them a camera that never stops hunting for focus
    /// would hang the measurement instead of reporting poor capture quality.
    private static let warmUpTimeout: TimeInterval = 3.0
    private static let lockSettleTimeout: TimeInterval = 2.0

    let snapshots: AsyncStream<CaptureSnapshot>

    /// Portrait rotation for the rear camera. The app is orientation-locked to
    /// portrait, because a measurement needs a fixed optical path, so a single
    /// constant is correct here. If free rotation is ever allowed,
    /// `AVCaptureDevice.RotationCoordinator` replaces this.
    private static let portraitRotationAngle: CGFloat = 90

    override convenience init() {
        self.init(requirements: .measurement)
    }

    init(requirements: CaptureRequirements) {
        self.requirements = requirements
        // Only the newest snapshot matters; a slow consumer must not build a
        // backlog of stale camera state.
        let (stream, continuation) = AsyncStream<CaptureSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.snapshots = stream
        self.continuation = continuation
        super.init()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        torchObservation?.invalidate()
        pressureObservation?.invalidate()
        publishTimer?.cancel()
        continuation.finish()
    }

    /// Safe from any thread: the recorder has its own lock.
    func resetFrameStatistics() {
        timing.reset()
    }

    func setFrameConsumer(_ consumer: CaptureFrameConsuming?) {
        consumerLock.lock()
        frameConsumer = consumer
        consumerLock.unlock()
    }

    /// Read from the MainActor to build the preview layer. `AVCaptureSession`
    /// is safe to hand to `AVCaptureVideoPreviewLayer` from another thread;
    /// its configuration still only happens on `sessionQueue`.
    var previewSession: AVCaptureSession? { session }

    // MARK: - Queue bridging

    private func onSessionQueue<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Named separately from the throwing variant so a call site can never be
    /// ambiguous between the two overloads.
    private func readOnSessionQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Prepare

    func prepare() async throws -> CameraSelectionSummary {
        try await onSessionQueue { [self] in
            guard lifecycle.apply(.prepareRequested) else {
                // Already prepared or running. Re-preparing would add a second
                // input to the session.
                if let summary = selectionSummary { return summary }
                throw CameraError.sessionNotConfigured
            }

            // Configured by an earlier run and then stopped. The session keeps
            // its input, output and active format across a stop, so repeating
            // discovery and format selection would cost a second and change
            // nothing — and it would reset the timing the caller may still be
            // reading.
            if let summary = selectionSummary, deviceInput != nil {
                lifecycle.apply(.prepareSucceeded)
                publishSnapshot()
                return summary
            }

            do {
                let summary = try configureSession()
                lifecycle.apply(.prepareSucceeded)
                selectionSummary = summary
                publishSnapshot()
                return summary
            } catch let error as CameraError {
                lifecycle.apply(.failed(error))
                publishSnapshot()
                throw error
            } catch {
                let wrapped = CameraError.configurationFailed(error.localizedDescription)
                lifecycle.apply(.failed(wrapped))
                publishSnapshot()
                throw wrapped
            }
        }
    }

    /// - Important: runs on `sessionQueue`.
    private func configureSession() throws -> CameraSelectionSummary {
        // Enumerated once: a second discovery pass would repeat the work and
        // leave a window in which the device list could change underneath us.
        let devices = CameraCapabilityReporter.discoverRearCameras()
        guard !devices.isEmpty else {
            throw CameraError.noSuitableCamera(reasons: ["this iPhone reports no rear camera"])
        }

        let cameras = devices.map(CameraCapabilityReporter.capabilities(for:))
        let outcome = CameraSelector(requirements: requirements).select(from: cameras)
        guard let selection = outcome.selection else {
            throw CameraError.noSuitableCamera(
                reasons: outcome.rejections.map { "\($0.cameraName): \($0.reason)" }
            )
        }

        guard let chosenDevice = devices
            .first(where: { $0.uniqueID == selection.capabilities.uniqueID }) else {
            throw CameraError.noSuitableCamera(reasons: ["the selected camera disappeared during setup"])
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: chosenDevice)
        } catch {
            throw CameraError.cannotAddInput(error.localizedDescription)
        }

        session.beginConfiguration()
        var committed = false
        defer {
            if !committed { session.commitConfiguration() }
        }

        // Setting the active format explicitly puts the session into input
        // priority, which is what we want: the system must not substitute a
        // different format behind a preset.
        session.sessionPreset = .inputPriority

        if let existing = deviceInput {
            session.removeInput(existing)
            deviceInput = nil
        }
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput("the session refused the selected camera")
        }
        session.addInput(input)
        deviceInput = input
        device = chosenDevice

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: selection.format.pixelFormat
        ]
        // Analysis must always work on the newest frame. A backlog would make
        // every timestamp stale and every motion estimate wrong.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        if !session.outputs.contains(videoOutput) {
            guard session.canAddOutput(videoOutput) else {
                throw CameraError.cannotAddOutput("the session refused the video output")
            }
            session.addOutput(videoOutput)
        }

        try applyFormat(selection.format, frameRate: selection.frameRate, to: chosenDevice)

        for connection in videoOutput.connections {
            if connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) {
                connection.videoRotationAngle = Self.portraitRotationAngle
            }
            // Stabilisation warps pixels between frames, which would be read as
            // particle motion.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }

        session.commitConfiguration()
        committed = true

        installObservers(for: chosenDevice)
        // The previous run's lock record belongs to a different configuration.
        lockedControls = nil
        selectedFormat = selection.format
        selectedCapabilities = selection.capabilities
        timing.reset()

        return CameraSelectionSummary(
            cameraName: selection.capabilities.localizedName,
            deviceType: selection.capabilities.deviceTypeRawValue,
            uniqueID: selection.capabilities.uniqueID,
            isVirtualDevice: selection.capabilities.isVirtualDevice,
            minimumFocusDistanceMillimetres: selection.capabilities.minimumFocusDistanceMillimetres,
            resolution: selection.format.resolutionText,
            pixelFormat: selection.format.pixelFormatText,
            frameRate: selection.frameRate,
            rationale: selection.rationale,
            warnings: selection.warnings,
            rejectedCameras: outcome.rejections
        )
    }

    /// - Important: runs on `sessionQueue`, inside `beginConfiguration()`.
    private func applyFormat(_ descriptor: CaptureFormatDescriptor,
                             frameRate: Double,
                             to device: AVCaptureDevice) throws {
        guard descriptor.id < device.formats.count else {
            throw CameraError.configurationFailed("the chosen format is no longer available")
        }

        do {
            try device.lockForConfiguration()
        } catch {
            throw CameraError.configurationFailed(error.localizedDescription)
        }
        defer { device.unlockForConfiguration() }

        device.activeFormat = device.formats[descriptor.id]

        // Pin both bounds so the camera cannot drift to a variable frame rate.
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        // HDR applies a scene-dependent tone curve, breaking any fixed relation
        // between pixel value and scattered light.
        if device.activeFormat.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
    }

    // MARK: - Start and stop

    func start() async throws {
        try await onSessionQueue { [self] in
            guard lifecycle.apply(.startRequested) else { return }
            session.startRunning()
            guard session.isRunning else {
                let error = CameraError.sessionRuntimeError("the capture session refused to start")
                lifecycle.apply(.failed(error))
                publishSnapshot()
                throw error
            }
            lifecycle.apply(.startSucceeded)
            startPublishing()
            publishSnapshot()
        }
    }

    func stop() async {
        await readOnSessionQueue { [self] in
            // Turn the torch off first and unconditionally: it must not survive
            // a failure anywhere else in teardown.
            turnTorchOffIgnoringErrors()

            guard lifecycle.apply(.stopRequested) else {
                stopPublishing()
                publishSnapshot()
                return
            }

            if session.isRunning {
                session.stopRunning()
            }
            stopPublishing()
            lifecycle.apply(.stopFinished)
            publishSnapshot()
        }
    }

    // MARK: - Torch

    @discardableResult
    func setTorch(on: Bool) async throws -> TorchStatus {
        try await onSessionQueue { [self] in
            guard let device else { throw CameraError.sessionNotConfigured }

            guard device.hasTorch else {
                throw CameraError.torchUnavailable("this camera has no torch")
            }
            guard device.isTorchModeSupported(on ? .on : .off) else {
                throw CameraError.torchUnavailable("the torch does not support this mode")
            }
            guard !on || device.isTorchAvailable else {
                throw CameraError.torchUnavailable("the torch is unavailable, usually because the iPhone is too warm")
            }

            let requested = on ? AVCaptureDevice.maxAvailableTorchLevel : 0

            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.torchUnavailable(error.localizedDescription)
            }
            defer { device.unlockForConfiguration() }

            if on {
                do {
                    // maxAvailableTorchLevel is the maximum available *now*.
                    // Under thermal duress it is below 1.0, so the delivered
                    // level is read back rather than assumed.
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } catch {
                    throw CameraError.torchUnavailable(error.localizedDescription)
                }
            } else {
                device.torchMode = .off
            }

            let status = TorchStatus(
                isAvailable: device.isTorchAvailable,
                isActive: device.isTorchActive,
                level: device.isTorchActive ? device.torchLevel : 0,
                requestedLevel: requested
            )
            torchStatus = status
            publishSnapshot()

            if on && !status.deliveredRequestedLevel {
                LucidLog.camera.notice("Torch active but below the requested level; the device is limiting output.")
            }
            return status
        }
    }

    /// - Important: runs on `sessionQueue`.
    private func turnTorchOffIgnoringErrors() {
        guard let device, device.hasTorch, device.torchMode != .off else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = .off
        } catch {
            LucidLog.camera.error("Could not turn the torch off: \(String(describing: error), privacy: .public)")
        }
        torchStatus = .off
    }

    // MARK: - Warm up and lock

    @discardableResult
    func warmUp() async throws -> Bool {
        try await beginContinuousControls()

        // Let the camera settle before reading anything. Locking mid-adjustment
        // would freeze focus and exposure at a transient value.
        let settled = await waitForControlsToSettle(timeout: Self.warmUpTimeout)
        if !settled {
            LucidLog.camera.notice("Camera controls did not settle within the warm-up window.")
        }
        return settled
    }

    func lockControls() async throws -> LockedCameraControls {
        let locked = try await applyControlLocks()

        // Locking moves the lens and re-times the sensor; wait for that to
        // finish before the caller treats the optical path as fixed.
        _ = await waitForControlsToSettle(timeout: Self.lockSettleTimeout)

        return try await onSessionQueue { [self] in
            guard let device else { throw CameraError.sessionNotConfigured }
            let confirmed = LockedCameraControls(
                lensPosition: device.lensPosition,
                exposureSeconds: CMTimeGetSeconds(device.exposureDuration),
                iso: device.iso,
                whiteBalanceGains: WhiteBalanceGains(device.deviceWhiteBalanceGains),
                focusModeDescription: Self.describe(focusMode: device.focusMode),
                exposureModeDescription: Self.describe(exposureMode: device.exposureMode),
                whiteBalanceModeDescription: Self.describe(whiteBalanceMode: device.whiteBalanceMode),
                clampNotes: locked.clampNotes,
                lockedAt: Date()
            )

            guard device.focusMode == .locked,
                  device.exposureMode == .locked || device.exposureMode == .custom,
                  device.whiteBalanceMode == .locked else {
                throw CameraError.controlLockFailed("the camera did not stay locked")
            }

            lockedControls = confirmed
            publishSnapshot()
            return confirmed
        }
    }

    private func beginContinuousControls() async throws {
        try await onSessionQueue { [self] in
            guard let device else { throw CameraError.sessionNotConfigured }

            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.controlLockFailed(error.localizedDescription)
            }
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                // The sample sits centimetres away; searching to infinity wastes
                // warm-up time and can settle on the container wall.
                device.autoFocusRangeRestriction = .near
            }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    /// Polls the device's own adjustment flags.
    ///
    /// Polling rather than awaiting the lock APIs' completion handlers: a
    /// checked continuation that a callback never resumes would hang the
    /// measurement, and every one of these calls has a documented "is
    /// adjusting" flag that answers the same question with a bounded wait.
    private func waitForControlsToSettle(timeout: TimeInterval) async -> Bool {
        let pollInterval = Duration.milliseconds(50)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let stillAdjusting = await readOnSessionQueue { [self] () -> Bool in
                guard let device else { return false }
                return device.isAdjustingFocus
                    || device.isAdjustingExposure
                    || device.isAdjustingWhiteBalance
            }
            if !stillAdjusting { return true }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        return false
    }

    private func applyControlLocks() async throws -> CameraControlLockPlan {
        try await onSessionQueue { [self] in
            guard let device,
                  let format = selectedFormat,
                  let capabilities = selectedCapabilities else {
                throw CameraError.sessionNotConfigured
            }

            let observed = ObservedCameraControls(
                lensPosition: device.lensPosition,
                exposureSeconds: CMTimeGetSeconds(device.exposureDuration),
                iso: device.iso,
                whiteBalanceGains: WhiteBalanceGains(device.deviceWhiteBalanceGains),
                focusIsSharp: !device.isAdjustingFocus
            )
            let plan = CameraControlLockPlanner.plan(observed: observed,
                                                     format: format,
                                                     capabilities: capabilities)

            do {
                try device.lockForConfiguration()
            } catch {
                throw CameraError.controlLockFailed(error.localizedDescription)
            }
            defer { device.unlockForConfiguration() }

            // Focus: lock at the position the camera actually reached. Forcing
            // an arbitrary lens position without measuring sharpness would put
            // the sample volume out of focus.
            if let lensPosition = plan.lensPosition,
               device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
            } else if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            } else {
                throw CameraError.controlLockFailed("this camera cannot lock focus")
            }

            if device.isExposureModeSupported(.custom) {
                let duration = CMTime(seconds: plan.exposureSeconds, preferredTimescale: 1_000_000)
                device.setExposureModeCustom(duration: duration,
                                             iso: plan.iso,
                                             completionHandler: nil)
            } else if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            } else {
                throw CameraError.controlLockFailed("this camera cannot lock exposure")
            }

            if let gains = plan.whiteBalanceGains,
               device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                device.setWhiteBalanceModeLocked(with: gains.deviceGains, completionHandler: nil)
            } else if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            } else {
                throw CameraError.controlLockFailed("this camera cannot lock white balance")
            }

            return plan
        }
    }

    // MARK: - Snapshots

    func currentSnapshot() async -> CaptureSnapshot {
        await readOnSessionQueue { [self] in makeSnapshot() }
    }

    /// - Important: runs on `sessionQueue`.
    private func makeSnapshot() -> CaptureSnapshot {
        CaptureSnapshot(
            runState: lifecycle.state,
            selection: selectionSummary,
            torch: torchStatus,
            lockedControls: lockedControls,
            timing: timing.statistics(),
            thermal: ThermalStatus(ProcessInfo.processInfo.thermalState),
            systemPressure: systemPressure,
            interruption: interruption
        )
    }

    /// - Important: runs on `sessionQueue`.
    private func publishSnapshot() {
        continuation.yield(makeSnapshot())
    }

    /// - Important: runs on `sessionQueue`.
    private func startPublishing() {
        stopPublishing()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.publishInterval,
                       repeating: Self.publishInterval)
        timer.setEventHandler { [weak self] in
            self?.publishSnapshot()
        }
        timer.resume()
        publishTimer = timer
    }

    /// - Important: runs on `sessionQueue`.
    private func stopPublishing() {
        publishTimer?.cancel()
        publishTimer = nil
    }

    // MARK: - Observers

    /// - Important: runs on `sessionQueue`.
    private func installObservers(for device: AVCaptureDevice) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        torchObservation?.invalidate()
        pressureObservation?.invalidate()

        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil
        ) { [weak self] note in
            let description = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                .localizedDescription ?? "unknown capture error"
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                LucidLog.camera.error("Capture runtime error: \(description, privacy: .public)")
                turnTorchOffIgnoringErrors()
                lifecycle.apply(.failed(.sessionRuntimeError(description)))
                publishSnapshot()
            }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil
        ) { [weak self] note in
            let reasonValue = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let description = Self.describeInterruption(reasonValue)
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                turnTorchOffIgnoringErrors()
                interruption = CaptureInterruption(reasonDescription: description, isActive: true)
                publishSnapshot()
            }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                interruption = interruption.map {
                    CaptureInterruption(reasonDescription: $0.reasonDescription, isActive: false)
                }
                publishSnapshot()
            }
        })

        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                self?.publishSnapshot()
            }
        })

        // The torch becomes unavailable under thermal load without any error
        // from the call that turned it on.
        torchObservation = device.observe(\.isTorchAvailable, options: [.new]) { [weak self] device, _ in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                torchStatus = TorchStatus(
                    isAvailable: device.isTorchAvailable,
                    isActive: device.isTorchActive,
                    level: device.isTorchActive ? device.torchLevel : 0,
                    requestedLevel: torchStatus.requestedLevel
                )
                publishSnapshot()
            }
        }

        pressureObservation = device.observe(\.systemPressureState, options: [.new, .initial]) { [weak self] device, _ in
            let level = SystemPressureLevel(device.systemPressureState.level)
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                systemPressure = level
                if !level.permitsMeasurement {
                    LucidLog.camera.notice("System pressure \(level.rawValue, privacy: .public); capture is being throttled.")
                }
                publishSnapshot()
            }
        }
    }

    // MARK: - Descriptions

    private static func describeInterruption(_ rawValue: Int?) -> String {
        guard let rawValue,
              let reason = AVCaptureSession.InterruptionReason(rawValue: rawValue) else {
            return "the camera was interrupted"
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return "the camera is not available while Lucid is in the background"
        case .audioDeviceInUseByAnotherClient:
            return "the microphone is in use by another app"
        case .videoDeviceInUseByAnotherClient:
            return "the camera is in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "the camera is not available in Split View or Slide Over"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "the camera is unavailable because the iPhone is too warm"
        @unknown default:
            return "the camera was interrupted"
        }
    }

    private static func describe(focusMode: AVCaptureDevice.FocusMode) -> String {
        switch focusMode {
        case .locked: return "locked"
        case .autoFocus: return "auto"
        case .continuousAutoFocus: return "continuous"
        @unknown default: return "unknown"
        }
    }

    private static func describe(exposureMode: AVCaptureDevice.ExposureMode) -> String {
        switch exposureMode {
        case .locked: return "locked"
        case .autoExpose: return "auto"
        case .continuousAutoExposure: return "continuous"
        case .custom: return "custom"
        @unknown default: return "unknown"
        }
    }

    private static func describe(whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch whiteBalanceMode {
        case .locked: return "locked"
        case .autoWhiteBalance: return "auto"
        case .continuousAutoWhiteBalance: return "continuous"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Sample buffers

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Runs on `processingQueue`.
    ///
    /// The sample buffer does not escape this method: the consumer is handed
    /// the pixel buffer for the duration of the call and nothing longer.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentation.isValid && presentation.isNumeric else { return }
        let seconds = CMTimeGetSeconds(presentation)
        timing.record(presentationSeconds: seconds)

        consumerLock.lock()
        let consumer = frameConsumer
        consumerLock.unlock()

        guard let consumer, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        consumer.consume(pixelBuffer: pixelBuffer, presentationSeconds: seconds)
    }

    /// Runs on `processingQueue`.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        timing.recordDrop()
    }
}

// MARK: - AVFoundation bridging

extension WhiteBalanceGains {
    init(_ gains: AVCaptureDevice.WhiteBalanceGains) {
        self.init(red: gains.redGain, green: gains.greenGain, blue: gains.blueGain)
    }

    var deviceGains: AVCaptureDevice.WhiteBalanceGains {
        AVCaptureDevice.WhiteBalanceGains(redGain: red, greenGain: green, blueGain: blue)
    }
}

extension ThermalStatus {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

extension SystemPressureLevel {
    init(_ level: AVCaptureDevice.SystemPressureState.Level) {
        switch level {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        case .shutdown: self = .shutdown
        default: self = .unknown
        }
    }
}
