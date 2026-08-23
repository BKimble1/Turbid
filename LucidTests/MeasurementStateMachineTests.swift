import XCTest
@testable import Lucid

final class MeasurementStateMachineTests: XCTestCase {

    // MARK: - Permission branch

    func testAuthorizedPathReachesPreparingCamera() {
        var machine = MeasurementStateMachine()
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .requestingPermission)
        XCTAssertTrue(machine.apply(.permissionResolved(.authorized)))
        XCTAssertEqual(machine.state, .preparingCamera)
    }

    func testDeniedAndRestrictedResolveToTheirOwnStates() {
        var denied = MeasurementStateMachine()
        denied.apply(.startRequested)
        denied.apply(.permissionResolved(.denied))
        XCTAssertEqual(denied.state, .permissionDenied)

        var restricted = MeasurementStateMachine()
        restricted.apply(.startRequested)
        restricted.apply(.permissionResolved(.restricted))
        XCTAssertEqual(restricted.state, .permissionRestricted)
    }

    func testDismissedPromptReturnsToIdle() {
        var machine = MeasurementStateMachine()
        machine.apply(.startRequested)
        machine.apply(.permissionResolved(.notDetermined))
        XCTAssertEqual(machine.state, .idle)
    }

    func testDeniedStateCanRetryPermission() {
        var machine = MeasurementStateMachine(state: .permissionDenied)
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .requestingPermission)
    }

    // MARK: - Happy path

    func testFullMeasurementPipeline() {
        var machine = MeasurementStateMachine()
        let script: [(MeasurementEvent, MeasurementState)] = [
            (.startRequested, .requestingPermission),
            (.permissionResolved(.authorized), .preparingCamera),
            (.cameraReady, .alignment),
            (.alignmentConfirmed, .warmingUp),
            (.warmUpCompleted, .lockingControls),
            (.controlsLocked, .acquiringBackground),
            (.backgroundAcquired, .measuring),
            (.measurementWindowCompleted, .calculating),
            (.calculationFinished, .result)
        ]

        for (event, expected) in script {
            XCTAssertTrue(machine.apply(event), "rejected \(event)")
            XCTAssertEqual(machine.state, expected)
        }
    }

    func testRepeatMeasurementReturnsToAlignmentNotStraightToMeasuring() {
        var machine = MeasurementStateMachine(state: .result)
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .alignment,
                       "the optical path must be re-confirmed before another window")
    }

    // MARK: - Illegal transitions

    func testOutOfOrderEventsAreRejectedAndLeaveStateUnchanged() {
        var machine = MeasurementStateMachine()
        XCTAssertFalse(machine.apply(.backgroundAcquired))
        XCTAssertFalse(machine.apply(.measurementWindowCompleted))
        XCTAssertFalse(machine.apply(.calculationFinished))
        XCTAssertFalse(machine.apply(.cameraReady))
        XCTAssertEqual(machine.state, .idle)
    }

    func testCancelAndResetAreNoOpsWhenAlreadyIdle() {
        var machine = MeasurementStateMachine()
        XCTAssertFalse(machine.apply(.cancelled))
        XCTAssertFalse(machine.apply(.reset))
        XCTAssertEqual(machine.state, .idle)
    }

    func testCancelFromAnyActiveStateReturnsToIdle() {
        let activeStates: [MeasurementState] = [
            .requestingPermission, .preparingCamera, .alignment, .warmingUp,
            .lockingControls, .acquiringBackground, .measuring, .calculating, .result
        ]

        for state in activeStates {
            var machine = MeasurementStateMachine(state: state)
            XCTAssertTrue(machine.apply(.cancelled), "cancel rejected from \(state)")
            XCTAssertEqual(machine.state, .idle)
        }
    }

    // MARK: - Interruption, thermal and quality

    func testInterruptionIsOnlyAcceptedWhileCaptureHardwareIsInUse() {
        var active = MeasurementStateMachine(state: .measuring)
        XCTAssertTrue(active.apply(.interrupted(.appBackgrounded)))
        XCTAssertEqual(active.state, .interrupted(.appBackgrounded))

        var idle = MeasurementStateMachine()
        XCTAssertFalse(idle.apply(.interrupted(.appBackgrounded)))
        XCTAssertEqual(idle.state, .idle)
    }

    func testInterruptionEndReturnsToAlignment() {
        var machine = MeasurementStateMachine(state: .interrupted(.sessionInterrupted))
        XCTAssertTrue(machine.apply(.interruptionEnded))
        XCTAssertEqual(machine.state, .alignment)
    }

    func testThermalLimitAppliesOnlyDuringCaptureAndRecoversToAlignment() {
        var machine = MeasurementStateMachine(state: .warmingUp)
        XCTAssertTrue(machine.apply(.thermalLimitReached))
        XCTAssertEqual(machine.state, .thermalLimited)
        XCTAssertTrue(machine.apply(.thermalRecovered))
        XCTAssertEqual(machine.state, .alignment)

        var result = MeasurementStateMachine(state: .result)
        XCTAssertFalse(result.apply(.thermalLimitReached))
    }

    func testQualityRejectionIsOnlyAcceptedWhileAnalysing() {
        let reasons = [MeasurementRejectionReason(rawValue: "test.reason")]

        var measuring = MeasurementStateMachine(state: .measuring)
        XCTAssertTrue(measuring.apply(.qualityFailed(reasons: reasons)))
        XCTAssertEqual(measuring.state, .lowQuality(reasons: reasons))

        var alignment = MeasurementStateMachine(state: .alignment)
        XCTAssertFalse(alignment.apply(.qualityFailed(reasons: reasons)),
                       "quality gates cannot reject a window that has not started")
    }

    func testLowQualityRestartsAtAlignment() {
        var machine = MeasurementStateMachine(state: .lowQuality(reasons: []))
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .alignment)
    }

    // MARK: - Hardware and failure

    func testUnsupportedHardwareCanBeReprobed() {
        var machine = MeasurementStateMachine(state: .preparingCamera)
        XCTAssertTrue(machine.apply(.cameraUnsupported(reason: "No torch")))
        XCTAssertEqual(machine.state, .unsupportedHardware(reason: "No torch"))
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .preparingCamera)
    }

    func testFailureIsAcceptedFromAnyStateButNotRepeatedIdentically() {
        var machine = MeasurementStateMachine(state: .measuring)
        XCTAssertTrue(machine.apply(.failed(.captureUnavailableInThisBuild)))
        XCTAssertEqual(machine.state, .failed(.captureUnavailableInThisBuild))
        XCTAssertFalse(machine.apply(.failed(.captureUnavailableInThisBuild)),
                       "re-applying the identical failure is not a transition")
    }

    func testFailureCanRestartTheWholeFlow() {
        var machine = MeasurementStateMachine(state: .failed(.captureUnavailableInThisBuild))
        XCTAssertTrue(machine.apply(.startRequested))
        XCTAssertEqual(machine.state, .requestingPermission)
    }

    // MARK: - Hardware predicate

    func testUsesCaptureHardwareCoversEveryLiveState() {
        let live: [MeasurementState] = [
            .preparingCamera, .alignment, .warmingUp, .lockingControls,
            .acquiringBackground, .measuring, .calculating
        ]
        for state in live {
            XCTAssertTrue(state.usesCaptureHardware, "\(state) must trigger torch/session teardown")
        }

        let inert: [MeasurementState] = [
            .idle, .requestingPermission, .permissionDenied, .permissionRestricted,
            .result, .lowQuality(reasons: []), .interrupted(.appBackgrounded),
            .thermalLimited, .unsupportedHardware(reason: "x"),
            .failed(.captureUnavailableInThisBuild)
        ]
        for state in inert {
            XCTAssertFalse(state.usesCaptureHardware, "\(state) must not claim live hardware")
        }
    }

    func testReducerIsPureAndDoesNotMutateItsInput() {
        let start = MeasurementState.measuring
        _ = MeasurementStateMachine.nextState(from: start, on: .measurementWindowCompleted)
        XCTAssertEqual(start, .measuring)
    }
}
