import SwiftUI
import XCTest
@testable import Lucid

/// The torch must never survive leaving the foreground, an error, or a
/// cancellation. These tests pin that down at both the reducer level and the
/// view-model level.
@MainActor
final class CaptureHardwareTeardownTests: XCTestCase {

    private func makeViewModel() -> (MeasurementViewModel, StubCameraService) {
        let camera = StubCameraService()
        let viewModel = MeasurementViewModel(environment: AppEnvironment(
            cameraAuthorization: StubCameraAuthorizationService(initialStatus: .authorized),
            camera: camera,
            settingsOpener: StubSettingsOpener(),
            allowsSimulatedData: false
        ))
        return (viewModel, camera)
    }

    func testEveryLiveStateIsInterruptibleSoTheTorchCanBeTurnedOff() {
        let live: [MeasurementState] = [
            .preparingCamera, .alignment, .warmingUp, .lockingControls,
            .acquiringBackground, .measuring, .calculating
        ]

        for state in live {
            var machine = MeasurementStateMachine(state: state)
            XCTAssertTrue(machine.apply(.interrupted(.appBackgrounded)),
                          "\(state) must be interruptible so the torch can be turned off")
            XCTAssertEqual(machine.state, .interrupted(.appBackgrounded))
            XCTAssertFalse(machine.state.usesCaptureHardware,
                           "after interruption no hardware may be considered live")
        }
    }

    func testBackgroundingALiveSessionStopsTheCamera() async {
        let (viewModel, camera) = makeViewModel()
        await viewModel.startSetup()
        XCTAssertEqual(viewModel.state, .alignment)

        await viewModel.handleScenePhaseChange(.background)

        XCTAssertEqual(viewModel.state, .interrupted(.appBackgrounded))
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
        let snapshot = await camera.currentSnapshot()
        XCTAssertFalse(snapshot.torch.isActive)
    }

    func testGoingInactiveIsTreatedTheSameAsBackgrounding() async {
        let (viewModel, camera) = makeViewModel()
        await viewModel.startSetup()

        await viewModel.handleScenePhaseChange(.inactive)

        XCTAssertEqual(viewModel.state, .interrupted(.appBackgrounded))
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
    }

    func testBackgroundingWhileIdleChangesNothing() async {
        let (viewModel, camera) = makeViewModel()

        await viewModel.handleScenePhaseChange(.background)

        XCTAssertEqual(viewModel.state, .idle)
        let calls = await camera.calls
        XCTAssertTrue(calls.isEmpty, "there is no hardware to tear down")
    }

    func testReturningToForegroundRefreshesAuthorizationWithoutPrompting() async {
        let authorization = StubCameraAuthorizationService(
            initialStatus: .notDetermined, statusAfterRequest: .authorized
        )
        let viewModel = MeasurementViewModel(environment: AppEnvironment(
            cameraAuthorization: authorization,
            camera: StubCameraService(),
            settingsOpener: StubSettingsOpener(),
            allowsSimulatedData: false
        ))

        await viewModel.handleScenePhaseChange(.active)

        let count = await authorization.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(viewModel.hasCheckedAuthorization)
    }

    func testInterruptingMidMeasurementStopsTheCamera() async {
        let (viewModel, camera) = makeViewModel()
        await viewModel.startSetup()

        await viewModel.interruptCapture(reason: .sessionInterrupted)

        XCTAssertEqual(viewModel.state, .interrupted(.sessionInterrupted))
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
    }
}
