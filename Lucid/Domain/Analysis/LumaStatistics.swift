import Foundation

/// Summary statistics for one frame's analysis region.
struct LumaStatistics: Equatable, Sendable {
    /// Number of unmasked samples the statistics were computed from.
    let sampleCount: Int
    let mean: Float
    let standardDeviation: Float
    let minimum: Float
    let maximum: Float
    let percentile01: Float
    let percentile50: Float
    let percentile99: Float
    /// Fraction of samples at or above the saturation threshold.
    let saturatedFraction: Double
    /// Fraction of samples below the near-black threshold.
    let nearBlackFraction: Double
    /// Share of the region's total signal contributed by its brightest tile.
    ///
    /// A uniformly lit region spreads its signal evenly, so this sits near
    /// `1 / tileCount`. A specular hotspot concentrates it, pushing the value
    /// towards 1. That distinguishes "bright because the sample scatters a lot"
    /// from "bright because the torch is reflecting off the glass".
    let brightestTileShare: Double
    /// Variance of the discrete Laplacian, normalized by mean squared.
    ///
    /// Normalizing removes the dependence on overall brightness, so the same
    /// scene at two exposures scores the same. Higher is sharper.
    let sharpness: Double

    static let empty = LumaStatistics(
        sampleCount: 0, mean: 0, standardDeviation: 0, minimum: 0, maximum: 0,
        percentile01: 0, percentile50: 0, percentile99: 0,
        saturatedFraction: 0, nearBlackFraction: 0,
        brightestTileShare: 0, sharpness: 0
    )
}

/// Computes `LumaStatistics` over a region, honouring an optical mask.
///
/// A plain-Swift reference implementation: correct, readable and easy to test
/// against synthetic frames. Phase 3B profiles the pipeline and moves whichever
/// kernels prove to be hot onto Accelerate or Metal, keeping these results as
/// the golden values.
enum LumaStatisticsCalculator {

    /// Histogram bins used for percentiles. 256 matches the 8-bit source, so
    /// binning adds no error beyond the source quantisation.
    static let histogramBins = 256

    /// Tiles per axis for the hotspot-concentration measure.
    static let tileGrid = 4

    static func statistics(
        of image: LumaImage,
        mask: RasterizedMask?,
        saturationThreshold: Float = FrameNormalization.saturationThreshold,
        nearBlackThreshold: Float = FrameNormalization.nearBlackThreshold
    ) -> LumaStatistics {
        guard image.width > 0, image.height > 0 else { return .empty }

        var histogram = [Int](repeating: 0, count: histogramBins)
        var tileTotals = [Double](repeating: 0, count: tileGrid * tileGrid)

        var count = 0
        var total: Double = 0
        var totalOfSquares: Double = 0
        var minimum: Float = .greatestFiniteMagnitude
        var maximum: Float = -.greatestFiniteMagnitude
        var saturated = 0
        var nearBlack = 0

        let maximumBin = histogramBins - 1

        for y in 0..<image.height {
            let rowOffset = y * image.width
            let tileRow = min(tileGrid - 1, y * tileGrid / image.height)

            for x in 0..<image.width {
                let index = rowOffset + x
                if let mask, !mask.isValid(atIndex: index) { continue }

                let value = image.values[index]
                count += 1
                total += Double(value)
                totalOfSquares += Double(value) * Double(value)
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                if value >= saturationThreshold { saturated += 1 }
                if value < nearBlackThreshold { nearBlack += 1 }

                let bin = min(maximumBin, max(0, Int(value * Float(maximumBin))))
                histogram[bin] += 1

                let tileColumn = min(tileGrid - 1, x * tileGrid / image.width)
                tileTotals[tileRow * tileGrid + tileColumn] += Double(value)
            }
        }

        guard count > 0 else { return .empty }

        let mean = total / Double(count)
        // Population variance, floored at zero: floating-point cancellation can
        // make the difference of two near-equal sums very slightly negative.
        let variance = max(0, totalOfSquares / Double(count) - mean * mean)

        let brightestTile = tileTotals.max() ?? 0
        let tileShare = total > 0 ? brightestTile / total : 0

        return LumaStatistics(
            sampleCount: count,
            mean: Float(mean),
            standardDeviation: Float(variance.squareRoot()),
            minimum: minimum,
            maximum: maximum,
            percentile01: percentile(0.01, histogram: histogram, count: count),
            percentile50: percentile(0.50, histogram: histogram, count: count),
            percentile99: percentile(0.99, histogram: histogram, count: count),
            saturatedFraction: Double(saturated) / Double(count),
            nearBlackFraction: Double(nearBlack) / Double(count),
            brightestTileShare: tileShare,
            sharpness: sharpness(of: image, mask: mask, mean: mean)
        )
    }

