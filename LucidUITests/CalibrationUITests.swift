import XCTest

/// What Calibrated Fixture Mode shows when a calibration applies, and when it
/// does not.
final class CalibrationUITests: LucidUITestCase {

    func testAMatchingCalibrationProducesAnNTUEstimateWithAnUncertainty() {
        let app = launch(scenario: "calibrated")
        measure(with: app)

        let ntu = value(of: UIID.Result.ntu, in: app)
        XCTAssertTrue(ntu.contains("NTU"),
                      "a matching calibration must produce a number, got \(ntu)")
        XCTAssertTrue(ntu.contains("±"),
                      "an estimate without an uncertainty is not a measurement, got \(ntu)")
    }

    func testAnIncompatibleCalibrationWithholdsNTUAndSaysWhy() {
        let app = launch(scenario: "incompatibleCalibration")
        measure(with: app)

        let ntu = value(of: UIID.Result.ntu, in: app)
        XCTAssertFalse(ntu.contains("±"),
                       "no number may be shown for a setup the calibration does not describe")
        XCTAssertTrue(ntu.lowercased().contains("does not match"),
                      "the reason must be stated, got \(ntu)")
    }

    func testTheCalibrationScreenLeadsWithSafetyAndNeverExplainsHowToMakeAStandard() {
        let app = launch(scenario: "screening")

        XCTAssertTrue(app.buttons[UIID.Root.calibrationLink].waitForExistence(timeout: Self.uiTimeout))
        app.buttons[UIID.Root.calibrationLink].tap()

        let notice = app.descendants(matching: .any)[UIID.Calibration.safetyNotice]
        XCTAssertTrue(notice.waitForExistence(timeout: Self.uiTimeout),
                      "the safety notice must be the first thing on the calibration screen")

        let text = notice.label.lowercased()
        XCTAssertTrue(text.contains("certified"),
                      "the notice must require certified standards")
        XCTAssertTrue(text.contains("never attempt to prepare"),
                      "the notice must forbid preparing formazin")

        XCTAssertTrue(app.descendants(matching: .any)[UIID.Calibration.requirements].exists,
                      "what a calibration needs must be stated before one is started")
        XCTAssertTrue(app.buttons[UIID.Calibration.startRun].exists)
    }
}
