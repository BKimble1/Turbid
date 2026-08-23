import XCTest
@testable import Lucid

/// Stage boundaries must follow presentation timestamps, never a frame count or
/// a wall clock: a dropped frame or a slow analyzer must shorten the number of
/// frames in a stage, not the stage itself.
final class CaptureProtocolTimelineTests: XCTestCase {

    private let timeline = CaptureProtocolTimeline(captureProtocol: .screening, startSeconds: 100)

    func testTheScreeningProtocolUsesTheIntendedWindowLength() {
        let captureProtocol = CaptureProtocol.screening
        XCTAssertGreaterThanOrEqual(captureProtocol.measurementWindowSeconds, 8)
        XCTAssertLessThanOrEqual(captureProtocol.measurementWindowSeconds, 10)
        XCTAssertEqual(captureProtocol.totalSeconds, 13.5, accuracy: 1e-9)
    }

    func testEachStageOccupiesItsOwnSpanOfTimestamps() {
        // Ambient 1.0s, torch settling 1.5s, background 2.0s, measurement 9.0s.
        XCTAssertEqual(timeline.stage(at: 100.0), .ambientReference)
        XCTAssertEqual(timeline.stage(at: 100.9), .ambientReference)
        XCTAssertEqual(timeline.stage(at: 101.0), .torchSettling)
        XCTAssertEqual(timeline.stage(at: 102.4), .torchSettling)
        XCTAssertEqual(timeline.stage(at: 102.5), .backgroundAcquisition)
        XCTAssertEqual(timeline.stage(at: 104.4), .backgroundAcquisition)
        XCTAssertEqual(timeline.stage(at: 104.5), .measurement)
        XCTAssertEqual(timeline.stage(at: 113.4), .measurement)
        XCTAssertEqual(timeline.stage(at: 113.5), .complete)
    }

    func testAFrameTimestampedBeforeTheStartBelongsToTheFirstStage() {
        // A frame already in flight when the run began.
        XCTAssertEqual(timeline.stage(at: 99.9), .ambientReference)
    }

    func testAProtocolWithNoAmbientBlockStartsAtTorchSettling() {
        var captureProtocol = CaptureProtocol.screening
        captureProtocol.ambientReferenceSeconds = 0
        let timeline = CaptureProtocolTimeline(captureProtocol: captureProtocol, startSeconds: 0)

        XCTAssertFalse(captureProtocol.capturesAmbientReference)
        XCTAssertEqual(timeline.stage(at: 0), .torchSettling)
        XCTAssertEqual(timeline.stage(at: 1.4), .torchSettling)
        XCTAssertEqual(timeline.stage(at: 1.6), .backgroundAcquisition)
    }

    func testOnlyBackgroundAndMeasurementFramesContributeToTheResult() {
        XCTAssertFalse(CaptureStage.ambientReference.contributesToResult)
        XCTAssertFalse(CaptureStage.torchSettling.contributesToResult)
        XCTAssertTrue(CaptureStage.backgroundAcquisition.contributesToResult)
        XCTAssertTrue(CaptureStage.measurement.contributesToResult)
        XCTAssertFalse(CaptureStage.complete.contributesToResult)
    }

    func testProgressIsMonotonicAndClamped() {
        XCTAssertEqual(timeline.progress(at: 90), 0, "before the start")
        XCTAssertEqual(timeline.progress(at: 100), 0)
        XCTAssertEqual(timeline.progress(at: 106.75), 0.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.progress(at: 113.5), 1)
        XCTAssertEqual(timeline.progress(at: 999), 1, "long past the end")

        var previous = 0.0
        for step in 0...200 {
            let value = timeline.progress(at: 100 + Double(step) * 0.1)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testStageProgressRunsZeroToOneWithinEachStage() {
        XCTAssertEqual(timeline.stageProgress(at: 100.0), 0, accuracy: 1e-9)
        XCTAssertEqual(timeline.stageProgress(at: 100.5), 0.5, accuracy: 1e-9)
        // Start of the measurement stage.
        XCTAssertEqual(timeline.stageProgress(at: 104.5), 0, accuracy: 1e-9)
        XCTAssertEqual(timeline.stageProgress(at: 109.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.stageProgress(at: 120), 1)
    }

    func testCompletionIsDecidedByTimestampNotByFrameCount() {
        XCTAssertFalse(timeline.isComplete(at: 113.4))
        XCTAssertTrue(timeline.isComplete(at: 113.5))
    }

    func testAStallDoesNotShortenAStage() {
        // Frames stop arriving for three seconds in the middle of the
        // measurement window. The stage must still end at the same timestamp.
        let beforeStall = timeline.stage(at: 106.0)
        let afterStall = timeline.stage(at: 109.0)
        XCTAssertEqual(beforeStall, .measurement)
        XCTAssertEqual(afterStall, .measurement)
        XCTAssertEqual(timeline.stage(at: 113.5), .complete)
    }

    func testExpectedFrameCountsScaleWithTheDeliveryRate() {
        XCTAssertEqual(timeline.expectedFrameCount(for: .measurement, atFrameRate: 30), 270)
        XCTAssertEqual(timeline.expectedFrameCount(for: .measurement, atFrameRate: 15), 135)
        XCTAssertEqual(timeline.expectedFrameCount(for: .backgroundAcquisition, atFrameRate: 30), 60)
        XCTAssertEqual(timeline.expectedFrameCount(for: .complete, atFrameRate: 30), 0)
        XCTAssertEqual(timeline.expectedFrameCount(for: .measurement, atFrameRate: 0), 0)
    }

    func testTheProtocolSurvivesACodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(CaptureProtocol.screening)
        let decoded = try JSONDecoder().decode(CaptureProtocol.self, from: encoded)
        XCTAssertEqual(decoded, CaptureProtocol.screening)
    }
}
