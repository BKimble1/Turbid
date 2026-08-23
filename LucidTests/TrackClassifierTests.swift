import CoreGraphics
import XCTest
@testable import Lucid

/// The classifier is a pure function of a track's features, so it is exercised
/// directly with tracks built to realistic kinematics rather than through the
/// whole image pipeline.
///
/// Realistic means: a region of 960x475 pixels covering roughly 20 mm of
/// sample, a suspended particle settling or convecting at a fraction of a
/// millimetre per second, and an air bubble rising one to two orders of
/// magnitude faster.
final class TrackClassifierTests: XCTestCase {

    private static let regionWidth = 960
    private static let regionHeight = 475
    private static var regionDiagonal: Double {
        Double(regionWidth * regionWidth + regionHeight * regionHeight).squareRoot()
    }

    private let classifier = TrackClassifier(configuration: .screening)

    /// Builds a track that walks a prescribed path.
    ///
    /// - Parameters:
    ///   - normalizedSpeed: region diagonals per second.
    ///   - direction: unit direction of travel in image space.
    ///   - curvatureRadians: how far the direction rotates over the whole path.
    ///     Zero draws a straight line; a large value draws an arc.
    private func makeTrack(
        normalizedSpeed: Double,
        direction: CGVector,
        curvatureRadians: Double = 0,
        normalizedDiameter: Double,
        observations: Int,
        frameRate: Double = 30
    ) -> Track {
        let speedPixels = normalizedSpeed * Self.regionDiagonal
        var x = Double(Self.regionWidth) / 2
        var y = Double(Self.regionHeight) / 2
        var heading = atan2(Double(direction.dy), Double(direction.dx))
        let step = speedPixels / frameRate
        let turnPerStep = observations > 1 ? curvatureRadians / Double(observations - 1) : 0

        func observation(at index: Int) -> TrackObservation {
            TrackObservation(
                timestampSeconds: Double(index) / frameRate,
                position: CGPoint(x: x, y: y),
                rawPosition: CGPoint(x: x, y: y),
                areaPixels: max(1, Int((normalizedDiameter * Self.regionDiagonal / 2)
                                       * (normalizedDiameter * Self.regionDiagonal / 2) * .pi)),
                normalizedDiameter: normalizedDiameter,
                peakResponse: 0.05,
                eccentricity: 0.2
            )
        }

        var track = Track(id: 1,
                          observation: observation(at: 0),
                          capacity: 32,
                          processNoise: 400,
                          measurementNoise: 1)
        for index in 1..<max(2, observations) {
            x += step * cos(heading)
            y += step * sin(heading)
            heading += turnPerStep
            track.accept(observation(at: index), confirmAfter: 4)
        }
        return track
    }

    private func classify(_ track: Track,
                          gravity: GravityReference = .portraitAssumed) -> TrackClassifier.Verdict {
        classifier.classify(track, regionDiagonal: Self.regionDiagonal, gravity: gravity)
    }

    private static let up = CGVector(dx: 0, dy: -1)
    private static let down = CGVector(dx: 0, dy: 1)
    private static let sideways = CGVector(dx: 1, dy: 0)

    // MARK: - The four classes

    func testAStationaryDefectIsNotCountedAsASpeck() {
        let track = makeTrack(normalizedSpeed: 0.001,
                              direction: Self.sideways,
                              normalizedDiameter: 0.004,
                              observations: 20)
        let verdict = classify(track)

        XCTAssertEqual(verdict.classification, .staticDefect)
        XCTAssertGreaterThan(verdict.confidence, 0.5)
    }

    func testAStationaryBrightBubbleIsNotCountedAsASpeck() {
        // Large, bright and utterly still: a bubble stuck to the glass.
        let track = makeTrack(normalizedSpeed: 0.002,
                              direction: Self.sideways,
                              normalizedDiameter: 0.020,
                              observations: 20)
        XCTAssertEqual(classify(track).classification, .staticDefect)
    }

    func testALargeFastConsistentlyUpwardBubbleIsRejected() {
        let track = makeTrack(normalizedSpeed: 0.15,
                              direction: Self.up,
                              normalizedDiameter: 0.028,
                              observations: 15)
        let verdict = classify(track)

        XCTAssertEqual(verdict.classification, .risingBubble)
        XCTAssertGreaterThan(verdict.confidence, 0.5)
        XCTAssertNotEqual(verdict.classification, .suspendedSpeck)
    }

    func testASmallSlowCurvedTrackIsRetainedAsASpeck() {
        // Half a turn over the path: convection, not a ballistic rise.
        let track = makeTrack(normalizedSpeed: 0.020,
                              direction: Self.sideways,
                              curvatureRadians: .pi,
                              normalizedDiameter: 0.003,
                              observations: 20)
        let verdict = classify(track)

        XCTAssertEqual(verdict.classification, .suspendedSpeck)
        XCTAssertGreaterThan(verdict.confidence, 0.5)
        XCTAssertLessThan(track.straightness, 0.9, "the path must actually curve")
    }

    func testASinkingParticleIsASpeckNotABubble() {
        // Downward is the opposite of bubble-like, whatever the speed.
        let track = makeTrack(normalizedSpeed: 0.025,
                              direction: Self.down,
                              normalizedDiameter: 0.004,
                              observations: 15)
        XCTAssertEqual(classify(track).classification, .suspendedSpeck)
    }

    // MARK: - Ambiguity is reported, not resolved by guessing

