import XCTest
@testable import Turbid

/// Verifies the privacy declaration that actually ships in the built app bundle.
/// Requires the unit-test bundle to be hosted by the Turbid app (TEST_HOST).
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
                         "\(key) must not be declared; Turbid only needs the camera")
        }
    }

    func testThereIsNoSeparateTorchPermissionKey() {
        // The torch is covered by NSCameraUsageDescription; iOS has no
        // flashlight-specific privacy key. This pins that expectation.
        XCTAssertNil(appBundle.object(forInfoDictionaryKey: "NSTorchUsageDescription"))
        XCTAssertNil(appBundle.object(forInfoDictionaryKey: "NSFlashlightUsageDescription"))
    }

    /// Answered in the Info.plist so it is not asked on every upload. Turbid
    /// implements no encryption and makes no network connections at all, so
    /// the answer is no; without the key, every TestFlight build waits in
    /// "Missing Compliance" for someone to click through the question.
    func testExportComplianceIsAnsweredInTheBundle() throws {
        let value = appBundle.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption")
        XCTAssertEqual(value as? Bool, false,
                       "ITSAppUsesNonExemptEncryption must be present and false")
    }

    /// A simulator build only warns when the App Store icon is missing, so
    /// nothing notices until the archive is rejected for a missing
    /// CFBundleIconName. This is where it gets noticed.
    func testTheAppIconIsNamedInTheInfoPlist() throws {
        let name = appBundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String
        XCTAssertEqual(name, "AppIcon",
                       "the asset catalogue's app icon must be named in the Info.plist")
    }

    /// The key above is declared as a build setting, so on its own it proves
    /// only that somebody typed it. This is the half that cannot be faked: the
    /// compiled asset catalogue is what `actool` produces from
    /// `Assets.xcassets`, and it exists in the bundle only if the catalogue was
    /// actually compiled into it. Without this, an asset catalogue that had
    /// silently stopped being built would still pass, and the archive would be
    /// rejected at upload for an icon the Info.plist promised and the bundle
    /// did not contain.
    func testTheCompiledAssetCatalogueReachesTheBundle() throws {
        XCTAssertNotNil(appBundle.url(forResource: "Assets", withExtension: "car"),
                        "Assets.car is not in the built app bundle, so no icon "
                            + "and no accent colour were compiled into it")
    }

    // MARK: - Privacy manifest

    /// The manifest has to be *in the bundle* to mean anything. A file sitting
    /// in the repository that never made it into a Resources build phase is
    /// something App Store Connect will never see.
    private func privacyManifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            appBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is not in the built app bundle"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data,
                                                               format: nil)
        return try XCTUnwrap(plist as? [String: Any],
                             "the privacy manifest is not a dictionary")
    }

    func testThePrivacyManifestDeclaresNoTrackingAndNoCollection() throws {
        let manifest = try privacyManifest()

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true,
                       "Turbid has no network code, so it can have no tracking domains")
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty, true,
                       "nothing leaves the device, so nothing is collected")
    }

    func testTheOnlyRequiredReasonAPIDeclaredIsUserDefaults() throws {
        let manifest = try privacyManifest()
        let accessed = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "NSPrivacyAccessedAPITypes is missing"
        )

        let categories = accessed.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertEqual(categories, ["NSPrivacyAccessedAPICategoryUserDefaults"],
                       "Turbid reads no file metadata, no disk space, no keyboards and no boot time")

        let reasons = accessed.flatMap { $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [] }
        XCTAssertEqual(reasons, ["CA92.1"],
                       "CA92.1 is 'information accessible only to the app itself', which is the one flag Turbid stores")
    }
}
