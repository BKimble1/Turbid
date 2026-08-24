import Foundation

/// The two measurement modes described in the Turbid measurement policy.
///
/// A numeric NTU value may only ever originate from `calibratedFixture`, and even
/// then only after the Phase 3D validity gate approves it. `screening` is a
/// relative optical observation and can never carry NTU.
enum MeasurementMode: String, Equatable, Sendable, CaseIterable, Codable {
    /// Phone-only or loosely positioned use. Relative results only.
    case screening
    /// Fixed shroud/fixture and container matching a valid calibration profile.
    case calibratedFixture

    /// Necessary but not sufficient for reporting NTU. The calibration profile
    /// compatibility gate (Phase 3D) is the remaining requirement.
    var permitsNumericNTU: Bool { self == .calibratedFixture }

    var title: String {
        switch self {
        case .screening: return "Screening Mode"
        case .calibratedFixture: return "Calibrated Fixture Mode"
        }
    }

    var summary: String {
        switch self {
        case .screening:
            return "Relative optical clarity only. No NTU value is produced."
        case .calibratedFixture:
            return "Requires a validated calibration profile that matches the exact hardware, fixture and capture settings in use."
        }
    }
}
