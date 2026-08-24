import Foundation

/// The quality gates that can be decided from a single frame.
///
/// Deliberately a subset of the window verdict: flicker, the usable-frame ratio
/// and delivery continuity need more than one frame and belong to
/// `FrameQualityEvaluator`, not here.
///
/// Extracted so the measurement analyzer and the alignment monitor apply
/// literally the same gates. Two copies of these rules would drift, and the
/// alignment screen would then promise a measurement the analyzer rejects.
struct FrameGate: Equatable, Sendable {
    let thresholds: QualityThresholds

    init(thresholds: QualityThresholds = .screening) {
        self.thresholds = thresholds
    }

    /// - Parameter motion: the normalized coarse-plane difference from the
    ///   previous frame, already noise-corrected.
    func rejections(statistics: LumaStatistics, motion: Double) -> [MeasurementRejectionReason] {
        var reasons: [MeasurementRejectionReason] = []
        if statistics.sampleCount == 0 {
            reasons.append(.insufficientUsableFrames)
            return reasons
        }
        if statistics.saturatedFraction > thresholds.maximumSaturatedFraction {
            reasons.append(.saturatedRegion)
        }
        if statistics.brightestTileShare > thresholds.maximumBrightestTileShare {
            reasons.append(.torchHotspot)
        }
        if statistics.mean < thresholds.minimumMeanLuma {
            reasons.append(.regionTooDark)
        } else if statistics.mean > thresholds.maximumMeanLuma {
            reasons.append(.regionTooBright)
        }
        if statistics.sharpness < thresholds.minimumSharpness {
            reasons.append(.outOfFocus)
        }
        if motion > thresholds.maximumGlobalMotion {
            reasons.append(.cameraMoved)
        }
        return reasons
    }
}
