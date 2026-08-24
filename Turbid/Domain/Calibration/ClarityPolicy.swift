import Foundation

/// The bands that turn a measurement into one of the three result states.
///
/// **These are Turbid's own presentation bands. They are not health thresholds,
/// not regulatory limits, and not a potability determination.** They exist so
/// that a number has a plain-language companion, and they are versioned so that
/// any result can be traced to the exact bands that produced it.
///
/// Two sets, because the two modes are measuring different things:
///
/// * **Screening Mode** bands are on the relative scattering index, and describe
///   *observed scattering* — low, moderate, high — with no claim about NTU or
///   about anything outside the frame.
/// * **Calibrated Fixture Mode** bands are on estimated NTU. Their edges are
///   chosen perceptually: around 1 NTU turbidity becomes noticeable to the eye
///   in a clear vessel, and by around 5 NTU it is obvious. That is the whole
///   justification. Regulatory values happen to exist near these numbers; Turbid
///   is not measuring against them and does not claim to.
struct ClarityPolicy: Equatable, Sendable, Codable {

    /// Index below which scattering is described as low.
    var screeningLowIndexCeiling: Double
    /// Index above which scattering is described as high.
    var screeningHighIndexFloor: Double

    /// NTU below which clarity is described as good.
    var calibratedGoodNTUCeiling: Double
    /// NTU above which clarity is described as poor.
    var calibratedPoorNTUFloor: Double

    var version: Int

    /// Unvalidated starting points. The index edges in particular are a guess
    /// until real samples have been measured on a real fixture; they are the
    /// first thing that should move once there is data.
    static let screening = ClarityPolicy(
        screeningLowIndexCeiling: 8,
        screeningHighIndexFloor: 40,
        calibratedGoodNTUCeiling: 1.0,
        calibratedPoorNTUFloor: 5.0,
        version: 1
    )
}

/// Maps a measurement to one of the three consumer-facing states.
///
/// In Calibrated Fixture Mode the NTU bands are used when — and only when — a
/// numeric NTU actually exists. When the gate withholds NTU the classification
/// falls back to the index bands, and says so, rather than pretending a
/// calibrated judgement was made.
enum ClarityCategoryEngine {

    struct Verdict: Equatable, Sendable {
        let clarity: OpticalClarityClass
        /// Which quantity decided it, for the audit trail.
        let basis: Basis
        let policyVersion: Int

        enum Basis: String, Equatable, Sendable {
            case relativeScatteringIndex
            case calibratedNTU
        }

        /// Wording that matches the basis. Screening describes observed
        /// scattering; it never describes a concentration.
        var description: String {
            switch basis {
            case .relativeScatteringIndex:
                switch clarity {
                case .crystalClear: return "Low observed scattering"
                case .slightlyTurbid: return "Moderate observed scattering"
                case .highParticleCount: return "High observed scattering"
                }
            case .calibratedNTU:
                return clarity.qualifier
            }
        }
    }

    static func classify(index: RelativeScatteringIndex,
                         ntu: NTUAvailability,
                         policy: ClarityPolicy = .screening) -> Verdict {
        if case .available(let estimate, _, _) = ntu {
            let clarity: OpticalClarityClass
            if estimate < policy.calibratedGoodNTUCeiling {
                clarity = .crystalClear
            } else if estimate < policy.calibratedPoorNTUFloor {
                clarity = .slightlyTurbid
            } else {
                clarity = .highParticleCount
            }
            return Verdict(clarity: clarity, basis: .calibratedNTU, policyVersion: policy.version)
        }

        let clarity: OpticalClarityClass
        if index.value < policy.screeningLowIndexCeiling {
            clarity = .crystalClear
        } else if index.value < policy.screeningHighIndexFloor {
            clarity = .slightlyTurbid
        } else {
            clarity = .highParticleCount
        }
        return Verdict(clarity: clarity, basis: .relativeScatteringIndex,
                       policyVersion: policy.version)
    }
}
