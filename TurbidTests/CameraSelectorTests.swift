import XCTest
@testable import Turbid

final class CameraSelectorTests: XCTestCase {

    private let selector = CameraSelector(requirements: .measurement)

    // MARK: - Hard requirements

    func testACameraWithNoTorchIsExcluded() {
        let outcome = selector.select(from: [CapabilityFactory.ultraWide(hasTorch: false)])

        XCTAssertNil(outcome.selection, "there is nothing to scatter without illumination")
        XCTAssertEqual(outcome.rejections.count, 1)
        XCTAssertEqual(outcome.rejections.first?.reason, "no torch")
    }

    func testACameraThatCannotLockFocusIsExcluded() {
        let camera = CapabilityFactory.camera(uniqueID: "a", supportsLockedFocus: false)
        let outcome = selector.select(from: [camera])

        XCTAssertNil(outcome.selection)
        XCTAssertEqual(outcome.rejections.first?.reason, "focus cannot be locked")
    }

    func testACameraThatCannotLockExposureIsExcluded() {
        let camera = CapabilityFactory.camera(uniqueID: "a",
                                              supportsLockedExposure: false,
                                              supportsCustomExposure: false)
        let outcome = selector.select(from: [camera])

        XCTAssertNil(outcome.selection)
        XCTAssertEqual(outcome.rejections.first?.reason, "exposure cannot be locked")
    }

    func testACameraThatCannotLockWhiteBalanceIsExcluded() {
        let camera = CapabilityFactory.camera(uniqueID: "a", supportsLockedWhiteBalance: false)
        let outcome = selector.select(from: [camera])

        XCTAssertNil(outcome.selection)
        XCTAssertEqual(outcome.rejections.first?.reason, "white balance cannot be locked")
    }

    func testACameraWithNoFormatAtTheRequiredFrameRateIsExcluded() {
        let slow = CapabilityFactory.camera(
            uniqueID: "slow",
            formats: [CapabilityFactory.format(minFrameRate: 1, maxFrameRate: 24)]
        )
        let outcome = selector.select(from: [slow])

        XCTAssertNil(outcome.selection)
        XCTAssertEqual(outcome.rejections.first?.reason, "no format supports 30 fps")
    }

    func testEmptyInputSelectsNothing() {
        let outcome = selector.select(from: [])
        XCTAssertNil(outcome.selection)
        XCTAssertTrue(outcome.rejections.isEmpty)
    }

    // MARK: - Preference between usable cameras

    func testCloserFocusWinsOverTheWideCamera() {
        let outcome = selector.select(from: [
            CapabilityFactory.wide(),
            CapabilityFactory.ultraWide()
        ])

        XCTAssertEqual(outcome.selection?.capabilities.uniqueID, "ultra-wide",
                       "the camera that can focus inside the working distance should win")
    }

    func testTheWideCameraIsUsedWhenTheUltraWideHasNoTorch() {
        let outcome = selector.select(from: [
            CapabilityFactory.ultraWide(hasTorch: false),
            CapabilityFactory.wide()
        ])

        XCTAssertEqual(outcome.selection?.capabilities.uniqueID, "wide")
        XCTAssertEqual(outcome.rejections.map(\.reason), ["no torch"])
    }

    func testSelectionIsCapabilityDrivenNotNameDriven() {
        // An "Ultra Wide" that cannot focus close loses to a "Wide" that can.
        // Nothing in the selector may key off the device type string.
        let outcome = selector.select(from: [
            CapabilityFactory.ultraWide(minimumFocusDistanceMillimetres: 400),
            CapabilityFactory.wide(minimumFocusDistanceMillimetres: 60)
        ])

        XCTAssertEqual(outcome.selection?.capabilities.uniqueID, "wide")
    }

    func testAVirtualDeviceLosesToAnyPhysicalCamera() {
        // The triple camera focuses just as close, but it can switch its
        // constituent camera mid-measurement.
        let outcome = selector.select(from: [
            CapabilityFactory.triple(),
            CapabilityFactory.wide()
        ])

        XCTAssertEqual(outcome.selection?.capabilities.uniqueID, "wide")
    }

    func testAVirtualDeviceIsStillUsableWhenItIsTheOnlyOption() {
        let outcome = selector.select(from: [CapabilityFactory.triple()])

        XCTAssertEqual(outcome.selection?.capabilities.uniqueID, "triple")
        XCTAssertTrue(
            outcome.selection?.warnings.contains { $0.contains("optical path can change") } ?? false,
            "using a virtual device must be surfaced as a warning"
        )
    }

    // MARK: - Reporting

    func testAFarFocusingCameraIsWarnedAboutRatherThanRejected() {
        let outcome = selector.select(from: [
            CapabilityFactory.wide(minimumFocusDistanceMillimetres: 300)
        ])

        XCTAssertNotNil(outcome.selection, "a longer working distance is a compromise, not a blocker")
        XCTAssertTrue(
            outcome.selection?.warnings.contains { $0.contains("300 mm") } ?? false
        )
    }

    func testAnUnreportedFocusDistanceIsWarnedAbout() {
        let outcome = selector.select(from: [
            CapabilityFactory.wide(minimumFocusDistanceMillimetres: nil)
        ])

        XCTAssertNotNil(outcome.selection)
        XCTAssertTrue(
            outcome.selection?.warnings.contains { $0.contains("not reported") } ?? false
        )
    }

    func testMissingCustomExposureIsWarnedAbout() {
        let camera = CapabilityFactory.camera(uniqueID: "a", supportsCustomExposure: false)
        let outcome = selector.select(from: [camera])

        XCTAssertNotNil(outcome.selection)
        XCTAssertTrue(
            outcome.selection?.warnings.contains { $0.contains("not set explicitly") } ?? false
        )
    }

    func testTheWinningCameraExplainsItself() {
        let outcome = selector.select(from: [CapabilityFactory.ultraWide()])
        let rationale = try? XCTUnwrap(outcome.selection?.rationale)

        XCTAssertNotNil(rationale)
        XCTAssertTrue(rationale?.contains { $0.contains("20 mm") } ?? false)
        XCTAssertTrue(rationale?.contains { $0.contains("single physical camera") } ?? false)
    }

    // MARK: - Determinism

    func testSelectionIsStableRegardlessOfInputOrder() {
        let cameras = [
            CapabilityFactory.ultraWide(),
            CapabilityFactory.wide(),
            CapabilityFactory.triple()
        ]
        let forwards = selector.select(from: cameras).selection?.capabilities.uniqueID
        let backwards = selector.select(from: cameras.reversed()).selection?.capabilities.uniqueID

        XCTAssertEqual(forwards, backwards)
    }

    func testIdenticalCamerasTieBreakOnUniqueIdentifier() {
        let first = CapabilityFactory.camera(uniqueID: "aaa")
        let second = CapabilityFactory.camera(uniqueID: "bbb")

        XCTAssertEqual(selector.select(from: [first, second]).selection?.capabilities.uniqueID, "aaa")
        XCTAssertEqual(selector.select(from: [second, first]).selection?.capabilities.uniqueID, "aaa")
    }
}
