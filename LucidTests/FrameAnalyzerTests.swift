import CoreGraphics
import XCTest
@testable import Lucid

/// The analyzer end to end, driven by synthetic scenes through the same entry
/// point a camera buffer would take after normalization.
final class FrameAnalyzerTests: XCTestCase {

    private func makeAnalyzer(
        region: AnalysisRegion = .fullFrame,
        captureProtocol: CaptureProtocol = .screening,
        thresholds: QualityThresholds = .screening
    ) -> FrameAnalyzer {
        let analyzer = FrameAnalyzer(region: region,
                                     captureProtocol: captureProtocol,
                                     thresholds: thresholds)
        analyzer.begin(atTimestamp: 0)
        return analyzer
    }

    private func run(_ analyzer: FrameAnalyzer,
                     scene: SyntheticScene,
                     timestamps: [Double]) -> [FrameObservation] {
        SyntheticFrameFactory.sequence(scene, timestamps: timestamps).map { frame in
            analyzer.analyze(luma: frame.image, presentationSeconds: frame.time)
        }
    }

    private func healthyTiming(frames: Int) -> FrameTimingStatistics {
        var collector = FrameTimingCollector()
        for index in 0..<frames {
            collector.record(presentationSeconds: Double(index) / 30.0)
        }
        return collector.statistics()
    }

    /// A well-exposed, textured, still sample: passes every gate.
    private var goodScene: SyntheticScene {
        SyntheticScene(
            baseLevel: 0.30,
            noiseSigma: 0.01,
            specks: (0..<12).map { index in
                SyntheticSpeck(center: CGPoint(x: 0.2 + Double(index % 4) * 0.2,
                                               y: 0.2 + Double(index / 4) * 0.25),
                               orbitRadius: 0.03,
                               angularSpeed: 0.6,
                               initialPhase: Double(index),
                               drift: .zero,
                               radiusPixels: 1.5,
                               brightness: 0.35)
            },
            seed: 2024
        )
    }

    // MARK: - Stage assignment follows timestamps

    func testEachFrameIsAssignedTheStageItsTimestampFallsIn() {
        let analyzer = makeAnalyzer()
        let timestamps = SyntheticTimestamps.regular(count: 420, frameRate: 30)
        let observations = run(analyzer, scene: goodScene, timestamps: timestamps)

        func stage(atTime time: Double) -> CaptureStage? {
            observations.first { abs($0.timestampSeconds - time) < 1e-6 }?.stage
        }

        XCTAssertEqual(stage(atTime: 0), .torchSettling)
        XCTAssertEqual(stage(atTime: 30.0 / 30.0), .torchSettling)
        XCTAssertEqual(stage(atTime: 75.0 / 30.0), .backgroundAcquisition)
        XCTAssertEqual(stage(atTime: 135.0 / 30.0), .measurement)
        XCTAssertEqual(stage(atTime: 405.0 / 30.0), .complete)
    }

    func testIrregularTimestampsStillLandInTheRightStages() {
        let analyzer = makeAnalyzer()
        let timestamps = SyntheticTimestamps.jittered(count: 300,
                                                       frameRate: 30,
                                                       jitterSeconds: 0.01,
                                                       seed: 5)
        let observations = run(analyzer, scene: goodScene, timestamps: timestamps)

        for observation in observations {
            let expected = CaptureProtocolTimeline(captureProtocol: .screening, startSeconds: 0)
                .stage(at: observation.timestampSeconds)
            XCTAssertEqual(observation.stage, expected,
                           "stage must follow the timestamp, not the frame index")
        }
    }

