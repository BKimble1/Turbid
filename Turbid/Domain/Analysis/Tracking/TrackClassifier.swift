import CoreGraphics
import Foundation

/// Decides what a track is, from several graded features rather than one cutoff.
///
/// Air bubbles and suspended particles overlap in every individual feature:
/// there are small slow bubbles and large fast specks. What separates them in
/// aggregate is the *combination* — direction, straightness, size and speed
/// together — and even then not completely. So each class gets a graded score,
/// the winner has to beat the runner-up by a margin, and anything that does not
/// is called ambiguous and counted separately. Nothing here claims a clean
/// separation, because there is not one.
struct TrackClassifier: Sendable {

    struct Configuration: Equatable, Sendable, Codable {
        /// Speeds are normalized by the region diagonal per second, so the same
        /// numbers mean the same physical thing at any capture resolution and
        /// any region size. There is no universal pixels-per-second threshold.
        var staticSpeedLow: Double
        var staticSpeedHigh: Double
        /// Speed band over which "fast enough to be a bubble" ramps in.
        var bubbleSpeedLow: Double
        var bubbleSpeedHigh: Double
        /// Diameter band, as a fraction of the region diagonal, over which
        /// "large enough to be a bubble" ramps in.
        var bubbleDiameterLow: Double
        var bubbleDiameterHigh: Double
        /// Upward-consistency band. `1` is perfectly along the up direction.
        var upwardLow: Double
        var upwardHigh: Double
        /// Straightness band. A ballistic rise approaches `1`.
        var straightnessLow: Double
        var straightnessHigh: Double
        /// Sightings a speck needs before it is believed.
        var minimumObservations: Int
        /// The winner must beat the runner-up by this much, or the track is
        /// ambiguous.
        var minimumConfidenceMargin: Double
        var version: Int

        /// Engineering starting points, versioned and **not** tuned from
        /// labelled validation clips, which is what the design calls for and
        /// what has not happened yet. They separate the synthetic cases
        /// convincingly; real footage will move them.
        static let screening = Configuration(
            staticSpeedLow: 0.004,
            staticSpeedHigh: 0.012,
            bubbleSpeedLow: 0.05,
            bubbleSpeedHigh: 0.15,
            bubbleDiameterLow: 0.010,
            bubbleDiameterHigh: 0.025,
            upwardLow: 0.35,
            upwardHigh: 0.80,
            straightnessLow: 0.55,
            straightnessHigh: 0.90,
            minimumObservations: 5,
            minimumConfidenceMargin: 0.12,
            version: 1
        )
    }

    struct Verdict: Equatable, Sendable {
        let classification: TrackClassification
        let confidence: Double
        /// Every class score, so a decision can be explained rather than just
        /// asserted.
        let scores: [TrackClassification: Double]
    }

    let configuration: Configuration

    init(configuration: Configuration = .screening) {
        self.configuration = configuration
    }

    func classify(_ track: Track,
                  regionDiagonal: Double,
                  gravity: GravityReference) -> Verdict {
        let speed = regionDiagonal > 0 ? track.medianStepSpeed / regionDiagonal : 0
        let diameter = track.medianDiameter
        let straightness = track.straightness
        let observationWeight = Self.ramp(Double(track.totalObservations),
                                          Double(configuration.minimumObservations),
                                          Double(configuration.minimumObservations * 2))

        // Direction evidence is only as good as the geometry. With the camera
        // looking along gravity, "up" barely projects into the image and a
        // rising bubble hardly moves; the term is blended towards neutral by
        // exactly how much of gravity lies in the image plane.
        let rawUpward = track.upwardConsistency(up: gravity.imageUp)
        let upwardTerm = Self.ramp(rawUpward, configuration.upwardLow, configuration.upwardHigh)
        let reliability = min(1, max(0, gravity.inPlaneFraction))
        let upward = 0.5 + (upwardTerm - 0.5) * reliability

        let staticScore = 1 - Self.ramp(speed, configuration.staticSpeedLow, configuration.staticSpeedHigh)

        let straightTerm = Self.ramp(straightness,
                                     configuration.straightnessLow,
                                     configuration.straightnessHigh)

        let bubbleSize = Self.ramp(diameter, configuration.bubbleDiameterLow, configuration.bubbleDiameterHigh)
        let bubbleSpeed = Self.ramp(speed, configuration.bubbleSpeedLow, configuration.bubbleSpeedHigh)
        let bubbleScore = Self.fuzzyAnd([
            upward,
            straightTerm,
            max(bubbleSize, bubbleSpeed),
            1 - staticScore
        ])

        // A straight path only argues against a speck when it is also going
        // *up*. Sedimentation is ballistic too: a particle settling out of
        // suspension falls in as straight a line as a bubble rises, and a bare
        // straightness veto called every sinking particle ambiguous — with all
        // three scores at zero it could not even be counted as unclassified
        // motion.
        //
        // The gate is the unblended direction ramp rather than `upward`.
        // `upward` is pulled towards neutral when gravity leaves the image
        // plane, and letting that leak in here would let a straight rise be
        // read as a speck whenever the phone is close to flat — the one
        // geometry in which the direction evidence is worth least.
        let ballisticRise = min(straightTerm, upwardTerm)

        let speckScore = Self.fuzzyAnd([
            1 - upward,
            1 - bubbleSize,
            1 - ballisticRise,
            1 - staticScore,
            observationWeight
        ])

        let scores: [TrackClassification: Double] = [
            .staticDefect: staticScore,
            .risingBubble: bubbleScore,
            .suspendedSpeck: speckScore
        ]

        let ranked = scores.sorted { first, second in
            first.value == second.value ? first.key.rawValue < second.key.rawValue
                                        : first.value > second.value
        }
        guard let best = ranked.first else {
            return Verdict(classification: .ambiguous, confidence: 0, scores: scores)
        }
        let runnerUp = ranked.count > 1 ? ranked[1].value : 0
        var margin = best.value - runnerUp

        // Both moving classes lean on which way is up. When gravity barely
        // projects into the image plane that evidence is weak, so the
        // confidence is reduced rather than the verdict being asserted at full
        // strength on geometry that cannot support it.
        if best.key == .risingBubble || best.key == .suspendedSpeck {
            margin *= 0.5 + 0.5 * reliability
        }

        guard margin >= configuration.minimumConfidenceMargin, best.value > 0 else {
            return Verdict(classification: .ambiguous, confidence: margin, scores: scores)
        }
        return Verdict(classification: best.key, confidence: margin, scores: scores)
    }

    /// `0` at or below `low`, `1` at or above `high`, linear between.
    static func ramp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard high > low else { return value >= high ? 1 : 0 }
        return min(1, max(0, (value - low) / (high - low)))
    }

    /// The weakest term wins: every term is a necessary condition, so a score
    /// should be no higher than its worst-supported requirement.
    ///
    /// A geometric mean was tried first and is wrong for this: its nth root
    /// undoes exactly the property it was chosen for. With five terms,
    /// `geometricMean([0.1, 1, 1, 1, 1])` is 0.63, so one badly failed
    /// requirement still scores well. Under that rule a small, slow, straight,
    /// upward-drifting track — the genuinely ambiguous case — came out as a
    /// confident speck.
    static func fuzzyAnd(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(1) { min($0, max(0, min(1, $1))) }
    }
}
