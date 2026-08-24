import Foundation

/// Background subtraction, band-pass detection and the bulk scattering channel.
///
/// The pipeline, for a normalized frame `I` and background model `B`:
///
///   1. `D = I - B`, signed. Kept signed on purpose: clipping at zero first
///      would make the noise one-sided and break the robust noise estimate that
///      everything downstream is scaled by.
///   2. `P = max(D, 0)` — the positive bright residual, which feeds the **bulk**
///      channel. Not band-passed: total excess light is exactly what a bulk
///      scattering measurement wants.
///   3. `G = DoG(D)` — band-passed, which feeds the **discrete** channel. The
///      band-pass removes anything varying slowly across the frame, which is
///      what makes an illumination gradient or a whole-frame exposure change
///      produce no candidates.
///   4. `sigma = 1.4826 * MAD(G)` over valid pixels, and `T = k * sigma`. The
///      threshold is measured from this frame's own noise, never a fixed code
///      value: the same fixed threshold would be far too strict at low ISO and
///      far too permissive at high ISO.
///   5. Components of `G > T` are extracted and filtered on normalized features.
///
/// Every buffer is allocated once per region size and reused. A per-frame call
/// allocates only the small candidate array.
final class SpeckDetector {

    struct Configuration: Equatable, Sendable, Codable {
        var background: BackgroundModel.Configuration
        var bandPass: BandPassFilter.Configuration
        var candidateFilter: CandidateFilterConfiguration
        /// Detection threshold as a multiple of the measured noise standard
        /// deviation. Five sigma against Gaussian noise gives roughly one false
        /// pixel in 3.5 million, so a 450,000-pixel region yields well under
        /// one spurious pixel per frame before connectivity is even required.
        var thresholdSigmas: Double
        var maximumCandidates: Int
        var version: Int

        static let screening = Configuration(
            background: .screening,
            bandPass: .screening,
            candidateFilter: .screening,
            thresholdSigmas: 5.0,
            maximumCandidates: 512,
            version: 1
        )
    }

    let configuration: Configuration

    private let background: BackgroundModel
    private let bandPass: BandPassFilter
    private let extractor: ConnectedComponentExtractor

    private var width = 0
    private var height = 0
    private var mask: RasterizedMask?

    // Reused buffers.
    private var signedDifference: [Float] = []
    private var positiveResidual: [Float] = []
    private var response: [Float] = []
    private var scratchA: [Float] = []
    private var scratchB: [Float] = []
    private var labels: [Int32] = []
    private var stack: [Int32] = []
    private var foreground: [Bool] = []
    private var exclusionDistance: [Float] = []
    private var noiseScratch: [Float] = []

    var backgroundIsReady: Bool { background.isReady }
    var backgroundStability: Double { background.stability }

    init(configuration: Configuration = .screening) {
        self.configuration = configuration
        self.background = BackgroundModel(configuration: configuration.background)
        self.bandPass = BandPassFilter(configuration: configuration.bandPass)
        self.extractor = ConnectedComponentExtractor(
            maximumComponents: configuration.maximumCandidates
        )
    }

    /// Allocates for a region size and mask. Idempotent for the same inputs.
    func prepare(width: Int, height: Int, mask: RasterizedMask?,
                 expectedAcquisitionFrames: Int = 0) {
        guard width > 0, height > 0 else { return }
        let sizeChanged = width != self.width || height != self.height
        let maskChanged = mask?.validCount != self.mask?.validCount
            || mask?.width != self.mask?.width

        self.mask = mask

        if sizeChanged {
            self.width = width
            self.height = height
            let count = width * height
            signedDifference = [Float](repeating: 0, count: count)
            positiveResidual = [Float](repeating: 0, count: count)
            response = [Float](repeating: 0, count: count)
            scratchA = [Float](repeating: 0, count: count)
            scratchB = [Float](repeating: 0, count: count)
            labels = [Int32](repeating: 0, count: count)
            foreground = [Bool](repeating: false, count: count)
            stack = []
            stack.reserveCapacity(min(count, 4096))
            noiseScratch = []
            noiseScratch.reserveCapacity(min(count, LumaStatisticsCalculator.noiseSampleTarget * 2))
        }

        if sizeChanged || maskChanged || exclusionDistance.count != width * height {
            exclusionDistance = ConnectedComponentExtractor.exclusionDistanceMap(
                width: width, height: height, mask: mask
            )
        }

        background.prepare(width: width, height: height,
                           expectedAcquisitionFrames: expectedAcquisitionFrames)
    }

