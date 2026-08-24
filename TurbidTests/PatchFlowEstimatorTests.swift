import CoreGraphics
import XCTest
@testable import Turbid

/// Global motion estimation against synthetic scenes whose true motion is known.
///
/// The sign is the thing these tests exist for. A sign error would not fail
/// loudly: compensation would *double* the apparent camera motion instead of
/// removing it, and every velocity downstream would be wrong in a way that
/// still looks plausible.
final class PatchFlowEstimatorTests: XCTestCase {

    private static let width = 192
    private static let height = 144
    private static let frameRate = 30.0

    /// A container with a few scratches and marks. Something has to be visible
    /// for camera motion to be measurable at all.
    private func texturedScene(translationX: Double = 0,
                               translationY: Double = 0) -> SyntheticScene {
        SyntheticScene(
            width: Self.width,
            height: Self.height,
            baseLevel: 0.30,
            noiseSigma: 0.01,
            scratches: [
                SyntheticScratch(start: CGPoint(x: 0.10, y: 0.20), end: CGPoint(x: 0.90, y: 0.26),
                                 brightness: 0.40, widthPixels: 2),
                SyntheticScratch(start: CGPoint(x: 0.15, y: 0.70), end: CGPoint(x: 0.85, y: 0.62),
                                 brightness: 0.35, widthPixels: 2),
                SyntheticScratch(start: CGPoint(x: 0.30, y: 0.10), end: CGPoint(x: 0.36, y: 0.90),
                                 brightness: 0.30, widthPixels: 2)
            ],
            stationaryBlobs: [
                SyntheticStationaryBlob(center: CGPoint(x: 0.25, y: 0.45), radiusPixels: 4, brightness: 0.5),
                SyntheticStationaryBlob(center: CGPoint(x: 0.70, y: 0.55), radiusPixels: 5, brightness: 0.45),
                SyntheticStationaryBlob(center: CGPoint(x: 0.50, y: 0.80), radiusPixels: 3, brightness: 0.4)
            ],
            globalTranslation: CGVector(dx: translationX, dy: translationY),
            seed: 77
        )
    }

    /// Runs a scene through the estimator and returns the final motion.
    private func run(_ scene: SyntheticScene, frames: Int = 60) -> GlobalMotion {
        let estimator = PatchFlowEstimator(configuration: .screening)
        estimator.prepare(regionWidth: Self.width, regionHeight: Self.height)

        var motion = GlobalMotion.none
        for index in 0..<frames {
            let time = Double(index) / Self.frameRate
            let image = SyntheticFrameFactory.render(scene, atTime: time, frameIndex: index)
            motion = estimator.update(with: image,
                                      timestampSeconds: time,
                                      noiseSigma: Double(scene.noiseSigma))
        }
        return motion
    }

    private func expectedOffset(_ scene: SyntheticScene, frames: Int) -> CGVector {
        let seconds = Double(frames - 1) / Self.frameRate
        return CGVector(dx: scene.globalTranslation.dx * CGFloat(Self.width) * CGFloat(seconds),
                        dy: scene.globalTranslation.dy * CGFloat(Self.height) * CGFloat(seconds))
    }

    // MARK: - Sign

    func testAScenePannedRightMeasuresPositiveHorizontalMotion() {
        let motion = run(texturedScene(translationX: 0.05))

        XCTAssertTrue(motion.isTrustworthy)
        XCTAssertGreaterThan(motion.flow.dxPixelsPerSecond, 0,
                             "content moving right must read as positive, not negative")
        XCTAssertGreaterThan(Double(motion.cumulativeOffset.dx), 0)
    }

    func testAScenePannedLeftMeasuresNegativeHorizontalMotion() {
        let motion = run(texturedScene(translationX: -0.05))

        XCTAssertTrue(motion.isTrustworthy)
        XCTAssertLessThan(motion.flow.dxPixelsPerSecond, 0)
        XCTAssertLessThan(Double(motion.cumulativeOffset.dx), 0)
    }

    func testASceneMovingDownMeasuresPositiveVerticalMotion() {
        // Image `y` increases downwards, so downward content is positive.
        let motion = run(texturedScene(translationY: 0.04))

        XCTAssertTrue(motion.isTrustworthy)
        XCTAssertGreaterThan(motion.flow.dyPixelsPerSecond, 0)
    }

    // MARK: - Accuracy

    func testTheAccumulatedOffsetMatchesTheTrueDisplacement() {
        for (dx, dy) in [(0.02, 0.0), (0.05, 0.0), (0.0, 0.04), (0.03, 0.03)] {
            let scene = texturedScene(translationX: dx, translationY: dy)
            let motion = run(scene, frames: 60)
            let expected = expectedOffset(scene, frames: 60)
            let error = hypot(Double(motion.cumulativeOffset.dx - expected.dx),
                              Double(motion.cumulativeOffset.dy - expected.dy))
            let magnitude = hypot(Double(expected.dx), Double(expected.dy))

            XCTAssertLessThan(error, max(1.0, magnitude * 0.15),
                              "pan (\(dx), \(dy)): expected \(expected), got \(motion.cumulativeOffset)")
        }
    }

