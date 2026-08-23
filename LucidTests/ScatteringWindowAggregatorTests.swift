import XCTest
@testable import Lucid

final class ScatteringWindowAggregatorTests: XCTestCase {

    private func bulk(residual: Double,
                      upper: Double = 0.01,
                      active: Double = 0.002) -> BulkScatteringMetrics {
        BulkScatteringMetrics(
            sampleCount: 100_000,
            meanPositiveResidual: residual,
            medianPositiveResidual: residual * 0.8,
            upperPercentileExcess: upper,
            activeForegroundFraction: active,
            residualBrightestTileShare: 0.07,
            residualSpatialVariation: 0.2,
            noiseSigma: 0.002,
            detectionThreshold: 0.01
        )
    }

    private func aggregator(
        _ mutate: (inout ScatteringWindowAggregator.Configuration) -> Void = { _ in }
    ) -> ScatteringWindowAggregator {
        var configuration = ScatteringWindowAggregator.Configuration.screening
        mutate(&configuration)
        return ScatteringWindowAggregator(configuration: configuration)
    }

    /// Feeds a steady stream at 30 fps.
    private func feed(_ target: inout ScatteringWindowAggregator,
                      seconds: Double,
                      residual: (Double) -> Double,
                      speckEvents: (Int) -> Int = { _ in 0 }) {
        let frames = Int(seconds * 30)
        for index in 0..<frames {
            let time = Double(index) / 30
            target.record(timestampSeconds: time,
                          bulk: bulk(residual: residual(time)),
                          newSpeckEvents: speckEvents(index))
        }
    }

    func testWindowsOverlapSoAnEventNearABoundaryIsWhollyInsideOne() {
        var target = aggregator()
        feed(&target, seconds: 9) { _ in 0.005 }
        target.finish()

        XCTAssertGreaterThan(target.windows.count, 3)
        for index in 1..<target.windows.count {
            XCTAssertLessThan(target.windows[index].startSeconds,
                              target.windows[index - 1].endSeconds,
                              "consecutive windows must overlap")
        }
    }

    func testASteadySignalSummarisesToItsOwnValueWithHighRepeatability() {
        var target = aggregator()
        feed(&target, seconds: 9) { _ in 0.005 }
        target.finish()
        let summary = target.summary()

        XCTAssertEqual(summary.medianPositiveResidual, 0.005, accuracy: 1e-6)
        XCTAssertEqual(summary.residualRelativeSpread, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(summary.repeatabilityConfidence, 0.9)
    }

    func testAWildlyVaryingSignalReportsPoorRepeatability() {
        var target = aggregator()
        // A two-second alternation against a three-second window, so
        // consecutive windows genuinely disagree. A period matching the stride
        // would average to the same value in every window and prove nothing.
        feed(&target, seconds: 15) { time in
            Int(time / 2.0) % 2 == 0 ? 0.002 : 0.020
        }
        target.finish()
        let summary = target.summary()

        XCTAssertGreaterThan(summary.residualRelativeSpread, 0.2,
                             "a measurement that does not repeat must say so")
        XCTAssertLessThan(summary.repeatabilityConfidence, 0.7)
    }

    func testOneSpoiledWindowDoesNotMoveTheMedian() {
        var target = aggregator()
        // A bubble drifts through for one window's worth of frames.
        feed(&target, seconds: 12) { time in
            (time >= 4.5 && time < 6.0) ? 0.100 : 0.005
        }
        target.finish()

        XCTAssertEqual(target.summary().medianPositiveResidual, 0.005, accuracy: 0.002,
                       "the median across windows must ignore a minority")
    }

    func testTheRawWindowsAreKeptForValidation() {
        var target = aggregator()
        feed(&target, seconds: 9) { time in 0.005 + time * 0.0001 }
        target.finish()

        XCTAssertFalse(target.windows.isEmpty)
        for window in target.windows {
            XCTAssertGreaterThan(window.frameCount, 0)
            XCTAssertGreaterThan(window.durationSeconds, 0)
        }
    }

    func testSmoothingIsForDisplayOnlyAndNeverChangesTheSummary() {
        var target = aggregator()
        feed(&target, seconds: 12) { time in time < 6 ? 0.002 : 0.020 }
        target.finish()

        let summary = target.summary()
        let smoothed = target.smoothedResidualForDisplay()

        XCTAssertNotEqual(smoothed, summary.medianPositiveResidual, accuracy: 1e-9,
                          "the two are different quantities and must not be confused")
        XCTAssertEqual(target.summary().medianPositiveResidual,
                       summary.medianPositiveResidual,
                       "asking for a smoothed value must not disturb the measurement")
    }

    func testStorageIsBoundedOverALongRun() {
        var target = aggregator { $0.maximumWindows = 4 }
        feed(&target, seconds: 60) { _ in 0.005 }
        target.finish()

        XCTAssertLessThanOrEqual(target.windows.count, 4)
        XCTAssertEqual(target.summary().medianPositiveResidual, 0.005, accuracy: 1e-6)
    }

    func testARunShorterThanOneWindowStillProducesAResult() {
        var target = aggregator()
        feed(&target, seconds: 1) { _ in 0.005 }
        target.finish()

        XCTAssertEqual(target.windows.count, 1)
        XCTAssertEqual(target.summary().medianPositiveResidual, 0.005, accuracy: 1e-6)
    }

    func testRepeatabilityIsNotClaimedFromTooFewWindows() {
        var target = aggregator()
        feed(&target, seconds: 2) { _ in 0.005 }
        target.finish()

        XCTAssertLessThan(target.windows.count, 3)
        XCTAssertEqual(target.summary().repeatabilityConfidence, 0,
                       "two windows cannot establish that a measurement repeats")
    }

    func testSpeckEventRateIsPerSecondNotPerFrame() {
        var target = aggregator()
        // One new speck every 30 frames, i.e. one per second.
        feed(&target, seconds: 9, residual: { _ in 0.005 }, speckEvents: { $0 % 30 == 0 ? 1 : 0 })
        target.finish()

        XCTAssertEqual(target.summary().medianSpeckEventsPerSecond, 1, accuracy: 0.35)
    }

    func testAnEmptyAggregatorSummarisesToNothing() {
        XCTAssertEqual(aggregator().summary(), .empty)
    }

    func testResetClearsEverything() {
        var target = aggregator()
        feed(&target, seconds: 9) { _ in 0.005 }
        target.finish()
        target.reset()

        XCTAssertTrue(target.windows.isEmpty)
        XCTAssertEqual(target.summary(), .empty)
    }
}
