import CoreMedia
import CoreVideo
import Foundation

/// Receives capture frames. Implemented by the pipeline, called by the camera.
protocol CaptureFrameConsuming: AnyObject, Sendable {
    /// Called on the capture pipeline's processing queue, with a buffer that
    /// must not outlive the call.
    func consume(pixelBuffer: CVPixelBuffer, presentationSeconds: Double)
}

/// Owns the frame analyzer and turns a stream of camera frames into progress
/// updates and, at the end, one reading.
///
/// The analyzer runs on the capture pipeline's processing queue and nowhere
/// else. Only value types cross to the MainActor, and they cross at about five
/// times a second regardless of the capture rate: the camera runs at 30 fps,
/// the analyzer at half that, and the interface needs neither.
final class MeasurementPipeline: CaptureFrameConsuming, @unchecked Sendable {

    struct Configuration: Equatable, Sendable {
        /// Analyse every Nth delivered frame.
        ///
        /// Two, so a 30 fps camera is analysed at 15 fps. Detection and
        /// tracking cost far more per frame than capture does, and a particle
        /// crossing the region takes seconds: nothing is learned from the
        /// frames in between that is worth dropping behind for.
        var frameStride: Int
        /// Minimum interval between updates published to the interface.
        var publishInterval: Double
        var version: Int

        static let screening = Configuration(frameStride: 2, publishInterval: 0.2, version: 1)
    }

    let configuration: Configuration
    private let analyzer: FrameAnalyzer
    private let lock = NSLock()

    // Guarded by `lock`.
    private var isRunning = false
    private var startTimestamp: Double?
    private var lastPublished: Double = 0
    private var frameCounter = 0
    private var analysedFrames = 0
    private var usableFrames = 0
    private var chart: ScatteringSampleBuffer
    private var latestProgress = MeasurementProgress.idle
    private var lastObservation: FrameObservation?
    private var completionTimestamp: Double?

    private let continuation: AsyncStream<MeasurementProgress>.Continuation
    /// Rate-limited progress, newest only: a slow interface must never make the
    /// analyzer wait or accumulate stale updates.
    let updates: AsyncStream<MeasurementProgress>

    init(analyzer: FrameAnalyzer = FrameAnalyzer(),
         configuration: Configuration = .screening,
         chartCapacity: Int = 240) {
        self.analyzer = analyzer
        self.configuration = configuration
        self.chart = ScatteringSampleBuffer(capacity: chartCapacity)
        let (stream, continuation) = AsyncStream<MeasurementProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.updates = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    var region: AnalysisRegion { analyzer.region }
    var captureProtocol: CaptureProtocol { analyzer.captureProtocol }

    /// Begins a run. The timeline anchors to the first frame that arrives.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = true
        startTimestamp = nil
        completionTimestamp = nil
        frameCounter = 0
        analysedFrames = 0
        usableFrames = 0
        lastPublished = 0
        lastObservation = nil
        chart.reset()
        latestProgress = .idle
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completionTimestamp != nil
    }

    var progress: MeasurementProgress {
        lock.lock()
        defer { lock.unlock() }
        return latestProgress
    }

    var chartSamples: [ScatteringSample] {
        lock.lock()
        defer { lock.unlock() }
        return chart.samples
    }

    // MARK: - Frames

    func consume(pixelBuffer: CVPixelBuffer, presentationSeconds: Double) {
        lock.lock()
        guard isRunning, completionTimestamp == nil else {
            lock.unlock()
            return
        }

        frameCounter += 1
        guard frameCounter % max(1, configuration.frameStride) == 0 else {
            lock.unlock()
            return
        }

        if startTimestamp == nil {
            startTimestamp = presentationSeconds
            analyzer.begin(atTimestamp: presentationSeconds)
        }
        let start = startTimestamp ?? presentationSeconds
        lock.unlock()

        // The analyzer runs outside the lock: it is the expensive part, and
        // holding a lock across it would stall `progress` reads from the
        // interface. Only this queue ever calls it.
        guard let observation = analyzer.analyze(pixelBuffer: pixelBuffer,
                                                 presentationSeconds: presentationSeconds) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        analysedFrames += 1
        if observation.isUsable { usableFrames += 1 }
        lastObservation = observation

        if observation.stage == .complete, completionTimestamp == nil {
            completionTimestamp = presentationSeconds
        }

        let elapsed = presentationSeconds - start
        if elapsed - lastPublished >= configuration.publishInterval
            || completionTimestamp != nil {
            lastPublished = elapsed
            appendChartSample(elapsed: elapsed)
            latestProgress = makeProgress(observation: observation,
                                          elapsed: elapsed,
                                          presentationSeconds: presentationSeconds)
            continuation.yield(latestProgress)
        }
    }

