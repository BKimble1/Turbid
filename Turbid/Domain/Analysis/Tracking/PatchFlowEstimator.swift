import CoreGraphics
import Foundation

/// Accumulated scene displacement and the current rate of change.
struct GlobalMotion: Equatable, Sendable {
    /// Total displacement of the scene since the run began, in region pixels.
    /// Subtracting this from a detection's position puts it in a stabilised
    /// frame in which a stationary object stays still.
    let cumulativeOffset: CGVector
    let flow: GlobalFlow
    /// `false` when the estimate is not trustworthy enough to subtract.
    let isTrustworthy: Bool

    static let none = GlobalMotion(cumulativeOffset: .zero, flow: .none, isTrustworthy: false)
}

/// Global motion estimation, behind a protocol so the estimator can be replaced
/// without touching the tracker.
protocol GlobalFlowEstimating: AnyObject {
    func prepare(regionWidth: Int, regionHeight: Int)
    func reset()
    func update(with region: LumaImage,
                timestampSeconds: Double,
                noiseSigma: Double) -> GlobalMotion
}

/// Robust global translation, by matching a sparse grid of patches against a
/// held reference frame.
///
/// ## Why not `VNGenerateOpticalFlowRequest`
///
/// A dense flow field is far more than this pipeline consumes: the only thing
/// taken from it is one robust vector for the whole region. A sparse grid of
/// block matches computes that directly, deterministically and cheaply.
///
/// It is also the only version whose correctness could be established here.
/// Vision's optical-flow request is a *targeted* request whose result sign
/// depends on which of the two frames is the targeted one, and that convention
/// cannot be confirmed without running it on a device. A sign error would not
/// fail loudly — it would *double* the apparent camera motion instead of
/// removing it, and every velocity downstream would be wrong. This
/// implementation's sign is pinned by a test. Adopting Vision remains
/// reasonable once it can be measured on hardware against this baseline.
///
/// ## Three things that make it work
///
/// **A multi-frame baseline.** Camera drift is sub-pixel per frame: a 10 px/s
/// drift moves the scene by a third of a pixel between consecutive frames,
/// which is below what block matching can resolve. Matching against a reference
/// frame held for several frames turns that into a few pixels, which it can.
/// The reference is re-anchored once the displacement approaches the search
/// window, so the accumulated offset stays exact while the rate stays
/// measurable.
///
/// **A Shi-Tomasi gate.** A patch containing only a horizontal scratch cannot
/// say anything about horizontal displacement — the aperture problem — and left
/// unchecked it votes with an arbitrary value. The smaller eigenvalue of the
/// patch's structure tensor is near zero exactly in that case, so patches
/// without gradient in both directions never vote.
///
/// **A robust median with an inlier count.** Patches spoiled by a passing
/// particle are a minority and the median ignores them; the fraction agreeing
/// with the median becomes the confidence, and a low-confidence estimate is
/// never subtracted from anything.
///
/// A clean container in a dark shroud may have too little texture for any patch
/// to pass the gate. That is reported as zero confidence, not guessed at.
final class PatchFlowEstimator: GlobalFlowEstimating {

    struct Configuration: Equatable, Sendable, Codable {
        /// Patch positions per axis. Generous, because most of a clean sample
        /// has no texture and only a few positions will land on any.
        var gridSize: Int
        var patchSize: Int
        /// Half-width of the search window. Bounds both the cost and the
        /// largest displacement that can be measured.
        var searchRadius: Int
        /// Minimum Shi-Tomasi eigenvalue, in multiples of the noise variance.
        var minimumEigenvalueSigmas: Double
        /// A patch is an inlier when it lands within this many pixels of the
        /// median.
        var inlierTolerancePixels: Double
        /// Fewer surviving patches than this and the estimate is refused.
        var minimumPatches: Int
        /// Below this inlier fraction the estimate is not subtracted.
        var minimumConfidence: Double
        /// Re-anchor the reference once the displacement reaches this fraction
        /// of the search radius.
        var reanchorFraction: Double
        /// Re-anchor at least this often, so the baseline cannot grow without
        /// bound while the scene is perfectly still.
        var maximumBaselineSeconds: Double
        /// Estimate on every Nth frame. The reference baseline makes a reduced
        /// cadence free of cost in accuracy.
        var frameStride: Int
        var version: Int

