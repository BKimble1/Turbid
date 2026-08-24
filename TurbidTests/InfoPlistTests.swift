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

    /// The app icon, checked by the only thing that can be checked from here.
    ///
    /// `Assets.car` is what `actool` produces from `Assets.xcassets`, and it is
    /// in the bundle only if the catalogue was genuinely compiled into it. An
    /// asset catalogue that silently stopped being built — the failure this
    /// guards against, and one a simulator build otherwise only warns about —
    /// takes this test with it.
    ///
    /// It deliberately does *not* assert `CFBundleIconName`. That key is
    /// written by `actool` into a partial Info.plist the build merges, and on
    /// the Xcode 26 toolchain the merge does not happen for this project:
    /// measured on both a Simulator build and a device archive, `Assets.car`
    /// was present and the key was absent. `INFOPLIST_KEY_CFBundleIconName`
    /// does not reach it either — that mechanism only serves keys the build
    /// system knows, and this one belongs to actool.
    ///
    /// Asserting it here would therefore be asserting a toolchain behaviour
    /// rather than anything about Turbid, and it would fail on a build whose
    /// icon is perfectly present. App Store Connect does require the key, so it
    /// is supplied and verified where it actually ships: the TestFlight
    /// workflow's "Verify what the archive actually contains" step proves
    /// `Assets.car` is in the archived app, writes `CFBundleIconName` on top of
    /// it, and re-reads it before allowing the upload. That check runs against
    /// the artifact being sent to Apple, which is a stronger guarantee than
    /// this test could ever make about a Simulator bundle.
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
