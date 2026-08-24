import Foundation

/// Records Settings requests instead of leaving the app.
final class StubSettingsOpener: SettingsOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func openAppSettings() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
