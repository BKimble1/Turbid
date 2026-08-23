import Foundation

/// Failures the capture pipeline can report, each with copy a non-technical
/// user can act on.
enum CameraError: Error, Equatable, Sendable {
    case notAuthorized
    case noSuitableCamera(reasons: [String])
    case cannotAddInput(String)
    case cannotAddOutput(String)
    case configurationFailed(String)
    case torchUnavailable(String)
    case controlLockFailed(String)
    case sessionRuntimeError(String)
    case sessionNotConfigured

    var message: String {
        switch self {
        case .notAuthorized:
            return "Lucid does not have permission to use the camera."
        case .noSuitableCamera(let reasons):
            return reasons.isEmpty
                ? "No rear camera on this iPhone can run a measurement."
                : "No rear camera on this iPhone can run a measurement: "
                    + reasons.joined(separator: "; ") + "."
        case .cannotAddInput(let detail):
            return "The camera could not be connected to the capture session. \(detail)"
        case .cannotAddOutput(let detail):
            return "The video output could not be connected to the capture session. \(detail)"
        case .configurationFailed(let detail):
            return "The camera could not be configured. \(detail)"
        case .torchUnavailable(let detail):
            return "The torch could not be turned on. \(detail)"
        case .controlLockFailed(let detail):
            return "Focus, exposure or white balance could not be locked. \(detail)"
        case .sessionRuntimeError(let detail):
            return "The camera stopped unexpectedly. \(detail)"
        case .sessionNotConfigured:
            return "The camera has not been prepared yet."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAuthorized:
            return "Turn Camera on for Lucid in Settings."
        case .noSuitableCamera:
            return "Lucid needs a rear camera with a torch and lockable focus, exposure and white balance."
        case .torchUnavailable:
            return "Let the iPhone cool down and try again. The torch is unavailable while the device is too warm."
        case .controlLockFailed:
            return "Keep the phone still and make sure the sample is lit, then try again."
        case .sessionRuntimeError, .configurationFailed, .cannotAddInput, .cannotAddOutput:
            return "Close and reopen Lucid, then try again."
        case .sessionNotConfigured:
            return nil
        }
    }
}
