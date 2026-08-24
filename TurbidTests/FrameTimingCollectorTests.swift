import XCTest
@testable import Turbid

final class FrameTimingCollectorTests: XCTestCase {

    func testAnEmptyCollectorReportsNothing() {
        let statistics = FrameTimingCollector().statistics()

        XCTAssertEqual(statistics.deliveredFrames, 0)
        XCTAssertEqual(statistics.measuredFrameRate, 0)
        XCTAssertFalse(statistics.isContinuous())
    }

    func testRegularThirtyHertzTimestampsMeasureThirtyFramesPerSecond() {
        var collector = FrameTimingCollector()
        for index in 0..<60 {
            collector.record(presentationSeconds: Double(index) / 30.0)
        }
        let statistics = collector.statistics()

        XCTAssertEqual(statistics.deliveredFrames, 60)
        XCTAssertEqual(statistics.measuredFrameRate, 30, accuracy: 0.01)
        XCTAssertEqual(statistics.spanSeconds, 59.0 / 30.0, accuracy: 1e-9)
        XCTAssertTrue(statistics.isContinuous())
    }

    func testIrregularTimestampsAreMeasuredNotAssumed() {
        // A camera quietly throttling to 24 fps must be reported as 24 fps,
        // not as the 30 fps that was requested.
        var collector = FrameTimingCollector()
        for index in 0..<48 {
            collector.record(presentationSeconds: Double(index) / 24.0)
        }

        XCTAssertEqual(collector.statistics().measuredFrameRate, 24, accuracy: 0.01)
    }

    func testASingleLongStallIsReportedAsDiscontinuousWithoutSkewingTheRate() {
        var collector = FrameTimingCollector()
        for index in 0..<30 {
            collector.record(presentationSeconds: Double(index) / 30.0)
        }
        // A one-second gap in the middle of a 30 fps stream.
        collector.record(presentationSeconds: 1.0 + 1.0)
        for index in 1..<30 {
            collector.record(presentationSeconds: 2.0 + Double(index) / 30.0)
        }
        let statistics = collector.statistics()

        XCTAssertEqual(statistics.measuredFrameRate, 30, accuracy: 0.5,
                       "the median must not be dragged down by one stall")
        XCTAssertGreaterThan(statistics.maximumIntervalSeconds, 0.9)
        XCTAssertFalse(statistics.isContinuous(),
                       "a stall invalidates a window even when the average looks healthy")
    }

    func testOutOfOrderAndNonFiniteTimestampsAreIgnored() {
        var collector = FrameTimingCollector()
        collector.record(presentationSeconds: 1.0)
        collector.record(presentationSeconds: 0.5)          // earlier than the last
        collector.record(presentationSeconds: .nan)
        collector.record(presentationSeconds: .infinity)
        collector.record(presentationSeconds: 1.0)          // identical timestamp

        let statistics = collector.statistics()
        XCTAssertEqual(statistics.deliveredFrames, 1)
        XCTAssertEqual(statistics.medianIntervalSeconds, 0)
    }

    func testDropsAreCountedAndRatioed() {
        var collector = FrameTimingCollector()
        for index in 0..<90 {
            collector.record(presentationSeconds: Double(index) / 30.0)
        }
        for _ in 0..<10 {
            collector.recordDrop()
        }
        let statistics = collector.statistics()

        XCTAssertEqual(statistics.droppedFrames, 10)
        XCTAssertEqual(statistics.totalFrames, 100)
        XCTAssertEqual(statistics.dropRatio, 0.1, accuracy: 1e-9)
    }

    func testStorageIsBoundedSoALongSessionCannotGrow() {
        var small = FrameTimingCollector(capacity: 8)
        for index in 0..<10_000 {
            small.record(presentationSeconds: Double(index) / 30.0)
        }
        let statistics = small.statistics()

        XCTAssertEqual(statistics.deliveredFrames, 10_000, "the count is still exact")
        XCTAssertEqual(statistics.measuredFrameRate, 30, accuracy: 0.01,
                       "and the rate is still right from a bounded window")
    }

    func testTheRingBufferKeepsTheMostRecentIntervals() {
        var collector = FrameTimingCollector(capacity: 4)
        // Ten frames at 10 fps, then four at 30 fps. Only the recent ones fit.
        for index in 0..<10 {
            collector.record(presentationSeconds: Double(index) / 10.0)
        }
        let base = 1.0
        for index in 1...4 {
            collector.record(presentationSeconds: base + Double(index) / 30.0)
        }

        XCTAssertEqual(collector.statistics().measuredFrameRate, 30, accuracy: 1.0)
    }

    func testResetClearsEverything() {
        var collector = FrameTimingCollector()
        collector.record(presentationSeconds: 1)
        collector.record(presentationSeconds: 2)
        collector.recordDrop()
        collector.reset()

        let statistics = collector.statistics()
        XCTAssertEqual(statistics.deliveredFrames, 0)
        XCTAssertEqual(statistics.droppedFrames, 0)
        XCTAssertNil(statistics.firstTimestampSeconds)
    }

    func testRecorderIsUsableFromMultipleThreads() {
        let recorder = FrameTimingRecorder()
        let iterations = 500

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            recorder.record(presentationSeconds: Double(index) / 30.0)
        }

        // Timestamps arrive out of order under concurrency, so only the ones
        // that moved forwards are counted; the point is that the lock holds and
        // nothing is lost or corrupted.
        let statistics = recorder.statistics()
        XCTAssertGreaterThan(statistics.deliveredFrames, 0)
        XCTAssertLessThanOrEqual(statistics.deliveredFrames, iterations)
    }
}