    func testDroppedFramesDoNotShiftLaterFramesIntoTheWrongStage() {
        let analyzer = makeAnalyzer()
        // Half the frames in the settling stage never arrive.
        let dropped = Set((30..<75).filter { $0 % 2 == 0 })
        let timestamps = SyntheticTimestamps.withDrops(count: 300,
                                                        frameRate: 30,
                                                        droppedIndices: dropped)
        let observations = run(analyzer, scene: goodScene, timestamps: timestamps)

        let measurementFrames = observations.filter { $0.stage == .measurement }
        XCTAssertFalse(measurementFrames.isEmpty)
        for observation in measurementFrames {
            XCTAssertGreaterThanOrEqual(observation.timestampSeconds, 3.5)
            XCTAssertLessThan(observation.timestampSeconds, 12.5)
        }
    }

    func testTimelineIsAnchoredToTheFirstFrameNotToZero() {
        let analyzer = FrameAnalyzer(region: .fullFrame)
        analyzer.begin(atTimestamp: 1_000)

        let first = analyzer.analyze(luma: SyntheticFrameFactory.render(goodScene, atTime: 0, frameIndex: 0),
                                     presentationSeconds: 1_000)
        let later = analyzer.analyze(luma: SyntheticFrameFactory.render(goodScene, atTime: 5, frameIndex: 150),
                                     presentationSeconds: 1_005)

        XCTAssertEqual(first.stage, .torchSettling)
        XCTAssertEqual(later.stage, .measurement)
    }

    func testSequenceNumbersIncreaseMonotonically() {
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: goodScene,
                               timestamps: SyntheticTimestamps.regular(count: 50, frameRate: 30))

