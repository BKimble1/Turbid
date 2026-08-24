import CoreGraphics
import XCTest
@testable import Turbid

final class SyntheticFrameFactoryTests: XCTestCase {

    // MARK: - Determinism

    func testTheSameSeedAndTimeAlwaysProduceTheIdenticalFrame() {
        let scene = SyntheticScene(noiseSigma: 0.02, seed: 12345)
        let first = SyntheticFrameFactory.render(scene, atTime: 0.5, frameIndex: 7)
        let second = SyntheticFrameFactory.render(scene, atTime: 0.5, frameIndex: 7)

        XCTAssertEqual(first, second, "a scenario that cannot be replayed is not a test")
    }

    func testDifferentSeedsProduceDifferentNoise() {
        let a = SyntheticFrameFactory.render(SyntheticScene(noiseSigma: 0.02, seed: 1),
                                             atTime: 0, frameIndex: 0)
        let b = SyntheticFrameFactory.render(SyntheticScene(noiseSigma: 0.02, seed: 2),
                                             atTime: 0, frameIndex: 0)
        XCTAssertNotEqual(a, b)
    }

    func testConsecutiveFramesHaveIndependentNoiseLikeARealSensor() {
        let scene = SyntheticScene(noiseSigma: 0.02, seed: 99)
        let first = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)
        let second = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 1)

        XCTAssertNotEqual(first, second, "frozen noise would hide temporal bugs")
    }

    func testTheGeneratorIsUniformAndCentred() {
        var random = DeterministicRandom(seed: 4)
        var total = 0.0
        var belowHalf = 0
        let samples = 20_000

        for _ in 0..<samples {
            let value = random.nextUnitFloat()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
            total += Double(value)
            if value < 0.5 { belowHalf += 1 }
        }

        XCTAssertEqual(total / Double(samples), 0.5, accuracy: 0.02)
        XCTAssertEqual(Double(belowHalf) / Double(samples), 0.5, accuracy: 0.02)
    }

    func testGaussianNoiseHasTheRequestedSpread() {
        var random = DeterministicRandom(seed: 11)
        let samples = 20_000
        var values: [Double] = []
        values.reserveCapacity(samples)
        for _ in 0..<samples { values.append(Double(random.nextGaussian())) }

        let mean = values.reduce(0, +) / Double(samples)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples)

        XCTAssertEqual(mean, 0, accuracy: 0.05)
        XCTAssertEqual(variance.squareRoot(), 1, accuracy: 0.05)
    }

    // MARK: - Scene features

    func testACleanSceneSitsAtItsBaseLevel() {
        let scene = SyntheticScene(baseLevel: 0.25, noiseSigma: 0)
        let image = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)
        let statistics = LumaStatisticsCalculator.statistics(of: image, mask: nil)

        XCTAssertEqual(statistics.mean, 0.25, accuracy: 1e-5)
        XCTAssertEqual(statistics.standardDeviation, 0, accuracy: 1e-5)
    }

    func testAStaticScratchDoesNotMoveBetweenFrames() {
        let scene = SyntheticScene(
            noiseSigma: 0,
            scratches: [SyntheticScratch(start: CGPoint(x: 0.2, y: 0.3),
                                         end: CGPoint(x: 0.7, y: 0.35),
                                         brightness: 0.4,
                                         widthPixels: 2)]
        )
        let first = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)
        let later = SyntheticFrameFactory.render(scene, atTime: 5, frameIndex: 150)

        XCTAssertEqual(first, later, "a scratch is attached to the glass; it must never move")
    }

    func testAStationaryBubbleStaysPutButIsBrighterThanTheBackground() {
        let scene = SyntheticScene(
            noiseSigma: 0,
            stationaryBlobs: [SyntheticStationaryBlob(center: CGPoint(x: 0.5, y: 0.5),
                                                      radiusPixels: 4,
                                                      brightness: 0.5)]
        )
        let first = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)
        let later = SyntheticFrameFactory.render(scene, atTime: 3, frameIndex: 90)

        XCTAssertEqual(first, later)
        XCTAssertGreaterThan(first[first.width / 2, first.height / 2], scene.baseLevel + 0.3)
    }

    func testASlowSpeckMovesAlongACurveRatherThanAStraightLine() {
        let speck = SyntheticSpeck(center: CGPoint(x: 0.5, y: 0.5),
                                   orbitRadius: 0.15,
                                   angularSpeed: 0.8,
                                   initialPhase: 0,
                                   drift: CGVector(dx: 0.002, dy: 0.001),
                                   radiusPixels: 1.5,
                                   brightness: 0.5)

        let p0 = speck.position(atTime: 0)
        let p1 = speck.position(atTime: 1)
        let p2 = speck.position(atTime: 2)

        // Collinear points would have zero cross product.
        let crossProduct = (p1.x - p0.x) * (p2.y - p1.y) - (p1.y - p0.y) * (p2.x - p1.x)
        XCTAssertGreaterThan(abs(crossProduct), 1e-4, "the path must actually curve")
    }

    func testARisingBubbleMovesSteadilyUpwards() {
        let bubble = SyntheticRisingBubble(startPosition: CGPoint(x: 0.5, y: 0.9),
                                           riseSpeed: -0.2,
                                           radiusPixels: 5,
                                           brightness: 0.6)

        XCTAssertEqual(bubble.position(atTime: 0).y, 0.9, accuracy: 1e-9)
        XCTAssertEqual(bubble.position(atTime: 1).y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(bubble.position(atTime: 2).y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(bubble.position(atTime: 2).x, 0.5, accuracy: 1e-9,
                       "a rising bubble does not drift sideways")
    }

    func testGlobalTranslationMovesEveryStationaryFeatureTogether() {
        let scene = SyntheticScene(
            noiseSigma: 0,
            stationaryBlobs: [SyntheticStationaryBlob(center: CGPoint(x: 0.3, y: 0.5),
                                                      radiusPixels: 3, brightness: 0.5)],
            globalTranslation: CGVector(dx: 0.1, dy: 0)
        )
        let first = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)
        let later = SyntheticFrameFactory.render(scene, atTime: 1, frameIndex: 30)

        XCTAssertNotEqual(first, later)
        // The blob started at x = 0.3 and moved to x = 0.4 of a 160px frame.
        XCTAssertGreaterThan(later[64, 60], later[48, 60])
        XCTAssertGreaterThan(first[48, 60], first[64, 60])
    }

    func testExposureFlickerModulatesTheWholeFrame() {
        let flicker = SyntheticFlicker(amplitude: 0.3, frequencyHertz: 1, phase: 0)
        let scene = SyntheticScene(baseLevel: 0.3, noiseSigma: 0, flicker: flicker)

        // sin(2*pi*1*0.25) = 1, so the gain peaks a quarter of a cycle in.
        let peak = SyntheticFrameFactory.render(scene, atTime: 0.25, frameIndex: 1)
        let trough = SyntheticFrameFactory.render(scene, atTime: 0.75, frameIndex: 2)

        let peakMean = LumaStatisticsCalculator.statistics(of: peak, mask: nil).mean
        let troughMean = LumaStatisticsCalculator.statistics(of: trough, mask: nil).mean

        XCTAssertEqual(peakMean, 0.39, accuracy: 0.005)
        XCTAssertEqual(troughMean, 0.21, accuracy: 0.005)
    }

    func testAHotspotClipsAndConcentratesTheSignal() {
        // A dark shroud with one specular reflection off the container: the
        // case the hotspot gate exists for. The spot sits inside a single tile
        // of the 4x4 grid rather than on a tile boundary, because a reflection
        // straddling four tiles splits its energy between them and reads as
        // far less concentrated than it is.
        let scene = SyntheticScene(
            baseLevel: 0.05,
            noiseSigma: 0,
            hotspot: SyntheticHotspot(center: CGPoint(x: 0.125, y: 0.125),
                                      radiusPixels: 40,
                                      peakBrightness: 1.5)
        )
        let image = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)
        let statistics = LumaStatisticsCalculator.statistics(of: image, mask: nil)

        XCTAssertGreaterThan(statistics.saturatedFraction,
                             QualityThresholds.screening.maximumSaturatedFraction,
                             "the hotspot must actually clip, as a real reflection does")
        XCTAssertGreaterThan(statistics.brightestTileShare,
                             QualityThresholds.screening.maximumBrightestTileShare,
                             "and concentrate enough signal to trip the hotspot gate")
        XCTAssertLessThanOrEqual(statistics.maximum, 1.0, "values stay in range")
    }

    func testVignettingDarkensTheCornersOnly() {
        let scene = SyntheticScene(baseLevel: 0.5, noiseSigma: 0, vignette: 0.6)
        let image = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)

        XCTAssertEqual(image[image.width / 2, image.height / 2], 0.5, accuracy: 1e-5)
        XCTAssertLessThan(image[0, 0], 0.3)
    }

    // MARK: - Timestamps

    func testRegularTimestampsAreEvenlySpaced() {
        let timestamps = SyntheticTimestamps.regular(count: 5, frameRate: 30)
        XCTAssertEqual(timestamps.count, 5)
        for index in 1..<timestamps.count {
            XCTAssertEqual(timestamps[index] - timestamps[index - 1], 1.0 / 30.0, accuracy: 1e-9)
        }
    }

    func testJitteredTimestampsStayStrictlyIncreasing() {
        let timestamps = SyntheticTimestamps.jittered(count: 200,
                                                       frameRate: 30,
                                                       jitterSeconds: 0.02,
                                                       seed: 7)
        for index in 1..<timestamps.count {
            XCTAssertGreaterThan(timestamps[index], timestamps[index - 1],
                                 "a presentation timestamp never goes backwards")
        }
    }

    func testDroppedFramesLeaveGapsAtTheOriginalTimes() {
        let timestamps = SyntheticTimestamps.withDrops(count: 10,
                                                        frameRate: 10,
                                                        droppedIndices: [3, 4])
        XCTAssertEqual(timestamps.count, 8)
        // The surviving frames keep their original times, so index 2 -> 5 is a
        // triple-length gap.
        XCTAssertEqual(timestamps[2], 0.2, accuracy: 1e-9)
        XCTAssertEqual(timestamps[3], 0.5, accuracy: 1e-9)
    }

    func testAStallShiftsEverythingAfterIt() {
        let timestamps = SyntheticTimestamps.withStall(count: 6,
                                                        frameRate: 10,
                                                        stallAfterIndex: 2,
                                                        stallSeconds: 1.0)
        XCTAssertEqual(timestamps[2], 0.2, accuracy: 1e-9)
        XCTAssertEqual(timestamps[3], 1.3, accuracy: 1e-9)
        XCTAssertEqual(timestamps[4], 1.4, accuracy: 1e-9)
    }

    func testDegenerateTimestampRequestsReturnNothing() {
        XCTAssertTrue(SyntheticTimestamps.regular(count: 0, frameRate: 30).isEmpty)
        XCTAssertTrue(SyntheticTimestamps.regular(count: 5, frameRate: 0).isEmpty)
    }

    func testASequenceRendersEachFrameAtItsOwnTimestamp() {
        let scene = SyntheticScene(
            noiseSigma: 0,
            risingBubbles: [SyntheticRisingBubble(startPosition: CGPoint(x: 0.5, y: 0.9),
                                                   riseSpeed: -0.3,
                                                   radiusPixels: 4,
                                                   brightness: 0.5)]
        )
        let frames = SyntheticFrameFactory.sequence(scene, timestamps: [0, 1, 2])

        XCTAssertEqual(frames.map(\.time), [0, 1, 2])
        XCTAssertNotEqual(frames[0].image, frames[1].image)
        XCTAssertNotEqual(frames[1].image, frames[2].image)
    }
}
