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
    Turbid estimates how much light a water sample scatters. It cannot detect \
    bacteria, viruses, dissolved chemicals, heavy metals, PFAS or toxins, and it \
    cannot tell you whether water is safe to drink.
    """

    /// Spelled out one by one, because a single sentence listing everything is
    /// easy to skim past and each of these is a thing people actually assume a
    /// water-testing app checks.
    static let cannotDetect = [
        "Bacteria, viruses, protozoa or any other pathogen",
        "Lead, arsenic, copper or other dissolved metals",
        "Nitrates, pesticides, PFAS or other dissolved chemicals",
        "Chlorine, pH, hardness or any chemical property",
        "Anything smaller than the camera can resolve, which includes most of what makes water turbid",
        "Anything outside the small region of the frame it looks at"
    ]

    /// What limits a reading even when everything went right.
    ///
    /// Every one of these is a property of the instrument, not a fault in the
    /// run, so they belong on the result rather than in a manual nobody opens.
    static let limitations = [
        "An iPhone is not a nephelometer: there is no calibrated light source, no fixed sample geometry and no defined detection angle.",
        "Only particles the camera can resolve are tracked. Colloidal and microscopic material, which dominates real turbidity, is invisible to it.",
        "Colour absorbs light as well as scattering it, so a tinted sample reads differently from a colourless one at the same turbidity.",
        "Bubbles, container marks, scratches and reflections are rejected as well as the design allows, and not perfectly.",
        "Results are comparable only between runs made with the same phone, the same container and the same technique.",
        "The clarity bands are Turbid's own presentation bands. They are not health thresholds, regulatory limits or a potability determination."
    ]
}