    func testAnEventThatMatchesNeitherClassWellIsCalledAmbiguous() {
        // Small and slow like a speck, but straight and upward like a bubble.
        // Nothing about this is decidable, and the classifier must say so.
        let track = makeTrack(normalizedSpeed: 0.030,
                              direction: Self.up,
                              normalizedDiameter: 0.009,
                              observations: 12)
        let verdict = classify(track)

        XCTAssertEqual(verdict.classification, .ambiguous)
        XCTAssertLessThan(verdict.confidence,
                          TrackClassifier.Configuration.screening.minimumConfidenceMargin)
    }

    func testATrackSeenTooFewTimesIsNeverCountedAsASpeck() {
        let track = makeTrack(normalizedSpeed: 0.020,
                              direction: Self.sideways,
                              curvatureRadians: .pi,
                              normalizedDiameter: 0.003,
                              observations: 3)
        XCTAssertEqual(classify(track).classification, .ambiguous)
    }

    // MARK: - Direction evidence is only as good as the geometry

    func testConfidenceFallsAsGravityLeavesTheImagePlane() {
        let track = makeTrack(normalizedSpeed: 0.060,
                              direction: Self.up,
                              normalizedDiameter: 0.014,
                              observations: 12)

        let upright = classify(track, gravity: .portraitAssumed).confidence
        let tilted = classify(track, gravity: GravityReference(
            imageUp: CGVector(dx: 0, dy: -1), inPlaneFraction: 0.3
        )).confidence
        let flat = classify(track, gravity: GravityReference(
            imageUp: CGVector(dx: 0, dy: -1), inPlaneFraction: 0.05
        )).confidence

        XCTAssertGreaterThan(upright, tilted)
        XCTAssertGreaterThan(tilted, flat)
    }

    func testGravityFromDeviceOrientation() {
        // Phone upright, camera pointing horizontally: gravity is fully in the
        // image plane and points down the frame.
        let upright = GravityReference.portraitRearCamera(
            deviceGravityX: 0, deviceGravityY: -1, deviceGravityZ: 0
        )
        XCTAssertEqual(upright.inPlaneFraction, 1, accuracy: 1e-6)
        XCTAssertEqual(Double(upright.imageUp.dy), -1, accuracy: 1e-6)
        XCTAssertTrue(upright.directionIsInformative)

        // Phone lying flat, camera pointing down: gravity is along the optical
        // axis and a rising bubble barely moves in frame.
        let flat = GravityReference.portraitRearCamera(
            deviceGravityX: 0, deviceGravityY: 0, deviceGravityZ: 1
        )
        XCTAssertEqual(flat.inPlaneFraction, 0, accuracy: 1e-6)
        XCTAssertFalse(flat.directionIsInformative)

        // Tilted halfway.
        let tilted = GravityReference.portraitRearCamera(
            deviceGravityX: 0, deviceGravityY: -0.7071, deviceGravityZ: 0.7071
        )
        XCTAssertEqual(tilted.inPlaneFraction, 0.7071, accuracy: 0.001)
    }

    // MARK: - The building blocks

    func testTheScoreIsNoBetterThanItsWeakestRequirement() {
        // A geometric mean would rate this 0.63; every term is a necessary
        // condition, so the score must be 0.1.
        XCTAssertEqual(TrackClassifier.fuzzyAnd([0.1, 1, 1, 1, 1]), 0.1, accuracy: 1e-9)
        XCTAssertEqual(TrackClassifier.fuzzyAnd([1, 1, 1]), 1, accuracy: 1e-9)
        XCTAssertEqual(TrackClassifier.fuzzyAnd([0, 1, 1]), 0, accuracy: 1e-9)
        XCTAssertEqual(TrackClassifier.fuzzyAnd([]), 0)
    }

    func testRampIsClampedAndLinearBetween() {
        XCTAssertEqual(TrackClassifier.ramp(0, 1, 3), 0)
        XCTAssertEqual(TrackClassifier.ramp(1, 1, 3), 0)
        XCTAssertEqual(TrackClassifier.ramp(2, 1, 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TrackClassifier.ramp(3, 1, 3), 1)
        XCTAssertEqual(TrackClassifier.ramp(9, 1, 3), 1)
    }

    func testStraightnessSeparatesABallisticPathFromACurvedOne() {
        let straight = makeTrack(normalizedSpeed: 0.05, direction: Self.up,
                                 normalizedDiameter: 0.01, observations: 15)
        let curved = makeTrack(normalizedSpeed: 0.05, direction: Self.up,
                               curvatureRadians: .pi, normalizedDiameter: 0.01,
                               observations: 15)

        XCTAssertGreaterThan(straight.straightness, 0.95)
        XCTAssertLessThan(curved.straightness, 0.8)
    }

    func testUpwardConsistencyIsSignedAndBounded() {
        let rising = makeTrack(normalizedSpeed: 0.05, direction: Self.up,
                               normalizedDiameter: 0.01, observations: 10)
        let sinking = makeTrack(normalizedSpeed: 0.05, direction: Self.down,
                                normalizedDiameter: 0.01, observations: 10)
        let crossing = makeTrack(normalizedSpeed: 0.05, direction: Self.sideways,
                                 normalizedDiameter: 0.01, observations: 10)

        XCTAssertEqual(rising.upwardConsistency(up: Self.up), 1, accuracy: 0.01)
        XCTAssertEqual(sinking.upwardConsistency(up: Self.up), -1, accuracy: 0.01)
        XCTAssertEqual(crossing.upwardConsistency(up: Self.up), 0, accuracy: 0.01)
    }
}