    private static func percentile(_ fraction: Double, histogram: [Int], count: Int) -> Float {
        guard count > 0 else { return 0 }
        let target = max(1, Int((fraction * Double(count)).rounded()))
        var running = 0
        for (bin, binCount) in histogram.enumerated() {
            running += binCount
            if running >= target {
                return Float(bin) / Float(histogramBins - 1)
            }
        }
        return 1
    }

    /// Robustly estimates the sensor-noise standard deviation.
    ///
    /// Uses the median absolute difference between horizontally adjacent
    /// pixels. In a smooth region those differences are pure noise; the median
    /// ignores the minority of pairs that straddle a real edge or a speck. For
    /// Gaussian noise the difference of two neighbours has standard deviation
    /// `sigma * sqrt(2)`, and the median of its absolute value is
    /// `0.6745 * sigma * sqrt(2)`, which is inverted here.
    /// Rows are subsampled so the scratch buffer stays small regardless of the
    /// region's resolution. A median needs a representative sample, not every
    /// sample, and at capture resolution "every sample" would mean allocating
    /// and sorting hundreds of thousands of floats on every frame.
    static let noiseSampleTarget = 8_192

    static func estimateNoiseSigma(of image: LumaImage, mask: RasterizedMask?) -> Double {
        guard image.width >= 2, image.height >= 1 else { return 0 }

        let pairsPerRow = image.width - 1
        guard pairsPerRow > 0 else { return 0 }
        let rowStride = max(1, (image.height * pairsPerRow) / noiseSampleTarget)

        var differences: [Float] = []
        differences.reserveCapacity(((image.height / rowStride) + 1) * pairsPerRow)

        for y in Swift.stride(from: 0, to: image.height, by: rowStride) {
            let rowOffset = y * image.width
            for x in 0..<pairsPerRow {
                let index = rowOffset + x
                if let mask {
                    guard mask.isValid(atIndex: index), mask.isValid(atIndex: index + 1) else { continue }
                }
                differences.append(abs(image.values[index + 1] - image.values[index]))
            }
        }

        guard differences.count >= 8 else { return 0 }
        differences.sort()
        let median = Double(differences[differences.count / 2])
        // For Gaussian noise the difference of two neighbours has standard
        // deviation sigma * sqrt(2), and the median of its absolute value is
        // 0.6745 * sigma * sqrt(2). Inverted here.
        return median / (0.6745 * 2.0.squareRoot())
    }

