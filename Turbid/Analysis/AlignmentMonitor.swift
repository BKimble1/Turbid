import CoreVideo
import Foundation

/// What the alignment screen knows about the frame in front of it right now.
struct AlignmentStatus: Equatable, Sendable {
    /// At most two, so the advice stays actionable.
    let hints: [LiveQualityHint]
    /// Every per-frame gate passed on the most recent frame.
    let passesGates: Bool
    /// Consecutive recent frames that passed. A measurement is worth starting
    /// once the view has been good for a moment, not the instant it flickers
    /// good.
    let steadyFrames: Int
    let meanLevel: Double
    let sharpness: Double
    let motion: Double

    static let unknown = AlignmentStatus(hints: [], passesGates: false, steadyFrames: 0,
                                         meanLevel: 0, sharpness: 0, motion: 0)

    /// Enough consecutive good frames to be worth the user's twelve seconds.
    var isReadyToMeasure: Bool { steadyFrames >= 8 }
}

/// Applies the per-frame quality gates to the live preview, so the setup screen
/// can say what is wrong *before* a measurement is committed to.
///
/// Runs the same `FrameGate` the analyzer runs, on the same region, but nothing
/// else: no background model, no detection, no tracking. Alignment is a
/// question about the view, not about the sample, and doing detection work here
/// would heat the phone up before the measurement that needs the thermal
/// headroom.
final class AlignmentMonitor: CaptureFrameConsuming, @unchecked Sendable {

    /// Frames are only examined this often. Alignment advice five times a
    /// second is already faster than anyone can act on.
    private let inspectionInterval: Double

    let region: AnalysisRegion
    private let gate: FrameGate

    private let lock = NSLock()
    private let continuation: AsyncStream<AlignmentStatus>.Continuation
    let updates: AsyncStream<AlignmentStatus>

    // Touched only on the capture pipeline's processing queue.
    private let extractor = PixelBufferLumaExtractor()
    private var coarse = LumaImage(width: 0, height: 0)
    private var previousCoarse = LumaImage(width: 0, height: 0)
    private var hasPreviousCoarse = false
    private var mask: RasterizedMask?
    private var maskSize: (width: Int, height: Int)?
    private var lastInspection: Double?

    // Guarded by `lock`.
    private var isRunning = false
    private var steadyFrames = 0
    private var latest = AlignmentStatus.unknown

    init(region: AnalysisRegion = .screeningDefault,
         thresholds: QualityThresholds = .screening,
         inspectionInterval: Double = 0.2) {
        self.region = region
        self.gate = FrameGate(thresholds: thresholds)
        self.inspectionInterval = max(0, inspectionInterval)
        let (stream, continuation) = AsyncStream<AlignmentStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.updates = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    var status: AlignmentStatus {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func start() {
        lock.lock()
        isRunning = true
        steadyFrames = 0
        latest = .unknown
        lock.unlock()
    }

    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    func consume(pixelBuffer: CVPixelBuffer, presentationSeconds: Double) {
        lock.lock()
        let running = isRunning
        lock.unlock()
        guard running else { return }

        if let last = lastInspection, presentationSeconds - last < inspectionInterval { return }
        lastInspection = presentationSeconds

        guard extractor.extract(from: pixelBuffer, using: region) else { return }
        publish(inspect(extractor.region))
    }

    /// Deterministic entry point, for tests and the Simulator.
    @discardableResult
    func inspect(luma: LumaImage, presentationSeconds: Double) -> AlignmentStatus {
        lastInspection = presentationSeconds
        let status = inspect(luma)
        publish(status)
        return status
    }

    // MARK: - Private

    private func inspect(_ image: LumaImage) -> AlignmentStatus {
        let mask = rasterizedMask(width: image.width, height: image.height)
        let statistics = LumaStatisticsCalculator.statistics(of: image, mask: mask)

        prepareCoarseBuffers(for: image)
        swap(&coarse, &previousCoarse)
        image.boxAverage(into: &coarse)
        let motion = hasPreviousCoarse
            ? LumaStatisticsCalculator.normalizedDifference(between: previousCoarse, and: coarse)
            : 0
        hasPreviousCoarse = true

        let reasons = gate.rejections(statistics: statistics, motion: motion)

        lock.lock()
        steadyFrames = reasons.isEmpty ? steadyFrames + 1 : 0
        let steady = steadyFrames
        lock.unlock()

        return AlignmentStatus(
            hints: Array(reasons.compactMap(\.livePrompt).prefix(2)),
            passesGates: reasons.isEmpty,
            steadyFrames: steady,
            meanLevel: Double(statistics.mean),
            sharpness: statistics.sharpness,
            motion: motion
        )
    }

    private func publish(_ status: AlignmentStatus) {
        lock.lock()
        latest = status
        lock.unlock()
        continuation.yield(status)
    }

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
}
