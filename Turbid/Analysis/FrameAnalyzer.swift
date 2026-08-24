import CoreVideo
import Foundation

/// Turns frames into observations and a window verdict.
///
/// Not thread-safe by design: it is owned by the capture pipeline's serial
/// processing queue and touched from nowhere else. All of its buffers are
/// reused between frames.
///
/// Detection runs only on frames that passed the per-frame quality gates, and
/// only inside the stages it belongs to: background-acquisition frames build
/// the model, measurement frames are compared against it. A rejected frame
/// never enters the background model and never produces candidates.
///
/// Phase 3C adds tracking on top of the candidates produced here.
final class FrameAnalyzer: FrameAnalyzing {

    let region: AnalysisRegion
    let captureProtocol: CaptureProtocol
    private let thresholds: QualityThresholds
    private let gate: FrameGate
    private let evaluator: FrameQualityEvaluator
    private let detector: SpeckDetector
    private let flowEstimator: GlobalFlowEstimating
    private let tracker: MultiObjectTracker
    private let classifier: TrackClassifier
    private let gravityProvider: GravityProviding
    private var aggregator: ScatteringWindowAggregator

    // Reused buffers.
    private let extractor = PixelBufferLumaExtractor()
    private var cropBuffer = LumaImage(width: 0, height: 0)
    private var coarse = LumaImage(width: 0, height: 0)
    private var previousCoarse = LumaImage(width: 0, height: 0)
    private var hasPreviousCoarse = false
    private var mask: RasterizedMask?
    private var maskSize: (width: Int, height: Int)?

    private var timeline: CaptureProtocolTimeline?
    private var aggregate = FrameAggregate()
    private var sequenceNumber = 0
    private var backgroundFinalized = false
    /// Estimated from the measured delivery rate, so the background samples
    /// spread across the acquisition window whatever rate the camera achieves.
    private var expectedAcquisitionFrames = 0
    private var firstTimestamp: Double?
    private var lastMotion = GlobalMotion.none
    /// Track identifiers already counted, so a speck visible for fifty frames
    /// contributes one event rather than fifty.
    private var seenTrackIdentifiers = Set<Int>()
    private var measurementStart: Double?
    private var measurementEnd: Double?

    init(region: AnalysisRegion = .screeningDefault,
         captureProtocol: CaptureProtocol = .screening,
         thresholds: QualityThresholds = .screening,
         detector: SpeckDetector.Configuration = .screening,
         flow: PatchFlowEstimator.Configuration = .screening,
         tracker: MultiObjectTracker.Configuration = .screening,
         classifier: TrackClassifier.Configuration = .screening,
         aggregation: ScatteringWindowAggregator.Configuration = .screening,
         gravityProvider: GravityProviding = AssumedPortraitGravityProvider()) {
        self.region = region
        self.captureProtocol = captureProtocol
        self.thresholds = thresholds
        self.gate = FrameGate(thresholds: thresholds)
        self.evaluator = FrameQualityEvaluator(thresholds: thresholds)
        self.detector = SpeckDetector(configuration: detector)
        self.flowEstimator = PatchFlowEstimator(configuration: flow)
        self.tracker = MultiObjectTracker(configuration: tracker)
        self.classifier = TrackClassifier(configuration: classifier)
        self.aggregator = ScatteringWindowAggregator(configuration: aggregation)
        self.gravityProvider = gravityProvider
    }

    func begin(atTimestamp presentationSeconds: Double) {
        timeline = CaptureProtocolTimeline(captureProtocol: captureProtocol,
                                           startSeconds: presentationSeconds)
        aggregate = FrameAggregate()
        sequenceNumber = 0
        hasPreviousCoarse = false
        backgroundFinalized = false
        expectedAcquisitionFrames = 0
        firstTimestamp = nil
        detector.reset()
        flowEstimator.reset()
        tracker.reset()
        aggregator.reset()
        lastMotion = .none
        seenTrackIdentifiers.removeAll(keepingCapacity: true)
        measurementStart = nil
        measurementEnd = nil
    }

    func analyze(pixelBuffer: CVPixelBuffer, presentationSeconds: Double) -> FrameObservation? {
        guard extractor.extract(from: pixelBuffer, using: region) else { return nil }
        return analyzeRegion(extractor.region, presentationSeconds: presentationSeconds)
    }

    func analyze(luma: LumaImage, presentationSeconds: Double) -> FrameObservation {
        // Cropped the same way a camera buffer is, so a synthetic frame and a
        // real one travel the identical path.
        guard let pixelRect = region.pixelRect(inWidth: luma.width, height: luma.height),
              cropInPlace(luma, to: pixelRect) else {
            return emptyObservation(at: presentationSeconds)
        }
        return analyzeRegion(cropBuffer, presentationSeconds: presentationSeconds)
    }

    // MARK: - Core

