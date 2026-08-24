import CoreGraphics
import XCTest
@testable import Turbid

/// The six properties Phase 3B has to prove, driven by synthetic scenes.
///
/// The region is 192x144 so the normalized size limits mean roughly what they
/// mean on a real capture: a suspended speck sits well inside the accepted band
/// and a large bubble sits outside it.
final class SpeckDetectorTests: XCTestCase {

    private static let width = 192
    private static let height = 144
    /// Two seconds at 30 fps: the acquisition length the screening protocol
    /// specifies, so the sampling stride under test is the real one.
    private static let backgroundFrames = 60
    private static let frameRate = 30.0

    private func scene(_ mutate: (inout SyntheticScene) -> Void = { _ in }) -> SyntheticScene {
        var scene = SyntheticScene(width: Self.width,
                                   height: Self.height,
                                   baseLevel: 0.30,
                                   noiseSigma: 0.01,
                                   seed: 4242)
        mutate(&scene)
        return scene
    }

    /// Builds a detector whose background model was acquired from `scene`.
    private func makeDetector(
        background scene: SyntheticScene,
        mask: RasterizedMask? = nil,
        configuration: SpeckDetector.Configuration = .screening
    ) -> SpeckDetector {
        let detector = SpeckDetector(configuration: configuration)
        detector.prepare(width: Self.width,
                         height: Self.height,
                         mask: mask,
                         expectedAcquisitionFrames: Self.backgroundFrames)

        for index in 0..<Self.backgroundFrames {
            detector.ingestBackgroundFrame(
                SyntheticFrameFactory.render(scene,
                                             atTime: Double(index) / Self.frameRate,
                                             frameIndex: index)
            )
        }
        XCTAssertTrue(detector.finalizeBackground(noiseSigma: Double(scene.noiseSigma)))
        return detector
    }

    private func frame(_ scene: SyntheticScene, at index: Int) -> LumaImage {
        SyntheticFrameFactory.render(scene,
                                     atTime: Double(index) / Self.frameRate,
                                     frameIndex: index)
    }

    // MARK: - 1. Static defects are absorbed

    func testAStaticScratchIsAbsorbedAndProducesNoCandidates() {
        let scene = self.scene {
            $0.scratches = [SyntheticScratch(start: CGPoint(x: 0.2, y: 0.3),
                                             end: CGPoint(x: 0.7, y: 0.35),
                                             brightness: 0.40,
                                             widthPixels: 2)]
        }
        let detector = makeDetector(background: scene)

        for index in 200..<220 {
            let observation = detector.detect(in: frame(scene, at: index), frameNoiseSigma: Double(scene.noiseSigma))
            XCTAssertTrue(observation.candidates.isEmpty,
                          "a scratch that never moves must be part of the background, "
                              + "found \(observation.candidates.count) candidates")
        }
    }

    func testAStationaryBrightBubbleIsAbsorbed() {
        let scene = self.scene {
            $0.stationaryBlobs = [SyntheticStationaryBlob(center: CGPoint(x: 0.5, y: 0.5),
                                                          radiusPixels: 3,
                                                          brightness: 0.45)]
        }
        let detector = makeDetector(background: scene)

        for index in 200..<210 {
            XCTAssertTrue(detector.detect(in: frame(scene, at: index), frameNoiseSigma: Double(scene.noiseSigma)).candidates.isEmpty)
        }
    }

    func testTheBackgroundModelReproducesTheStationaryScene() {
        let scene = self.scene {
            $0.stationaryBlobs = [SyntheticStationaryBlob(center: CGPoint(x: 0.4, y: 0.6),
                                                          radiusPixels: 4,
                                                          brightness: 0.5)]
        }
        let detector = makeDetector(background: scene)
        let observation = detector.detect(in: frame(scene, at: 300), frameNoiseSigma: Double(scene.noiseSigma))

        // Residual against a correct model is noise, so the mean excess is a
        // small fraction of the scene level rather than of the blob.
        XCTAssertLessThan(observation.bulk.meanPositiveResidual, 0.01)
    }

