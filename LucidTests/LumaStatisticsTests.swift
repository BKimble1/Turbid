import XCTest
@testable import Lucid

final class LumaStatisticsTests: XCTestCase {

    private func image(width: Int, height: Int, _ generator: (Int, Int) -> Float) -> LumaImage {
        var image = LumaImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = generator(x, y)
            }
        }
        return image
    }

    // MARK: - Normalization

    func testFullRangeLumaMapsTheWholeCodeRange() {
        XCTAssertEqual(FrameNormalization.normalize(code: 0, range: .full), 0, accuracy: 1e-6)
        XCTAssertEqual(FrameNormalization.normalize(code: 255, range: .full), 1, accuracy: 1e-6)
        XCTAssertEqual(FrameNormalization.normalize(code: 128, range: .full), 0.502, accuracy: 0.002)
    }

    func testVideoRangeLumaMapsSixteenToTwoThirtyFive() {
        XCTAssertEqual(FrameNormalization.normalize(code: 16, range: .video), 0, accuracy: 1e-6)
        XCTAssertEqual(FrameNormalization.normalize(code: 235, range: .video), 1, accuracy: 1e-6)
        XCTAssertEqual(FrameNormalization.normalize(code: 125, range: .video), 0.4977, accuracy: 0.002)
    }

    func testOutOfRangeVideoCodesAreClampedNotWrapped() {
        // Codes outside 16...235 are legal in the bitstream. Letting them
        // through would put values outside 0...1 where the gates cannot see them.
        XCTAssertEqual(FrameNormalization.normalize(code: 0, range: .video), 0)
        XCTAssertEqual(FrameNormalization.normalize(code: 255, range: .video), 1)
    }

    // MARK: - Basic statistics

    func testAUniformImageHasZeroSpread() {
        let statistics = LumaStatisticsCalculator.statistics(
            of: image(width: 20, height: 20) { _, _ in 0.4 }, mask: nil
        )

        XCTAssertEqual(statistics.sampleCount, 400)
        XCTAssertEqual(statistics.mean, 0.4, accuracy: 1e-5)
        XCTAssertEqual(statistics.standardDeviation, 0, accuracy: 1e-5)
        XCTAssertEqual(statistics.minimum, 0.4, accuracy: 1e-5)
        XCTAssertEqual(statistics.maximum, 0.4, accuracy: 1e-5)
    }

    func testAnEmptyImageYieldsEmptyStatistics() {
        XCTAssertEqual(LumaStatisticsCalculator.statistics(of: LumaImage(width: 0, height: 0), mask: nil),
                       .empty)
    }

    func testPercentilesTrackTheDistribution() {
        // A linear ramp from 0 to almost 1 across 100 columns.
        let statistics = LumaStatisticsCalculator.statistics(
            of: image(width: 100, height: 10) { x, _ in Float(x) / 100 }, mask: nil
        )

        XCTAssertEqual(statistics.percentile50, 0.5, accuracy: 0.03)
        XCTAssertEqual(statistics.percentile99, 0.99, accuracy: 0.03)
        XCTAssertEqual(statistics.percentile01, 0.01, accuracy: 0.03)
    }

    func testSaturatedAndNearBlackFractionsAreCounted() {
        // A quarter clipped, a quarter black, half mid-grey.
        let statistics = LumaStatisticsCalculator.statistics(
            of: image(width: 4, height: 1) { x, _ in
                switch x {
                case 0: return 1.0
                case 1: return 0.0
                default: return 0.5
                }
            }, mask: nil
        )

        XCTAssertEqual(statistics.saturatedFraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(statistics.nearBlackFraction, 0.25, accuracy: 1e-9)
    }

    // MARK: - Masking

    func testMaskedPixelsAreExcludedFromEveryStatistic() {
        // Left half is blown out, right half is mid-grey. Masking the left half
        // must leave statistics that see only the right half.
        let source = image(width: 20, height: 20) { x, _ in x < 10 ? 1.0 : 0.3 }
        let description = OpticalMaskDescription(
            excludedRectangles: [CGRect(x: 0, y: 0, width: 0.5, height: 1)],
            excludedEllipses: []
        )
        let mask = RasterizedMask(description: description, width: 20, height: 20)
        let statistics = LumaStatisticsCalculator.statistics(of: source, mask: mask)

        XCTAssertEqual(statistics.sampleCount, 200)
        XCTAssertEqual(statistics.mean, 0.3, accuracy: 1e-5)
        XCTAssertEqual(statistics.saturatedFraction, 0, accuracy: 1e-9,
                       "the clipped half was masked out, so nothing is saturated")
    }

    // MARK: - Hotspot concentration

    func testAnEvenlyLitRegionSpreadsItsSignalAcrossTheTiles() {
        let statistics = LumaStatisticsCalculator.statistics(
            of: image(width: 40, height: 40) { _, _ in 0.4 }, mask: nil
        )
        // A 4x4 grid over a uniform image gives each tile 1/16 of the signal.
        XCTAssertEqual(statistics.brightestTileShare, 1.0 / 16.0, accuracy: 0.01)
    }

    func testASpecularHighlightConcentratesTheSignalInOneTile() {
        let statistics = LumaStatisticsCalculator.statistics(
            of: image(width: 40, height: 40) { x, y in
                (x < 10 && y < 10) ? 1.0 : 0.02
            }, mask: nil
        )
        XCTAssertGreaterThan(statistics.brightestTileShare, 0.7,
                             "one bright corner must dominate the signal")
    }

    // MARK: - Sharpness

    func testASharpEdgeScoresHigherThanABlurredOne() {
        let sharp = image(width: 40, height: 40) { x, _ in x < 20 ? 0.2 : 0.6 }
        // The same edge spread over eight pixels.
        let blurred = image(width: 40, height: 40) { x, _ in
            let t = min(max((Float(x) - 16) / 8, 0), 1)
            return 0.2 + 0.4 * t
        }

        let sharpScore = LumaStatisticsCalculator.statistics(of: sharp, mask: nil).sharpness
        let blurredScore = LumaStatisticsCalculator.statistics(of: blurred, mask: nil).sharpness

        XCTAssertGreaterThan(sharpScore, blurredScore * 4)
    }

    func testAFlatImageHasNoSharpness() {
        let statistics = LumaStatisticsCalculator.statistics(
            of: image(width: 20, height: 20) { _, _ in 0.5 }, mask: nil
        )
        XCTAssertEqual(statistics.sharpness, 0, accuracy: 1e-9)
    }

    func testSharpnessIsIndependentOfOverallBrightness() {
        // The same pattern at two exposures must score the same, because the
        // two measurement modes run at very different brightness.
        let dim = image(width: 40, height: 40) { x, _ in x < 20 ? 0.1 : 0.3 }
        let bright = image(width: 40, height: 40) { x, _ in x < 20 ? 0.2 : 0.6 }

        let dimScore = LumaStatisticsCalculator.statistics(of: dim, mask: nil).sharpness
        let brightScore = LumaStatisticsCalculator.statistics(of: bright, mask: nil).sharpness

        XCTAssertEqual(dimScore, brightScore, accuracy: dimScore * 0.02)
    }

    func testSharpnessIsZeroForAnImageTooSmallToHaveAnInterior() {
        let tiny = LumaImage(width: 2, height: 2, fill: 0.5)
        XCTAssertEqual(LumaStatisticsCalculator.sharpness(of: tiny, mask: nil, mean: 0.5), 0)
    }

    // MARK: - Frame-to-frame difference

    func testIdenticalFramesHaveNoDifference() {
        let frame = image(width: 16, height: 16) { x, y in Float(x + y) / 32 }
        XCTAssertEqual(LumaStatisticsCalculator.normalizedDifference(between: frame, and: frame), 0,
                       accuracy: 1e-9)
    }

    func testAShiftedFrameProducesALargerDifferenceThanAStillOne() {
        let still = image(width: 16, height: 16) { x, _ in x < 8 ? 0.2 : 0.6 }
        let shifted = image(width: 16, height: 16) { x, _ in x < 10 ? 0.2 : 0.6 }

        let stillDifference = LumaStatisticsCalculator.normalizedDifference(between: still, and: still)
        let shiftedDifference = LumaStatisticsCalculator.normalizedDifference(between: still, and: shifted)

        XCTAssertGreaterThan(shiftedDifference, stillDifference)
        XCTAssertGreaterThan(shiftedDifference, 0.05)
    }

    func testMismatchedSizesReportNoDifferenceRatherThanReadingOutOfBounds() {
        let a = LumaImage(width: 8, height: 8, fill: 0.5)
        let b = LumaImage(width: 4, height: 4, fill: 0.5)
        XCTAssertEqual(LumaStatisticsCalculator.normalizedDifference(between: a, and: b), 0)
    }

    // MARK: - Box averaging

    func testBoxAveragingPreservesTheMeanLevel() {
        let source = image(width: 64, height: 64) { x, y in Float((x % 8) + (y % 8)) / 16 }
        var destination = LumaImage(width: 8, height: 8)
        source.boxAverage(into: &destination)

        let sourceMean = LumaStatisticsCalculator.statistics(of: source, mask: nil).mean
        let destinationMean = LumaStatisticsCalculator.statistics(of: destination, mask: nil).mean
        XCTAssertEqual(sourceMean, destinationMean, accuracy: 1e-4)
    }

    func testBoxAveragingSuppressesSinglePixelDetail() {
        // One bright pixel in an otherwise dark frame: exactly what downscaling
        // before speck detection would destroy, and why detection does not.
        var source = LumaImage(width: 64, height: 64, fill: 0.1)
        source[32, 32] = 1.0
        var destination = LumaImage(width: 8, height: 8)
        source.boxAverage(into: &destination)

        XCTAssertLessThan(destination[4, 4], 0.13,
                          "a single speck must be averaged away on the coarse plane")
    }

    func testBoxAveragingIntoAnEmptyDestinationIsSafe() {
        let source = LumaImage(width: 8, height: 8, fill: 0.5)
        var destination = LumaImage(width: 0, height: 0)
        source.boxAverage(into: &destination)
        XCTAssertEqual(destination.count, 0)
    }

    // MARK: - LumaImage

    func testAMismatchedBufferIsRejectedRatherThanMisread() {
        XCTAssertNil(LumaImage(width: 4, height: 4, values: [0, 1, 2]))
        XCTAssertNotNil(LumaImage(width: 2, height: 2, values: [0, 1, 2, 3]))
    }
}
