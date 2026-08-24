import Foundation

/// A completed, validated calibration.
///
/// Carries not just the curve but everything needed to decide whether the curve
/// still applies, and everything needed to re-fit it if the formula changes:
/// the standards used, every replicate, the validation figures and the
/// uncertainty model.
struct CalibrationProfile: Equatable, Sendable, Codable, Identifiable {
    /// Bumped whenever the stored shape changes. A profile written by a newer
    /// schema is refused rather than half-read.
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let name: String
    let createdAt: Date

    /// Standards degrade, fixtures shift, and phones age. A calibration with no
    /// end date is a calibration nobody will ever re-check.
    let expiresAt: Date

    let binding: CalibrationBinding
    let mapping: MonotonicMapping
    let uncertainty: UncertaintyModel
    let validation: CalibrationValidation

    /// The range of index values the standards actually covered. Anything
    /// outside it has never been checked and will not be reported.
    let validatedIndexRange: ClosedRange<Double>
    let validatedNTURange: ClosedRange<Double>

    /// Every level and every replicate, kept so the profile can be audited and
    /// re-fitted rather than merely trusted.
    let levels: [CalibrationLevel]

    func isExpired(asOf date: Date) -> Bool { date > expiresAt }

    func covers(index: Double) -> Bool { validatedIndexRange.contains(index) }

    var standardsSummary: String {
        levels
            .sorted { $0.standard.nominalNTU < $1.standard.nominalNTU }
            .map { String(format: "%.3g NTU x%d", $0.standard.nominalNTU, $0.usableReplicates.count) }
            .joined(separator: ", ")
    }
}

/// What can be said about NTU right now.
///
/// An enumeration rather than an optional `Double`, so that "no NTU" always
/// carries the reason, and so that no code path can ever produce a zero that
/// reads like a measurement of very clear water.
enum NTUAvailability: Equatable, Sendable {
    case available(estimateNTU: Double, uncertaintyNTU: Double, validatedRange: ClosedRange<Double>)

    /// Screening Mode does not produce NTU at all, by design.
    case screeningMode
    case calibrationRequired
    case profileExpired(expiredAt: Date)
    case incompatibleProfile(reasons: [String])
    case captureQualityInsufficient(reasons: [MeasurementRejectionReason])
    case belowValidatedRange(lowerBoundNTU: Double)
    case aboveValidatedRange(upperBoundNTU: Double)
    case uncertaintyUnavailable

    var estimate: Double? {
        if case .available(let estimate, _, _) = self { return estimate }
        return nil
    }

    /// What the user is shown where a number would otherwise go.
    var displayText: String {
        switch self {
        case .available(let estimate, let uncertainty, _):
            return String(format: "%.2f ± %.2f NTU", estimate, uncertainty)
        case .screeningMode, .calibrationRequired:
            return "Calibration required"
        case .profileExpired:
            return "Calibration expired"
        case .incompatibleProfile:
            return "Setup does not match the calibration"
        case .captureQualityInsufficient:
            return "Capture quality too low"
        case .belowValidatedRange(let bound):
            return String(format: "Below validated range (< %.3g NTU)", bound)
        case .aboveValidatedRange(let bound):
            return String(format: "Above validated range (> %.3g NTU)", bound)
        case .uncertaintyUnavailable:
            return "Uncertainty unavailable"
        }
    }

    var explanation: String {
        switch self {
        case .available:
            return "Estimated from a calibration made with certified standards on this exact setup."
        case .screeningMode:
            return "Screening Mode reports relative optical clarity only. NTU requires a calibrated fixture."
        case .calibrationRequired:
            return "No calibration has been made for this setup."
        case .profileExpired(let date):
            return "The calibration expired on \(date.formatted(date: .abbreviated, time: .omitted)) and needs to be repeated."
        case .incompatibleProfile(let reasons):
            return "The current setup differs from the calibrated one: " + reasons.joined(separator: "; ") + "."
        case .captureQualityInsufficient(let reasons):
            return reasons.map(\.explanation).joined(separator: " ")
        case .belowValidatedRange:
            return "The sample scattered less light than the clearest standard used, so no number can be given without extrapolating."
        case .aboveValidatedRange:
            return "The sample scattered more light than the cloudiest standard used, so no number can be given without extrapolating."
        case .uncertaintyUnavailable:
            return "An estimate without an uncertainty is not a measurement, so none is shown."
        }
    }
}

/// The single place an NTU number can come into existence.
///
/// Every condition is checked here and nowhere else. There is deliberately no
/// other function in the app that turns an index into NTU.
enum NTUGate {

    static func evaluate(mode: MeasurementMode,
                         profile: CalibrationProfile?,
                         index: RelativeScatteringIndex,
                         quality: CaptureQuality,
                         liveBinding: CalibrationBinding?,
                         tolerances: CalibrationTolerances = .screening,
                         asOf date: Date) -> NTUAvailability {
        guard mode.permitsNumericNTU else { return .screeningMode }
        guard let profile else { return .calibrationRequired }
        guard profile.schemaVersion == CalibrationProfile.currentSchemaVersion else {
            return .incompatibleProfile(reasons: ["calibration was saved by a different version of Turbid"])
        }
        guard !profile.isExpired(asOf: date) else {
            return .profileExpired(expiredAt: profile.expiresAt)
        }
        guard let liveBinding else {
            return .incompatibleProfile(reasons: ["the current capture settings are unknown"])
        }

        let mismatches = CalibrationCompatibility.mismatches(
            live: liveBinding, calibrated: profile.binding, tolerances: tolerances
        )
        guard mismatches.isEmpty else { return .incompatibleProfile(reasons: mismatches) }

        guard quality.isUsable else {
            return .captureQualityInsufficient(reasons: quality.verdict.reasons)
        }

        // Outside the calibrated range the curve has never been checked. It
        // clamps rather than extrapolating, and a clamped value presented as a
        // measurement would be a fabrication.
        if index.value < profile.validatedIndexRange.lowerBound {
            return .belowValidatedRange(lowerBoundNTU: profile.validatedNTURange.lowerBound)
        }
        if index.value > profile.validatedIndexRange.upperBound {
            return .aboveValidatedRange(upperBoundNTU: profile.validatedNTURange.upperBound)
        }

        let uncertainty = profile.uncertainty.uncertainty(atIndex: index.value,
                                                          mapping: profile.mapping)
        guard uncertainty.isFinite, uncertainty > 0 else { return .uncertaintyUnavailable }

        return .available(estimateNTU: profile.mapping.ntu(forIndex: index.value),
                          uncertaintyNTU: uncertainty,
                          validatedRange: profile.validatedNTURange)
    }
}
