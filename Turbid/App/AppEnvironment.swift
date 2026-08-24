import Foundation

/// The injected dependency container. Every service the app uses is reachable
/// from here, so the Simulator, previews and tests can substitute stand-ins.
struct AppEnvironment: Sendable {
    let cameraAuthorization: CameraAuthorizing
    let camera: CameraControlling
    let settingsOpener: SettingsOpening
    let disclosure: DisclosureRecording
    let calibrationStore: any CalibrationStoring
    /// Which way is up, for bubble rejection. Owned here rather than by the
    /// analyzer so it can be started when the camera starts: device motion
    /// takes a moment to produce its first sample, and a measurement that began
    /// before then would classify under an assumption instead of a measurement.
    let gravity: GravityProviding
    /// Builds the analysis pipeline for one run. A factory rather than a shared
    /// instance: each run gets a clean analyzer, and nothing from a previous
    /// measurement can survive into the next one.
    let makePipeline: @Sendable () -> MeasurementPipeline
    /// Which mode a fresh session starts in. Screening everywhere except a UI
    /// test that is specifically exercising the calibrated path.
    let initialMode: MeasurementMode
    /// Whether illustrative or simulated content may be displayed at all.
    let allowsSimulatedData: Bool

    init(cameraAuthorization: CameraAuthorizing,
         camera: CameraControlling,
         settingsOpener: SettingsOpening,
         disclosure: DisclosureRecording = InMemoryDisclosureRecorder(acknowledged: true),
         calibrationStore: any CalibrationStoring = InMemoryCalibrationStore(),
         gravity: GravityProviding = AssumedPortraitGravityProvider(),
         makePipeline: @escaping @Sendable () -> MeasurementPipeline = { MeasurementPipeline() },
         initialMode: MeasurementMode = .screening,
         allowsSimulatedData: Bool) {
        self.cameraAuthorization = cameraAuthorization
        self.camera = camera
        self.settingsOpener = settingsOpener
        self.disclosure = disclosure
        self.calibrationStore = calibrationStore
        self.gravity = gravity
        self.makePipeline = makePipeline
        self.initialMode = initialMode
        self.allowsSimulatedData = allowsSimulatedData
    }

    /// The environment used by the shipping app.
    ///
    /// The Simulator has no camera or torch, so it gets the stub driven by a
    /// synthetic frame source rather than a `CameraService` that would fail on
    /// every call. That substitution is tied to
    /// `RuntimeEnvironment.allowsSimulatedData`, which also requires a debug
    /// build, so a shipped binary always gets the real pipeline.
    static func live() -> AppEnvironment {
        let simulated = RuntimeEnvironment.allowsSimulatedData
        let camera: CameraControlling = simulated
            ? StubCameraService(summary: .simulatedFeed, frameSource: SimulatedFrameSource())
            : CameraService()

        // The measured provider, not the assumed one. Bubble rejection depends
        // on knowing how much of gravity lies in the image plane: with the
        // phone flat, a rising bubble barely moves in frame, and assuming
        // otherwise would report a confident direction that means nothing.
        let gravity = CoreMotionGravityProvider()

        return AppEnvironment(
            cameraAuthorization: SystemCameraAuthorizationService(),
            camera: camera,
            settingsOpener: SystemSettingsOpener(),
            disclosure: DefaultsDisclosureRecorder(),
            calibrationStore: Self.calibrationStore(),
            gravity: gravity,
            makePipeline: { MeasurementPipeline(analyzer: FrameAnalyzer(gravityProvider: gravity)) },
            allowsSimulatedData: simulated
        )
    }

    /// Falls back to memory when the support directory cannot be created.
    ///
    /// Losing calibrations on relaunch is bad; refusing to launch is worse, and
    /// the calibration screen reports the failure rather than hiding it.
    private static func calibrationStore() -> any CalibrationStoring {
        do {
            return FileCalibrationStore(url: try FileCalibrationStore.defaultURL())
        } catch {
            TurbidLog.calibration.error("Calibration storage is unavailable; using memory only.")
            return InMemoryCalibrationStore()
        }
    }
}
