import XCTest

/// Setting up, measuring, and what a Screening Mode result says.
final class MeasurementFlowUITests: TurbidUITestCase {

    func testSetupOffersTheChecklistAndTheLiveViewBeforeCommitting() {
        let app = launch(scenario: "screening")

        app.buttons[UIID.Root.start].tap()

        XCTAssertTrue(app.otherElements[UIID.Setup.screen].waitForExistence(timeout: Self.uiTimeout),
                      "the setup step must come before the measurement")
        XCTAssertTrue(app.descendants(matching: .any)[UIID.Setup.checklist].exists,
                      "the checklist is how someone gets a usable reading")
        XCTAssertTrue(app.buttons[UIID.Setup.cancel].exists,
                      "there must always be a way to stop and turn the torch off")
    }

    func testMeasuringShowsProgressAndAGraphAndCanBeStopped() {
        let app = launch(scenario: "screening")

        app.buttons[UIID.Root.start].tap()
        XCTAssertTrue(app.buttons[UIID.Setup.begin].waitForExistence(timeout: Self.uiTimeout))
        app.buttons[UIID.Setup.begin].tap()

        let progress = app.descendants(matching: .any)[UIID.Measurement.progress]
        XCTAssertTrue(progress.waitForExistence(timeout: Self.uiTimeout),
                      "a run that gives no feedback is indistinguishable from a hang")
        XCTAssertTrue(app.descendants(matching: .any)[UIID.Measurement.stage].exists,
                      "the current stage must be named, not just a bar")

        let cancel = app.buttons[UIID.Measurement.cancel]
        XCTAssertTrue(cancel.exists, "a run must be stoppable at any point")
        cancel.tap()

        XCTAssertTrue(app.buttons[UIID.Root.start].waitForExistence(timeout: Self.uiTimeout),
                      "stopping must return to the home screen, not strand the user")
    }

    func testScreeningResultReportsClarityWithoutAnNTUValue() {
        let app = launch(scenario: "screening")
        measure(with: app)

        let headline = app.descendants(matching: .any)[UIID.Result.headline]
        XCTAssertTrue(headline.exists)
        XCTAssertTrue(headline.label.lowercased().contains("optical clarity"),
                      "the headline must describe optical clarity, got \(headline.label)")

        let ntu = value(of: UIID.Result.ntu, in: app)
        XCTAssertTrue(ntu.contains("Calibration required"),
                      "Screening Mode must never produce a number, got \(ntu)")

        XCTAssertTrue(app.descendants(matching: .any)[UIID.Result.index].exists,
                      "the relative index is what Screening Mode actually measured")

        let disclaimer = app.staticTexts[UIID.Result.disclaimer]
        XCTAssertTrue(disclaimer.exists, "every result carries the disclaimer")
        XCTAssertTrue(disclaimer.label.lowercased().contains("not a drinking-water safety test"))
    }

    func testTheDeepDiveShowsTheEvidenceBehindTheResult() {
        let app = launch(scenario: "screening")
        measure(with: app)

        app.buttons[UIID.Result.deepDive].tap()

        XCTAssertTrue(app.descendants(matching: .any)[UIID.DeepDive.qualitySection]
                        .waitForExistence(timeout: Self.uiTimeout),
                      "a result without its capture quality cannot be judged")
        XCTAssertTrue(app.descendants(matching: .any)[UIID.DeepDive.provenanceSection].exists,
                      "every result must name the versions that produced it")

        app.buttons[UIID.DeepDive.close].tap()
        XCTAssertTrue(app.descendants(matching: .any)[UIID.Result.headline]
                        .waitForExistence(timeout: Self.uiTimeout))
    }

    func testAnUnsteadyRunIsReportedAsUnusableRatherThanQuietlyAccepted() {
        let app = launch(scenario: "lowQuality")
        measure(with: app)

        let banner = app.descendants(matching: .any)[UIID.Result.lowQuality]
        XCTAssertTrue(banner.waitForExistence(timeout: Self.uiTimeout),
                      "a capture that failed the gates must say so on the result")
        XCTAssertTrue(app.staticTexts[UIID.Result.disclaimer].exists,
                      "a rejected result still carries the disclaimer")
    }
}