    /// Deterministic entry point, for tests and the Simulator.
    @discardableResult
    func consume(luma: LumaImage, presentationSeconds: Double) -> FrameObservation? {
        lock.lock()
        guard isRunning, completionTimestamp == nil else {
            lock.unlock()
            return nil
        }
        frameCounter += 1
        guard frameCounter % max(1, configuration.frameStride) == 0 else {
            lock.unlock()
            return nil
        }
        if startTimestamp == nil {
            startTimestamp = presentationSeconds
            analyzer.begin(atTimestamp: presentationSeconds)
        }
        let start = startTimestamp ?? presentationSeconds
        lock.unlock()

        let observation = analyzer.analyze(luma: luma, presentationSeconds: presentationSeconds)

        lock.lock()
        defer { lock.unlock() }
        analysedFrames += 1
        if observation.isUsable { usableFrames += 1 }
        lastObservation = observation
        if observation.stage == .complete, completionTimestamp == nil {
            completionTimestamp = presentationSeconds
        }
        let elapsed = presentationSeconds - start
        if elapsed - lastPublished >= configuration.publishInterval || completionTimestamp != nil {
            lastPublished = elapsed
            appendChartSample(elapsed: elapsed)
            latestProgress = makeProgress(observation: observation,
                                          elapsed: elapsed,
                                          presentationSeconds: presentationSeconds)
            continuation.yield(latestProgress)
        }
        return observation
    }

    /// Assembles the reading. Called once the run is complete.
    ///
    /// - Parameter profile: the calibration in force, or `nil`. The NTU gate
    ///   decides what that means; nothing here does.
    func makeReading(mode: MeasurementMode,
                     profile: CalibrationProfile?,
                     liveBinding: CalibrationBinding?,
                     thermal: ThermalStatus,
                     systemPressure: SystemPressureLevel,
                     controlsRemainedLocked: Bool,
                     timing: FrameTimingStatistics,
                     timestamp: Date,
                     algorithmVersions: CalibrationBinding.AlgorithmVersions) -> TurbidityReading {
        let quality = analyzer.quality(thermal: thermal,
                                       systemPressure: systemPressure,
                                       controlsRemainedLocked: controlsRemainedLocked,
                                       timing: timing)
        return TurbidityReading.make(
            timestamp: timestamp,
            windowSeconds: analyzer.captureProtocol.measurementWindowSeconds,
            mode: mode,
            summary: analyzer.scatteringSummary(),
            tracking: analyzer.tracking(),
            quality: quality,
            profile: profile,
            liveBinding: liveBinding,
            algorithmVersions: algorithmVersions
        )
    }

    /// The raw per-window results, for validation rather than display.
    func scatteringWindows() -> [ScatteringWindow] { analyzer.scatteringWindows() }

    // MARK: - Progress

    /// Runs under `lock`.
    private func appendChartSample(elapsed: Double) {
        // The running index over everything measured so far, so the chart shows
        // the measurement converging rather than per-frame noise.
        let index = RelativeScatteringIndex.make(summary: analyzer.scatteringSummary(),
                                                 tracking: analyzer.tracking())
        chart.append(elapsedSeconds: elapsed, index: index.value, ntu: nil)
    }

    /// Runs under `lock`.
    private func makeProgress(observation: FrameObservation,
                              elapsed: Double,
                              presentationSeconds: Double) -> MeasurementProgress {
        let timeline = CaptureProtocolTimeline(captureProtocol: analyzer.captureProtocol,
                                               startSeconds: presentationSeconds - elapsed)
        // At most two prompts: a wall of warnings is not actionable while
        // holding a phone still.
        let hints = Array(observation.rejectionReasons.compactMap(\.livePrompt).prefix(2))

        return MeasurementProgress(
            stage: observation.stage,
            overallProgress: timeline.progress(at: presentationSeconds),
            stageProgress: timeline.stageProgress(at: presentationSeconds),
            elapsedSeconds: elapsed,
            remainingSeconds: max(0, analyzer.captureProtocol.totalSeconds - elapsed),
            framesAnalysed: analysedFrames,
            usableFrames: usableFrames,
            backgroundIsReady: analyzer.backgroundIsReady,
            hints: hints,
            latestSample: chart.latest
        )
    }
}
