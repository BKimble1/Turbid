import Foundation

/// Per-pixel model of the stationary scene: the container, its scratches, and
/// every fixed reflection.
///
/// Built from a temporal median over the background-acquisition frames, then
/// maintained with a slow robust update. The median is the right initial
/// statistic because a particle drifting through a pixel during acquisition
/// affects a minority of the samples, and a median ignores a minority.
///
/// Storage is bounded and allocated once. The sample buffer used for the
/// initial median is released as soon as the median is computed, because it is
/// the largest allocation in the pipeline and is not needed again.
final class BackgroundModel {

    struct Configuration: Equatable, Sendable, Codable {
        /// Frames retained for the initial median. An odd count so the median
        /// is a real sample rather than an average of two. Nine gives a
        /// breakdown point of 44%: the model survives a particle sitting in a
        /// pixel for up to four of the nine samples.
        ///
        /// Retained samples are spread across the whole acquisition window
        /// rather than taken consecutively — see `prepare`. Nine consecutive
        /// frames at 30 fps span only 0.3 s, in which a slowly drifting speck
        /// barely moves, so it would sit in a majority of the samples at its
        /// own position and be absorbed into the very model it is meant to be
        /// measured against.
        var medianSampleCount: Int
        /// Step size for the running update, as a multiple of the measured
        /// noise standard deviation. A sign-based step of this size tracks the
        /// running median rather than the running mean, so one very bright
        /// frame moves the model by one step instead of by its own brightness.
        var backgroundStepSigma: Double
        /// The same step, applied where the pixel is currently classified as
        /// foreground. Non-zero but much smaller, so a genuinely slow-moving
        /// speck is not absorbed within a few frames, while something that has
        /// settled permanently is eventually absorbed.
        var foregroundStepSigma: Double
        var version: Int

        static let screening = Configuration(
            medianSampleCount: 9,
            backgroundStepSigma: 0.25,
            foregroundStepSigma: 0.01,
            version: 1
        )
    }

    let configuration: Configuration
    private(set) var width = 0
    private(set) var height = 0
    private(set) var isReady = false

    /// The model itself: one value per pixel.
    private(set) var values: [Float] = []

    /// Ring of acquisition samples, released once the median is taken.
    private var samples: [[Float]] = []
    private var sampleWriteIndex = 0
    private var sampleCount = 0
    /// Store every `ingestStride`-th offered frame, so the retained samples
    /// span the acquisition window instead of clustering at its end.
    private var ingestStride = 1
    private var ingestCounter = 0

    /// Fraction of pixels whose value held still across the acquisition
    /// samples, in `0...1`.
    ///
    /// Measures whether the *model* is trustworthy, not whether the phone was
    /// still. A featureless scene translating behind the lens is still
    /// perfectly described by its median, and camera movement is the motion
    /// gate's job. What this catches is a structured scene shifting during
    /// acquisition, which leaves the median describing a place nothing is any
    /// more. Particles drifting through affect a small minority of pixels and
    /// barely move it, which is the intended behaviour: that is a sample, not
    /// a fault.
    private(set) var stability: Double = 0

    private var scratch: [Float] = []

    init(configuration: Configuration = .screening) {
        self.configuration = configuration
    }

    /// Allocates for a region size and sets the sampling stride.
    ///
    /// Safe to call on every frame: it is a no-op unless the region size
    /// changed, or the stride changed before acquisition started. It never
    /// discards a model that is being built or has been built — use `reset()`
    /// for that.
    ///
    /// - Parameter expectedAcquisitionFrames: how many frames the acquisition
    ///   stage is expected to deliver. The stride is chosen so the retained
    ///   samples spread across all of them; passing `0` keeps every frame.
    func prepare(width: Int, height: Int, expectedAcquisitionFrames: Int = 0) {
        guard width > 0, height > 0 else { return }
        let stride = expectedAcquisitionFrames > 0
            ? max(1, expectedAcquisitionFrames / max(1, configuration.medianSampleCount))
            : 1

        let sizeChanged = width != self.width || height != self.height
        // A stride change is only honoured before any sample has been taken.
        // Otherwise a caller that prepares once per frame — which is the normal
        // pattern, since the region size is not known until the first frame
        // arrives — would discard the model it is in the middle of building.
        let strideChangeAllowed = stride != ingestStride && sampleCount == 0 && !isReady

        guard sizeChanged || strideChangeAllowed else { return }

        self.width = width
        self.height = height
        self.ingestStride = stride
        values = [Float](repeating: 0, count: width * height)
        scratch = [Float](repeating: 0, count: max(1, configuration.medianSampleCount))
        allocateSamples()
        isReady = false
        sampleWriteIndex = 0
        sampleCount = 0
        ingestCounter = 0
        stability = 0
    }

