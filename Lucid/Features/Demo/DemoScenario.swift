import Foundation

/// Illustrative examples of what each result state looks like.
///
/// Every value is stored as pre-formatted text, never as a number. That is
/// deliberate: there is no numeric type here that could accidentally be routed
/// into a measurement, a chart or a calibration fit. NTU is always unavailable.
struct DemoScenario: Identifiable, Sendable, Equatable {
    let id: String
    let clarity: OpticalClarityClass
    /// Pre-formatted example text, e.g. "low". Not a measured value.
    let relativeScatteringExample: String
    let trackedSpecksExample: String
    let explanation: String

    /// Screening Mode can never produce NTU, so the demo cannot either.
    var estimatedNTUText: String { "Calibration required" }

    static let all: [DemoScenario] = [
        DemoScenario(
            id: "crystal-clear",
            clarity: .crystalClear,
            relativeScatteringExample: "low",
            trackedSpecksExample: "few",
            explanation: "Little light is scattered back to the camera and few moving specks are tracked."
        ),
        DemoScenario(
            id: "slightly-turbid",
            clarity: .slightlyTurbid,
            relativeScatteringExample: "moderate",
            trackedSpecksExample: "some",
            explanation: "More light is scattered and a moderate number of moving specks are tracked."
        ),
        DemoScenario(
            id: "high-particle-count",
            clarity: .highParticleCount,
            relativeScatteringExample: "high",
            trackedSpecksExample: "many",
            explanation: "Strong scattering with many tracked moving specks in the analysis region."
        )
    ]
}
