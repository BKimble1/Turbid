import Foundation

/// Records whether the person using Turbid has read what it does and does not
/// measure.
///
/// Behind a protocol so the onboarding flow can be tested, and so a UI test can
/// launch straight into either state instead of tapping through it every run.
protocol DisclosureRecording: Sendable {
    func hasAcknowledged() -> Bool
    func acknowledge()
    func reset()
}

/// Stored in `UserDefaults`: this is a preference, not a measurement, and it
/// should follow the app rather than survive its deletion.
struct DefaultsDisclosureRecorder: DisclosureRecording, @unchecked Sendable {
    /// Versioned. If the disclosure text ever changes materially, the key
    /// changes with it and everyone reads the new one — silently keeping an
    /// acknowledgement of wording nobody saw would defeat the point.
    static let key = "turbid.disclosure.acknowledged.v1"

    // `DisclosureRecording` refines `Sendable`, and `UserDefaults` carries no
    // `Sendable` conformance, so the compiler cannot check this one for us.
    // Apple documents the type as "thread-safe, and you can use the same
    // object in multiple threads or tasks simultaneously", and this holds one
    // reference to a shared store and never mutates the reference itself, so
    // the vouch states a fact about the framework type rather than waiving a
    // real requirement. `InMemoryDisclosureRecorder` below does the same for
    // its lock.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasAcknowledged() -> Bool { defaults.bool(forKey: Self.key) }

    func acknowledge() { defaults.set(true, forKey: Self.key) }

    func reset() { defaults.removeObject(forKey: Self.key) }
}

/// In-memory recorder for tests, previews and the Simulator.
final class InMemoryDisclosureRecorder: DisclosureRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledged: Bool

    init(acknowledged: Bool = false) {
        self.acknowledged = acknowledged
    }

    func hasAcknowledged() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acknowledged
    }

    func acknowledge() {
        lock.lock()
        defer { lock.unlock() }
        acknowledged = true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        acknowledged = false
    }
}