    // MARK: - 2. Noise alone produces nothing

    func testNoiseOnlyFramesProduceNoCandidates() {
        let scene = self.scene()
        let detector = makeDetector(background: scene)

        var total = 0
        for index in 200..<250 {
            total += detector.detect(in: frame(scene, at: index), frameNoiseSigma: Double(scene.noiseSigma)).candidates.count
        }
        XCTAssertEqual(total, 0, "50 noise-only frames must yield no candidates at all")
    }

    func testTheDetectionThresholdScalesWithMeasuredNoise() {
        // The same scene at two noise levels must produce proportionally
        // different thresholds. A fixed pixel threshold would not.
        var quiet = scene(); quiet.noiseSigma = 0.004
        var loud = scene(); loud.noiseSigma = 0.02

        let quietThreshold = makeDetector(background: quiet)
            .detect(in: frame(quiet, at: 200),
                    frameNoiseSigma: Double(quiet.noiseSigma)).bulk.detectionThreshold
        let loudThreshold = makeDetector(background: loud)
            .detect(in: frame(loud, at: 200),
                    frameNoiseSigma: Double(loud.noiseSigma)).bulk.detectionThreshold

        XCTAssertGreaterThan(loudThreshold, quietThreshold * 2,
                             "a noisier sensor must raise its own threshold")
    }

    func testHigherNoiseStillProducesNoCandidates() {
        var loud = scene(); loud.noiseSigma = 0.02
        let detector = makeDetector(background: loud)

        var total = 0
        for index in 200..<230 {
            total += detector.detect(in: frame(loud, at: index), frameNoiseSigma: Double(loud.noiseSigma)).candidates.count
        }
        XCTAssertEqual(total, 0, "the adaptive threshold must hold at any noise level")
    }

    // MARK: - 3. Slow-moving point-like signals stay detectable

    func testASlowMovingSpeckIsDetected() {
        let scene = self.scene {
            $0.specks = [SyntheticSpeck(center: CGPoint(x: 0.5, y: 0.5),
                                        orbitRadius: 0.25,
                                        angularSpeed: 1.2,
                                        initialPhase: 0,
                                        drift: .zero,
                                        radiusPixels: 1.5,
                                        brightness: 0.35)]
        }
        let detector = makeDetector(background: scene)

        var detections = 0
        for index in 200..<230 where !detector.detect(in: frame(scene, at: index), frameNoiseSigma: Double(scene.noiseSigma)).candidates.isEmpty {
            detections += 1
        }
        XCTAssertGreaterThan(detections, 25, "a moving speck must be found in almost every frame")
    }

    func testADimSpeckIsStillDetected() {
        let scene = self.scene {
            $0.specks = [SyntheticSpeck(center: CGPoint(x: 0.5, y: 0.5),
                                        orbitRadius: 0.25,
                                        angularSpeed: 1.2,
                                        initialPhase: 0,
                                        drift: .zero,
                                        radiusPixels: 1.5,
                                        brightness: 0.10)]
        }
        let detector = makeDetector(background: scene)
        XCTAssertFalse(detector.detect(in: frame(scene, at: 200), frameNoiseSigma: Double(scene.noiseSigma)).candidates.isEmpty,
                       "the smallest valid events are the ones that matter most")
    }

    func testASlowSpeckIsNotAbsorbedIntoTheBackgroundOverTime() {
        // The background updates far more slowly at foreground pixels, so a
        // speck lingering in one area must still be visible many frames later.
        let scene = self.scene {
            $0.specks = [SyntheticSpeck(center: CGPoint(x: 0.5, y: 0.5),
                                        orbitRadius: 0.05,
                                        angularSpeed: 0.15,
                                        initialPhase: 0,
                                        drift: .zero,
                                        radiusPixels: 1.5,
                                        brightness: 0.35)]
        }
        let detector = makeDetector(background: scene)

        for index in 200..<290 {
            _ = detector.detect(in: frame(scene, at: index), frameNoiseSigma: Double(scene.noiseSigma))
        }
        XCTAssertFalse(detector.detect(in: frame(scene, at: 290), frameNoiseSigma: Double(scene.noiseSigma)).candidates.isEmpty,
                       "90 frames of slow drift must not erase the speck")
    }