    /// Variance of the 4-neighbour discrete Laplacian over interior pixels,
    /// with the sensor-noise contribution removed.
    ///
    /// A blurred image has small second derivatives everywhere, so the variance
    /// collapses; a sharp one has large ones at edges. Dividing by mean squared
    /// makes the score independent of exposure, which matters because the two
    /// measurement modes run at very different brightness levels.
    ///
    /// The noise term is not optional. White noise of standard deviation
    /// `sigma` produces a Laplacian variance of `20 * sigma^2` all by itself
    /// (`16` from the centre tap and `4` from the four neighbours), and at a
    /// realistic sensor noise level that swamps the real detail: a completely
    /// defocused frame would otherwise score more than an order of magnitude
    /// above any usable threshold, and the focus gate could never fire.
    static func sharpness(of image: LumaImage, mask: RasterizedMask?, mean: Double) -> Double {
        guard image.width >= 3, image.height >= 3, mean > 0 else { return 0 }

        var count = 0
        var total: Double = 0
        var totalOfSquares: Double = 0

        for y in 1..<(image.height - 1) {
            let rowOffset = y * image.width
            for x in 1..<(image.width - 1) {
                let index = rowOffset + x
                if let mask {
                    guard mask.isValid(atIndex: index),
                          mask.isValid(atIndex: index - 1),
                          mask.isValid(atIndex: index + 1),
                          mask.isValid(atIndex: index - image.width),
                          mask.isValid(atIndex: index + image.width) else { continue }
                }

                let laplacian = Double(
                    4 * image.values[index]
                        - image.values[index - 1]
                        - image.values[index + 1]
                        - image.values[index - image.width]
                        - image.values[index + image.width]
                )
                count += 1
                total += laplacian
                totalOfSquares += laplacian * laplacian
            }
        }

        guard count > 1 else { return 0 }
        let laplacianMean = total / Double(count)
        let variance = max(0, totalOfSquares / Double(count) - laplacianMean * laplacianMean)

        let sigma = estimateNoiseSigma(of: image, mask: mask)
        let noiseVariance = 20 * sigma * sigma
        return max(0, variance - noiseVariance) / (mean * mean)
    }

    /// Mean absolute difference between two equally sized planes, with the
    /// sensor-noise floor removed, normalized by their mean level.
    ///
    /// Computed on the coarse plane, where individual specks have been averaged
    /// away, so what remains is dominated by whole-frame movement.
    ///
    /// Subtracting the noise floor is what makes the number mean anything. Two
    /// consecutive frames of a perfectly still scene still differ by their
    /// independent sensor noise: for noise of standard deviation `sigma` the
    /// difference has standard deviation `sigma * sqrt(2)` and mean absolute
    /// value `2 * sigma / sqrt(pi)`. At realistic noise levels that floor is
    /// larger than the signal from a visible camera pan, so without removing it
    /// a still scene and a moving one are indistinguishable.
    ///
    /// This remains a deliberately cheap stand-in with two real limitations.
    /// The reading depends on how much contrast the scene has, so the same
    /// physical movement scores differently on a textured sample than on a
    /// featureless one. And a whole-frame brightness change — exposure flicker,
    /// a torch whose output is still settling — is indistinguishable from
    /// movement, so it registers here as well as in the exposure gate. Both are
    /// acceptable for a gate whose only job is to reject the window: it is
    /// rejected either way. Phase 3C replaces this with an optical flow field,
    /// which measures displacement directly and separates camera motion from
    /// particle motion and from illumination change.
    static func normalizedDifference(between first: LumaImage, and second: LumaImage) -> Double {
        guard first.width == second.width,
              first.height == second.height,
              first.count > 0 else { return 0 }

        var total: Double = 0
        var level: Double = 0
        for index in 0..<first.count {
            total += Double(abs(first.values[index] - second.values[index]))
            level += Double(first.values[index] + second.values[index]) / 2
        }

        let meanLevel = level / Double(first.count)
        guard meanLevel > 0 else { return 0 }

        let sigma = (estimateNoiseSigma(of: first, mask: nil)
                     + estimateNoiseSigma(of: second, mask: nil)) / 2
        // 2 / sqrt(pi) = 1.1284: the mean absolute value of the difference of
        // two independent zero-mean Gaussians of standard deviation sigma.
        let noiseFloor = 1.1284 * sigma

        return max(0, (total / Double(first.count)) - noiseFloor) / meanLevel
    }
}
