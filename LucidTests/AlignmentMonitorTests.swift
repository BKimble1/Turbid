import CoreGraphics
import XCTest
@testable import Lucid

/// The live feedback shown while a sample is being lined up.
///
/// It has to apply exactly the gates the analyzer applies, or the setup screen
/// would promise a measurement that is then rejected.
final class AlignmentMonitorTests: XCTestCase {

    private let frameRate: Double = 30

    /// The same clean scene `FrameAnalyzerTests` and
    /// `Tools/analysis_reference.py` use, so the numbers these tests rely on
    /// are the ones the reference has already checked.
    private var goodScene: SyntheticScene {
        SyntheticScene(
            baseLevel: 0.30,
            noiseSigma: 0.01,
            specks: (0..<12).map { index in
                SyntheticSpeck(center: CGPoint(x: 0.2 + Double(index % 4) * 0.2,
                                               y: 0.2 + Double(index / 4) * 0.25),
                               orbitRadius: 0.03,
                               angularSpeed: 0.6,
                               initialPhase: Double(index),
                               drift: .zero,
                               radiusPixels: 1.5,
                               brightness: 0.35)
            },
            seed: 2024
        )
    }

    /// The gates are what is under test here, not the region geometry, so the
    /// monitor looks at the whole frame — exactly the conditions the reference
    /// checks its thresholds under.
    private func makeMonitor() -> AlignmentMonitor {
        AlignmentMonitor(region: .fullFrame)
    }

    @discardableResult
    private func feed(_ monitor: AlignmentMonitor,
                      scene: SyntheticScene,
                      frames: Int,
                      startingAt start: Int = 0) -> AlignmentStatus {
        var status = AlignmentStatus.unknown
        for step in 0..<frames {
            let index = start + step
            let time = Double(index) / frameRate
            let frame = SyntheticFrameFactory.render(scene, atTime: time, frameIndex: index)
            status = monitor.inspect(luma: frame, presentationSeconds: time)
        }
        return status
    }

    func testAGoodViewPassesAndBecomesReadyOnlyAfterItHasHeldSteady() {
        let monitor = makeMonitor()
        monitor.start()

        let early = feed(monitor, scene: goodScene, frames: 3)
        XCTAssertTrue(early.passesGates)
        XCTAssertFalse(early.isReadyToMeasure,
                       "three good frames is a flicker, not a steady view")

        let later = feed(monitor, scene: goodScene, frames: 10, startingAt: 3)
        XCTAssertTrue(later.isReadyToMeasure)
        XCTAssertTrue(later.hints.isEmpty)
    }

    func testADarkViewSaysSoRatherThanSayingNothing() {
        let monitor = makeMonitor()
        monitor.start()

        let dark = SyntheticScene(width: 160, height: 120, baseLevel: 0.004,
                                  noiseSigma: 0.0005, seed: 4)
        let status = feed(monitor, scene: dark, frames: 5)

        XCTAssertFalse(status.passesGates)
        XCTAssertTrue(status.hints.contains { $0.reason == .regionTooDark },
                      "expected a darkness prompt, got \(status.hints.map(\.prompt))")
    }

    func testAMovingPhoneIsReportedWhileItIsStillFixable() {
        let monitor = makeMonitor()
        monitor.start()

        var moving = goodScene
        moving.globalTranslation = CGVector(dx: 0.35, dy: 0.25)
        let status = feed(monitor, scene: moving, frames: 6)

        XCTAssertFalse(status.passesGates)
        XCTAssertTrue(status.hints.contains { $0.reason == .cameraMoved },
                      "expected a steadiness prompt, got \(status.hints.map(\.prompt))")
    }

    func testASingleBadFrameResetsTheSteadyCount() {
        let monitor = makeMonitor()
        monitor.start()

        let steady = feed(monitor, scene: goodScene, frames: 12)
        XCTAssertTrue(steady.isReadyToMeasure)

        let dark = SyntheticScene(width: 160, height: 120, baseLevel: 0.004,
                                  noiseSigma: 0.0005, seed: 4)
        let interrupted = feed(monitor, scene: dark, frames: 1, startingAt: 12)

        XCTAssertEqual(interrupted.steadyFrames, 0)
        XCTAssertFalse(interrupted.isReadyToMeasure,
                       "readiness must not survive the view going bad")
    }

    func testAtMostTwoPromptsAreShownAtOnce() {
        let monitor = makeMonitor()
        monitor.start()

        // Dark, unfocused and moving all at once.
        var awful = SyntheticScene(width: 160, height: 120, baseLevel: 0.004,
                                   noiseSigma: 0.0005, seed: 9)
        awful.globalTranslation = CGVector(dx: 0.35, dy: 0.25)
        let status = feed(monitor, scene: awful, frames: 6)

        XCTAssertLessThanOrEqual(status.hints.count, 2,
                                 "a wall of warnings is not actionable")
        XCTAssertEqual(Set(status.hints.map(\.id)).count, status.hints.count,
                       "the same prompt must not appear twice")
    }

    func testStartingAgainForgetsTheLastAlignment() {
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertTrue(feed(monitor, scene: goodScene, frames: 12).isReadyToMeasure)

        monitor.start()

        XCTAssertEqual(monitor.status, .unknown,
                       "a new alignment must not inherit the previous one's readiness")
        XCTAssertFalse(monitor.status.isReadyToMeasure)
    }

    func testTheMonitorLooksAtTheAnalysisRegionByDefault() {
        // Whatever the analyzer will measure is what the setup screen must be
        // judging, or the advice is about the wrong pixels.
        XCTAssertEqual(AlignmentMonitor().region, .screeningDefault)
        XCTAssertEqual(AlignmentMonitor().region, FrameAnalyzer().region)
    }
}
