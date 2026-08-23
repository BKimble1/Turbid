import Foundation

/// A commercially prepared, certified turbidity standard.
///
/// Lucid never describes how to prepare a standard. Formazin is made from
/// hydrazine sulfate, which is acutely toxic and a suspected carcinogen, and
/// nothing in this app will ever instruct a user to synthesise it. Calibration
/// uses standards bought ready-made — formazin or a certified styrene-
/// divinylbenzene polymer equivalent — and used according to the
/// manufacturer's own safety and handling instructions.
struct CalibrationStandard: Equatable, Sendable, Codable, Identifiable {
    var id: String { "\(manufacturer)-\(lotNumber)-\(nominalNTU)" }

    /// The certified value, in NTU.
    let nominalNTU: Double
    /// The certificate's stated tolerance, as plus-or-minus NTU. Carried into
    /// the uncertainty budget: a calibration can never be more certain than the
    /// standards it was made from.
    let toleranceNTU: Double
    let manufacturer: String
    let lotNumber: String
    /// Standards degrade. A calibration made with an expired standard is not a
    /// calibration.
    let expiryDate: Date

    var isBlank: Bool { nominalNTU == 0 }

    func isExpired(asOf date: Date) -> Bool { date > expiryDate }
}

/// One recorded measurement of one standard.
///
/// Stores the extracted feature summary and the quality metadata, not just the
/// index. A calibration that kept only its final numbers could never be
/// re-fitted after a formula change, and could never be audited.
struct CalibrationReplicate: Equatable, Sendable, Codable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let standardNominalNTU: Double

    let index: RelativeScatteringIndex
    /// The raw window summary the index was computed from.
    let scattering: ScatteringSummary
    let tracking: TrackingMetrics
    /// Whether the capture that produced it passed the quality gates, and why
    /// not if it did not.
    let captureWasUsable: Bool
    let captureRejectionReasons: [String]
    let captureConfidence: Double

    init(id: UUID = UUID(),
         recordedAt: Date,
         standardNominalNTU: Double,
         index: RelativeScatteringIndex,
         scattering: ScatteringSummary,
         tracking: TrackingMetrics,
         quality: CaptureQuality) {
        self.id = id
        self.recordedAt = recordedAt
        self.standardNominalNTU = standardNominalNTU
        self.index = index
        self.scattering = scattering
        self.tracking = tracking
        self.captureWasUsable = quality.isUsable
        self.captureRejectionReasons = quality.verdict.reasons.map(\.rawValue)
        self.captureConfidence = quality.confidence
    }
}

/// All the replicates recorded for one standard.
struct CalibrationLevel: Equatable, Sendable, Codable, Identifiable {
    var id: String { standard.id }

    let standard: CalibrationStandard
    let replicates: [CalibrationReplicate]

    /// Only replicates whose capture passed the gates may inform a curve. A
    /// calibration built partly from rejected captures is not a calibration.
    var usableReplicates: [CalibrationReplicate] {
        replicates.filter(\.captureWasUsable)
    }

    var indexValues: [Double] { usableReplicates.map(\.index.value) }

    var meanIndex: Double {
        let values = indexValues
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation of the replicate indices. Needs at least two
    /// replicates to exist at all, which is why the design requires them.
    var indexStandardDeviation: Double {
        let values = indexValues
        guard values.count >= 2 else { return 0 }
        let mean = meanIndex
        let sumOfSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumOfSquares / Double(values.count - 1)).squareRoot()
    }

    /// Standard deviation relative to the mean: how repeatable this level was.
    var relativeStandardDeviation: Double {
        meanIndex > 0 ? indexStandardDeviation / meanIndex : 0
    }
}

/// Why a set of levels cannot become a calibration.
enum CalibrationDataProblem: String, Equatable, Sendable, Codable, CaseIterable {
    case noBlank
    case tooFewNonZeroStandards
    case tooFewReplicates
    case expiredStandard
    case notMonotonic
    case indistinguishableLevels

    var explanation: String {
        switch self {
        case .noBlank:
            return "A blank (0 NTU) reading is required, to establish what the fixture reads with nothing suspended in it."
        case .tooFewNonZeroStandards:
            return "At least four non-zero certified standards are required, spanning the intended range."
        case .tooFewReplicates:
            return "Each standard needs repeat readings, or there is no way to know how repeatable the measurement is."
        case .expiredStandard:
            return "One of the standards was past its expiry date. A calibration is only as good as the standards it was made from."
        case .notMonotonic:
            return "The index did not increase with turbidity across the standards. Something in the setup is not behaving as a scattering measurement should."
        case .indistinguishableLevels:
            return "Two standards produced readings too close together to tell apart, given how much the repeat readings varied."
        }
    }
}
