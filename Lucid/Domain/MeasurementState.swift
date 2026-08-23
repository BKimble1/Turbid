import Foundation

/// The explicit measurement session state. Modelled as one value so the UI never
/// has to reconstruct session status from a scatter of Boolean flags.
enum MeasurementState: Equatable, Sendable {
    case idle
    case requestingPermission
    case permissionDenied
    case permissionRestricted
    case preparingCamera
    case alignment
    case warmingUp
    case lockingControls
    case acquiringBackground
    case measuring
    case calculating
    case result

    case lowQuality(reasons: [MeasurementRejectionReason])
    case interrupted(MeasurementInterruption)
    case thermalLimited
    case unsupportedHardware(reason: String)
    case failed(MeasurementFailure)

    /// States in which the capture session and torch may be powered.
    ///
    /// This is the single predicate Phase 2 uses to decide whether leaving the
    /// screen, backgrounding the app or an error must tear down the hardware.
    /// `calculating` is included deliberately: it is safer to issue a redundant
    /// shutdown than to leave the torch on.
    var usesCaptureHardware: Bool {
        switch self {
        case .preparingCamera, .alignment, .warmingUp, .lockingControls,
             .acquiringBackground, .measuring, .calculating:
            return true
        case .idle, .requestingPermission, .permissionDenied, .permissionRestricted,
             .result, .lowQuality, .interrupted, .thermalLimited,
             .unsupportedHardware, .failed:
            return false
        }
    }

    /// States during which capture-quality gates may reject the window.
    var acceptsQualityRejection: Bool {
        switch self {
        case .warmingUp, .lockingControls, .acquiringBackground, .measuring, .calculating:
            return true
        default:
            return false
        }
    }

    /// `true` when the user can restart the flow from this state.
    var isRestartable: Bool {
        switch self {
        case .idle, .permissionDenied, .permissionRestricted, .result,
             .lowQuality, .thermalLimited, .unsupportedHardware, .failed:
            return true
        case .requestingPermission, .preparingCamera, .alignment, .warmingUp,
             .lockingControls, .acquiringBackground, .measuring, .calculating,
             .interrupted:
            return false
        }
    }
}
