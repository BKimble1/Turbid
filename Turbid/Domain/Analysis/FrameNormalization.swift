import Foundation

/// How raw camera luma is turned into the values the analyzer works with.
///
/// ## Why no transfer function is inverted
///
/// A video buffer is the output of the camera's image-signal processor, not a
/// radiance measurement. Between the photons and the pixel sit demosaicing,
/// black-level subtraction, lens-shading correction, noise reduction, a
/// possibly scene-dependent tone curve, and an encoding transfer function whose
/// exact form Apple does not publish per device. Applying a nominal inverse
/// (sRGB, BT.709, or a fixed gamma) would produce numbers that *look* like
/// linear radiance while being wrong by an unknown, scene-dependent factor.
///
/// Turbid therefore treats the normalized value as a **repeatable relative
/// signal**, not as optical power. That is sufficient, because:
///
/// * the capture settings are locked, so the ISP is applied consistently
///   within and between measurements made under the same profile; and
/// * absolute meaning is supplied end-to-end by calibration against certified
///   turbidity standards (Phase 3D), which absorbs whatever fixed monotonic
///   transform the ISP applies.
///
/// The one thing this requires is **monotonicity**: more scattered light must
/// never produce a lower value. Clipping breaks that, which is why the
/// saturation gate is a hard rejection rather than a warning.
enum FrameNormalization {

    /// Code-range mapping for the two pixel formats the capture pipeline uses.
    enum LumaRange: Equatable, Sendable {
        /// `420f`: luma uses the whole 0...255 code range.
        case full
        /// `420v`: luma is limited to 16...235.
        case video

        var blackCode: Float {
            switch self {
            case .full: return 0
            case .video: return 16
            }
        }

        var whiteCode: Float {
            switch self {
            case .full: return 255
            case .video: return 235
            }
        }

        var scale: Float { 1 / (whiteCode - blackCode) }
    }

    /// Maps an 8-bit luma code to `0...1`, clamped.
    ///
    /// Clamping matters for video range: codes below 16 and above 235 are legal
    /// in the bitstream, and letting them through would put values outside
    /// `0...1` where the saturation gate could not see them.
    static func normalize(code: UInt8, range: LumaRange) -> Float {
        let value = (Float(code) - range.blackCode) * range.scale
        return min(max(value, 0), 1)
    }

    /// The value at or above which a sample is treated as clipped.
    ///
    /// Slightly below 1.0 because the ISP rarely emits the exact maximum code
    /// even when the sensor well is full, and a sample one code short of the
    /// ceiling has already lost its monotonic relationship to scattered light.
    static let saturationThreshold: Float = 0.98

    /// The value below which a sample carries essentially no signal.
    static let nearBlackThreshold: Float = 0.02

    /// Target long edge for the coarse statistics plane.
    ///
    /// Small on purpose. The coarse plane exists to measure *global* properties
    /// — mean level, flicker, whole-frame motion — and averaging away
    /// individual specks is exactly what makes the global-motion estimate
    /// respond to the camera rather than to the particles.
    static let coarsePlaneLongEdge = 64
}
