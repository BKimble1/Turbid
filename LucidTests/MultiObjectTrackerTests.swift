import CoreGraphics
import XCTest
@testable import Lucid

/// Association and lifecycle, driven with synthetic detections so the
/// behaviour under crossing, occlusion and irregular timing can be stated
/// exactly.
final class MultiObjectTrackerTests: XCTestCase {

    private static let width = 960
    private static let height = 475

    private func makeTracker(
        _ mutate: (inout MultiObjectTracker.Configuration) -> Void = { _ in }
    ) -> MultiObjectTracker {
        var configuration = MultiObjectTracker.Configuration.screening
        mutate(&configuration)
        let tracker = MultiObjectTracker(configuration: configuration)
        tracker.prepare(regionWidth: Self.width, regionHeight: Self.height)
        return tracker
    }

    private func candidate(x: Double, y: Double,
                           diameter: Double = 0.003,
                           response: Float = 0.05) -> SpeckCandidate {
        SpeckCandidate(
            centroidX: x, centroidY: y,
            normalizedCentroid: CGPoint(x: x / Double(Self.width), y: y / Double(Self.height)),
            areaPixels: 9, normalizedArea: 0.0001,
            equivalentDiameterPixels: 3.4, normalizedDiameter: diameter,
            peakResponse: response, integratedResponse: 0.2,
            peakResidual: 0.08, localContrast: 3,
            eccentricity: 0.2, fillRatio: 0.7,
            boundingBox: PixelRect(x: Int(x) - 2, y: Int(y) - 2, width: 4, height: 4),
            distanceToExclusionPixels: 100, normalizedDistanceToExclusion: 0.1,
            containsSaturatedPixel: false
        )
    }

    // MARK: - Identity

    func testASteadilyMovingDetectionKeepsOneIdentity() {
        let tracker = makeTracker()
        for frame in 0..<20 {
            tracker.update(candidates: [candidate(x: 100 + Double(frame) * 3, y: 200)],
                           timestampSeconds: Double(frame) / 30,
                           motion: .none)
        }

        XCTAssertEqual(tracker.tracks.count, 1)
        XCTAssertEqual(tracker.tracks.first?.id, 1)
        XCTAssertEqual(tracker.tracks.first?.state, .confirmed)
        XCTAssertEqual(tracker.tracks.first?.totalObservations, 20)
    }

