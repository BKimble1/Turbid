import Foundation

/// Everything the gates need, as one value so the evaluation is a pure
/// function of its input.
struct QualityEvaluationInput: Equatable, Sendable {
    /// Statistics aggregated over the window's usable frames.
    var statistics: LumaStatistics
    /// Median normalized frame-to-frame difference on the coarse plane.
    var globalMotionScore: Double
    /// Coefficient of variation of the per-frame mean level.
    var exposureVariation: Double
    var controlsRemainedLocked: Bool

    var usableFrames: Int
    var evaluatedFrames: Int
    var droppedFrameRatio: Double
    var frameDeliveryIsContinuous: Bool

    var thermal: ThermalStatus
    var systemPressure: SystemPressureLevel

    /// `nil` until Phase 3B builds a background model.
    var backgroundStability: Double?
    /// `nil` until Phase 3D loads a calibration profile.
    var calibrationProfileIsCompatible: Bool?

    var analysisRegionVersion: Int
    var captureProtocolVersion: Int
}

/// Applies the capture-quality gates.
///
/// Two rules shape the design:
///
/// 1. An invalid window produces **no** number. There is no path that computes
///    a plausible-looking result from frames that failed a gate.
/// 2. Every rejection names itself. A window that fails reports which gates it
///    failed, so the UI can tell the user what to change.
struct FrameQualityEvaluator: Sendable {
    let thresholds: QualityThresholds

    init(thresholds: QualityThresholds = .screening) {
        self.thresholds = thresholds
    }

    func evaluate(_ input: QualityEvaluationInput) -> CaptureQuality {
        var failures: [MeasurementRejectionReason] = []
        var marginal: [MeasurementRejectionReason] = []
        var headrooms: [Double] = []

        /// A gate whose reading must stay at or below `limit`.
        func upperBound(_ value: Double,
                        limit: Double,
                        reason: MeasurementRejectionReason) {
            guard limit > 0 else { return }
            let usage = value / limit
            if usage > 1 {
                failures.append(reason)
            } else if usage > 1 - thresholds.marginalBand {
                marginal.append(reason)
            }
            headrooms.append(min(max(1 - usage, 0), 1))
        }

        /// A gate whose reading must stay at or above `limit`.
        func lowerBound(_ value: Double,
                        limit: Double,
                        reason: MeasurementRejectionReason) {
            guard limit > 0 else { return }
            if value < limit {
                failures.append(reason)
                headrooms.append(0)
                return
            }
            // Headroom saturates at twice the limit: being far above a minimum
            // is good, but not unboundedly better.
            let margin = min(1, (value - limit) / limit)
            if margin < thresholds.marginalBand {
                marginal.append(reason)
            }
            headrooms.append(margin)
        }

        // --- Illumination and level -----------------------------------------
        upperBound(input.statistics.saturatedFraction,
                   limit: thresholds.maximumSaturatedFraction,
                   reason: .saturatedRegion)

        upperBound(input.statistics.brightestTileShare,
                   limit: thresholds.maximumBrightestTileShare,
                   reason: .torchHotspot)

        if input.statistics.mean < thresholds.minimumMeanLuma {
            failures.append(.regionTooDark)
            headrooms.append(0)
        } else if input.statistics.mean > thresholds.maximumMeanLuma {
            failures.append(.regionTooBright)
            headrooms.append(0)
        } else {
            // Distance to whichever end of the usable band is closer, scaled by
            // the band's half-width.
            let low = Double(input.statistics.mean - thresholds.minimumMeanLuma)
            let high = Double(thresholds.maximumMeanLuma - input.statistics.mean)
            let halfWidth = Double(thresholds.maximumMeanLuma - thresholds.minimumMeanLuma) / 2
            let margin = halfWidth > 0 ? min(low, high) / halfWidth : 1
            if margin < thresholds.marginalBand {
                marginal.append(input.statistics.mean < thresholds.maximumMeanLuma / 2
                                ? .regionTooDark : .regionTooBright)
            }
            headrooms.append(min(max(margin, 0), 1))
        }

        // --- Optics -----------------------------------------------------------
        lowerBound(input.statistics.sharpness,
                   limit: thresholds.minimumSharpness,
                   reason: .outOfFocus)

        upperBound(input.globalMotionScore,
                   limit: thresholds.maximumGlobalMotion,
                   reason: .cameraMoved)

        // --- Capture stability -----------------------------------------------
        upperBound(input.exposureVariation,
                   limit: thresholds.maximumExposureVariation,
                   reason: .exposureUnstable)

        if !input.controlsRemainedLocked {
            failures.append(.controlsUnlocked)
            headrooms.append(0)
        }

        // --- Frame delivery ---------------------------------------------------
        if input.evaluatedFrames < thresholds.minimumEvaluatedFrames {
            failures.append(.insufficientUsableFrames)
            headrooms.append(0)
        } else {
            let ratio = Double(input.usableFrames) / Double(input.evaluatedFrames)
            lowerBound(ratio,
                       limit: thresholds.minimumUsableFrameRatio,
                       reason: .insufficientUsableFrames)
        }

        upperBound(input.droppedFrameRatio,
                   limit: thresholds.maximumDroppedFrameRatio,
                   reason: .excessiveDroppedFrames)

        if !input.frameDeliveryIsContinuous {
            failures.append(.frameDeliveryDiscontinuous)
            headrooms.append(0)
        }

        // --- Device -----------------------------------------------------------
        if !input.thermal.permitsMeasurement {
            failures.append(.thermalLimit)
            headrooms.append(0)
        }
        if !input.systemPressure.permitsMeasurement {
            failures.append(.systemPressure)
            headrooms.append(0)
        }

        // --- Gates whose inputs arrive in later phases -------------------------
        if let stability = input.backgroundStability {
            lowerBound(stability,
                       limit: thresholds.minimumBackgroundStability,
                       reason: .backgroundModelUnstable)
        }
        if let compatible = input.calibrationProfileIsCompatible, !compatible {
            failures.append(.calibrationProfileMismatch)
            headrooms.append(0)
        }

        // A window is only as trustworthy as its weakest gate, so confidence is
        // the minimum headroom rather than an average that a single bad reading
        // could hide inside.
        let confidence = failures.isEmpty ? (headrooms.min() ?? 0) : 0

        let verdict: CaptureQualityVerdict
        if !failures.isEmpty {
            verdict = .invalid(reasons: failures)
        } else if !marginal.isEmpty {
            verdict = .usableWithLowConfidence(notes: marginal)
        } else {
            verdict = .usable
        }

        return CaptureQuality(
            saturatedFraction: input.statistics.saturatedFraction,
            meanLuma: input.statistics.mean,
            lumaStandardDeviation: input.statistics.standardDeviation,
            brightestTileShare: input.statistics.brightestTileShare,
            sharpness: input.statistics.sharpness,
            globalMotionScore: input.globalMotionScore,
            exposureStability: input.exposureVariation,
            controlsRemainedLocked: input.controlsRemainedLocked,
            usableFrames: input.usableFrames,
            evaluatedFrames: input.evaluatedFrames,
            droppedFrameRatio: input.droppedFrameRatio,
            frameDeliveryIsContinuous: input.frameDeliveryIsContinuous,
            backgroundStability: input.backgroundStability,
            calibrationProfileIsCompatible: input.calibrationProfileIsCompatible,
            thermal: input.thermal,
            systemPressure: input.systemPressure,
            thresholdsVersion: thresholds.version,
            analysisRegionVersion: input.analysisRegionVersion,
            captureProtocolVersion: input.captureProtocolVersion,
            verdict: verdict,
            confidence: confidence
        )
    }
}
