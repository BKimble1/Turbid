import Foundation

/// White-balance gains as plain floats, so the clamping maths can be tested
/// without an `AVCaptureDevice`.
struct WhiteBalanceGains: Equatable, Sendable, Codable {
    let red: Float
    let green: Float
    let blue: Float

    init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// What the camera reported once it finished settling during warm-up.
struct ObservedCameraControls: Equatable, Sendable {
    let lensPosition: Float
    let exposureSeconds: Double
    let iso: Float
    let whiteBalanceGains: WhiteBalanceGains
    let focusIsSharp: Bool
}

/// The exact values that will be pushed back to the device to lock it.
struct CameraControlLockPlan: Equatable, Sendable {
    let lensPosition: Float?
    let exposureSeconds: Double
    let iso: Float
    let whiteBalanceGains: WhiteBalanceGains?
    /// Records every value that had to be clamped, so a measurement made with
    /// clamped settings can be recognised later.
    let clampNotes: [String]

    var requiredClamping: Bool { !clampNotes.isEmpty }
}

/// Clamps the settled camera values into the ranges the active format and the
/// device actually accept.
///
/// `AVCaptureDevice` raises an exception for an out-of-range exposure, ISO or
/// white-balance gain, so every value is clamped here first, in code that can be
/// tested against synthetic ranges.
enum CameraControlLockPlanner {

    /// The smallest legal white-balance gain. Device gains are relative to the
    /// green channel, which is fixed at 1.0.
    static let minimumWhiteBalanceGain: Float = 1.0

    static func plan(observed: ObservedCameraControls,
                     format: CaptureFormatDescriptor,
                     capabilities: CameraCapabilities) -> CameraControlLockPlan {
        var notes: [String] = []

        let exposure = clamp(Double(observed.exposureSeconds),
                             lower: format.minExposureSeconds,
                             upper: format.maxExposureSeconds)
        if exposure != observed.exposureSeconds {
            notes.append(String(format: "exposure clamped from %.5f s to %.5f s",
                                observed.exposureSeconds, exposure))
        }

        let iso = clamp(observed.iso, lower: format.minISO, upper: format.maxISO)
        if iso != observed.iso {
            notes.append(String(format: "ISO clamped from %.1f to %.1f", observed.iso, iso))
        }

        let lensPosition: Float?
        if capabilities.supportsCustomLensPositionLock {
            let position = clamp(observed.lensPosition, lower: 0, upper: 1)
            if position != observed.lensPosition {
                notes.append(String(format: "lens position clamped from %.3f to %.3f",
                                    observed.lensPosition, position))
            }
            lensPosition = position
        } else {
            // The device can only be told "lock where you are".
            lensPosition = nil
            notes.append("lens position cannot be set explicitly on this camera")
        }

        let gains: WhiteBalanceGains?
        if capabilities.supportsCustomWhiteBalanceGainsLock {
            let upper = max(minimumWhiteBalanceGain, capabilities.maxWhiteBalanceGain)
            let clamped = WhiteBalanceGains(
                red: clamp(observed.whiteBalanceGains.red, lower: minimumWhiteBalanceGain, upper: upper),
                green: clamp(observed.whiteBalanceGains.green, lower: minimumWhiteBalanceGain, upper: upper),
                blue: clamp(observed.whiteBalanceGains.blue, lower: minimumWhiteBalanceGain, upper: upper)
            )
            if clamped != observed.whiteBalanceGains {
                notes.append("white-balance gains clamped into the device's supported range")
            }
            gains = clamped
        } else {
            gains = nil
            notes.append("white-balance gains cannot be set explicitly on this camera")
        }

        return CameraControlLockPlan(lensPosition: lensPosition,
                                     exposureSeconds: exposure,
                                     iso: iso,
                                     whiteBalanceGains: gains,
                                     clampNotes: notes)
    }

    private static func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }
}

/// The values the device reported *after* locking. This is the record a
/// calibration profile binds to, so it is stored, not recomputed.
struct LockedCameraControls: Equatable, Sendable, Codable {
    let lensPosition: Float
    let exposureSeconds: Double
    let iso: Float
    let whiteBalanceGains: WhiteBalanceGains
    let focusModeDescription: String
    let exposureModeDescription: String
    let whiteBalanceModeDescription: String
    let clampNotes: [String]
    let lockedAt: Date
}
