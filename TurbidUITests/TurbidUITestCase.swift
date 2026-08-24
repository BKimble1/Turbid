import XCTest

/// Shared plumbing for the interface tests.
///
/// Every test launches the app into a named scenario. A UI test cannot answer
/// the system camera prompt, cannot point a Simulator at a water sample and
/// cannot conjure a calibration, so the app builds the starting state from a
/// launch argument. That path is only compiled into a debug build and only
/// taken on the Simulator.
class TurbidUITestCase: XCTestCase {

    /// Generous on purpose. A measurement run is a real analysis of real
    /// synthetic frames, and the Simulator is slow at it. A short timeout here
    /// would fail the build for being slow rather than for being wrong.
    static let runTimeout: TimeInterval = 180
    static let uiTimeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-turbid-uitest", "-turbid-uitest-scenario", scenario]
        app.launch()
        return app
    }

    /// Runs one whole measurement, from the home screen to the result screen.
    func measure(with app: XCUIApplication,
                 file: StaticString = #filePath,
                 line: UInt = #line) {
        let start = app.buttons[UIID.Root.start]
        XCTAssertTrue(start.waitForExistence(timeout: Self.uiTimeout),
                      "the home screen never offered a way to start", file: file, line: line)
        start.tap()

        let begin = app.buttons[UIID.Setup.begin]
        XCTAssertTrue(begin.waitForExistence(timeout: Self.uiTimeout),
                      "the setup step never appeared", file: file, line: line)
        begin.tap()

        let result = app.otherElements[UIID.Result.screen]
        XCTAssertTrue(result.waitForExistence(timeout: Self.runTimeout),
                      "the run never produced a result", file: file, line: line)
    }

    /// The value a `MetricRow` is showing, read from its combined label.
    func value(of identifier: String, in app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)[identifier]
        guard element.waitForExistence(timeout: Self.uiTimeout) else { return "" }
        return element.label
    }
}
