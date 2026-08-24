import Foundation

/// What the analyzer produces for one frame.
///
/// A small value type on purpose: this is what crosses out of the processing
/// queue. No pixel buffer, no image, nothing that has to be retained.
struct FrameObservation: Equatable, Sendable {
    let sequenceNumber: Int
    let timestampSeconds: Double
    let stage: CaptureStage
    let statistics: LumaStatistics
    /// Normalized frame-to-frame difference on the coarse plane, or `0` for the
    /// first frame, which has nothing to compare against.
    let globalMotionScore: Double
    /// Whether this individual frame passed the per-frame gates.
    let isUsable: Bool
    let rejectionReasons: [MeasurementRejectionReason]
    /// Detection output. Empty and `backgroundIsReady == false` outside the
    /// measurement stage, or before the background model has been built.
    let foreground: ForegroundObservation

    var contributesToResult: Bool { isUsable && stage.contributesToResult }
}

/// Running aggregate over a measurement run.
///
/// Bounded: the per-frame observations are folded into running sums and a
/// fixed-size history rather than being accumulated in a growing array, so a
/// long run cannot grow the heap.
struct FrameAggregate: Equatable, Sendable {
    private(set) var evaluatedFrames = 0
    private(set) var usableFrames = 0
    private(set) var contributingFrames = 0

    private var meanLevels: [Float]
    private var motionScores: [Double]
    private var writeIndex = 0
    private var filled = 0
    private let capacity: Int

    // Running sums over measurement-stage frames only.
    private(set) var detectionFrames = 0
    private var totalCandidates = 0
    private var totalComponents = 0
    private var totalTruncated = 0
    private var totalMeanResidual: Double = 0
    private var totalMedianResidual: Double = 0
    private var totalUpperExcess: Double = 0
    private var totalActiveFraction: Double = 0
    private var totalResidualTileShare: Double = 0
    private var totalResidualVariation: Double = 0

    // Running sums over contributing frames only.
    private var totalMean: Double = 0
    private var totalStandardDeviation: Double = 0
    private var totalNoiseSigma: Double = 0
    private var totalSaturated: Double = 0
    private var totalTileShare: Double = 0
    private var totalSharpness: Double = 0
    private var totalSamples = 0
    private var minimumSharpness: Double = .greatestFiniteMagnitude
    private var maximumSaturated: Double = 0
    private var maximumTileShare: Double = 0

    init(capacity: Int = 600) {
        self.capacity = max(1, capacity)
        self.meanLevels = Array(repeating: 0, count: self.capacity)
        self.motionScores = Array(repeating: 0, count: self.capacity)
    }

    mutating func record(_ observation: FrameObservation) {
        evaluatedFrames += 1
        if observation.isUsable { usableFrames += 1 }

        guard observation.contributesToResult else { return }
        contributingFrames += 1

        meanLevels[writeIndex] = observation.statistics.mean
        motionScores[writeIndex] = observation.globalMotionScore
        writeIndex = (writeIndex + 1) % capacity
        filled = min(filled + 1, capacity)

        totalMean += Double(observation.statistics.mean)
        totalStandardDeviation += Double(observation.statistics.standardDeviation)
        totalNoiseSigma += observation.statistics.noiseSigma
        totalSaturated += observation.statistics.saturatedFraction
        totalTileShare += observation.statistics.brightestTileShare
        totalSharpness += observation.statistics.sharpness
        totalSamples += observation.statistics.sampleCount

        // Worst-case readings are kept alongside the averages: a single frame
        // with a blown-out reflection matters even if the mean looks fine.
        minimumSharpness = min(minimumSharpness, observation.statistics.sharpness)
        maximumSaturated = max(maximumSaturated, observation.statistics.saturatedFraction)
        maximumTileShare = max(maximumTileShare, observation.statistics.brightestTileShare)

        // Detection output is only aggregated over the measurement stage. The
        // background-acquisition frames built the model the detection is
        // relative to, so including them would compare the model with itself.
        guard observation.stage == .measurement,
              observation.foreground.backgroundIsReady else { return }

        detectionFrames += 1
        totalCandidates += observation.foreground.acceptedCount
        totalComponents += observation.foreground.componentCount
        totalTruncated += observation.foreground.truncatedCount

        let bulk = observation.foreground.bulk
        totalMeanResidual += bulk.meanPositiveResidual
        totalMedianResidual += bulk.medianPositiveResidual
        totalUpperExcess += bulk.upperPercentileExcess
        totalActiveFraction += bulk.activeForegroundFraction
        totalResidualTileShare += bulk.residualBrightestTileShare
        totalResidualVariation += bulk.residualSpatialVariation
    }