    func reset() {
        background.reset()
    }

    /// Records one background-acquisition frame.
    func ingestBackgroundFrame(_ image: LumaImage) {
        background.ingest(image)
    }

    /// Builds the background model from the acquisition frames.
    ///
    /// - Parameter noiseSigma: the frame noise standard deviation, used to
    ///   decide which pixels were too unsettled during acquisition for the
    ///   median to describe them.
    @discardableResult
    func finalizeBackground(noiseSigma: Double) -> Bool {
        background.finalize(noiseSigma: noiseSigma)
    }

    /// Runs detection on one measurement frame.
    ///
    /// - Parameter frameNoiseSigma: the noise standard deviation of the *raw*
    ///   frame. The background model lives in raw luma units, so its update
    ///   step has to be scaled by that, not by the much smaller noise figure
    ///   measured on the band-passed image.
    func detect(in image: LumaImage, frameNoiseSigma: Double) -> ForegroundObservation {
        guard background.isReady,
              image.width == width, image.height == height,
              width > 0, height > 0 else {
            return .notReady
        }

        let count = width * height

        for index in 0..<count {
            let difference = image.values[index] - background.values[index]
            positiveResidual[index] = max(difference, 0)
            // Masked pixels are zeroed before band-passing so a clipped glare
            // sitting just outside the mask cannot bleed inward through the
            // kernel. The step this creates at the mask edge is itself an
            // artefact, which is why candidates within a kernel radius of the
            // edge are rejected below.
            if let mask, !mask.isValid(atIndex: index) {
                signedDifference[index] = 0
            } else {
                signedDifference[index] = difference
            }
        }

        bandPass.apply(to: signedDifference,
                       width: width,
                       height: height,
                       destination: &response,
                       scratchA: &scratchA,
                       scratchB: &scratchB)

        let sigma = medianAbsoluteDeviationSigma(of: response)
        let threshold = Float(max(sigma * configuration.thresholdSigmas, 1e-7))

        let extraction = extractor.extract(
            ConnectedComponentExtractor.Input(
                response: response,
                residual: positiveResidual,
                source: image.values,
                width: width,
                height: height,
                mask: mask,
                threshold: threshold,
                saturationThreshold: FrameNormalization.saturationThreshold,
                exclusionDistance: exclusionDistance
            ),
            labels: &labels,
            stack: &stack,
            foreground: &foreground
        )

        var accepted: [SpeckCandidate] = []
        accepted.reserveCapacity(extraction.components.count)
        var rejections: [CandidateRejection: Int] = [:]

        for candidate in extraction.components {
            if let reason = rejection(for: candidate) {
                rejections[reason, default: 0] += 1
            } else {
                accepted.append(candidate)
            }
        }

        let bulk = bulkMetrics(threshold: threshold, sigma: sigma)

        // The background is updated after detection, and only slowly where a
        // foreground pixel was found, so a slow-moving speck is not absorbed
        // into the model it is being measured against.
        background.update(with: image, foreground: foreground, noiseSigma: frameNoiseSigma)

        return ForegroundObservation(
            candidates: accepted,
            componentCount: extraction.totalComponentCount,
            rejections: rejections,
            truncatedCount: extraction.truncatedCount,
            bulk: bulk,
            backgroundIsReady: true
        )
    }

    // MARK: - Filtering

    private func rejection(for candidate: SpeckCandidate) -> CandidateRejection? {
        let limits = configuration.candidateFilter

        if candidate.areaPixels < limits.minimumAreaPixels
            || candidate.normalizedArea < limits.minimumNormalizedArea {
            return .tooSmall
        }
        if candidate.normalizedDiameter > limits.maximumNormalizedDiameter {
            return .tooLarge
        }
        if candidate.eccentricity > limits.maximumEccentricity {
            return .tooElongated
        }
        if limits.rejectsSaturatedCores && candidate.containsSaturatedPixel {
            return .saturatedCore
        }
        if candidate.distanceToExclusionPixels < minimumExclusionDistancePixels {
            return .tooCloseToExclusion
        }
        if candidate.localContrast < limits.minimumLocalContrast {
            return .lowContrast
        }
        return nil
    }

