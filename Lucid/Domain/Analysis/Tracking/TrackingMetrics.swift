import Foundation

/// What tracking produced over a window.
///
/// The speck count is reported as *Visible particles (tracked)*, never as a
/// particle concentration: a camera cannot resolve or count the microscopic and
/// colloidal material that dominates real turbidity. Phase 3D calibrates the
/// bulk scattering channel, not these counts.
struct TrackingMetrics: Equatable, Sendable {
    let confirmedSpeckCount: Int
    let speckEventsPerSecond: Double
    /// Rate per second per million region pixels, so runs made with different
    /// region sizes can be compared.
    let speckEventsPerSecondPerMegapixel: Double

    /// Residual speeds after motion compensation, normalized by the region
    /// diagonal per second.
    let medianResidualSpeed: Double
    let percentile90ResidualSpeed: Double

    let bubbleRejectionCount: Int
    let ambiguousCount: Int
    let staticDefectCount: Int
    /// Mean classification margin over the confirmed tracks.
    let meanTrackConfidence: Double

    let globalMotionSpeed: Double
    let globalMotionConfidence: Double
    let globalMotionWasCompensated: Bool

    /// Tracks discarded because the tracker hit its cap. Non-zero means every
    /// count here is a lower bound.
    let tracksDroppedForCapacity: Int

    static let empty = TrackingMetrics(
        confirmedSpeckCount: 0, speckEventsPerSecond: 0,
        speckEventsPerSecondPerMegapixel: 0, medianResidualSpeed: 0,
        percentile90ResidualSpeed: 0, bubbleRejectionCount: 0, ambiguousCount: 0,
        staticDefectCount: 0, meanTrackConfidence: 0, globalMotionSpeed: 0,
        globalMotionConfidence: 0, globalMotionWasCompensated: false,
        tracksDroppedForCapacity: 0
    )

    /// Builds the metrics from a classified track set.
    static func make(tracks: [Track],
                     regionWidth: Int,
                     regionHeight: Int,
                     windowSeconds: Double,
                     motion: GlobalMotion,
                     tracksDroppedForCapacity: Int) -> TrackingMetrics {
        let diagonal = max(1, Double(regionWidth * regionWidth
                                     + regionHeight * regionHeight).squareRoot())
        let countable = tracks.filter { $0.state.isCountable }

        let specks = countable.filter { $0.classification == .suspendedSpeck }
        let bubbles = countable.filter { $0.classification == .risingBubble }
        let ambiguous = countable.filter { $0.classification == .ambiguous }
        let statics = countable.filter { $0.classification == .staticDefect }

        var speeds = specks.map { $0.medianStepSpeed / diagonal }
        speeds.sort()

        let megapixels = Double(regionWidth * regionHeight) / 1_000_000
        let rate = windowSeconds > 0 ? Double(specks.count) / windowSeconds : 0

        return TrackingMetrics(
            confirmedSpeckCount: specks.count,
            speckEventsPerSecond: rate,
            speckEventsPerSecondPerMegapixel: megapixels > 0 ? rate / megapixels : 0,
            medianResidualSpeed: percentile(speeds, 0.5),
            percentile90ResidualSpeed: percentile(speeds, 0.9),
            bubbleRejectionCount: bubbles.count,
            ambiguousCount: ambiguous.count,
            staticDefectCount: statics.count,
            meanTrackConfidence: countable.isEmpty ? 0
                : countable.reduce(0) { $0 + $1.classificationConfidence } / Double(countable.count),
            globalMotionSpeed: motion.flow.normalizedSpeed(regionDiagonal: diagonal),
            globalMotionConfidence: motion.flow.confidence,
            globalMotionWasCompensated: motion.isTrustworthy,
            tracksDroppedForCapacity: tracksDroppedForCapacity
        )
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1,
                        max(0, Int((fraction * Double(sorted.count - 1)).rounded())))
        return sorted[index]
    }
}