    private func analyzeRegion(_ image: LumaImage, presentationSeconds: Double) -> FrameObservation {
        let timeline = self.timeline ?? CaptureProtocolTimeline(
            captureProtocol: captureProtocol, startSeconds: presentationSeconds
        )
        if self.timeline == nil { self.timeline = timeline }

        let mask = rasterizedMask(width: image.width, height: image.height)
        let statistics = LumaStatisticsCalculator.statistics(of: image, mask: mask)

        prepareCoarseBuffers(for: image)
        // Double-buffered rather than copied: assigning `previousCoarse = coarse`
        // would leave the two sharing storage, so the next `boxAverage` would
        // trigger a copy-on-write allocation on every single frame.
        swap(&coarse, &previousCoarse)
        image.boxAverage(into: &coarse)
        let motion = hasPreviousCoarse
            ? LumaStatisticsCalculator.normalizedDifference(between: previousCoarse, and: coarse)
            : 0
        hasPreviousCoarse = true

        let stage = timeline.stage(at: presentationSeconds)
        let reasons = perFrameRejections(statistics: statistics, motion: motion)
        let isUsable = reasons.isEmpty

        if expectedAcquisitionFrames == 0, aggregate.evaluatedFrames >= 2,
           let first = firstTimestamp, presentationSeconds > first {
            let rate = Double(aggregate.evaluatedFrames) / (presentationSeconds - first)
            expectedAcquisitionFrames = timeline.expectedFrameCount(
                for: .backgroundAcquisition, atFrameRate: rate
            )
        }
        if firstTimestamp == nil { firstTimestamp = presentationSeconds }

        let foreground = runDetection(on: image,
                                      stage: stage,
                                      isUsable: isUsable,
                                      noiseSigma: statistics.noiseSigma)

        if stage == .measurement, isUsable, foreground.backgroundIsReady {
            runTracking(on: image,
                        candidates: foreground.candidates,
                        bulk: foreground.bulk,
                        timestampSeconds: presentationSeconds,
                        noiseSigma: statistics.noiseSigma)
        }

        let observation = FrameObservation(
            sequenceNumber: sequenceNumber,
            timestampSeconds: presentationSeconds,
            stage: stage,
            statistics: statistics,
            globalMotionScore: motion,
            isUsable: isUsable,
            rejectionReasons: reasons,
            foreground: foreground
        )
        sequenceNumber += 1
        aggregate.record(observation)
        return observation
    }

    /// Feeds the detector according to the stage, and only with frames that
    /// passed the gates.
    private func runDetection(on image: LumaImage,
                              stage: CaptureStage,
                              isUsable: Bool,
                              noiseSigma: Double) -> ForegroundObservation {
        detector.prepare(
            width: image.width,
            height: image.height,
            mask: rasterizedMask(width: image.width, height: image.height),
            expectedAcquisitionFrames: expectedAcquisitionFrames
        )

        switch stage {
        case .backgroundAcquisition:
            // A frame that failed a gate must never enter the model every
            // later frame is measured against.
            if isUsable { detector.ingestBackgroundFrame(image) }
            return .notReady

        case .measurement:
            if !backgroundFinalized {
                backgroundFinalized = detector.finalizeBackground(noiseSigma: noiseSigma)
                if !backgroundFinalized {
                    TurbidLog.analysis.notice(
                        "Background model could not be built; too few usable acquisition frames."
                    )
                }
            }
            guard isUsable, detector.backgroundIsReady else { return .notReady }
            return detector.detect(in: image, frameNoiseSigma: noiseSigma)

        case .ambientReference, .torchSettling, .complete:
            return .notReady
        }
    }

    private func perFrameRejections(statistics: LumaStatistics, motion: Double) -> [MeasurementRejectionReason] {
        gate.rejections(statistics: statistics, motion: motion)
    }

    func quality(thermal: ThermalStatus,
                 systemPressure: SystemPressureLevel,
                 controlsRemainedLocked: Bool,
                 timing: FrameTimingStatistics) -> CaptureQuality {
        evaluator.evaluate(QualityEvaluationInput(
            statistics: aggregate.windowStatistics(),
            globalMotionScore: aggregate.medianMotion(),
            exposureVariation: aggregate.exposureVariation(),
            controlsRemainedLocked: controlsRemainedLocked,
            usableFrames: aggregate.usableFrames,
            evaluatedFrames: aggregate.evaluatedFrames,
            droppedFrameRatio: timing.dropRatio,
            frameDeliveryIsContinuous: timing.isContinuous(),
            thermal: thermal,
            systemPressure: systemPressure,
            // `nil` until the model has actually been built: an unbuilt model
            // has no stability, and reporting zero would fire the gate for a
            // measurement that simply has not reached that stage yet.
            backgroundStability: detector.backgroundIsReady ? detector.backgroundStability : nil,
            // Deliberately `nil`. Calibration compatibility is enforced by the
            // NTU gate, which withholds the number and says why. Feeding it in
            // here would invalidate the whole window instead, discarding a
            // perfectly good optical observation because the calibration that
            // would have labelled it in NTU does not apply.
            calibrationProfileIsCompatible: nil,
            analysisRegionVersion: region.version,
            captureProtocolVersion: captureProtocol.version
        ))
    }

