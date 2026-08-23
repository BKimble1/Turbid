import Foundation

/// A recoverable, user-presentable failure of the measurement session.
struct MeasurementFailure: Equatable, Sendable {
    enum Code: String, Equatable, Sendable {
        case cameraPermissionDenied
        case cameraPermissionRestricted
        /// The frame analyzer is not part of this build. Removed in Phase 3A.
        case analysisUnavailableInThisBuild
        case cameraUnavailable
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
    /// Phase 2 stops here on purpose, once the hardware has been exercised.
    /// The frame analyzer replaces this in Phase 3A.
    static let analysisUnavailableInThisBuild = MeasurementFailure(
        code: .analysisUnavailableInThisBuild,
        message: "Frame analysis is not part of this build.",
        recoverySuggestion: "The camera, torch and control locks all worked. Particle detection is added in Phase 3."
    )

    static func cameraUnavailable(_ error: CameraError) -> MeasurementFailure {
        MeasurementFailure(
            code: .cameraUnavailable,
            message: error.message,
            recoverySuggestion: error.recoverySuggestion
        )
    }
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
