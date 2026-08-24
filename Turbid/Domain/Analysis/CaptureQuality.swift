import Foundation

/// The verdict on a measurement window.
///
/// Three states, not two. "Low confidence" and "invalid" are different things:
/// a low-confidence window produced a number that is probably right but should
/// be trusted less, while an invalid window produced no number at all. Merging
/// them would either discard usable measurements or let unusable ones through.
enum CaptureQualityVerdict: Equatable, Sendable {
    case usable
    case usableWithLowConfidence(notes: [MeasurementRejectionReason])
    case invalid(reasons: [MeasurementRejectionReason])

    var isUsable: Bool {
        switch self {
        case .usable, .usableWithLowConfidence: return true
        case .invalid: return false
        }
    }

    var reasons: [MeasurementRejectionReason] {
        switch self {
        case .usable: return []
        case .usableWithLowConfidence(let notes): return notes
        case .invalid(let reasons): return reasons
        }
    }
}

/// Everything known about how good a measurement window's capture was.
///
/// Published as one value so a result can never be shown without the evidence
/// that justifies it.
struct CaptureQuality: Equatable, Sendable {
    // Region statistics
    let saturatedFraction: Double
    let meanLuma: Float
    let lumaStandardDeviation: Float
    let brightestTileShare: Double
    let sharpness: Double

    // Stability
    let globalMotionScore: Double
    let exposureStability: Double
    let controlsRemainedLocked: Bool

    // Frame delivery
    let usableFrames: Int
    let evaluatedFrames: Int
    let droppedFrameRatio: Double
    let frameDeliveryIsContinuous: Bool

    /// How much of the background changed while the model was being built,
    /// `0...1`. Recorded, never gated on: it cannot tell suspended material
    /// from a moving container. `nil` when the model was never built.
    let backgroundStability: Double?
    // Supplied by later phases; `nil` means "this build cannot measure it".
    let calibrationProfileIsCompatible: Bool?

    // Device
    let thermal: ThermalStatus
    let systemPressure: SystemPressureLevel

    // Provenance
    let thresholdsVersion: Int
    let analysisRegionVersion: Int
    let captureProtocolVersion: Int

    let verdict: CaptureQualityVerdict
    /// `0...1`. The smallest headroom across all continuous gates: a window is
    /// only as trustworthy as its weakest measurement.
    let confidence: Double

    var isUsable: Bool { verdict.isUsable }

    var usableFrameRatio: Double {
        evaluatedFrames == 0 ? 0 : Double(usableFrames) / Double(evaluatedFrames)
    }

    /// Plain-language text for every reason, in the order they were raised.
    var explanations: [String] { verdict.reasons.map(\.explanation) }
}

/// The limits each gate applies.
///
/// **These are engineering starting points, not validated constants.** None has
/// been checked against measured repeatability on real samples. They are
/// versioned so that every measurement records which set produced it, and so a
/// calibration profile can refuse a window captured under a different set.
///
/// They govern *capture quality* only. They are not clarity thresholds and
/// carry no health or regulatory meaning.
struct QualityThresholds: Equatable, Sendable, Codable {
    var maximumSaturatedFraction: Double
    var maximumBrightestTileShare: Double
    var minimumMeanLuma: Float
    var maximumMeanLuma: Float
    var minimumSharpness: Double
    var maximumExposureVariation: Double
    var maximumGlobalMotion: Double
    var minimumUsableFrameRatio: Double
    var maximumDroppedFrameRatio: Double
    var minimumEvaluatedFrames: Int
    /// A gate reading within this fraction of its limit is flagged as low
    /// confidence rather than passed silently.
    var marginalBand: Double
    var version: Int

    static let screening = QualityThresholds(
        // Any clipping breaks the monotonic link between value and scattered
        // light, so the allowance is small rather than zero only because a few
        // hot sensor pixels are normal.
        maximumSaturatedFraction: 0.005,
        // A 4x4 tile grid means an evenly lit region sits near 1/16 = 0.0625.
        // A third of the signal in one tile is a specular reflection, not a
        // uniformly scattering sample.
        maximumBrightestTileShare: 0.35,
        minimumMeanLuma: 0.02,
        maximumMeanLuma: 0.65,
        minimumSharpness: 0.0008,
        // Locked exposure should hold the mean level to well under a percent;
        // 3% allows for sensor noise without admitting real flicker.
        maximumExposureVariation: 0.03,
        // Small because the reading is noise-corrected: a still scene scores
        // essentially zero. Calibrated against synthetic pans, where a drift of
        // 10% of the frame width per second stays under the limit and 25% per
        // second exceeds it. Scene-dependent, and superseded in Phase 3C.
        maximumGlobalMotion: 0.0012,
        minimumUsableFrameRatio: 0.80,
        maximumDroppedFrameRatio: 0.10,
        // At 30 fps this is one second of frames: below that the cross-frame
        // statistics are too noisy to gate on.
        minimumEvaluatedFrames: 30,
        marginalBand: 0.20,
        // Version 2 removed the background-stability limit. It could not
        // distinguish a sample full of suspended material from a container
        // creeping, so it rejected the turbid samples the app exists to
        // identify. The number is still recorded; see `FrameQualityEvaluator`.
        version: 2
    )
}