    func testATrackIsOnlyConfirmedAfterEnoughSightings() {
        let tracker = makeTracker()
        let confirmAfter = MultiObjectTracker.Configuration.screening.confirmAfterObservations

        for frame in 0..<(confirmAfter - 1) {
            tracker.update(candidates: [candidate(x: 100 + Double(frame) * 3, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: .none)
        }
        XCTAssertEqual(tracker.tracks.first?.state, .tentative,
                       "a single noise detection must never be counted")

        tracker.update(candidates: [candidate(x: 100 + Double(confirmAfter - 1) * 3, y: 200)],
                       timestampSeconds: Double(confirmAfter - 1) / 30, motion: .none)
        XCTAssertEqual(tracker.tracks.first?.state, .confirmed)
    }

    func testAOneFrameDetectionIsDiscardedRatherThanCounted() {
        let tracker = makeTracker()
        tracker.update(candidates: [candidate(x: 500, y: 200)],
                       timestampSeconds: 0, motion: .none)
        for frame in 1...6 {
            tracker.update(candidates: [], timestampSeconds: Double(frame) / 30, motion: .none)
        }
        XCTAssertTrue(tracker.tracks.isEmpty)
    }

    // MARK: - Crossing

    func testTwoCrossingTracksDoNotDoubleCount() {
        // Two specks approach, meet in the middle, and continue. The identities
        // must survive: restarting one as a new track would count one particle
        // twice.
        let tracker = makeTracker()
        for frame in 0..<40 {
            let time = Double(frame) / 30
            let offset = Double(frame) * 4
            tracker.update(candidates: [
                candidate(x: 300 + offset, y: 200 + offset * 0.5),
                candidate(x: 460 - offset, y: 200 + offset * 0.5)
            ], timestampSeconds: time, motion: .none)
        }

        let confirmed = tracker.tracks.filter { $0.state.isCountable }
        XCTAssertEqual(confirmed.count, 2,
                       "two particles crossing must remain two tracks, got \(tracker.tracks.count)")
        XCTAssertEqual(Set(confirmed.map(\.id)), [1, 2])
    }

    func testOneDetectionCannotUpdateTwoTracks() {
        // Two tracks converge onto a single detection. Only one may take it;
        // the other must record a miss.
        let tracker = makeTracker()
        for frame in 0..<10 {
            tracker.update(candidates: [candidate(x: 400, y: 200), candidate(x: 420, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: .none)
        }
        XCTAssertEqual(tracker.tracks.count, 2)

        tracker.update(candidates: [candidate(x: 410, y: 200)],
                       timestampSeconds: 10.0 / 30, motion: .none)

        let updated = tracker.tracks.filter { $0.missedFrames == 0 }
        XCTAssertEqual(updated.count, 1, "a detection may only feed one track")
    }

    // MARK: - Occlusion

    func testAShortDisappearanceDoesNotRestartTheTrack() {
        let tracker = makeTracker()
        for frame in 0..<10 {
            tracker.update(candidates: [candidate(x: 100 + Double(frame) * 5, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: .none)
        }
        // Two frames with nothing, then the speck reappears where the filter
        // predicts it.
        tracker.update(candidates: [], timestampSeconds: 10.0 / 30, motion: .none)
        tracker.update(candidates: [], timestampSeconds: 11.0 / 30, motion: .none)
        tracker.update(candidates: [candidate(x: 160, y: 200)],
                       timestampSeconds: 12.0 / 30, motion: .none)

        XCTAssertEqual(tracker.tracks.count, 1,
                       "a brief occlusion must not create a second track")
        XCTAssertEqual(tracker.tracks.first?.id, 1)
        XCTAssertEqual(tracker.tracks.first?.missedFrames, 0)
    }

    func testALongDisappearanceEndsTheTrack() {
        let tracker = makeTracker()
        for frame in 0..<10 {
            tracker.update(candidates: [candidate(x: 100 + Double(frame) * 5, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: .none)
        }
        for frame in 10..<20 {
            tracker.update(candidates: [], timestampSeconds: Double(frame) / 30, motion: .none)
        }
        XCTAssertEqual(tracker.tracks.first?.state, .lost)
    }

    // MARK: - Timing

    func testIrregularTimestampsYieldCorrectVelocities() {
        // The same physical motion delivered on an irregular clock must produce
        // the same velocity. A tracker assuming a fixed frame interval would
        // get this wrong by the ratio of the intervals.
        let tracker = makeTracker()
        let speed = 90.0
        var time = 0.0
        var x = 200.0
        let intervals = [1.0 / 30, 1.0 / 30, 2.0 / 30, 1.0 / 30, 3.0 / 30,
                         1.0 / 30, 1.0 / 30, 2.0 / 30, 1.0 / 30, 1.0 / 30,
                         1.0 / 30, 2.0 / 30, 1.0 / 30, 1.0 / 30, 1.0 / 30]

        tracker.update(candidates: [candidate(x: x, y: 200)],
                       timestampSeconds: time, motion: .none)
        for interval in intervals {
            time += interval
            x += speed * interval
            tracker.update(candidates: [candidate(x: x, y: 200)],
                           timestampSeconds: time, motion: .none)
        }

        let track = tracker.tracks.first
        XCTAssertEqual(track?.velocity.dx ?? 0, speed, accuracy: speed * 0.15)
        XCTAssertEqual(track?.velocity.dy ?? 0, 0, accuracy: 5)
        XCTAssertEqual(track?.medianStepSpeed ?? 0, speed, accuracy: speed * 0.05,
                       "the step speed is computed from real intervals")
    }

    func testADroppedFrameWidensTheAssociationGate() {
        // With a doubled interval the target has moved twice as far, and the
        // gate has to grow with it or the track is lost.
        let tracker = makeTracker()
        var x = 200.0
        tracker.update(candidates: [candidate(x: x, y: 200)], timestampSeconds: 0, motion: .none)
        for frame in 1...5 {
            x += 8
            tracker.update(candidates: [candidate(x: x, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: .none)
        }
        // One frame missing: twice the interval, twice the distance.
        x += 16
        tracker.update(candidates: [candidate(x: x, y: 200)],
                       timestampSeconds: 7.0 / 30, motion: .none)

        XCTAssertEqual(tracker.tracks.count, 1)
        XCTAssertEqual(tracker.tracks.first?.missedFrames, 0)
    }

    // MARK: - Motion compensation

    func testAStationaryObjectUnderAPanIsTrackedAsStationary() {
        // The camera pans; a stationary defect's image position moves with it.
        // After compensation its track must show no motion.
        let tracker = makeTracker()
        let panPixelsPerSecond = 60.0

        for frame in 0..<20 {
            let time = Double(frame) / 30
            let shift = panPixelsPerSecond * time
            let motion = GlobalMotion(
                cumulativeOffset: CGVector(dx: shift, dy: 0),
                flow: GlobalFlow(dxPixelsPerSecond: panPixelsPerSecond, dyPixelsPerSecond: 0,
                                 confidence: 1, patchesUsed: 10, patchesOffered: 20),
                isTrustworthy: true
            )
            tracker.update(candidates: [candidate(x: 400 + shift, y: 200)],
                           timestampSeconds: time, motion: motion)
        }

        let track = tracker.tracks.first
        XCTAssertEqual(track?.medianStepSpeed ?? .nan, 0, accuracy: 1,
                       "compensation must remove the camera's contribution")
    }

    func testAnUntrustworthyFlowIsNotSubtracted() {
        // Compensating with a wrong vector is worse than not compensating.
        let tracker = makeTracker()
        for frame in 0..<10 {
            let motion = GlobalMotion(
                cumulativeOffset: CGVector(dx: 500, dy: 500),
                flow: GlobalFlow(dxPixelsPerSecond: 900, dyPixelsPerSecond: 900,
                                 confidence: 0.1, patchesUsed: 4, patchesOffered: 49),
                isTrustworthy: false
            )
            tracker.update(candidates: [candidate(x: 400, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: motion)
        }

        let position = tracker.tracks.first?.observations.last?.position
        XCTAssertEqual(Double(position?.x ?? 0), 400, accuracy: 1)
        XCTAssertEqual(Double(position?.y ?? 0), 200, accuracy: 1)
    }

    // MARK: - Bounds

    func testTheTrackCapIsReportedRatherThanHidden() {
        let tracker = makeTracker { $0.maximumTracks = 5 }
        let candidates = (0..<20).map { candidate(x: 50 + Double($0) * 40, y: 200) }
        tracker.update(candidates: candidates, timestampSeconds: 0, motion: .none)

        XCTAssertEqual(tracker.tracks.count, 5)
        XCTAssertEqual(tracker.droppedForCapacity, 15,
                       "a run that hit the cap has counts that are a lower bound")
    }

    func testTheObservationHistoryStaysBounded() {
        let tracker = makeTracker()
        for frame in 0..<500 {
            tracker.update(candidates: [candidate(x: 100 + Double(frame % 50) * 2, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: .none)
        }
        for track in tracker.tracks {
            XCTAssertLessThanOrEqual(track.observations.count,
                                     MultiObjectTracker.Configuration.screening.observationCapacity)
        }
    }

    func testResetClearsEverything() {
        let tracker = makeTracker()
        for frame in 0..<10 {
            tracker.update(candidates: [candidate(x: 100 + Double(frame) * 5, y: 200)],
                           timestampSeconds: Double(frame) / 30, motion: .none)
        }
        tracker.reset()

        XCTAssertTrue(tracker.tracks.isEmpty)
        XCTAssertEqual(tracker.droppedForCapacity, 0)

        tracker.update(candidates: [candidate(x: 100, y: 200)], timestampSeconds: 0, motion: .none)
        XCTAssertEqual(tracker.tracks.first?.id, 1, "identifiers restart with the run")
    }
}
