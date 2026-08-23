import Foundation

/// Everything about one physical camera that matters to a measurement,
/// captured as plain values.
///
/// This is built by probing the actual device rather than by consulting a list
/// of iPhone model names: what a given camera can do varies by model, by iOS
/// version and by thermal state, and a name lookup cannot know any of that.
struct CameraCapabilities: Equatable, Sendable, Identifiable {
    var id: String { uniqueID }

    let uniqueID: String
    let localizedName: String
    let deviceTypeRawValue: String
    let modelID: String

    /// A virtual device silently switches between constituent cameras, which
    /// changes the optical path mid-measurement. Recorded so it can be avoided.
    let isVirtualDevice: Bool
    let constituentDeviceTypes: [String]

    /// Millimetres. `nil` when the device does not report it (`-1`).
    let minimumFocusDistanceMillimetres: Int?

    let supportsContinuousAutoFocus: Bool
    let supportsAutoFocus: Bool
    let supportsLockedFocus: Bool
    let supportsCustomLensPositionLock: Bool
    let supportsNearFocusRangeRestriction: Bool

    let hasTorch: Bool
    let supportsTorchOnMode: Bool

    let supportsContinuousAutoExposure: Bool
    let supportsLockedExposure: Bool
    let supportsCustomExposure: Bool

    let supportsContinuousAutoWhiteBalance: Bool
    let supportsLockedWhiteBalance: Bool
    let supportsCustomWhiteBalanceGainsLock: Bool
    let maxWhiteBalanceGain: Float

    let formats: [CaptureFormatDescriptor]

    /// The torch is the illumination source; without it there is nothing to
    /// scatter and no measurement to make.
    var canIlluminate: Bool { hasTorch && supportsTorchOnMode }

    /// Every control must hold still for the whole measurement window.
    var canLockAllControls: Bool {
        supportsLockedFocus
            && (supportsLockedExposure || supportsCustomExposure)
            && supportsLockedWhiteBalance
    }
}
