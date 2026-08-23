import CoreVideo
import Foundation

/// A capture format described as plain values.
///
/// Format choice is measurement-critical and must be deterministic, so it is
/// modelled as data that can be constructed in a test rather than read from an
/// `AVCaptureDevice.Format` that only exists on real hardware.
struct CaptureFormatDescriptor: Equatable, Sendable, Identifiable {
    /// Index of this format in the device's `formats` array. Used to re-select
    /// the exact same format on the device after it has been chosen.
    let id: Int
    let width: Int
    let height: Int
    /// CoreVideo pixel format of the format's media subtype.
    let pixelFormat: OSType
    let minFrameRate: Double
    let maxFrameRate: Double
    let minISO: Float
    let maxISO: Float
    let minExposureSeconds: Double
    let maxExposureSeconds: Double
    let fieldOfViewDegrees: Float
    let supportsVideoHDR: Bool
    let isBinned: Bool
    /// Stabilisation moves pixels between frames, which corrupts a scattering
    /// measurement. Recorded so a format that forces it can be scored down.
    let supportsCinematicStabilization: Bool

    var pixelCount: Int { width * height }

    func supports(frameRate: Double) -> Bool {
        frameRate >= minFrameRate - 0.001 && frameRate <= maxFrameRate + 0.001
    }

    var resolutionText: String { "\(width)x\(height)" }

    var pixelFormatText: String { CaptureFormatDescriptor.fourCharacterCode(pixelFormat) }

    /// Renders a CoreVideo pixel format as its four-character code, e.g. "420f".
    static func fourCharacterCode(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        let characters = bytes.map { byte -> Character in
            let scalar = UnicodeScalar(byte)
            return scalar.isASCII && byte >= 32 && byte < 127 ? Character(scalar) : "?"
        }
        return String(characters)
    }
}

/// Pixel formats the analyzer can consume without a wasteful conversion.
///
/// Both are bi-planar 8-bit YUV, so the luma plane can be read directly. Full
/// range is preferred because it uses the whole 0-255 code range, which keeps
/// one extra stop of headroom before the bright specks clip.
enum MeasurementPixelFormat {
    static let fullRangeYUV = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let videoRangeYUV = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// In descending order of preference.
    static let preferred: [OSType] = [fullRangeYUV, videoRangeYUV]
}
