import Foundation

/// A dimensionless, repeatable measure of how much light the sample scattered.
///
/// **This is not NTU and must never be presented as NTU.** It is an index on an
/// arbitrary scale whose only guaranteed property is that more scattering
/// produces a larger number under the same capture configuration.
///
/// ## The formula
///
/// ```
/// index = 1000 x ( wBulk    x medianPositiveResidual
///                + wExcess  x upperPercentileExcess
///                + wActive  x activeForegroundFraction
///                + wSpecks  x speckScale x speckEventsPerSecondPerMegapixel )
/// ```
///
/// All four inputs are window-level medians, not per-frame values, so a single
/// bubble or nudge cannot move the result. The bulk terms carry most of the
/// weight because turbidity is a bulk optical measurement: a camera cannot
/// resolve the microscopic and colloidal material that dominates it, so the
/// tracked-speck term is secondary by design.
///
/// ## What the weights are, honestly
///
/// They are an engineering starting point. Nothing has established that this
/// particular mixture is the best predictor of turbidity — that is an empirical
/// question, answerable only with real standards.
///
/// It matters less than it looks, because in Calibrated Fixture Mode the
/// calibration maps *this index* to NTU empirically. Any monotone index works;
/// the weights only decide which mixture of features the curve is fitted
/// through. What they must not do is change between calibration and
/// measurement, which is why the formula is versioned and the version is
/// recorded in every profile and every reading.
///
/// ## Normalization
///
/// Only by quantities the capture design actually fixes: the region's area (via
/// the per-megapixel speck rate) and the residual scale, which is already
/// relative to the background model. Nothing is normalized by torch output or
/// exposure, because those are locked rather than measured in physical units,
/// and dividing by a number the app cannot express in radiometric terms would
/// manufacture false precision.
struct RelativeScatteringIndex: Equatable, Sendable, Codable {

    struct Weights: Equatable, Sendable, Codable {
        var bulk: Double
        var excess: Double
        var active: Double
        var specks: Double
        /// Converts events per second per megapixel onto a scale comparable
        /// with the residual terms, which sit in the low hundredths.
        ///
        /// Set so the speck term stays around 2% of the index across the range
        /// from a very clear sample to a very turbid one. An earlier value ten
        /// times larger let it dominate: a clear sample with a burst of tracked
        /// events outscored a genuinely cloudy one, which would have made the
        /// index a particle counter wearing a turbidity label.
        var speckScale: Double
        var version: Int

        /// Unvalidated starting point. The weights that best predict NTU are an
        /// empirical question for calibration, not a choice to be made here.
        static let screening = Weights(
            bulk: 0.55,
            excess: 0.25,
            active: 0.15,
            specks: 0.05,
            speckScale: 0.0002,
            version: 1
        )

        var total: Double { bulk + excess + active + specks }
    }

    /// Each term's contribution, so any displayed index can be traced back to
    /// the numbers that produced it.
    struct Components: Equatable, Sendable, Codable {
        let bulkContribution: Double
        let excessContribution: Double
        let activeContribution: Double
        let speckContribution: Double
    }

    let value: Double
    let components: Components
    let weightsVersion: Int
    /// The window count the index was aggregated over. One window is a
    /// measurement; several is a measurement with a repeatability figure.
    let windowCount: Int

    static let zero = RelativeScatteringIndex(
        value: 0,
        components: Components(bulkContribution: 0, excessContribution: 0,
                               activeContribution: 0, speckContribution: 0),
        weightsVersion: 0,
        windowCount: 0
    )

    /// Scale factor. Chosen only so a typical clear sample reads in single
    /// digits and a visibly cloudy one in the hundreds, which makes the index
    /// legible. It carries no physical meaning.
    static let scale: Double = 1000

    static func make(summary: ScatteringSummary,
                     tracking: TrackingMetrics,
                     weights: Weights = .screening) -> RelativeScatteringIndex {
        let bulk = weights.bulk * max(0, summary.medianPositiveResidual)
        let excess = weights.excess * max(0, summary.medianUpperPercentileExcess)
        let active = weights.active * max(0, summary.medianActiveForegroundFraction)
        let specks = weights.specks * weights.speckScale
            * max(0, tracking.speckEventsPerSecondPerMegapixel)

        return RelativeScatteringIndex(
            value: scale * (bulk + excess + active + specks),
            components: Components(
                bulkContribution: scale * bulk,
                excessContribution: scale * excess,
                activeContribution: scale * active,
                speckContribution: scale * specks
            ),
            weightsVersion: weights.version,
            windowCount: summary.windowCount
        )
    }
}
