import Foundation

/// A recoverable, user-presentable failure of the measurement session.
struct MeasurementFailure: Equatable, Sendable {
    enum Code: String, Equatable, Sendable {
        case cameraPermissionDenied
        case cameraPermissionRestricted
        /// Frames stopped arriving before the measurement window finished.
        case frameDeliveryStopped
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
    /// The run is driven by frame presentation timestamps, so if frames stop
    /// arriving it would otherwise wait forever. The measurement is abandoned
    /// rather than completed from whatever arrived: a window that was never
    /// filled is not a shorter measurement, it is not a measurement.
    static let frameDeliveryStopped = MeasurementFailure(
        code: .frameDeliveryStopped,
        message: "The camera stopped delivering frames before the measurement finished.",
        recoverySuggestion: "Close other apps that use the camera, then try again."
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
