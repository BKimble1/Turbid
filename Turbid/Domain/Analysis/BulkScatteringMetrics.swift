import Foundation

/// The bulk optical channel: how much light the whole sample volume scatters.
///
/// Deliberately separate from the discrete candidate list. Turbidity is a bulk
/// scattering measurement, and a camera cannot resolve or count every particle
/// that contributes to it. These aggregate quantities — not the speck count —
/// are what Phase 3D calibrates against certified standards.
struct BulkScatteringMetrics: Equatable, Sendable {
    /// Number of valid, unmasked pixels the metrics were computed over.
    let sampleCount: Int

    /// Mean positive residual over valid pixels: the average excess brightness
    /// above the stationary background. The primary bulk quantity.
    let meanPositiveResidual: Double
    /// Median positive residual. Robust to a handful of bright events, so it
    /// tracks the diffuse haze rather than the specks sitting in it.
    let medianPositiveResidual: Double
    /// 99th percentile minus the median: how much brighter the top of the
    /// distribution is than its bulk. Sensitive to discrete scattering while
    /// the median is not.
    let upperPercentileExcess: Double
    /// Fraction of valid pixels whose band-passed response exceeded the
    /// detection threshold.
    let activeForegroundFraction: Double

    /// Share of the total positive residual falling in the brightest tile of a
    /// 4x4 grid. Near `1/16` when scattering is spread evenly through the
    /// volume, higher when it is concentrated — which usually means a
    /// reflection or a settled clump rather than suspended material.
    let residualBrightestTileShare: Double
    /// Coefficient of variation of the per-tile residual totals. Another view
    /// of the same spatial question, less sensitive to which tile happens to
    /// be brightest.
    let residualSpatialVariation: Double

    /// The noise standard deviation measured on this frame's band-passed
    /// residual, and the threshold derived from it. Recorded because every
    /// other number here is only meaningful relative to them.
    let noiseSigma: Double
    let detectionThreshold: Double

    static let empty = BulkScatteringMetrics(
        sampleCount: 0, meanPositiveResidual: 0, medianPositiveResidual: 0,
        upperPercentileExcess: 0, activeForegroundFraction: 0,
        residualBrightestTileShare: 0, residualSpatialVariation: 0,
        noiseSigma: 0, detectionThreshold: 0
    )
}

/// What the detector produced for one frame.
struct ForegroundObservation: Equatable, Sendable {
    /// Accepted candidates, capped at the configured maximum.
    let candidates: [SpeckCandidate]
    /// How many components were found in total, before filtering or capping.
    let componentCount: Int
    /// Rejections by reason. A run that discards most of what it finds is
    /// saying something about the capture, so the counts are reported.
    let rejections: [CandidateRejection: Int]
    /// Components dropped only because the per-frame cap was reached. Never
    /// silently zero: a truncated frame is a frame whose count is a lower bound.
    let truncatedCount: Int
    let bulk: BulkScatteringMetrics
    /// `false` until the background model has been built. No detection result
    /// is meaningful before then.
    let backgroundIsReady: Bool

    static let notReady = ForegroundObservation(
        candidates: [], componentCount: 0, rejections: [:], truncatedCount: 0,
        bulk: .empty, backgroundIsReady: false
    )

    var acceptedCount: Int { candidates.count }
    var rejectedCount: Int { rejections.values.reduce(0, +) }
}
