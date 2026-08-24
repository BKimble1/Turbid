import Foundation

/// Scripted `CameraAuthorizing` for unit tests, SwiftUI previews and the
/// Simulator demo state. It performs no hardware access of any kind.
actor StubCameraAuthorizationService: CameraAuthorizing {
    private var status: CameraAuthorization
    private let statusAfterRequest: CameraAuthorization

    /// Number of times the (simulated) system prompt was raised. Used by tests
    /// to prove the prompt is never raised twice.
    private(set) var requestCount = 0

    init(initialStatus: CameraAuthorization,
         statusAfterRequest: CameraAuthorization? = nil) {
        self.status = initialStatus
        self.statusAfterRequest = statusAfterRequest ?? initialStatus
    }

    func currentStatus() async -> CameraAuthorization {
        status
    }

    func requestAccess() async -> CameraAuthorization {
        guard status.canRequestSystemPrompt else { return status }
        requestCount += 1
        status = statusAfterRequest
        return status
    }

    /// Simulates the user changing the setting outside the app.
    func overrideStatus(_ newStatus: CameraAuthorization) {
        status = newStatus
    }
}
