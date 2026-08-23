import Foundation

/// Camera authorization, behind a protocol so the app's permission logic can be
/// tested without the system prompt (which cannot be driven from a unit test).
protocol CameraAuthorizing: Sendable {
    /// Reads the current status. Must never raise the system prompt.
    func currentStatus() async -> CameraAuthorization

    /// Raises the system prompt only when the status is still undecided;
    /// otherwise returns the existing status unchanged.
    func requestAccess() async -> CameraAuthorization
}