        XCTAssertEqual(observations.map(\.sequenceNumber), Array(0..<50))
    }

    func testBeginResetsEverything() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: goodScene,
                timestamps: SyntheticTimestamps.regular(count: 100, frameRate: 30))

        analyzer.begin(atTimestamp: 500)
        let observation = analyzer.analyze(
            luma: SyntheticFrameFactory.render(goodScene, atTime: 0, frameIndex: 0),
            presentationSeconds: 500
        )

        XCTAssertEqual(observation.sequenceNumber, 0)
        XCTAssertEqual(observation.stage, .torchSettling)
        XCTAssertEqual(observation.globalMotionScore, 0,
                       "the first frame after a reset has nothing to compare against")
    }

    // MARK: - The gates, driven by synthetic scenes

    func testAGoodSceneProducesAUsableWindow() {
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: goodScene,
                               timestamps: SyntheticTimestamps.regular(count: 300, frameRate: 30))
        let quality = analyzer.quality(thermal: .nominal,
                                       systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: healthyTiming(frames: 300))

        XCTAssertTrue(observations.allSatisfy(\.isUsable),
                      "no frame in a clean scene should be rejected")
        XCTAssertTrue(quality.isUsable, "rejected because: \(quality.explanations)")
        XCTAssertGreaterThan(quality.usableFrameRatio, 0.99)
    }

    func testASaturatedSceneIsRejectedFrameByFrameAndOverall() {
        let scene = SyntheticScene(
            baseLevel: 0.95,
            noiseSigma: 0.05,
            hotspot: SyntheticHotspot(center: CGPoint(x: 0.5, y: 0.5),
                                      radiusPixels: 60,
                                      peakBrightness: 1.0),
            seed: 3
        )
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: scene,
                               timestamps: SyntheticTimestamps.regular(count: 300, frameRate: 30))
        let quality = analyzer.quality(thermal: .nominal,
                                       systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: healthyTiming(frames: 300))

        XCTAssertTrue(observations.contains { $0.rejectionReasons.contains(.saturatedRegion) })
        XCTAssertFalse(quality.isUsable)
    }

    func testADarkSceneIsRejected() {
        let scene = SyntheticScene(baseLevel: 0.004, noiseSigma: 0.0005, seed: 4)
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: scene,
                               timestamps: SyntheticTimestamps.regular(count: 300, frameRate: 30))

        XCTAssertTrue(observations.allSatisfy { $0.rejectionReasons.contains(.regionTooDark) })
        XCTAssertFalse(analyzer.quality(thermal: .nominal,
                                        systemPressure: .nominal,
                                        controlsRemainedLocked: true,
                                        timing: healthyTiming(frames: 300)).isUsable)
    }

    func testAFeaturelessSceneIsRejectedAsOutOfFocus() {
        // A perfectly flat frame has no second derivatives anywhere, which is
        // what a completely defocused sample looks like.
        let scene = SyntheticScene(baseLevel: 0.3, noiseSigma: 0, seed: 5)
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: scene,
                               timestamps: SyntheticTimestamps.regular(count: 300, frameRate: 30))

        XCTAssertTrue(observations.allSatisfy { $0.rejectionReasons.contains(.outOfFocus) })
    }

    func testAPanningCameraIsRejectedAsMotion() {
        var scene = goodScene
        scene.globalTranslation = CGVector(dx: 0.25, dy: 0)
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: scene,
                               timestamps: SyntheticTimestamps.regular(count: 300, frameRate: 30))
        let quality = analyzer.quality(thermal: .nominal,
                                       systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: healthyTiming(frames: 300))

        XCTAssertTrue(observations.dropFirst().contains { $0.rejectionReasons.contains(.cameraMoved) })
        XCTAssertFalse(quality.isUsable)
        XCTAssertTrue(quality.verdict.reasons.contains(.cameraMoved))
    }

    func testAStillSceneScoresEssentiallyZeroMotionAndAPanScoresMore() {
        // The point of subtracting the noise floor: without it, two consecutive
        // frames of a perfectly still scene differ by their independent sensor
        // noise by more than a visible pan contributes, and the two are
        // indistinguishable.
        let stillAnalyzer = makeAnalyzer()
        _ = run(stillAnalyzer, scene: goodScene,
                timestamps: SyntheticTimestamps.regular(count: 200, frameRate: 30))
        let still = stillAnalyzer.quality(thermal: .nominal, systemPressure: .nominal,
                                          controlsRemainedLocked: true,
                                          timing: healthyTiming(frames: 200))

        var moving = goodScene
        moving.globalTranslation = CGVector(dx: 0.15, dy: 0.05)
        let movingAnalyzer = makeAnalyzer()
        _ = run(movingAnalyzer, scene: moving,
                timestamps: SyntheticTimestamps.regular(count: 200, frameRate: 30))
        let panned = movingAnalyzer.quality(thermal: .nominal, systemPressure: .nominal,
                                            controlsRemainedLocked: true,
                                            timing: healthyTiming(frames: 200))

        XCTAssertLessThan(still.globalMotionScore, 0.0001,
                          "a still scene must read as still, not as its own noise floor")
        XCTAssertGreaterThan(panned.globalMotionScore, still.globalMotionScore)
        XCTAssertGreaterThan(panned.globalMotionScore, 0.0002)
    }

    func testExposureFlickerIsRejectedAndAlsoReadsAsMotion() {
        var scene = goodScene
        scene.flicker = SyntheticFlicker(amplitude: 0.25, frequencyHertz: 2, phase: 0)
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: scene,
                               timestamps: SyntheticTimestamps.regular(count: 300, frameRate: 30))
        let quality = analyzer.quality(thermal: .nominal,
                                       systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: healthyTiming(frames: 300))

        // Every individual frame is correctly exposed on its own: the mean
        // level stays inside the usable band throughout. Only comparing frames
        // reveals the flicker, which is why exposure stability is a window gate
        // rather than a per-frame one.
        XCTAssertTrue(observations.allSatisfy {
            $0.statistics.mean > QualityThresholds.screening.minimumMeanLuma
                && $0.statistics.mean < QualityThresholds.screening.maximumMeanLuma
        })
        XCTAssertFalse(quality.isUsable)
        XCTAssertTrue(quality.verdict.reasons.contains(.exposureUnstable))

        // A whole-frame brightness change is indistinguishable from movement to
        // a frame-difference metric, so the motion gate fires too. That is a
        // known limitation of the Phase 3A stand-in, not a bug: the window is
        // rejected either way, and Phase 3C's optical flow separates the two.
        XCTAssertTrue(quality.verdict.reasons.contains(.cameraMoved))
    }

    func testAStalledStreamInvalidatesTheWindow() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: goodScene,
                timestamps: SyntheticTimestamps.regular(count: 300, frameRate: 30))

        var collector = FrameTimingCollector()
        for time in SyntheticTimestamps.withStall(count: 300, frameRate: 30,
                                                  stallAfterIndex: 150, stallSeconds: 2.0) {
            collector.record(presentationSeconds: time)
        }

        let quality = analyzer.quality(thermal: .nominal,
                                       systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: collector.statistics())

        XCTAssertFalse(quality.isUsable)
        XCTAssertTrue(quality.verdict.reasons.contains(.frameDeliveryDiscontinuous))
    }

    func testTooShortARunCannotProduceAResult() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: goodScene,
                timestamps: SyntheticTimestamps.regular(count: 5, frameRate: 30))

        let quality = analyzer.quality(thermal: .nominal,
                                       systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: healthyTiming(frames: 5))

        XCTAssertFalse(quality.isUsable)
        XCTAssertTrue(quality.verdict.reasons.contains(.insufficientUsableFrames))
    }

    // MARK: - Region and mask are honoured

    func testOnlyTheRegionIsAnalysedNotTheWholeFrame() {
        // Blow out the top-left quarter. The full frame sees the clipping; a
        // region in the bottom-right does not.
        let scene = SyntheticScene(
            baseLevel: 0.3,
            noiseSigma: 0.01,
            hotspot: SyntheticHotspot(center: CGPoint(x: 0.1, y: 0.1),
                                      radiusPixels: 25,
                                      peakBrightness: 1.5),
            seed: 8
        )
        let frame = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)

        let whole = FrameAnalyzer(region: .fullFrame)
        whole.begin(atTimestamp: 0)
        let wholeObservation = whole.analyze(luma: frame, presentationSeconds: 0)

        let corner = FrameAnalyzer(region: AnalysisRegion(
            normalizedRect: CGRect(x: 0.6, y: 0.6, width: 0.35, height: 0.35)
        ))
        corner.begin(atTimestamp: 0)
        let cornerObservation = corner.analyze(luma: frame, presentationSeconds: 0)

        XCTAssertGreaterThan(wholeObservation.statistics.saturatedFraction, 0.005)
        XCTAssertEqual(cornerObservation.statistics.saturatedFraction, 0, accuracy: 1e-9)
    }

    func testTheOpticalMaskExcludesTheHotspotFromTheStatistics() {
        // A hotspot exactly where the screening mask expects the torch
        // reflection: masked out, it stops driving the statistics.
        let scene = SyntheticScene(
            baseLevel: 0.3,
            noiseSigma: 0.01,
            hotspot: SyntheticHotspot(center: CGPoint(x: 0.5, y: 0.33),
                                      radiusPixels: 30,
                                      peakBrightness: 1.5),
            seed: 9
        )
        let frame = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)

        let unmasked = AnalysisRegion(normalizedRect: AnalysisRegion.screeningDefault.normalizedRect)
        let withoutMask = FrameAnalyzer(region: unmasked)
        withoutMask.begin(atTimestamp: 0)
        let withoutMaskObservation = withoutMask.analyze(luma: frame, presentationSeconds: 0)

        let withMask = FrameAnalyzer(region: .screeningDefault)
        withMask.begin(atTimestamp: 0)
        let withMaskObservation = withMask.analyze(luma: frame, presentationSeconds: 0)

        XCTAssertGreaterThan(withoutMaskObservation.statistics.saturatedFraction,
                             withMaskObservation.statistics.saturatedFraction,
                             "the mask must actually remove the reflection")
    }

    func testAnalyzingBeforeBeginStillWorksAndAnchorsAtTheFirstFrame() {
        let analyzer = FrameAnalyzer(region: .fullFrame)
        let observation = analyzer.analyze(
            luma: SyntheticFrameFactory.render(goodScene, atTime: 0, frameIndex: 0),
            presentationSeconds: 42
        )
        XCTAssertEqual(observation.stage, .torchSettling)
    }

    // MARK: - Detection is stage-gated

    /// A scene with drifting specks, so detection has something to find.
    private var samplingScene: SyntheticScene {
        var scene = goodScene
        scene.specks = (0..<8).map { index in
            SyntheticSpeck(center: CGPoint(x: 0.2 + Double(index % 4) * 0.2,
                                           y: 0.25 + Double(index / 4) * 0.35),
                           orbitRadius: 0.06,
                           angularSpeed: 1.4,
                           initialPhase: Double(index),
                           drift: .zero,
                           radiusPixels: 1.5,
                           brightness: 0.35)
        }
        return scene
    }

    func testDetectionRunsOnlyDuringTheMeasurementStage() {
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: samplingScene,
                               timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))

        for observation in observations where observation.stage != .measurement {
            XCTAssertFalse(observation.foreground.backgroundIsReady,
                           "\(observation.stage) must not produce detection output")
            XCTAssertTrue(observation.foreground.candidates.isEmpty)
        }

        let measuring = observations.filter { $0.stage == .measurement }
        XCTAssertFalse(measuring.isEmpty)
        XCTAssertTrue(measuring.allSatisfy(\.foreground.backgroundIsReady),
                      "the model must be built by the time measurement starts")
    }

    func testTheBackgroundModelIsBuiltAndReportedAsStable() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: samplingScene,
                timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))

        XCTAssertTrue(analyzer.backgroundIsReady)
        XCTAssertGreaterThan(analyzer.backgroundStability, 0.93)
    }

    func testBackgroundStabilityIsReportedInTheQualityVerdict() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: samplingScene,
                timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))
        let quality = analyzer.quality(thermal: .nominal, systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: healthyTiming(frames: 400))

        XCTAssertNotNil(quality.backgroundStability,
                        "the number is measured, so it must reach the reading")
        XCTAssertTrue(quality.isUsable, "rejected because: \(quality.explanations)")
    }

    func testScatteringIsAggregatedOverTheMeasurementWindowOnly() {
        let analyzer = makeAnalyzer()
        let observations = run(analyzer, scene: samplingScene,
                               timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))
        let scattering = analyzer.scattering()

        let measurementFrames = observations.filter { $0.stage == .measurement }.count
        XCTAssertEqual(scattering.detectionFrames, measurementFrames)
        XCTAssertGreaterThan(scattering.totalAcceptedCandidates, 0)
        XCTAssertGreaterThan(scattering.meanPositiveResidual, 0)
        XCTAssertEqual(scattering.truncatedComponents, 0)
    }

    func testACleanSampleScattersLessThanALoadedOne() {
        // The bulk channel, not the speck count, is what Phase 3D calibrates,
        // so it has to move in the right direction with particle load.
        func meanResidual(speckCount: Int) -> Double {
            var scene = goodScene
            scene.specks = (0..<speckCount).map { index in
                SyntheticSpeck(center: CGPoint(x: 0.1 + Double(index % 8) * 0.11,
                                               y: 0.15 + Double(index / 8) * 0.12),
                               orbitRadius: 0.04,
                               angularSpeed: 1.4,
                               initialPhase: Double(index),
                               drift: .zero,
                               radiusPixels: 1.5,
                               brightness: 0.35)
            }
            let analyzer = makeAnalyzer()
            _ = run(analyzer, scene: scene,
                    timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))
            return analyzer.scattering().meanPositiveResidual
        }

        let sparse = meanResidual(speckCount: 4)
        let dense = meanResidual(speckCount: 40)
        XCTAssertGreaterThan(dense, sparse,
                             "more suspended material must scatter more light")
    }

    func testRejectedFramesNeverEnterTheBackgroundModel() {
        // A run whose background-acquisition frames are all too dark to pass
        // the gates must not produce a model built from them.
        var dark = goodScene
        dark.baseLevel = 0.004
        dark.noiseSigma = 0.0005
        dark.specks = []

        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: dark,
                timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))

        XCTAssertFalse(analyzer.backgroundIsReady,
                       "every acquisition frame failed a gate, so there is nothing to build from")
        XCTAssertEqual(analyzer.scattering().detectionFrames, 0)
    }

    // MARK: - Tracking end to end

    /// A container with marks on it plus drifting particles: enough texture for
    /// camera motion to be measurable, and something to track.
    private func trackedScene(translationX: Double = 0) -> SyntheticScene {
        var scene = samplingScene
        scene.scratches = [
            SyntheticScratch(start: CGPoint(x: 0.10, y: 0.12), end: CGPoint(x: 0.90, y: 0.18),
                             brightness: 0.40, widthPixels: 2),
            SyntheticScratch(start: CGPoint(x: 0.20, y: 0.10), end: CGPoint(x: 0.26, y: 0.90),
                             brightness: 0.30, widthPixels: 2)
        ]
        scene.stationaryBlobs = [
            SyntheticStationaryBlob(center: CGPoint(x: 0.80, y: 0.75), radiusPixels: 4, brightness: 0.45)
        ]
        scene.globalTranslation = CGVector(dx: translationX, dy: 0)
        return scene
    }

    func testAStillRunMeasuresNoGlobalMotion() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: trackedScene(),
                timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))

        XCTAssertLessThan(analyzer.globalMotion.flow.speedPixelsPerSecond, 4,
                          "a still phone must read as still")
    }

    func testAPanIsEitherCompensatedOrInvalidatesTheWindow() {
        // The required outcome is one or the other, never a result computed as
        // though the phone had been still.
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: trackedScene(translationX: 0.05),
                timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))
        let quality = analyzer.quality(thermal: .nominal, systemPressure: .nominal,
                                       controlsRemainedLocked: true,
                                       timing: healthyTiming(frames: 400))
        let motion = analyzer.globalMotion

        let compensated = motion.isTrustworthy && motion.flow.speedPixelsPerSecond > 2
        let invalidated = !quality.isUsable && quality.verdict.reasons.contains(.cameraMoved)

        XCTAssertTrue(compensated || invalidated,
                      "pan neither measured (\(motion.flow.speedPixelsPerSecond) px/s, "
                          + "trustworthy \(motion.isTrustworthy)) nor rejected")
    }

    func testTrackingProducesMetricsOverTheMeasurementWindow() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: trackedScene(),
                timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))
        let metrics = analyzer.tracking()

        XCTAssertGreaterThan(metrics.confirmedSpeckCount + metrics.ambiguousCount
                                 + metrics.staticDefectCount + metrics.bubbleRejectionCount, 0,
                             "something moving in the sample must be tracked")
        XCTAssertEqual(metrics.tracksDroppedForCapacity, 0)
    }

    func testTheWindowSummaryReportsRepeatability() {
        let analyzer = makeAnalyzer()
        _ = run(analyzer, scene: trackedScene(),
                timestamps: SyntheticTimestamps.regular(count: 400, frameRate: 30))
        let summary = analyzer.scatteringSummary()

        XCTAssertGreaterThan(summary.windowCount, 0)
        XCTAssertGreaterThan(summary.medianPositiveResidual, 0)
        XCTAssertFalse(analyzer.scatteringWindows().isEmpty,
                       "the raw windows are kept for validation, not just the summary")
    }

    // MARK: - Determinism

    func testTheSameSceneAlwaysProducesTheSameObservations() {
        let timestamps = SyntheticTimestamps.regular(count: 120, frameRate: 30)

        let first = run(makeAnalyzer(), scene: goodScene, timestamps: timestamps)
        let second = run(makeAnalyzer(), scene: goodScene, timestamps: timestamps)

        XCTAssertEqual(first, second)
    }
}
