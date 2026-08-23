import CoreMotion
import Foundation

/// Supplies which way is up, in image space.
protocol GravityProviding: Sendable {
    func currentGravity() -> GravityReference
    func start()
    func stop()
}

/// The orientation-only default: assumes the phone is upright and the rear
/// camera is pointing horizontally at the sample, which is what the setup
/// instructions ask for.
///
/// Correct whenever the instructions are followed, and wrong in a way that
/// matters only when they are not — which is exactly why the measured provider
/// exists.
struct AssumedPortraitGravityProvider: GravityProviding {
    func currentGravity() -> GravityReference { .portraitAssumed }
    func start() {}
    func stop() {}
}

/// Measures gravity with Core Motion.
///
/// Worth measuring rather than assuming because bubble rejection depends on it:
/// with the phone lying flat and the camera looking down, gravity is almost
/// perpendicular to the image plane, a rising bubble barely moves in frame, and
/// separating bubbles from specks by direction becomes impossible. Reporting
/// that honestly requires knowing it, and only a measurement can tell.
final class CoreMotionGravityProvider: GravityProviding, @unchecked Sendable {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var fallback = GravityReference.portraitAssumed

    init(updateInterval: TimeInterval = 0.2) {
        manager.deviceMotionUpdateInterval = updateInterval
    }

    deinit {
        manager.stopDeviceMotionUpdates()
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates()
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    func currentGravity() -> GravityReference {
        guard let motion = manager.deviceMotion else {
            lock.lock()
            defer { lock.unlock() }
            return fallback
        }
        let gravity = motion.gravity
        let reference = GravityReference.portraitRearCamera(
            deviceGravityX: gravity.x,
            deviceGravityY: gravity.y,
            deviceGravityZ: gravity.z
        )
        lock.lock()
        fallback = reference
        lock.unlock()
        return reference
    }
}
