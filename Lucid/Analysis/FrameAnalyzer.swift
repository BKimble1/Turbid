import CoreVideo
import Foundation

/// Turns frames into observations and a window verdict.
///
/// Not thread-safe by design: it is owned by the capture pipeline's serial
/// processing queue and touched from nowhere else. All of its buffers are
/// reused between frames.
///
/// Phase 3A stops here: the observations describe capture *quality*, not
/// particle content. Background subtraction (3B) and tracking (3C) plug into
/// `analyze(luma:presentationSeconds:)` after the quality gates have run, so
/// they never see a frame the gates rejected.
final class FrameAnalyzer: FrameAnalyzing {

    let region: AnalysisRegion
    let captureProtocol: CaptureProtocol
    private let thresholds: QualityThresholds
    private let evaluator: FrameQualityEvaluator

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

    init(region: AnalysisRegion = .screeningDefault,
         captureProtocol: CaptureProtocol = .screening,
         thresholds: QualityThresholds = .screening) {
        self.region = region
        self.captureProtocol = captureProtocol
        self.thresholds = thresholds
        self.evaluator = FrameQualityEvaluator(thresholds: thresholds)
    }

    func begin(atTimestamp presentationSeconds: Double) {
        timeline = CaptureProtocolTimeline(captureProtocol: captureProtocol,
                                           startSeconds: presentationSeconds)
        aggregate = FrameAggregate()
        sequenceNumber = 0
        hasPreviousCoarse = false
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

        let observation = FrameObservation(
            sequenceNumber: sequenceNumber,
            timestampSeconds: presentationSeconds,
            stage: stage,
            statistics: statistics,
            globalMotionScore: motion,
            isUsable: reasons.isEmpty,
            rejectionReasons: reasons
        )
        sequenceNumber += 1
        aggregate.record(observation)
        return observation
    }

    /// Gates that can be decided from a single frame.
    ///
    /// Deliberately a subset: flicker, usable-frame ratio and continuity need
    /// more than one frame and belong to the window verdict, not here.
    private func perFrameRejections(statistics: LumaStatistics, motion: Double) -> [MeasurementRejectionReason] {
        var reasons: [MeasurementRejectionReason] = []
        if statistics.sampleCount == 0 {
            reasons.append(.insufficientUsableFrames)
            return reasons
        }
        if statistics.saturatedFraction > thresholds.maximumSaturatedFraction {
            reasons.append(.saturatedRegion)
        }
        if statistics.brightestTileShare > thresholds.maximumBrightestTileShare {
            reasons.append(.torchHotspot)
        }
        if statistics.mean < thresholds.minimumMeanLuma {
            reasons.append(.regionTooDark)
        } else if statistics.mean > thresholds.maximumMeanLuma {
            reasons.append(.regionTooBright)
        }
        if statistics.sharpness < thresholds.minimumSharpness {
            reasons.append(.outOfFocus)
        }
        if motion > thresholds.maximumGlobalMotion {
            reasons.append(.cameraMoved)
        }
        return reasons
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
            // Phase 3B supplies background stability; Phase 3D supplies
            // calibration compatibility. `nil` means this build cannot measure
            // it, so the gate does not fire either way.
            backgroundStability: nil,
            calibrationProfileIsCompatible: nil,
            analysisRegionVersion: region.version,
            captureProtocolVersion: captureProtocol.version
        ))
    }

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
            rejectionReasons: [.insufficientUsableFrames]
        )
        sequenceNumber += 1
        aggregate.record(observation)
        return observation
    }
}