        static let screening = Configuration(
            gridSize: 7,
            patchSize: 21,
            searchRadius: 6,
            minimumEigenvalueSigmas: 4.0,
            inlierTolerancePixels: 0.6,
            minimumPatches: 3,
            minimumConfidence: 0.6,
            reanchorFraction: 0.6,
            maximumBaselineSeconds: 0.5,
            frameStride: 3,
            version: 1
        )
    }

    let configuration: Configuration

    private var width = 0
    private var height = 0
    private var current = LumaImage(width: 0, height: 0)
    private var reference = LumaImage(width: 0, height: 0)
    private var hasReference = false
    private var referenceTimestamp: Double = 0
    /// The total folded in at the last re-anchor. Only ever advanced by a
    /// measurement that was trustworthy at the moment it was taken.
    private var cumulativeOffset = CGVector.zero
    /// Displacement measured against the *current* reference, not yet folded
    /// into `cumulativeOffset`.
    ///
    /// This is what makes the reported offset continuous. An estimate is only
    /// computed every `frameStride` frames, and the offset is only folded in at
    /// a re-anchor; without carrying the measurement in between, the reported
    /// origin would snap back to the last anchor on every frame that did not
    /// measure, and snap forward again on the one that did. Downstream that
    /// sawtooth is indistinguishable from real particle motion: the tracker
    /// subtracts this offset to stabilise detections, so a 3.6 px step at 30 fps
    /// injects roughly 100 px/s of velocity into every track on two frames out
    /// of three.
    private var pendingDisplacement = CGVector.zero
    private var lastFlow = GlobalFlow.none
    private var lastTrustworthy = false
    private var frameCounter = 0

    init(configuration: Configuration = .screening) {
        self.configuration = configuration
    }

    func prepare(regionWidth: Int, regionHeight: Int) {
        guard regionWidth > 0, regionHeight > 0 else { return }
        guard regionWidth != width || regionHeight != height else { return }
        width = regionWidth
        height = regionHeight
        current = LumaImage(width: regionWidth, height: regionHeight)
        reference = LumaImage(width: regionWidth, height: regionHeight)
        reset()
    }

    func reset() {
        hasReference = false
        referenceTimestamp = 0
        cumulativeOffset = .zero
        pendingDisplacement = .zero
        lastFlow = .none
        lastTrustworthy = false
        frameCounter = 0
    }

    func update(with region: LumaImage,
                timestampSeconds: Double,
                noiseSigma: Double) -> GlobalMotion {
        guard region.width == width, region.height == height, width > 0 else { return .none }

        defer { frameCounter += 1 }

        guard hasReference else {
            reference.values = region.values
            referenceTimestamp = timestampSeconds
            hasReference = true
            return GlobalMotion(cumulativeOffset: reportedOffset, flow: .none, isTrustworthy: false)
        }

        // Between estimates the last known rate and the last measured
        // displacement both still hold. Reporting the anchor alone here would
        // discard everything measured since it.
        guard frameCounter % max(1, configuration.frameStride) == 0 else {
            return GlobalMotion(cumulativeOffset: reportedOffset,
                                flow: lastFlow,
                                isTrustworthy: lastTrustworthy)
        }

        let elapsed = timestampSeconds - referenceTimestamp
        guard elapsed > 0 else {
            return GlobalMotion(cumulativeOffset: reportedOffset,
                                flow: lastFlow,
                                isTrustworthy: lastTrustworthy)
        }

        current.values = region.values
        let measurement = measureDisplacement(noiseSigma: noiseSigma)

        guard let displacement = measurement.displacement else {
            lastFlow = GlobalFlow(dxPixelsPerSecond: 0, dyPixelsPerSecond: 0,
                                  confidence: 0,
                                  patchesUsed: measurement.patchesUsed,
                                  patchesOffered: measurement.patchesOffered)
            lastTrustworthy = false
            // Re-anchor anyway: a reference that nothing matches is stale. The
            // pending displacement is folded in rather than dropped — it is the
            // last thing actually measured about this baseline, and discarding
            // it would lose that much offset permanently.
            if elapsed >= configuration.maximumBaselineSeconds {
                anchor(to: region, at: timestampSeconds, adding: pendingDisplacement)
            }
            return GlobalMotion(cumulativeOffset: reportedOffset,
                                flow: lastFlow,
                                isTrustworthy: false)
        }

        let flow = GlobalFlow(
            dxPixelsPerSecond: displacement.dx / elapsed,
            dyPixelsPerSecond: displacement.dy / elapsed,
            confidence: measurement.confidence,
            patchesUsed: measurement.patchesUsed,
            patchesOffered: measurement.patchesOffered
        )
        lastFlow = flow
        lastTrustworthy = measurement.confidence >= configuration.minimumConfidence

        let magnitude = (displacement.dx * displacement.dx
                         + displacement.dy * displacement.dy).squareRoot()
        let reanchorDistance = Double(configuration.searchRadius) * configuration.reanchorFraction

        // An untrustworthy measurement replaces nothing: the previous pending
        // displacement is still the best thing known about this baseline.
        if lastTrustworthy {
            pendingDisplacement = CGVector(dx: displacement.dx, dy: displacement.dy)
        }

        if magnitude >= reanchorDistance || elapsed >= configuration.maximumBaselineSeconds {
            // Fold the measured displacement into the running total and start a
            // new baseline from here, so error does not accumulate across a
            // long run.
            anchor(to: region, at: timestampSeconds, adding: pendingDisplacement)
            return GlobalMotion(cumulativeOffset: reportedOffset,
                                flow: flow,
                                isTrustworthy: lastTrustworthy)
        }

        return GlobalMotion(cumulativeOffset: reportedOffset,
                            flow: flow,
                            isTrustworthy: lastTrustworthy)
    }

