import Foundation
@testable import Turbid

/// Builders for calibration fixtures.
///
/// A calibration is a large object with a lot of provenance attached, and every
/// test needs a slightly different one. Building them here keeps the tests
/// about the behaviour under test rather than about construction.
enum CalibrationFactory {

    // MARK: - Capture quality

    static func quality(usable: Bool = true,
                        confidence: Double = 0.8,
                        reasons: [MeasurementRejectionReason] = []) -> CaptureQuality {
        CaptureQuality(
            saturatedFraction: 0.0001,
            meanLuma: 0.30,
            lumaStandardDeviation: 0.05,
            brightestTileShare: 0.08,
            sharpness: 0.01,
            globalMotionScore: 0.0001,
            exposureStability: 0.004,
            controlsRemainedLocked: true,
            usableFrames: 268,
            evaluatedFrames: 270,
            droppedFrameRatio: 0.01,
            frameDeliveryIsContinuous: true,
            backgroundStability: 0.98,
            calibrationProfileIsCompatible: nil,
            thermal: .nominal,
            systemPressure: .nominal,
            thresholdsVersion: 1,
            analysisRegionVersion: 1,
            captureProtocolVersion: 1,
            verdict: usable ? .usable : .invalid(reasons: reasons.isEmpty ? [.cameraMoved] : reasons),
            confidence: usable ? confidence : 0
        )
    }

    // MARK: - Measurement inputs

    static func summary(residual: Double,
                        windows: Int = 5,
                        repeatability: Double = 0.9) -> ScatteringSummary {
        ScatteringSummary(
            windowCount: windows,
            medianPositiveResidual: residual,
            medianUpperPercentileExcess: residual * 1.6,
            medianActiveForegroundFraction: residual * 0.4,
            medianSpeckEventsPerSecond: residual * 200,
            residualRelativeSpread: 0.05,
            repeatabilityConfidence: repeatability
        )
    }

    static func tracking(speckRate: Double = 2) -> TrackingMetrics {
        TrackingMetrics(
            confirmedSpeckCount: Int(speckRate * 9),
            speckEventsPerSecond: speckRate,
            speckEventsPerSecondPerMegapixel: speckRate / 0.456,
            medianResidualSpeed: 0.02,
            percentile90ResidualSpeed: 0.03,
            bubbleRejectionCount: 1,
            ambiguousCount: 2,
            staticDefectCount: 0,
            meanTrackConfidence: 0.6,
            globalMotionSpeed: 0.0005,
            globalMotionConfidence: 1,
            globalMotionWasCompensated: true,
            tracksDroppedForCapacity: 0
        )
    }

    /// An index built from a residual, so a test can ask for "a sample that
    /// scatters this much" without assembling the whole chain.
    static func index(residual: Double) -> RelativeScatteringIndex {
        RelativeScatteringIndex.make(summary: summary(residual: residual),
                                     tracking: tracking())
    }

    // MARK: - Readings