    func testSeveralSpecksAreFoundSeparately() {
        let scene = self.scene {
            $0.specks = (0..<5).map { index in
                SyntheticSpeck(center: CGPoint(x: 0.2 + Double(index) * 0.15, y: 0.5),
                               orbitRadius: 0.04,
                               angularSpeed: 1.0,
                               initialPhase: Double(index),
                               drift: .zero,
                               radiusPixels: 1.5,
                               brightness: 0.35)
            }
        }
        let detector = makeDetector(background: scene)
        XCTAssertEqual(detector.detect(in: frame(scene, at: 200), frameNoiseSigma: Double(scene.noiseSigma)).candidates.count, 5)
    }

    // MARK: - 4. Exposure flicker is rejected, not counted

    func testExposureFlickerProducesNoCandidates() {
        // The background is built on a clean scene and the flicker arrives
        // afterwards, which is the hard case: a background acquired *during*
        // the flicker would have partly absorbed it.
        let clean = scene()
        let detector = makeDetector(background: clean)

        var flickering = clean
        flickering.flicker = SyntheticFlicker(amplitude: 0.25, frequencyHertz: 2, phase: 0)

        var total = 0
        for index in 200..<240 {
            total += detector.detect(in: frame(flickering, at: index), frameNoiseSigma: Double(clean.noiseSigma)).candidates.count
        }
        XCTAssertEqual(total, 0,
                       "a whole-frame brightness change is removed by the band-pass")
    }

    func testASlowIlluminationGradientProducesNoCandidates() {
        let clean = scene()
        let detector = makeDetector(background: clean)

        var vignetted = clean
        vignetted.vignette = 0.5

        XCTAssertTrue(detector.detect(in: frame(vignetted, at: 200), frameNoiseSigma: Double(clean.noiseSigma)).candidates.isEmpty,
                      "the band-pass exists to suppress slowly varying illumination")
    }

    func testFlickerStillMovesTheBulkChannel() {
        // The bulk channel is not band-passed, so it does see the extra light.
        // That is correct: the discrete channel must ignore flicker, the bulk
        // channel must not pretend the frame was unchanged.
        let clean = scene()
        let detector = makeDetector(background: clean)

        var brighter = clean
        brighter.flicker = SyntheticFlicker(amplitude: 0.2, frequencyHertz: 0.001, phase: .pi / 2)

        let steady = detector.detect(in: frame(clean, at: 200),
                                     frameNoiseSigma: Double(clean.noiseSigma)).bulk.meanPositiveResidual
        let lit = detector.detect(in: frame(brighter, at: 201),
                                  frameNoiseSigma: Double(clean.noiseSigma)).bulk.meanPositiveResidual
        XCTAssertGreaterThan(lit, steady)
    }

    // MARK: - 5. Saturated glare stays masked

