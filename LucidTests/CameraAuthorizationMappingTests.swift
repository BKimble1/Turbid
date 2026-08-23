import AVFoundation
import XCTest
@testable import Lucid

final class CameraAuthorizationMappingTests: XCTestCase {

    func testEverySystemStatusMapsToTheMatchingDomainCase() {
        XCTAssertEqual(CameraAuthorization(systemStatus: .notDetermined), .notDetermined)
        XCTAssertEqual(CameraAuthorization(systemStatus: .authorized), .authorized)
        XCTAssertEqual(CameraAuthorization(systemStatus: .denied), .denied)
        XCTAssertEqual(CameraAuthorization(systemStatus: .restricted), .restricted)
    }

    func testOnlyAuthorizedAllowsCapture() {
        for authorization in CameraAuthorization.allCases {
            XCTAssertEqual(authorization.allowsCapture,
                           authorization == .authorized,
                           "\(authorization.rawValue) reported the wrong capture permission")
        }
    }

    func testOnlyUndecidedStatusMayRaiseTheSystemPrompt() {
        for authorization in CameraAuthorization.allCases {
            XCTAssertEqual(authorization.canRequestSystemPrompt,
                           authorization == .notDetermined,
                           "\(authorization.rawValue) reported the wrong prompt eligibility")
        }
    }

    func testDeniedAndRestrictedRequireSettings() {
        XCTAssertTrue(CameraAuthorization.denied.requiresSettingsChange)
        XCTAssertTrue(CameraAuthorization.restricted.requiresSettingsChange)
        XCTAssertFalse(CameraAuthorization.authorized.requiresSettingsChange)
        XCTAssertFalse(CameraAuthorization.notDetermined.requiresSettingsChange)
    }

    func testSettingsLinkIsOfferedOnlyForDenied() {
        // `restricted` is imposed by policy, so the Settings toggle is usually
        // absent or disabled and must not be presented as the fix.
        XCTAssertTrue(CameraAuthorization.denied.settingsLinkIsLikelyEffective)
        XCTAssertFalse(CameraAuthorization.restricted.settingsLinkIsLikelyEffective)
        XCTAssertFalse(CameraAuthorization.authorized.settingsLinkIsLikelyEffective)
        XCTAssertFalse(CameraAuthorization.notDetermined.settingsLinkIsLikelyEffective)
    }

    func testGuidanceIsProvidedExactlyWhenTheUserIsBlocked() {
        XCTAssertNil(CameraAuthorization.notDetermined.guidance)
        XCTAssertNil(CameraAuthorization.authorized.guidance)
        XCTAssertNotNil(CameraAuthorization.denied.guidance)
        XCTAssertNotNil(CameraAuthorization.restricted.guidance)
    }
}