    /// The anchored total plus whatever has been measured against the current
    /// reference. This is the only value ever published, so the stabilised
    /// origin moves continuously rather than in steps at each re-anchor.
    private var reportedOffset: CGVector {
        CGVector(dx: cumulativeOffset.dx + pendingDisplacement.dx,
                 dy: cumulativeOffset.dy + pendingDisplacement.dy)
    }

    private func anchor(to region: LumaImage, at timestamp: Double, adding delta: CGVector) {
        cumulativeOffset = CGVector(dx: cumulativeOffset.dx + delta.dx,
                                    dy: cumulativeOffset.dy + delta.dy)
        pendingDisplacement = .zero
        reference.values = region.values
        referenceTimestamp = timestamp
    }

    // MARK: - Measurement

    private struct Measurement {
        var displacement: (dx: Double, dy: Double)?
        var confidence: Double = 0
        var patchesUsed = 0
        var patchesOffered = 0
    }

    private func measureDisplacement(noiseSigma: Double) -> Measurement {
        var result = Measurement()

        let half = configuration.patchSize / 2
        let margin = half + configuration.searchRadius
        let usableWidth = width - 2 * margin
        let usableHeight = height - 2 * margin
        guard usableWidth > 0, usableHeight > 0 else { return result }

        // Noise alone contributes about `sigma^2 / 2` to each gradient energy
        // term, so the eigenvalue gate is expressed in noise variance.
        let eigenvalueLimit = configuration.minimumEigenvalueSigmas * noiseSigma * noiseSigma

        var displacementsX: [Double] = []
        var displacementsY: [Double] = []
        displacementsX.reserveCapacity(configuration.gridSize * configuration.gridSize)
        displacementsY.reserveCapacity(configuration.gridSize * configuration.gridSize)

        for gridY in 0..<configuration.gridSize {
            let centreY = margin + (usableHeight * (2 * gridY + 1)) / (2 * configuration.gridSize)
            for gridX in 0..<configuration.gridSize {
                let centreX = margin + (usableWidth * (2 * gridX + 1)) / (2 * configuration.gridSize)
                result.patchesOffered += 1

                guard minimumEigenvalue(centreX: centreX, centreY: centreY, half: half) > eigenvalueLimit,
                      let matched = match(centreX: centreX, centreY: centreY, half: half) else {
                    continue
                }
                displacementsX.append(matched.dx)
                displacementsY.append(matched.dy)
            }
        }

        result.patchesUsed = displacementsX.count
        guard displacementsX.count >= configuration.minimumPatches else { return result }

        let medianX = Self.median(of: displacementsX)
        let medianY = Self.median(of: displacementsY)

        var inliers = 0
        for index in displacementsX.indices {
            let dx = displacementsX[index] - medianX
            let dy = displacementsY[index] - medianY
            if (dx * dx + dy * dy).squareRoot() <= configuration.inlierTolerancePixels {
                inliers += 1
            }
        }

        result.displacement = (dx: medianX, dy: medianY)
        result.confidence = Double(inliers) / Double(displacementsX.count)
        return result
    }