    /// Bulk scattering averaged over the measurement window.
    ///
    /// The mean across frames, not across pixels: each frame is an independent
    /// look at the same volume, and averaging them is what reduces the
    /// per-frame noise that a single look carries.
    func windowScattering() -> WindowScattering {
        guard detectionFrames > 0 else { return .empty }
        let n = Double(detectionFrames)
        return WindowScattering(
            detectionFrames: detectionFrames,
            meanPositiveResidual: totalMeanResidual / n,
            medianPositiveResidual: totalMedianResidual / n,
            upperPercentileExcess: totalUpperExcess / n,
            activeForegroundFraction: totalActiveFraction / n,
            residualBrightestTileShare: totalResidualTileShare / n,
            residualSpatialVariation: totalResidualVariation / n,
            totalAcceptedCandidates: totalCandidates,
            totalComponents: totalComponents,
            truncatedComponents: totalTruncated
        )
    }

    /// Statistics representing the window as a whole.
    ///
    /// Averages for level and spread; worst case for saturation, hotspot and
    /// sharpness, because those are failure conditions rather than quantities
    /// it makes sense to average.
    func windowStatistics() -> LumaStatistics {
        guard contributingFrames > 0 else { return .empty }
        let n = Double(contributingFrames)
        return LumaStatistics(
            sampleCount: totalSamples / contributingFrames,
            mean: Float(totalMean / n),
            standardDeviation: Float(totalStandardDeviation / n),
            minimum: 0,
            maximum: 0,
            percentile01: 0,
            percentile50: 0,
            percentile99: 0,
            saturatedFraction: maximumSaturated,
            nearBlackFraction: 0,
            brightestTileShare: maximumTileShare,
            sharpness: minimumSharpness == .greatestFiniteMagnitude ? 0 : minimumSharpness,
            // Averaged, like the standard deviation it is a sibling of. Left
            // at zero it would be the one field here a consumer might divide
            // by or compare against, and zero noise is not a claim to make.
            noiseSigma: totalNoiseSigma / n
        )
    }

    /// Coefficient of variation of the per-frame mean level.
    ///
    /// Dimensionless, so it can be compared across measurements made at
    /// different brightness. With exposure locked it should be dominated by
    /// sensor noise; anything larger is flicker or a control that came unlocked.
    func exposureVariation() -> Double {
        guard filled >= 2 else { return 0 }
        let window = meanLevels.prefix(filled).map(Double.init)
        let mean = window.reduce(0, +) / Double(window.count)
        guard mean > 0 else { return 0 }
        let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)
        return variance.squareRoot() / mean
    }

    /// Median frame-to-frame motion, so one jolt does not condemn a window that
    /// was otherwise held still, and a sustained drift is not averaged away.
    func medianMotion() -> Double {
        guard filled > 0 else { return 0 }
        let sorted = motionScores.prefix(filled).sorted()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    func maximumMotion() -> Double {
        motionScores.prefix(filled).max() ?? 0
    }
}


/// Bulk scattering and candidate counts aggregated over a measurement window.
///
/// The candidate counts are reported as **Visible particles (tracked)** in the
/// UI, never as a particle concentration: a camera cannot resolve or count the
/// microscopic and colloidal material that dominates real turbidity. The bulk
/// residual quantities, not the counts, are what Phase 3D calibrates.
struct WindowScattering: Equatable, Sendable {
    let detectionFrames: Int
    let meanPositiveResidual: Double
    let medianPositiveResidual: Double
    let upperPercentileExcess: Double
    let activeForegroundFraction: Double
    let residualBrightestTileShare: Double
    let residualSpatialVariation: Double

    /// Total accepted candidates summed over the window. Phase 3C turns these
    /// into tracks; until then a candidate seen in ten frames counts ten times.
    let totalAcceptedCandidates: Int
    let totalComponents: Int
    /// Components dropped because a frame hit the per-frame cap. Non-zero means
    /// the counts above are a lower bound.
    let truncatedComponents: Int

    static let empty = WindowScattering(
        detectionFrames: 0, meanPositiveResidual: 0, medianPositiveResidual: 0,
        upperPercentileExcess: 0, activeForegroundFraction: 0,
        residualBrightestTileShare: 0, residualSpatialVariation: 0,
        totalAcceptedCandidates: 0, totalComponents: 0, truncatedComponents: 0
    )

    /// Mean accepted candidates per analysed frame.
    var candidatesPerFrame: Double {
        detectionFrames == 0 ? 0 : Double(totalAcceptedCandidates) / Double(detectionFrames)
    }
}
