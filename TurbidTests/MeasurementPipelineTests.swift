import CoreGraphics
import XCTest
@testable import Turbid

/// The bridge between camera frames and the interface.
final class MeasurementPipelineTests: XCTestCase {

    private let frameRate: Double = 30

    /// The same clean scene `FrameAnalyzerTests` and
    /// `Tools/analysis_reference.py` use. Its specks orbit, so tracking has
    /// something real to follow.
    private var scene: SyntheticScene {
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

    /// The gates and the timeline are what is under test, not the region
    /// geometry, so the analyzer looks at the whole frame — the conditions the
    /// reference has already checked its thresholds under. The region itself is
    /// covered by `AnalysisRegionTests`.
    private func makePipeline(chartCapacity: Int = 240) -> MeasurementPipeline {
        MeasurementPipeline(analyzer: FrameAnalyzer(region: .fullFrame),
                            chartCapacity: chartCapacity)
    }

    private func healthyTiming() -> FrameTimingStatistics {
        FrameTimingStatistics(
            deliveredFrames: 375, droppedFrames: 1, measuredFrameRate: frameRate,
            medianIntervalSeconds: 1 / frameRate, maximumIntervalSeconds: 1.5 / frameRate,
            firstTimestampSeconds: 0, lastTimestampSeconds: 12.5
        )
    }

    /// Feeds a whole protocol's worth of frames through the deterministic path.
    @discardableResult
    private func runWholeProtocol(_ pipeline: MeasurementPipeline,
                                  scene: SyntheticScene? = nil) -> Int {
        let used = scene ?? self.scene
        let total = Int((CaptureProtocol.screening.totalSeconds + 0.5) * frameRate)
        pipeline.start()
        for index in 0..<total {
            let time = Double(index) / frameRate
            let frame = SyntheticFrameFactory.render(used, atTime: time, frameIndex: index)
            pipeline.consume(luma: frame, presentationSeconds: time)
        }
        return total
    }

    // MARK: - Frame handling

    func testThePipelineMeasuresTheAnalysisRegionByDefault() {
        XCTAssertEqual(MeasurementPipeline().region, .screeningDefault)
        XCTAssertEqual(MeasurementPipeline().captureProtocol, .screening)
    }

    func testOnlyEveryOtherFrameIsAnalysed() {
        let pipeline = makePipeline()
        pipeline.start()

        for index in 0..<20 {
            let time = Double(index) / frameRate
            let frame = SyntheticFrameFactory.render(scene, atTime: time, frameIndex: index)
            pipeline.consume(luma: frame, presentationSeconds: time)
        }

        XCTAssertEqual(pipeline.progress.framesAnalysed, 10,
                       "a stride of two must halve the analysis rate, not the capture rate")
    }

    func testNoFrameIsAnalysedBeforeStartOrAfterCompletion() {
        let pipeline = makePipeline()

        let frame = SyntheticFrameFactory.render(scene, atTime: 0, frameIndex: 0)
        pipeline.consume(luma: frame, presentationSeconds: 0)
        pipeline.consume(luma: frame, presentationSeconds: 1 / frameRate)
        XCTAssertEqual(pipeline.progress.framesAnalysed, 0,
                       "frames arriving before a run belong to no run")

        runWholeProtocol(pipeline)
        XCTAssertTrue(pipeline.isComplete)

        let analysed = pipeline.progress.framesAnalysed
        pipeline.consume(luma: frame, presentationSeconds: 99)
        XCTAssertEqual(pipeline.progress.framesAnalysed, analysed,
                       "a finished run must not absorb late frames")
    }

    func testAWholeProtocolReachesCompletionAndPassesThroughEveryStage() {
        let pipeline = makePipeline()
        pipeline.start()

        var stages: [CaptureStage] = []
        let total = Int((CaptureProtocol.screening.totalSeconds + 0.5) * frameRate)
        for index in 0..<total {
            let time = Double(index) / frameRate
            let frame = SyntheticFrameFactory.render(scene, atTime: time, frameIndex: index)
            if let observation = pipeline.consume(luma: frame, presentationSeconds: time) {
                if stages.last != observation.stage { stages.append(observation.stage) }
            }
        }

        XCTAssertEqual(stages, [.torchSettling, .backgroundAcquisition, .measurement, .complete],
                       "screening runs settling, background, measurement, done")
        XCTAssertTrue(pipeline.isComplete)
        XCTAssertEqual(pipeline.progress.stage, .complete)
        XCTAssertEqual(pipeline.progress.overallProgress, 1, accuracy: 1e-9)
        XCTAssertTrue(pipeline.progress.backgroundIsReady,
                      "a completed run must have built the background it measured against")
    }

    // MARK: - What the interface receives

    func testProgressIsPublishedAboutFiveTimesASecondNotOncePerFrame() {
        let pipeline = makePipeline()
        runWholeProtocol(pipeline)

        let samples = pipeline.chartSamples
        let expected = CaptureProtocol.screening.totalSeconds
            / MeasurementPipeline.Configuration.screening.publishInterval

        XCTAssertGreaterThan(samples.count, Int(expected * 0.7),
                             "the graph must actually fill in during the run")
        XCTAssertLessThan(samples.count, Int(expected * 1.4),
                          "publishing per frame would flood the MainActor")
    }

    func testTheChartIsBoundedEvenWhenTheRunIsLong() {
        let pipeline = makePipeline(chartCapacity: 12)
        runWholeProtocol(pipeline)

        XCTAssertLessThanOrEqual(pipeline.chartSamples.count, 12)
        XCTAssertEqual(pipeline.chartSamples.map(\.elapsedSeconds),
                       pipeline.chartSamples.map(\.elapsedSeconds).sorted(),
                       "chart samples must stay in time order after the ring wraps")
    }

    func testChartSamplesCarryNoNTUBecauseNoneExistsMidRun() {
        let pipeline = makePipeline()
        runWholeProtocol(pipeline)

        XCTAssertFalse(pipeline.chartSamples.isEmpty)
        XCTAssertTrue(pipeline.chartSamples.allSatisfy { $0.ntu == nil },
                      "an NTU that appears mid-run and is withheld at the end is worse than none")
    }

    func testStartingAgainDiscardsEverythingFromThePreviousRun() {
        let pipeline = makePipeline()
        runWholeProtocol(pipeline)
        XCTAssertTrue(pipeline.isComplete)

        pipeline.start()

        XCTAssertFalse(pipeline.isComplete)
        XCTAssertTrue(pipeline.chartSamples.isEmpty)
        XCTAssertEqual(pipeline.progress.framesAnalysed, 0)
    }

    // MARK: - The reading

    func testScreeningModeProducesAReadingWithNoNumberAndSaysWhy() {
        let pipeline = makePipeline()
        runWholeProtocol(pipeline)

        let reading = pipeline.makeReading(
            mode: .screening,
            profile: nil,
            liveBinding: nil,
            thermal: .nominal,
            systemPressure: .nominal,
            controlsRemainedLocked: true,
            timing: healthyTiming(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            algorithmVersions: CalibrationBindingBuilder.algorithmVersions()
        )

        XCTAssertEqual(reading.ntu, .screeningMode)
        XCTAssertEqual(reading.ntu.displayText, "Calibration required")
        XCTAssertNil(reading.calibrationProfileID)
        XCTAssertEqual(reading.clarity.basis, .relativeScatteringIndex,
                       "with no NTU the classification must say what it was based on")
        XCTAssertEqual(reading.mode, .screening)
        XCTAssertGreaterThanOrEqual(reading.index.value, 0)
        XCTAssertEqual(reading.measurementWindowSeconds,
                       CaptureProtocol.screening.measurementWindowSeconds)
    }

    func testTheReadingRecordsTheVersionsThatProducedIt() {
        let pipeline = makePipeline()
        runWholeProtocol(pipeline)

        let versions = CalibrationBindingBuilder.algorithmVersions()
        let reading = pipeline.makeReading(
            mode: .screening, profile: nil, liveBinding: nil,
            thermal: .nominal, systemPressure: .nominal, controlsRemainedLocked: true,
            timing: healthyTiming(), timestamp: Date(),
            algorithmVersions: versions
        )

        XCTAssertEqual(reading.algorithmVersions, versions)
        XCTAssertEqual(reading.quality.captureProtocolVersion,
                       CaptureProtocol.screening.version)
        XCTAssertEqual(reading.quality.analysisRegionVersion,
                       AnalysisRegion.fullFrame.version)
        XCTAssertEqual(reading.clarityPolicyVersion, ClarityPolicy.screening.version)
    }

    func testAShakenRunIsRejectedRatherThanReported() {
        var moving = scene
        // Well past the gate: `Tools/analysis_reference.py` measures a 0.4
        // per-second translation at about twice `maximumGlobalMotion`.
        moving.globalTranslation = CGVector(dx: 0.35, dy: 0.25)

        let pipeline = makePipeline()
        runWholeProtocol(pipeline, scene: moving)

        let reading = pipeline.makeReading(
            mode: .screening, profile: nil, liveBinding: nil,
            thermal: .nominal, systemPressure: .nominal, controlsRemainedLocked: true,
            timing: healthyTiming(), timestamp: Date(),
            algorithmVersions: CalibrationBindingBuilder.algorithmVersions()
        )

        XCTAssertFalse(reading.validity.isValid,
                       "a phone that moved through the whole window has not measured anything")
        XCTAssertFalse(reading.validity.reasons.isEmpty,
                       "a rejection must always name its reasons")
    }
}