    func testGlareInsideTheMaskProducesNoCandidates() {
        let clean = scene()

        var glaring = clean
        glaring.hotspot = SyntheticHotspot(center: CGPoint(x: 0.30, y: 0.30),
                                           radiusPixels: 22,
                                           peakBrightness: 1.6)

        let description = OpticalMaskDescription(
            excludedRectangles: [],
            excludedEllipses: [CGRect(x: 0.06, y: 0.06, width: 0.48, height: 0.48)]
        )
        let mask = RasterizedMask(description: description,
                                  width: Self.width, height: Self.height)

        let masked = makeDetector(background: clean, mask: mask)
        let unmasked = makeDetector(background: clean)

        let maskedResult = masked.detect(in: frame(glaring, at: 200), frameNoiseSigma: Double(clean.noiseSigma))
        let unmaskedResult = unmasked.detect(in: frame(glaring, at: 200), frameNoiseSigma: Double(clean.noiseSigma))

        // Asserted on the component count, not the accepted candidates: a
        // glare this size is also rejected by the size filter, so comparing
        // candidate counts would pass whether the mask worked or not.
        XCTAssertGreaterThan(unmaskedResult.componentCount, 0,
                             "without the mask the glare is found, so the comparison means something")
        XCTAssertEqual(maskedResult.componentCount, 0,
                       "with the mask the glare must not even be examined")
        XCTAssertTrue(maskedResult.candidates.isEmpty)
        XCTAssertTrue(unmaskedResult.candidates.isEmpty,
                      "and either way a glare that large is never an accepted candidate")
    }

    func testASaturatedCoreIsRejectedEvenWhereItIsNotMasked() {
        let clean = scene()
        let detector = makeDetector(background: clean)

        var clipped = clean
        clipped.stationaryBlobs = [SyntheticStationaryBlob(center: CGPoint(x: 0.6, y: 0.6),
                                                           radiusPixels: 3,
                                                           brightness: 1.5)]
        let observation = detector.detect(in: frame(clipped, at: 200), frameNoiseSigma: Double(clean.noiseSigma))

        XCTAssertTrue(observation.candidates.allSatisfy { !$0.containsSaturatedPixel })
        XCTAssertGreaterThan(observation.rejections[.saturatedCore] ?? 0, 0,
                             "a clipped event has lost its link to scattered light")
    }

    // MARK: - 6. Bounded work per frame

    func testRepeatedFramesDoNotGrowAnyBuffer() {
        let scene = self.scene {
            $0.specks = (0..<20).map { index in
                SyntheticSpeck(center: CGPoint(x: 0.1 + Double(index % 5) * 0.2,
                                               y: 0.15 + Double(index / 5) * 0.22),
                               orbitRadius: 0.03,
                               angularSpeed: 1.0,
                               initialPhase: Double(index),
                               drift: .zero,
                               radiusPixels: 1.5,
                               brightness: 0.35)
            }
        }
        let detector = makeDetector(background: scene)

        // The candidate array is the only per-frame allocation, and it is
        // bounded by the configured cap.
        for index in 200..<400 {
            let observation = detector.detect(in: frame(scene, at: index), frameNoiseSigma: Double(scene.noiseSigma))
            XCTAssertLessThanOrEqual(observation.candidates.count,
                                     SpeckDetector.Configuration.screening.maximumCandidates)
            XCTAssertEqual(observation.truncatedCount, 0)
        }
    }

    func testTheComponentCapIsReportedRatherThanHiddenWhenItIsHit() {
        var configuration = SpeckDetector.Configuration.screening
        configuration.maximumCandidates = 3

        let scene = self.scene {
            $0.specks = (0..<10).map { index in
                SyntheticSpeck(center: CGPoint(x: 0.1 + Double(index % 5) * 0.2,
                                               y: 0.3 + Double(index / 5) * 0.3),
                               orbitRadius: 0.03,
                               angularSpeed: 1.0,
                               initialPhase: Double(index),
                               drift: .zero,
                               radiusPixels: 1.5,
                               brightness: 0.4)
            }
        }
        let detector = makeDetector(background: scene, configuration: configuration)
        let observation = detector.detect(in: frame(scene, at: 200), frameNoiseSigma: Double(scene.noiseSigma))

        XCTAssertGreaterThan(observation.truncatedCount, 0,
                             "a truncated frame's count is a lower bound and must say so")
        XCTAssertEqual(observation.componentCount,
                       observation.candidates.count + observation.rejectedCount
                           + observation.truncatedCount)
    }

    // MARK: - Detection before the model exists