    /// Smaller eigenvalue of the patch's structure tensor.
    private func minimumEigenvalue(centreX: Int, centreY: Int, half: Int) -> Double {
        var gxx: Double = 0, gyy: Double = 0, gxy: Double = 0
        var count = 0

        for y in (centreY - half + 1)..<(centreY + half) {
            let row = y * width
            for x in (centreX - half + 1)..<(centreX + half) {
                let index = row + x
                let gx = Double(current.values[index + 1] - current.values[index - 1]) * 0.5
                let gy = Double(current.values[index + width] - current.values[index - width]) * 0.5
                gxx += gx * gx
                gyy += gy * gy
                gxy += gx * gy
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        gxx /= Double(count); gyy /= Double(count); gxy /= Double(count)

        let trace = gxx + gyy
        let root = ((gxx - gyy) * (gxx - gyy) + 4 * gxy * gxy).squareRoot()
        return (trace - root) / 2
    }

    /// If the content moved by `d`, the patch taken from the current frame at
    /// `p` matches the reference at `p - d`. The best search offset is `-d`, so
    /// the scene displacement is its negation. The sign is pinned by a test.
    private func match(centreX: Int, centreY: Int, half: Int) -> (dx: Double, dy: Double)? {
        let radius = configuration.searchRadius
        var bestCost = Double.greatestFiniteMagnitude
        var bestOffsetX = 0
        var bestOffsetY = 0

        for offsetY in -radius...radius {
            for offsetX in -radius...radius {
                let cost = sumOfAbsoluteDifferences(centreX: centreX, centreY: centreY, half: half,
                                                    offsetX: offsetX, offsetY: offsetY,
                                                    abortAbove: bestCost)
                if cost < bestCost {
                    bestCost = cost
                    bestOffsetX = offsetX
                    bestOffsetY = offsetY
                }
            }
        }

        // A minimum on the edge of the search window means the real match lies
        // outside it, so the measurement is a bound rather than a value.
        guard abs(bestOffsetX) < radius, abs(bestOffsetY) < radius else { return nil }

        let subX = Self.parabolicOffset(
            left: sumOfAbsoluteDifferences(centreX: centreX, centreY: centreY, half: half,
                                           offsetX: bestOffsetX - 1, offsetY: bestOffsetY),
            centre: bestCost,
            right: sumOfAbsoluteDifferences(centreX: centreX, centreY: centreY, half: half,
                                            offsetX: bestOffsetX + 1, offsetY: bestOffsetY)
        )
        let subY = Self.parabolicOffset(
            left: sumOfAbsoluteDifferences(centreX: centreX, centreY: centreY, half: half,
                                           offsetX: bestOffsetX, offsetY: bestOffsetY - 1),
            centre: bestCost,
            right: sumOfAbsoluteDifferences(centreX: centreX, centreY: centreY, half: half,
                                            offsetX: bestOffsetX, offsetY: bestOffsetY + 1)
        )

        return (dx: -(Double(bestOffsetX) + subX), dy: -(Double(bestOffsetY) + subY))
    }

    /// Aborts as soon as the running total passes `abortAbove`, which cannot
    /// change the outcome and typically removes most of the work.
    private func sumOfAbsoluteDifferences(centreX: Int, centreY: Int, half: Int,
                                          offsetX: Int, offsetY: Int,
                                          abortAbove: Double = .greatestFiniteMagnitude) -> Double {
        var total: Double = 0
        for y in (centreY - half)...(centreY + half) {
            let currentRow = y * width
            let referenceRow = (y + offsetY) * width
            for x in (centreX - half)...(centreX + half) {
                total += Double(abs(current.values[currentRow + x]
                                    - reference.values[referenceRow + x + offsetX]))
            }
            if total > abortAbove { return total }
        }
        return total
    }

    /// Sub-pixel minimum of the parabola through three equally spaced costs.
    static func parabolicOffset(left: Double, centre: Double, right: Double) -> Double {
        let denominator = left - 2 * centre + right
        guard denominator > 0 else { return 0 }
        let offset = 0.5 * (left - right) / denominator
        // A fit landing outside the central sample is not a refinement.
        return abs(offset) <= 1 ? offset : 0
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
