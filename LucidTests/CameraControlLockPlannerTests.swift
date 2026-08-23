import XCTest
@testable import Lucid

/// `AVCaptureDevice` raises an exception for an out-of-range exposure, ISO or
/// white-balance gain, so every clamp is pinned down here.
final class CameraControlLockPlannerTests: XCTestCase {

    private func observed(lensPosition: Float = 0.5,
                          exposureSeconds: Double = 1.0 / 60.0,
                          iso: Float = 200,
                          gains: WhiteBalanceGains = WhiteBalanceGains(red: 2, green: 1, blue: 1.8))
    -> ObservedCameraControls {
        ObservedCameraControls(lensPosition: lensPosition,
                               exposureSeconds: exposureSeconds,
                               iso: iso,
                               whiteBalanceGains: gains,
                               focusIsSharp: true)
    }

    func testValuesInsideTheSupportedRangesArePassedThroughUnchanged() {
        let plan = CameraControlLockPlanner.plan(
            observed: observed(),
            format: CapabilityFactory.format(),
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )

        XCTAssertEqual(plan.lensPosition, 0.5)
        XCTAssertEqual(plan.exposureSeconds, 1.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(plan.iso, 200)
        XCTAssertEqual(plan.whiteBalanceGains, WhiteBalanceGains(red: 2, green: 1, blue: 1.8))
        XCTAssertFalse(plan.requiredClamping)
    }

    func testAnExposureLongerThanTheFormatAllowsIsClamped() {
        let format = CapabilityFactory.format(minExposureSeconds: 1.0 / 8000.0,
                                              maxExposureSeconds: 1.0 / 30.0)
        let plan = CameraControlLockPlanner.plan(
            observed: observed(exposureSeconds: 0.5),
            format: format,
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )

        XCTAssertEqual(plan.exposureSeconds, 1.0 / 30.0, accuracy: 1e-9)
        XCTAssertTrue(plan.clampNotes.contains { $0.contains("exposure clamped") })
    }

    func testAnExposureShorterThanTheFormatAllowsIsClamped() {
        let format = CapabilityFactory.format(minExposureSeconds: 1.0 / 1000.0,
                                              maxExposureSeconds: 1.0)
        let plan = CameraControlLockPlanner.plan(
            observed: observed(exposureSeconds: 1.0 / 20000.0),
            format: format,
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )

        XCTAssertEqual(plan.exposureSeconds, 1.0 / 1000.0, accuracy: 1e-9)
    }

    func testISOIsClampedToTheFormatRange() {
        let format = CapabilityFactory.format(minISO: 50, maxISO: 800)

        let high = CameraControlLockPlanner.plan(
            observed: observed(iso: 5000),
            format: format,
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )
        XCTAssertEqual(high.iso, 800)
        XCTAssertTrue(high.clampNotes.contains { $0.contains("ISO clamped") })

        let low = CameraControlLockPlanner.plan(
            observed: observed(iso: 10),
            format: format,
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )
        XCTAssertEqual(low.iso, 50)
    }

    func testWhiteBalanceGainsAreClampedIntoTheDeviceRange() {
        let capabilities = CapabilityFactory.camera(uniqueID: "a", maxWhiteBalanceGain: 3)
        let plan = CameraControlLockPlanner.plan(
            observed: observed(gains: WhiteBalanceGains(red: 9, green: 1, blue: 0.2)),
            format: CapabilityFactory.format(),
            capabilities: capabilities
        )

        let gains = plan.whiteBalanceGains
        XCTAssertEqual(gains?.red, 3)
        XCTAssertEqual(gains?.green, 1)
        // Gains are relative to green, which is fixed at 1.0, so nothing may
        // fall below it.
        XCTAssertEqual(gains?.blue, 1)
        XCTAssertTrue(plan.clampNotes.contains { $0.contains("white-balance gains clamped") })
    }

    func testLensPositionIsClampedToZeroThroughOne() {
        let over = CameraControlLockPlanner.plan(
            observed: observed(lensPosition: 3),
            format: CapabilityFactory.format(),
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )
        XCTAssertEqual(over.lensPosition, 1)

        let under = CameraControlLockPlanner.plan(
            observed: observed(lensPosition: -2),
            format: CapabilityFactory.format(),
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )
        XCTAssertEqual(under.lensPosition, 0)
    }

    func testACameraWithoutCustomLensPositionGetsNoExplicitPosition() {
        let capabilities = CapabilityFactory.camera(uniqueID: "a",
                                                    supportsCustomLensPositionLock: false)
        let plan = CameraControlLockPlanner.plan(
            observed: observed(),
            format: CapabilityFactory.format(),
            capabilities: capabilities
        )

        XCTAssertNil(plan.lensPosition, "the device can only be told to lock where it is")
        XCTAssertTrue(plan.clampNotes.contains { $0.contains("lens position cannot be set") })
    }

    func testACameraWithoutCustomWhiteBalanceGetsNoExplicitGains() {
        let capabilities = CapabilityFactory.camera(uniqueID: "a",
                                                    supportsCustomWhiteBalanceGainsLock: false)
        let plan = CameraControlLockPlanner.plan(
            observed: observed(),
            format: CapabilityFactory.format(),
            capabilities: capabilities
        )

        XCTAssertNil(plan.whiteBalanceGains)
        XCTAssertTrue(plan.clampNotes.contains { $0.contains("white-balance gains cannot be set") })
    }

    func testAnInvertedFormatRangeDoesNotProduceANonsenseValue() {
        // Defensive: a device reporting min > max must not yield a value
        // outside both bounds.
        let format = CapabilityFactory.format(minExposureSeconds: 1.0, maxExposureSeconds: 0.01)
        let plan = CameraControlLockPlanner.plan(
            observed: observed(exposureSeconds: 0.5),
            format: format,
            capabilities: CapabilityFactory.camera(uniqueID: "a")
        )

        XCTAssertEqual(plan.exposureSeconds, 1.0, accuracy: 1e-9)
    }
}
