import XCTest

/// The two states someone can be in before any measurement is possible.
final class PermissionAndOnboardingUITests: TurbidUITestCase {

    func testDeniedCameraAccessExplainsItselfAndOffersSettings() {
        let app = launch(scenario: "permissionDenied")

        XCTAssertTrue(app.otherElements[UIID.Root.screen].waitForExistence(timeout: Self.uiTimeout))

        let status = app.descendants(matching: .any)[UIID.Root.permissionStatus]
        XCTAssertTrue(status.waitForExistence(timeout: Self.uiTimeout),
                      "the permission state must be visible without hunting for it")
        XCTAssertTrue(status.label.lowercased().contains("denied"),
                      "expected the denied state, got \(status.label)")

        XCTAssertTrue(app.buttons[UIID.Root.openSettings].exists,
                      "a denied user needs a way into Settings")

        // Starting must not silently do nothing: with no camera there is
        // nothing to align, so the capture screen must never appear.
        app.buttons[UIID.Root.start].tap()
        XCTAssertFalse(app.buttons[UIID.Setup.begin].waitForExistence(timeout: 3),
                       "the capture screen must not open without camera access")
    }

    func testFirstLaunchShowsTheDisclosureBeforeAnythingElse() {
        let app = launch(scenario: "firstLaunch")

        let onboarding = app.otherElements[UIID.Onboarding.screen]
        XCTAssertTrue(onboarding.waitForExistence(timeout: Self.uiTimeout),
                      "the disclosure must be the first thing shown")

        let acknowledgement = app.staticTexts[UIID.Onboarding.acknowledge]
        XCTAssertTrue(acknowledgement.exists,
                      "the acknowledgement text must be present, not implied")
        XCTAssertTrue(acknowledgement.label.lowercased().contains("safe to drink"),
                      "the acknowledgement must name the thing Turbid does not do")

        // Nothing behind it is reachable until it is acknowledged.
        XCTAssertFalse(app.buttons[UIID.Root.start].isHittable)

        let button = app.buttons[UIID.Onboarding.continueButton]
        XCTAssertTrue(button.exists)
        button.tap()

        XCTAssertTrue(app.buttons[UIID.Root.start].waitForExistence(timeout: Self.uiTimeout),
                      "acknowledging the disclosure must lead to the home screen")
    }
}
