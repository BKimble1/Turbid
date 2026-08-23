import Foundation
@testable import Lucid

/// Counts start and stop without touching Core Motion.
final class SpyGravityProvider: GravityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0

    var starts: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    var stops: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCount
    }

    func currentGravity() -> GravityReference { .portraitAssumed }

    func start() {
        lock.lock()
        startCount += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}