    func testAStillSceneAccumulatesEssentiallyNoOffset() {
        let motion = run(texturedScene(), frames: 60)

        XCTAssertLessThan(hypot(Double(motion.cumulativeOffset.dx),
                                Double(motion.cumulativeOffset.dy)), 1.5)
        XCTAssertLessThan(motion.flow.speedPixelsPerSecond, 3)
        XCTAssertGreaterThan(motion.flow.confidence, 0.6)
    }

    // MARK: - Refusing to guess

    func testAFeaturelessSceneRefusesRatherThanGuessing() {
        // A clean container in a dark shroud may genuinely have nothing to
        // match. Reporting no measurement is the honest answer; inventing one
        // would corrupt every velocity that depends on it.
        var flat = texturedScene(translationX: 0.05)
        flat.scratches = []
        flat.stationaryBlobs = []

        let motion = run(flat, frames: 30)

        XCTAssertFalse(motion.isTrustworthy)
        XCTAssertEqual(motion.flow.confidence, 0)
        XCTAssertEqual(Double(motion.cumulativeOffset.dx), 0, accuracy: 1e-9)
    }

    func testTheFirstFrameHasNothingToCompareAgainst() {
        let estimator = PatchFlowEstimator(configuration: .screening)
        estimator.prepare(regionWidth: Self.width, regionHeight: Self.height)
        let motion = estimator.update(
            with: SyntheticFrameFactory.render(texturedScene(), atTime: 0, frameIndex: 0),
            timestampSeconds: 0,
            noiseSigma: 0.01
        )

        XCTAssertFalse(motion.isTrustworthy)
        XCTAssertEqual(motion.flow, .none)
    }

    func testResetClearsTheAccumulatedOffset() {
        let estimator = PatchFlowEstimator(configuration: .screening)
        estimator.prepare(regionWidth: Self.width, regionHeight: Self.height)
        let scene = texturedScene(translationX: 0.05)

        for index in 0..<40 {
            _ = estimator.update(
                with: SyntheticFrameFactory.render(scene, atTime: Double(index) / Self.frameRate,
                                                   frameIndex: index),
                timestampSeconds: Double(index) / Self.frameRate,
                noiseSigma: 0.01
            )
        }
        estimator.reset()

        let motion = estimator.update(
            with: SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0),
            timestampSeconds: 0, noiseSigma: 0.01
        )
        XCTAssertEqual(Double(motion.cumulativeOffset.dx), 0, accuracy: 1e-9)
    }

    // MARK: - The pieces

    func testTheParabolicFitFindsTheMinimumBetweenSamples() {
        // A symmetric minimum sits exactly on the centre sample.
        XCTAssertEqual(PatchFlowEstimator.parabolicOffset(left: 2, centre: 1, right: 2), 0,
                       accuracy: 1e-9)
        // Skewed left means the true minimum is left of centre.
        XCTAssertLessThan(PatchFlowEstimator.parabolicOffset(left: 1.2, centre: 1, right: 3), 0)
        XCTAssertGreaterThan(PatchFlowEstimator.parabolicOffset(left: 3, centre: 1, right: 1.2), 0)
        // A flat or inverted neighbourhood is not a minimum to refine.
        XCTAssertEqual(PatchFlowEstimator.parabolicOffset(left: 1, centre: 1, right: 1), 0)
        XCTAssertEqual(PatchFlowEstimator.parabolicOffset(left: 1, centre: 2, right: 1), 0)
    }

    func testTheMedianIgnoresAMinorityOfOutliers() {
        XCTAssertEqual(PatchFlowEstimator.median(of: [1, 2, 3, 4, 900]), 3)
        XCTAssertEqual(PatchFlowEstimator.median(of: [2, 4]), 3)
        XCTAssertEqual(PatchFlowEstimator.median(of: []), 0)
    }

    func testFlowConvertsToNormalizedSpeed() {
        let flow = GlobalFlow(dxPixelsPerSecond: 30, dyPixelsPerSecond: 40,
                              confidence: 1, patchesUsed: 10, patchesOffered: 20)
        XCTAssertEqual(flow.speedPixelsPerSecond, 50, accuracy: 1e-9)
        XCTAssertEqual(flow.normalizedSpeed(regionDiagonal: 500), 0.1, accuracy: 1e-9)
        XCTAssertEqual(flow.normalizedSpeed(regionDiagonal: 0), 0)
    }
}
