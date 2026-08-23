import Foundation

/// The injected dependency container. Every service the app uses is reachable
/// from here, so the Simulator, previews and tests can substitute stand-ins.
struct AppEnvironment: Sendable {
    let cameraAuthorization: CameraAuthorizing
    let camera: CameraControlling
    let settingsOpener: SettingsOpening
    /// Whether illustrative sample data may be displayed at all.
    let allowsSimulatedData: Bool

    init(cameraAuthorization: CameraAuthorizing,
         camera: CameraControlling,
         settingsOpener: SettingsOpening,
         allowsSimulatedData: Bool) {
        self.cameraAuthorization = cameraAuthorization
        self.camera = camera
        self.settingsOpener = settingsOpener
        self.allowsSimulatedData = allowsSimulatedData
    }

    /// The environment used by the shipping app.
    ///
    /// The Simulator has no camera or torch, so it gets the stub rather than a
    /// `CameraService` that would fail on every call. That substitution is tied
    /// to `RuntimeEnvironment.allowsSimulatedData`, which also requires a debug
    /// build, so a shipped binary always gets the real pipeline.
    static func live() -> AppEnvironment {
        let simulated = RuntimeEnvironment.allowsSimulatedData
        return AppEnvironment(
            cameraAuthorization: SystemCameraAuthorizationService(),
            camera: simulated ? StubCameraService() : CameraService(),
            settingsOpener: SystemSettingsOpener(),
            allowsSimulatedData: simulated
        )
    }
}