    /// Bulk scattering and candidate counts for the measurement window.
    func scattering() -> WindowScattering {
        aggregate.windowScattering()
    }

    /// Tracking results for the measurement window.
    func tracking() -> TrackingMetrics {
        guard let start = measurementStart, let end = measurementEnd else { return .empty }
        tracker.classifyAll(using: classifier, gravity: gravityProvider.currentGravity())
        return TrackingMetrics.make(
            tracks: tracker.tracks,
            regionWidth: regionPixelWidth,
            regionHeight: regionPixelHeight,
            windowSeconds: max(0, end - start),
            motion: lastMotion,
            tracksDroppedForCapacity: tracker.droppedForCapacity
        )
    }

    /// Robust summary across the overlapping sub-windows, with repeatability.
    func scatteringSummary() -> ScatteringSummary {
        var closing = aggregator
        closing.finish()
        return closing.summary()
    }

    /// The raw per-window results, kept for validation rather than display.
    func scatteringWindows() -> [ScatteringWindow] {
        var closing = aggregator
        closing.finish()
        return closing.windows
    }

    /// Runs flow estimation, tracking and window aggregation for one
    /// measurement frame.
    private func runTracking(on image: LumaImage,
                             candidates: [SpeckCandidate],
                             bulk: BulkScatteringMetrics,
                             timestampSeconds: Double,
                             noiseSigma: Double) {
        regionPixelWidth = image.width
        regionPixelHeight = image.height
        flowEstimator.prepare(regionWidth: image.width, regionHeight: image.height)
        tracker.prepare(regionWidth: image.width, regionHeight: image.height)

        lastMotion = flowEstimator.update(with: image,
                                          timestampSeconds: timestampSeconds,
                                          noiseSigma: noiseSigma)

        let tracks = tracker.update(candidates: candidates,
                                    timestampSeconds: timestampSeconds,
                                    motion: lastMotion)

        // A speck counts once, on the frame its track is first confirmed.
        var newEvents = 0
        for track in tracks where track.state.isCountable {
            if seenTrackIdentifiers.insert(track.id).inserted { newEvents += 1 }
        }

        aggregator.record(timestampSeconds: timestampSeconds,
                          bulk: bulk,
                          newSpeckEvents: newEvents)

        if measurementStart == nil { measurementStart = timestampSeconds }
        measurementEnd = timestampSeconds
    }

    var backgroundIsReady: Bool { detector.backgroundIsReady }
    var backgroundStability: Double { detector.backgroundStability }
    var globalMotion: GlobalMotion { lastMotion }

    private var regionPixelWidth = 0
    private var regionPixelHeight = 0

    /// Progress through the run, for the UI.
    func progress(at presentationSeconds: Double) -> Double {
        timeline?.progress(at: presentationSeconds) ?? 0
    }

    func stage(at presentationSeconds: Double) -> CaptureStage {
        timeline?.stage(at: presentationSeconds) ?? .torchSettling
    }

    // MARK: - Buffers

    private func rasterizedMask(width: Int, height: Int) -> RasterizedMask? {
        guard !region.mask.isEmpty else { return nil }
        if maskSize?.width != width || maskSize?.height != height {
            mask = RasterizedMask(description: region.mask, width: width, height: height)
            maskSize = (width, height)
        }
        return mask
    }

    private func prepareCoarseBuffers(for image: LumaImage) {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return }

        let scale = max(1, longEdge / FrameNormalization.coarsePlaneLongEdge)
        let width = max(1, image.width / scale)
        let height = max(1, image.height / scale)

        guard coarse.width != width || coarse.height != height else { return }
        coarse = LumaImage(width: width, height: height)
        previousCoarse = LumaImage(width: width, height: height)
        hasPreviousCoarse = false
    }

    /// Fills the reused crop buffer, reallocating only when the size changes.
    private func cropInPlace(_ image: LumaImage, to rect: PixelRect) -> Bool {
        guard rect.width > 0, rect.height > 0,
              rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= image.width,
              rect.y + rect.height <= image.height else { return false }

        if cropBuffer.width != rect.width || cropBuffer.height != rect.height {
            cropBuffer = LumaImage(width: rect.width, height: rect.height)
        }

        for row in 0..<rect.height {
            let sourceOffset = (rect.y + row) * image.width + rect.x
            let destinationOffset = row * rect.width
            for column in 0..<rect.width {
                cropBuffer.values[destinationOffset + column] = image.values[sourceOffset + column]
            }
        }
        return true
    }

    private func emptyObservation(at presentationSeconds: Double) -> FrameObservation {
        let observation = FrameObservation(
            sequenceNumber: sequenceNumber,
            timestampSeconds: presentationSeconds,
            stage: timeline?.stage(at: presentationSeconds) ?? .torchSettling,
            statistics: .empty,
            globalMotionScore: 0,
            isUsable: false,
            rejectionReasons: [.insufficientUsableFrames],
            foreground: .notReady
        )
        sequenceNumber += 1
        aggregate.record(observation)
        return observation
    }
}
