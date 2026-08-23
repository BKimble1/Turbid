import Foundation

/// The torch as the device actually reports it, not as it was requested.
struct TorchStatus: Equatable, Sendable {
    let isAvailable: Bool
    let isActive: Bool
    /// The level the device reports right now.
    let level: Float
    /// The level that was asked for.
    let requestedLevel: Float

    static let off = TorchStatus(isAvailable: false, isActive: false, level: 0, requestedLevel: 0)

    /// The maximum available torch level drops under thermal duress, so a
    /// request for the maximum can succeed and still deliver less light than a
    /// calibration was made with.
    var deliveredRequestedLevel: Bool {
        isActive && level >= requestedLevel - 0.01
    }
}

enum ThermalStatus: String, Equatable, Sendable, CaseIterable {
    case nominal, fair, serious, critical, unknown

    /// Above `fair` the torch output and frame rate are no longer trustworthy.
    ///
    /// `unknown` permits: it means the state has not been read yet, not that
    /// something is wrong. A real device always reports one of the four
    /// concrete states, and a genuine problem shows up as `serious` or worse.
    var permitsMeasurement: Bool {
        switch self {
        case .nominal, .fair, .unknown: return true
        case .serious, .critical: return false
        }
    }

    var displayName: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Too hot"
        case .unknown: return "Unknown"
        }
    }
}

enum SystemPressureLevel: String, Equatable, Sendable, CaseIterable {
    case nominal, fair, serious, critical, shutdown, unknown

    /// `unknown` permits, for the same reason as `ThermalStatus`.
    var permitsMeasurement: Bool {
        switch self {
        case .nominal, .fair, .unknown: return true
        case .serious, .critical, .shutdown: return false
        }
    }
}

struct CaptureInterruption: Equatable, Sendable {
    let reasonDescription: String
    let isActive: Bool
}

/// A short summary of the selected camera, safe to publish to the MainActor.
struct CameraSelectionSummary: Equatable, Sendable {
    let cameraName: String
    let deviceType: String
    let uniqueID: String
    let isVirtualDevice: Bool
    let minimumFocusDistanceMillimetres: Int?
    let resolution: String
    let pixelFormat: String
    let frameRate: Double
    let rationale: [String]
    let warnings: [String]
    let rejectedCameras: [CameraRejection]

    var minimumFocusDistanceText: String {
        guard let distance = minimumFocusDistanceMillimetres else { return "not reported" }
        return "\(distance) mm"
    }
}

/// The immutable value the capture pipeline publishes to the UI.
///
/// Everything here is a value type: no `CMSampleBuffer`, no `CVPixelBuffer` and
/// no `AVCaptureDevice` crosses this boundary.
struct CaptureSnapshot: Equatable, Sendable {
    // `var` so a snapshot can be copied and adjusted; the type is still a
    // value, so a published copy can never be mutated by the publisher.
    var runState: CaptureRunState
    var selection: CameraSelectionSummary?
    var torch: TorchStatus
    var lockedControls: LockedCameraControls?
    var timing: FrameTimingStatistics
    var thermal: ThermalStatus
    var systemPressure: SystemPressureLevel
    var interruption: CaptureInterruption?

    static let idle = CaptureSnapshot(
        runState: .idle,
        selection: nil,
        torch: .off,
        lockedControls: nil,
        timing: .empty,
        thermal: .unknown,
        systemPressure: .unknown,
        interruption: nil
    )

    /// Hardware conditions under which a measurement must not be trusted.
    var hardwarePermitsMeasurement: Bool {
        thermal.permitsMeasurement
            && systemPressure.permitsMeasurement
            && interruption?.isActive != true
    }
}