    /// A complete reading, so tests that consume one do not have to assemble
    /// the whole chain that produces it.
    static func reading(residual: Double = 0.02,
                        mode: MeasurementMode = .screening,
                        usable: Bool = true,
                        profile: CalibrationProfile? = nil,
                        liveBinding: CalibrationBinding? = nil,
                        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000))
    -> TurbidityReading {
        TurbidityReading.make(
            timestamp: timestamp,
            windowSeconds: CaptureProtocol.screening.measurementWindowSeconds,
            mode: mode,
            summary: summary(residual: residual),
            tracking: tracking(),
            quality: quality(usable: usable),
            profile: profile,
            liveBinding: liveBinding,
            algorithmVersions: algorithmVersions
        )
    }

    // MARK: - Binding

    static let algorithmVersions = CalibrationBinding.AlgorithmVersions(
        captureProtocol: 1, qualityThresholds: 1, detector: 1, bandPass: 1,
        backgroundModel: 1, tracker: 1, classifier: 1, aggregation: 1, indexWeights: 1
    )

    static func binding(cameraUniqueID: String = "camera-ultra-wide",
                        lensPosition: Float = 0.42,
                        exposureSeconds: Double = 1.0 / 60.0,
                        iso: Float = 200,
                        torchLevel: Float = 1.0,
                        fixture: String = "shroud-v1",
                        container: String = "cuvette-10mm",
                        workingDistance: Double = 100,
                        algorithmVersions: CalibrationBinding.AlgorithmVersions = algorithmVersions)
    -> CalibrationBinding {
        CalibrationBinding(
            algorithmVersion: algorithmVersions,
            deviceModelIdentifier: "iPhone16,1",
            cameraUniqueID: cameraUniqueID,
            cameraDeviceType: "AVCaptureDeviceTypeBuiltInUltraWideCamera",
            captureWidth: 1920,
            captureHeight: 1080,
            pixelFormat: "420f",
            frameRate: 30,
            lensPosition: lensPosition,
            exposureSeconds: exposureSeconds,
            iso: iso,
            whiteBalanceGains: WhiteBalanceGains(red: 1.8, green: 1.0, blue: 1.6),
            torchLevel: torchLevel,
            analysisRegion: .screeningDefault,
            fixtureIdentifier: fixture,
            fixtureGeometryVersion: 1,
            containerIdentifier: container,
            fillVolumeMillilitres: 15,
            workingDistanceMillimetres: workingDistance
        )
    }

    // MARK: - Standards and levels

    static func standard(ntu: Double,
                         tolerance: Double = 0.05,
                         expiresAt: Date = Date(timeIntervalSince1970: 2_000_000_000))
    -> CalibrationStandard {
        CalibrationStandard(
            nominalNTU: ntu,
            toleranceNTU: tolerance,
            manufacturer: "Certified Standards Ltd",
            lotNumber: "LOT-\(Int(ntu * 100))",
            expiryDate: expiresAt
        )
    }

    /// Replicates whose indices scatter around `meanIndex` by a fixed pattern,
    /// so a level is reproducible run to run.
    static func level(ntu: Double,
                      meanIndex: Double,
                      replicates: Int = 4,
                      relativeSpread: Double = 0.02,
                      usable: Bool = true,
                      expiresAt: Date = Date(timeIntervalSince1970: 2_000_000_000))
    -> CalibrationLevel {
        // A symmetric, zero-mean pattern, so the mean index is exactly
        // `meanIndex` no matter how many replicates are asked for.
        let offsets = (0..<replicates).map { index -> Double in
            let step = Double(index) - Double(replicates - 1) / 2
            return step * relativeSpread * meanIndex / max(1, Double(replicates - 1) / 2)
        }

        let recorded = offsets.enumerated().map { position, offset in
            CalibrationReplicate(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d",
                                            Int(ntu * 1000) * 100 + position))
                    ?? UUID(),
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(position) * 60),
                standardNominalNTU: ntu,
                index: RelativeScatteringIndex(
                    value: meanIndex + offset,
                    components: RelativeScatteringIndex.Components(
                        bulkContribution: (meanIndex + offset) * 0.6,
                        excessContribution: (meanIndex + offset) * 0.25,
                        activeContribution: (meanIndex + offset) * 0.12,
                        speckContribution: (meanIndex + offset) * 0.03
                    ),
                    weightsVersion: 1,
                    windowCount: 5
                ),
                scattering: summary(residual: meanIndex / 1000),
                tracking: tracking(),
                quality: quality(usable: usable)
            )
        }
        return CalibrationLevel(standard: standard(ntu: ntu, expiresAt: expiresAt),
                                replicates: recorded)
    }

    /// A complete, well-behaved calibration set: a blank plus five standards
    /// whose index rises sublinearly, as multiple scattering makes it.
    static var goodLevels: [CalibrationLevel] {
        [
            level(ntu: 0, meanIndex: 2),
            level(ntu: 1, meanIndex: 22),
            level(ntu: 5, meanIndex: 92),
            level(ntu: 10, meanIndex: 160),
            level(ntu: 20, meanIndex: 265),
            level(ntu: 50, meanIndex: 520)
        ]
    }

    static let fitDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Fits `goodLevels` into a usable profile.
    static func profile(levels: [CalibrationLevel]? = nil,
                        binding: CalibrationBinding? = nil,
                        name: String = "Bench fixture",
                        createdAt: Date = fitDate,
                        expiresAt: Date = Date(timeIntervalSince1970: 1_900_000_000),
                        id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    -> CalibrationProfile? {
        let usedLevels = levels ?? goodLevels
        let outcome = CalibrationFitter().fit(levels: usedLevels, asOf: fitDate)
        guard let candidate = outcome.candidate,
              let uncertainty = outcome.uncertainty,
              let indexRange = outcome.validatedIndexRange,
              let ntuRange = outcome.validatedNTURange else { return nil }

        return CalibrationProfile(
            id: id,
            schemaVersion: CalibrationProfile.currentSchemaVersion,
            name: name,
            createdAt: createdAt,
            expiresAt: expiresAt,
            binding: binding ?? Self.binding(),
            mapping: candidate.mapping,
            uncertainty: uncertainty,
            validation: candidate.validation,
            validatedIndexRange: indexRange,
            validatedNTURange: ntuRange,
            levels: usedLevels
        )
    }
}
