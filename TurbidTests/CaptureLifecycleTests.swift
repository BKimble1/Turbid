import XCTest
@testable import Turbid

/// Repeated start/stop must never add a second input, leave a torch on, or
/// deadlock. The lifecycle reducer is where that is guaranteed.
final class CaptureLifecycleTests: XCTestCase {

    func testTheNormalPathReachesRunning() {
        var machine = CaptureLifecycleMachine()
        XCTAssertTrue(machine.apply(.prepareRequested))
        XCTAssertEqual(machine.state, .preparing)
        XCTAssertTrue(machine.apply(.prepareSucceeded))
        XCTAssertEqual(machine.state, .prepared)
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertTrue(machine.apply(.startSucceeded))
        XCTAssertEqual(machine.state, .running)
    }

    func testPreparingTwiceIsRefused() {
        var machine = CaptureLifecycleMachine()
        machine.apply(.prepareRequested)
        machine.apply(.prepareSucceeded)

        XCTAssertFalse(machine.apply(.prepareRequested),
                       "a second prepare would add a duplicate input to the session")
        XCTAssertEqual(machine.state, .prepared)
    }

    func testPreparingWhileRunningIsRefused() {
        var machine = CaptureLifecycleMachine(state: .running)
        XCTAssertFalse(machine.apply(.prepareRequested))
        XCTAssertEqual(machine.state, .running)
    }

    func testStartingTwiceIsRefused() {
        var machine = CaptureLifecycleMachine(state: .prepared)
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertTrue(machine.apply(.startSucceeded))
        XCTAssertFalse(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .running)
    }

    func testStartingBeforePreparingIsRefused() {
        var machine = CaptureLifecycleMachine()
        XCTAssertFalse(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .idle)
    }

    func testStoppingIsLegalFromEveryStateThatOwnsHardware() {
        for state in [CaptureRunState.prepared, .starting, .running] {
            var machine = CaptureLifecycleMachine(state: state)
            XCTAssertTrue(machine.apply(.stopRequested), "stop refused from \(state)")
            XCTAssertEqual(machine.state, .stopping)
            XCTAssertTrue(machine.apply(.stopFinished))
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testStoppingWhenIdleIsAHarmlessNoOp() {
        var machine = CaptureLifecycleMachine()
        XCTAssertFalse(machine.apply(.stopRequested))
        XCTAssertEqual(machine.state, .idle)
    }

    func testStoppingTwiceDoesNotDoubleTearDown() {
        var machine = CaptureLifecycleMachine(state: .running)
        XCTAssertTrue(machine.apply(.stopRequested))
        XCTAssertFalse(machine.apply(.stopRequested))
        XCTAssertEqual(machine.state, .stopping)
    }

    func testFailureIsAcceptedFromAnyState() {
        let error = CameraError.sessionRuntimeError("media services reset")
        for state in [CaptureRunState.idle, .preparing, .prepared, .starting, .running, .stopping] {
            var machine = CaptureLifecycleMachine(state: state)
            XCTAssertTrue(machine.apply(.failed(error)))
            XCTAssertEqual(machine.state, .failed(error))
        }
    }

    func testTheSameFailureTwiceIsNotATransition() {
        let error = CameraError.torchUnavailable("too warm")
        var machine = CaptureLifecycleMachine(state: .failed(error))
        XCTAssertFalse(machine.apply(.failed(error)))
    }

    func testAFailedSessionCanBePreparedAgain() {
        var machine = CaptureLifecycleMachine(state: .failed(.sessionNotConfigured))
        XCTAssertTrue(machine.apply(.prepareRequested))
        XCTAssertEqual(machine.state, .preparing)
    }

    func testHoldsHardwareCoversExactlyTheStatesThatOwnTheSession() {
        XCTAssertFalse(CaptureRunState.idle.holdsHardware)
        XCTAssertFalse(CaptureRunState.preparing.holdsHardware)
        XCTAssertTrue(CaptureRunState.prepared.holdsHardware)
        XCTAssertTrue(CaptureRunState.starting.holdsHardware)
        XCTAssertTrue(CaptureRunState.running.holdsHardware)
        XCTAssertTrue(CaptureRunState.stopping.holdsHardware)
        XCTAssertFalse(CaptureRunState.failed(.sessionNotConfigured).holdsHardware)
    }
}
