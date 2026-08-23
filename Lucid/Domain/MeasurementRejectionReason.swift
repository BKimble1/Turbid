import Foundation

/// An extensible, string-backed reason why a measurement window was rejected.
///
/// Each constant is produced by exactly one gate in `FrameQualityEvaluator`,
/// and every one of them has a test that makes it fire.
struct MeasurementRejectionReason: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

extension MeasurementRejectionReason {
    // Illumination and level
    static let saturatedRegion = MeasurementRejectionReason(rawValue: "quality.saturatedRegion")
    static let torchHotspot = MeasurementRejectionReason(rawValue: "quality.torchHotspot")
    static let regionTooDark = MeasurementRejectionReason(rawValue: "quality.regionTooDark")
    static let regionTooBright = MeasurementRejectionReason(rawValue: "quality.regionTooBright")

    // Optics
    static let outOfFocus = MeasurementRejectionReason(rawValue: "quality.outOfFocus")
    static let cameraMoved = MeasurementRejectionReason(rawValue: "quality.cameraMoved")

    // Capture stability
    static let exposureUnstable = MeasurementRejectionReason(rawValue: "quality.exposureUnstable")
    static let controlsUnlocked = MeasurementRejectionReason(rawValue: "quality.controlsUnlocked")

    // Frame delivery
    static let insufficientUsableFrames = MeasurementRejectionReason(rawValue: "quality.insufficientUsableFrames")
    static let excessiveDroppedFrames = MeasurementRejectionReason(rawValue: "quality.excessiveDroppedFrames")
    static let frameDeliveryDiscontinuous = MeasurementRejectionReason(rawValue: "quality.frameDeliveryDiscontinuous")

    // Device
    static let thermalLimit = MeasurementRejectionReason(rawValue: "quality.thermalLimit")
    static let systemPressure = MeasurementRejectionReason(rawValue: "quality.systemPressure")

    // Supplied by later phases
    static let backgroundModelUnstable = MeasurementRejectionReason(rawValue: "quality.backgroundModelUnstable")
    static let calibrationProfileMismatch = MeasurementRejectionReason(rawValue: "quality.calibrationProfileMismatch")

    /// Plain-language text for the UI. Kept beside the constants so a new
    /// reason cannot be added without deciding what the user is told.
    var explanation: String {
        switch self {
        case .saturatedRegion:
            return "Part of the sample is too bright to measure. Reduce glare or move the phone back."
        case .torchHotspot:
            return "The torch is reflecting off the container into the analysis area."
        case .regionTooDark:
            return "The sample is too dark. Check that the torch is on and the sample is in view."
        case .regionTooBright:
            return "The sample is too bright. Move the phone slightly further away."
        case .outOfFocus:
            return "The sample is not in focus."
        case .cameraMoved:
            return "The phone moved during the measurement. Keep it still."
        case .exposureUnstable:
            return "The camera brightness kept changing during the measurement."
        case .controlsUnlocked:
            return "Focus, exposure or white balance came unlocked during the measurement."
        case .insufficientUsableFrames:
            return "Too few usable frames were captured."
        case .excessiveDroppedFrames:
            return "Too many frames were dropped to trust the result."
        case .frameDeliveryDiscontinuous:
            return "Video stalled during the measurement."
        case .thermalLimit:
            return "The iPhone is too warm for a reliable measurement."
        case .systemPressure:
            return "The system throttled the camera during the measurement."
        case .backgroundModelUnstable:
            return "The stationary background never settled."
        case .calibrationProfileMismatch:
            return "The current setup does not match the loaded calibration."
        default:
            return rawValue
        }
    }
}