    /// Discards the model and the samples, ready for a new run.
    func reset() {
        isReady = false
        sampleWriteIndex = 0
        sampleCount = 0
        ingestCounter = 0
        stability = 0
        for index in values.indices { values[index] = 0 }
        allocateSamples()
    }

    private func allocateSamples() {
        let count = max(1, configuration.medianSampleCount)
        if samples.count != count || samples.first?.count != width * height {
            samples = (0..<count).map { _ in [Float](repeating: 0, count: width * height) }
        }
    }

    /// Records one acquisition frame. Frames beyond the buffer's capacity
    /// overwrite the oldest, so the median is taken over the most recent
    /// samples however long acquisition runs.
    func ingest(_ image: LumaImage) {
        guard image.width == width, image.height == height, !samples.isEmpty else { return }
        defer { ingestCounter += 1 }
        guard ingestCounter % ingestStride == 0 else { return }

        samples[sampleWriteIndex] = image.values
        sampleWriteIndex = (sampleWriteIndex + 1) % samples.count
        sampleCount = min(sampleCount + 1, samples.count)
    }

    /// Computes the per-pixel median and the stability score.
    ///
    /// - Returns: `false` when too few frames were collected to take a
    ///   meaningful median, in which case the model stays unready and no
    ///   detection can run.
    @discardableResult
    func finalize(noiseSigma: Double) -> Bool {
        guard sampleCount >= 3, width > 0, height > 0 else {
            isReady = false
            return false
        }

        let used = sampleCount
        var unstablePixels = 0
        // Full range rather than an interquartile spread. An interquartile
        // measure trims the extremes, which is exactly what makes it useless
        // here: a bright feature sweeping across a pixel appears in a minority
        // of the samples, and trimming discards precisely that evidence.
        //
        // Six standard deviations, because the expected range of nine Gaussian
        // samples is already about 3.1 standard deviations. Anything past that
        // is a feature that moved through, not sensor noise.
        let spreadLimit = Float(max(noiseSigma, 1e-6) * 6)

        for pixel in 0..<(width * height) {
            for sample in 0..<used {
                scratch[sample] = samples[sample][pixel]
            }
            var window = Array(scratch.prefix(used))
            window.sort()
            values[pixel] = window[used / 2]

            if window[used - 1] - window[0] > spreadLimit { unstablePixels += 1 }
        }

        stability = 1 - Double(unstablePixels) / Double(width * height)
        isReady = true

        // The sample buffer is the largest allocation in the pipeline and is
        // not needed again until the next run.
        samples = []
        return true
    }

    /// Slow robust update, applied after each measurement frame.
    ///
    /// Sign-based rather than proportional: the model steps towards the
    /// observed value by a fixed amount regardless of how far away it is, which
    /// is a stochastic median tracker. A single very bright frame therefore
    /// moves the background by one step instead of by its own brightness.
    ///
    /// - Parameter foreground: `true` where the pixel is currently classified
    ///   as foreground; those pixels update far more slowly so a genuinely
    ///   slow-moving speck is not absorbed into the model it is being measured
    ///   against.
    func update(with image: LumaImage, foreground: [Bool], noiseSigma: Double) {
        guard isReady,
              image.width == width, image.height == height,
              foreground.count == values.count else { return }

        let backgroundStep = Float(noiseSigma * configuration.backgroundStepSigma)
        let foregroundStep = Float(noiseSigma * configuration.foregroundStepSigma)
        guard backgroundStep > 0 || foregroundStep > 0 else { return }

        for index in values.indices {
            let step = foreground[index] ? foregroundStep : backgroundStep
            guard step > 0 else { continue }
            let difference = image.values[index] - values[index]
            if difference > 0 {
                values[index] += min(step, difference)
            } else if difference < 0 {
                values[index] -= min(step, -difference)
            }
        }
    }
}
