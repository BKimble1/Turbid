import Foundation

/// Whether a reading may be shown at all.
enum MeasurementValidity: Equatable, Sendable {
    case valid
    case validWithLowConfidence(reasons: [MeasurementRejectionReason])
    case invalid(reasons: [MeasurementRejectionReason])

    var isValid: Bool {
        switch self {
        case .valid, .validWithLowConfidence: return true
        case .invalid: return false
        }
    }

    var reasons: [MeasurementRejectionReason] {
        switch self {
        case .valid: return []
        case .validWithLowConfidence(let reasons), .invalid(let reasons): return reasons
        }
    }

    init(quality: CaptureQuality) {
        switch quality.verdict {
        case .usable: self = .valid
        case .usableWithLowConfidence(let notes): self = .validWithLowConfidence(reasons: notes)
        case .invalid(let reasons): self = .invalid(reasons: reasons)
        }
    }
}

/// The complete result of one measurement.
///
/// Every displayed number is here, together with the versions of everything
/// that produced it. Nothing in the UI computes a measurement quantity of its
/// own: if it is on screen, it came from this value, and it can be traced to a
/// documented calculation.
struct TurbidityReading: Equatable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let measurementWindowSeconds: Double
    let mode: MeasurementMode

    /// Relative, dimensionless, and never NTU.
    let index: RelativeScatteringIndex

    /// Tracked bright events per second. Reported as *Visible particles
    /// (tracked)*, never as a particle concentration: a camera cannot resolve
    /// or count the microscopic and colloidal material that dominates real
    /// turbidity.
    let trackedSpeckEventsPerSecond: Double
    /// The same rate normalized by the region's area, so runs made with
    /// different region sizes can be compared.
    let trackedSpeckEventsPerSecondPerMegapixel: Double

    /// Either a number with its uncertainty and validated range, or the reason
    /// there is none. Never an optional that could read as zero.
    let ntu: NTUAvailability

    let clarity: ClarityCategoryEngine.Verdict
    /// `0...1`, the smaller of the capture-quality confidence and the
    /// repeatability across sub-windows. A result is only as good as the worse
    /// of "was this captured well" and "would it come out the same again".
    let confidence: Double

    let quality: CaptureQuality
    let scattering: ScatteringSummary
    let tracking: TrackingMetrics
    let validity: MeasurementValidity

    let algorithmVersions: CalibrationBinding.AlgorithmVersions
    let calibrationProfileID: UUID?
    let clarityPolicyVersion: Int

    /// The disclaimer that must accompany every result surface.
    var disclaimer: String { MeasurementDisclaimer.short }

    /// Assembles a reading, applying the NTU gate.
    ///
    /// The only constructor. Making it the only way to produce a reading is
    /// what guarantees no code path can assemble one with an ungated NTU.
    static func make(id: UUID = UUID(),
                     timestamp: Date,
                     windowSeconds: Double,
                     mode: MeasurementMode,
                     summary: ScatteringSummary,
                     tracking: TrackingMetrics,
                     quality: CaptureQuality,
                     profile: CalibrationProfile?,
                     liveBinding: CalibrationBinding?,
                     weights: RelativeScatteringIndex.Weights = .screening,
                     policy: ClarityPolicy = .screening,
                     tolerances: CalibrationTolerances = .screening,
                     algorithmVersions: CalibrationBinding.AlgorithmVersions) -> TurbidityReading {
        let index = RelativeScatteringIndex.make(summary: summary,
                                                 tracking: tracking,
                                                 weights: weights)
        let ntu = NTUGate.evaluate(mode: mode,
                                   profile: profile,
                                   index: index,
                                   quality: quality,
                                   liveBinding: liveBinding,
                                   tolerances: tolerances,
                                   asOf: timestamp)
        let validity = MeasurementValidity(quality: quality)

        return TurbidityReading(
            id: id,
            timestamp: timestamp,
            measurementWindowSeconds: windowSeconds,
            mode: mode,
            index: index,
            trackedSpeckEventsPerSecond: tracking.speckEventsPerSecond,
            trackedSpeckEventsPerSecondPerMegapixel: tracking.speckEventsPerSecondPerMegapixel,
            ntu: ntu,
            clarity: ClarityCategoryEngine.classify(index: index, ntu: ntu, policy: policy),
            confidence: min(quality.confidence, summary.repeatabilityConfidence),
            quality: quality,
            scattering: summary,
            tracking: tracking,
            validity: validity,
            algorithmVersions: algorithmVersions,
            calibrationProfileID: ntu.estimate == nil ? nil : profile?.id,
            clarityPolicyVersion: policy.version
        )
    }
}
