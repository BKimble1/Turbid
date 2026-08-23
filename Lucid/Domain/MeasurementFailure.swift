import Foundation

/// A recoverable, user-presentable failure of the measurement session.
struct MeasurementFailure: Equatable, Sendable {
    enum Code: String, Equatable, Sendable {
        case cameraPermissionDenied
        case cameraPermissionRestricted
        /// The capture pipeline is not part of this build. Removed in Phase 2.
        case captureUnavailableInThisBuild
        case captureConfigurationFailed
    }

    let code: Code
    let message: String
    let recoverySuggestion: String?

    init(code: Code, message: String, recoverySuggestion: String? = nil) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

extension MeasurementFailure {
    /// Phase 1 stops here on purpose. `CameraService` replaces this in Phase 2.
    static let captureUnavailableInThisBuild = MeasurementFailure(
        code: .captureUnavailableInThisBuild,
        message: "Live capture is not part of this build.",
        recoverySuggestion: "The AVFoundation camera and torch pipeline is added in Phase 2. Camera permission has been verified and stored."
    )
}

/// Why an in-progress measurement was interrupted.
enum MeasurementInterruption: String, Equatable, Sendable, CaseIterable {
    case appBackgrounded
    case sessionInterrupted
    case permissionRevoked
    case mediaServicesReset

    var message: String {
        switch self {
        case .appBackgrounded:
            return "Measurement stopped because Lucid left the foreground."
        case .sessionInterrupted:
            return "The camera session was interrupted by the system."
        case .permissionRevoked:
            return "Camera access was turned off for Lucid."
        case .mediaServicesReset:
            return "The system reset media services."
        }
    }
}
