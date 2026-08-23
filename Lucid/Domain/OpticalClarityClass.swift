import Foundation

/// The three consumer-facing result states.
///
/// These labels describe *observed optical clarity only*. They are not a
/// potability, pathogen, chemical or safety determination.
enum OpticalClarityClass: String, Equatable, Sendable, CaseIterable, Codable {
    case crystalClear
    case slightlyTurbid
    case highParticleCount

    var headline: String {
        switch self {
        case .crystalClear: return "Crystal Clear"
        case .slightlyTurbid: return "Slightly Turbid"
        case .highParticleCount: return "High Particle Count"
        }
    }

    var qualifier: String {
        switch self {
        case .crystalClear: return "Good optical clarity"
        case .slightlyTurbid: return "Fair optical clarity"
        case .highParticleCount: return "Poor optical clarity"
        }
    }

    /// A shape cue so the result never depends on colour alone.
    var symbolName: String {
        switch self {
        case .crystalClear: return "checkmark.circle.fill"
        case .slightlyTurbid: return "exclamationmark.triangle.fill"
        case .highParticleCount: return "xmark.octagon.fill"
        }
    }
}

/// Copy that must accompany every result surface in the app.
enum MeasurementDisclaimer {
    static let short = "Optical screening only — not a drinking-water safety test."

    static let long = """
    Lucid estimates how much light a water sample scatters. It cannot detect \
    bacteria, viruses, dissolved chemicals, heavy metals, PFAS or toxins, and it \
    cannot tell you whether water is safe to drink.
    """
}
