import XCTest
@testable import Lucid

/// Verifies the privacy declaration that actually ships in the built app bundle.
/// Requires the unit-test bundle to be hosted by the Lucid app (TEST_HOST).
final class InfoPlistTests: XCTestCase {

    private var appBundle: Bundle {
        Bundle(for: CameraPreviewUIView.self)
    }

    func testCameraUsageDescriptionIsPresentAndMeaningful() throws {
        let value = try XCTUnwrap(
            appBundle.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
            "NSCameraUsageDescription is missing from the built app bundle"
        )

        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(value.localizedCaseInsensitiveContains("camera"))
        XCTAssertTrue(value.localizedCaseInsensitiveContains("torch"))
        XCTAssertTrue(value.localizedCaseInsensitiveContains("not saved"),
                      "the purpose string must state that video is not saved by default")
    }

    func testNoUnnecessaryPrivacyPermissionsAreDeclared() {
        let forbidden = [
            "NSMicrophoneUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSContactsUsageDescription",
            "NSBluetoothAlwaysUsageDescription"
        ]

        for key in forbidden {
            XCTAssertNil(appBundle.object(forInfoDictionaryKey: key),
                         "\(key) must not be declared; Lucid only needs the camera")
        }
    }

    func testThereIsNoSeparateTorchPermissionKey() {
        // The torch is covered by NSCameraUsageDescription; iOS has no
        // flashlight-specific privacy key. This pins that expectation.
        XCTAssertNil(appBundle.object(forInfoDictionaryKey: "NSTorchUsageDescription"))
        XCTAssertNil(appBundle.object(forInfoDictionaryKey: "NSFlashlightUsageDescription"))
    }
}