    func testNothingIsDetectedBeforeTheBackgroundIsBuilt() {
        let detector = SpeckDetector()
        detector.prepare(width: Self.width, height: Self.height, mask: nil)

        let observation = detector.detect(in: frame(scene(), at: 0), frameNoiseSigma: 0.01)
        XCTAssertFalse(observation.backgroundIsReady)
        XCTAssertTrue(observation.candidates.isEmpty)
        XCTAssertEqual(observation.bulk, .empty)
    }

    func testTooFewAcquisitionFramesLeavesTheModelUnbuilt() {
        let detector = SpeckDetector()
        detector.prepare(width: Self.width, height: Self.height, mask: nil)
        detector.ingestBackgroundFrame(frame(scene(), at: 0))
        detector.ingestBackgroundFrame(frame(scene(), at: 1))

        XCTAssertFalse(detector.finalizeBackground(noiseSigma: 0.01))
        XCTAssertFalse(detector.backgroundIsReady)
    }

    // MARK: - Background stability
    //
    // Reported, never gated on. These tests pin the number down because it is
    // shown to the user and because it is the evidence for that decision: it
    // separates a still container from a moving one, and it does *not*
    // separate a still container from one full of drifting particles, which is
    // why it cannot be a gate.

    func testAStillSceneGivesAStableBackground() {
        let detector = makeDetector(background: scene())
        XCTAssertGreaterThan(detector.backgroundStability, 0.95)
    }

    func testAStructuredSceneShiftingDuringAcquisitionGivesAnUnstableBackground() {
        // Structure is the point. A featureless field translating behind the
        // lens is still perfectly described by its median, so it is correctly
        // reported as stable; what breaks a background model is a scene with
        // features in it moving to somewhere else.
        let moving = scene {
            $0.scratches = [
                SyntheticScratch(start: CGPoint(x: 0.10, y: 0.20),
                                 end: CGPoint(x: 0.90, y: 0.26),
                                 brightness: 0.40, widthPixels: 2),
                SyntheticScratch(start: CGPoint(x: 0.15, y: 0.70),
                                 end: CGPoint(x: 0.85, y: 0.62),
                                 brightness: 0.35, widthPixels: 2),
                SyntheticScratch(start: CGPoint(x: 0.30, y: 0.10),
                                 end: CGPoint(x: 0.36, y: 0.90),
                                 brightness: 0.30, widthPixels: 2)
            ]
            $0.stationaryBlobs = [
                SyntheticStationaryBlob(center: CGPoint(x: 0.25, y: 0.45),
                                        radiusPixels: 4, brightness: 0.5),
                SyntheticStationaryBlob(center: CGPoint(x: 0.70, y: 0.55),
                                        radiusPixels: 5, brightness: 0.45),
                SyntheticStationaryBlob(center: CGPoint(x: 0.50, y: 0.80),
                                        radiusPixels: 3, brightness: 0.4)
            ]
            $0.globalTranslation = CGVector(dx: 0.4, dy: 0.2)
        }
        let detector = makeDetector(background: moving)
        XCTAssertLessThan(detector.backgroundStability, 0.93,
                          "a median over a scene that moved describes somewhere nothing is any more")
    }

    func testDriftingParticlesDoNotMakeTheBackgroundLookUnstable() {
        // Particles moving through the volume is a sample, not a fault.
        let sample = scene {
            $0.specks = (0..<20).map { index in
                SyntheticSpeck(center: CGPoint(x: 0.1 + Double(index % 5) * 0.2,
                                               y: 0.15 + Double(index / 5) * 0.22),
                               orbitRadius: 0.03,
                               angularSpeed: 1.0,
                               initialPhase: Double(index),
                               drift: .zero,
                               radiusPixels: 1.5,
                               brightness: 0.35)
            }
        }
        let detector = makeDetector(background: sample)
        XCTAssertGreaterThan(detector.backgroundStability, 0.93)
    }
}