    /// The larger of the region-relative margin and the band-pass kernel
    /// radius. An edge artefact extends as far as the kernel reaches, which is
    /// a pixel-domain fact; the normalized margin covers the separate concern
    /// that a candidate hugging the region border is only partly visible.
    private var minimumExclusionDistancePixels: Double {
        let diagonal = (Double(width * width + height * height)).squareRoot()
        let normalized = configuration.candidateFilter.minimumNormalizedDistanceToExclusion * diagonal
        return max(normalized, Double(bandPass.wideKernelRadius))
    }

    // MARK: - Bulk channel

    private func bulkMetrics(threshold: Float, sigma: Double) -> BulkScatteringMetrics {
        let tileGrid = LumaStatisticsCalculator.tileGrid
        var tileTotals = [Double](repeating: 0, count: tileGrid * tileGrid)

        var samples = 0
        var total: Double = 0
        var active = 0
        var histogram = [Int](repeating: 0, count: LumaStatisticsCalculator.histogramBins)
        let maximumBin = histogram.count - 1

        for y in 0..<height {
            let row = y * width
            let tileRow = min(tileGrid - 1, y * tileGrid / height)
            for x in 0..<width {
                let index = row + x
                if let mask, !mask.isValid(atIndex: index) { continue }

                let value = Double(positiveResidual[index])
                samples += 1
                total += value
                if response[index] > threshold { active += 1 }

                // Residuals are small, so the histogram covers 0...0.25 rather
                // than 0...1: binning the full range would put almost every
                // sample in the first bin and make the percentiles useless.
                let bin = min(maximumBin, max(0, Int(value * 4 * Double(maximumBin))))
                histogram[bin] += 1

                let tileColumn = min(tileGrid - 1, x * tileGrid / width)
                tileTotals[tileRow * tileGrid + tileColumn] += value
            }
        }

        guard samples > 0 else { return .empty }

        func percentile(_ fraction: Double) -> Double {
            let target = max(1, Int((fraction * Double(samples)).rounded()))
            var running = 0
            for (bin, binCount) in histogram.enumerated() {
                running += binCount
                if running >= target { return Double(bin) / (4 * Double(maximumBin)) }
            }
            return 0.25
        }

        let median = percentile(0.5)
        let upper = percentile(0.99)

        let tileMean = tileTotals.reduce(0, +) / Double(tileTotals.count)
        let tileVariance = tileTotals.reduce(0) { $0 + ($1 - tileMean) * ($1 - tileMean) }
            / Double(tileTotals.count)

        return BulkScatteringMetrics(
            sampleCount: samples,
            meanPositiveResidual: total / Double(samples),
            medianPositiveResidual: median,
            upperPercentileExcess: max(0, upper - median),
            activeForegroundFraction: Double(active) / Double(samples),
            residualBrightestTileShare: total > 0 ? (tileTotals.max() ?? 0) / total : 0,
            residualSpatialVariation: tileMean > 0 ? tileVariance.squareRoot() / tileMean : 0,
            noiseSigma: sigma,
            detectionThreshold: Double(threshold)
        )
    }

    // MARK: - Noise

    /// `1.4826 * MAD`, the standard consistent estimator of the standard
    /// deviation for Gaussian data.
    ///
    /// Robust by construction: the specks being detected are a tiny minority of
    /// the pixels, and a median ignores a minority. Estimating with a plain
    /// standard deviation would let the very events being looked for raise the
    /// threshold that is supposed to find them.
    private func medianAbsoluteDeviationSigma(of values: [Float]) -> Double {
        noiseScratch.removeAll(keepingCapacity: true)

        let count = width * height
        let stride = max(1, count / LumaStatisticsCalculator.noiseSampleTarget)
        var index = 0
        while index < count {
            if mask?.isValid(atIndex: index) ?? true {
                noiseScratch.append(values[index])
            }
            index += stride
        }

        guard noiseScratch.count >= 8 else { return 0 }
        noiseScratch.sort()
        let median = noiseScratch[noiseScratch.count / 2]

        for scratchIndex in noiseScratch.indices {
            noiseScratch[scratchIndex] = abs(noiseScratch[scratchIndex] - median)
        }
        noiseScratch.sort()
        return Double(noiseScratch[noiseScratch.count / 2]) * 1.4826
    }
}
