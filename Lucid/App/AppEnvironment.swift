import Foundation

/// The injected dependency container. Every service the app uses is reachable
/// from here, so the Simulator, previews and tests can substitute stand-ins.
struct AppEnvironment: Sendable {
    let cameraAuthorization: CameraAuthorizing
    let settingsOpener: SettingsOpening
    /// Whether illustrative sample data may be displayed at all.
    let allowsSimulatedData: Bool

    init(cameraAuthorization: CameraAuthorizing,
         settingsOpener: SettingsOpening,
         allowsSimulatedData: Bool) {
        self.cameraAuthorization = cameraAuthorization
        self.settingsOpener = settingsOpener
        self.allowsSimulatedData = allowsSimulatedData
    }

    /// The environment used by the shipping app.
    static func live() -> AppEnvironment {
        AppEnvironment(
            cameraAuthorization: SystemCameraAuthorizationService(),
            settingsOpener: SystemSettingsOpener(),
            allowsSimulatedData: RuntimeEnvironment.allowsSimulatedData
        )
    }
}
