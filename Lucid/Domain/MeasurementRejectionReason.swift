import Foundation

/// An extensible, string-backed reason why a measurement window was rejected.
///
/// Deliberately empty of concrete cases in Phase 1: no analysis exists yet, so
/// inventing quality-gate reasons now would describe behaviour the app does not
/// have. Phase 3A adds the real constants (saturation, focus, global motion,
/// background instability, dropped frames, thermal limits, profile mismatch)
/// alongside the code that can actually produce them.
struct MeasurementRejectionReason: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}
