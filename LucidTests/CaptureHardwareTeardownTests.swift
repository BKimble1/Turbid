import SwiftUI
import XCTest
@testable import Lucid

/// The scene-phase hook is the single place Phase 2 will stop the capture
/// session and turn the torch off, so its state handling is pinned down now.
@MainActor
final class CaptureHardwareTeardownTests: XCTestCase {

    private func makeViewModel() -> MeasurementViewModel {
        MeasurementViewModel(environment: AppEnvironment(
            cameraAuthorization: StubCameraAuthorizationService(initialStatus: .authorized),
            settingsOpener: StubSettingsOpener(),
            allowsSimulatedData: false
        ))
    }

    func testEveryLiveStateIsInterruptedByLeavingFullScreen() {
        // Exercised through the reducer because Phase 1 cannot reach these
        // states without a capture pipeline.
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

    func testInactiveSceneIsTreatedTheSameAsBackground() {
        let viewModel = makeViewModel()
        // Idle holds no hardware, so neither phase may change the state.
        viewModel.handleScenePhaseChange(.inactive)
        XCTAssertEqual(viewModel.state, .idle)
        viewModel.handleScenePhaseChange(.background)
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testReturningToForegroundRefreshesAuthorizationWithoutPrompting() async {
        let authorization = StubCameraAuthorizationService(
            initialStatus: .notDetermined, statusAfterRequest: .authorized
        )
        let viewModel = MeasurementViewModel(environment: AppEnvironment(
            cameraAuthorization: authorization,
            settingsOpener: StubSettingsOpener(),
            allowsSimulatedData: false
        ))

        viewModel.handleScenePhaseChange(.active)
        // Let the refresh task started by the hook complete.
        await Task.yield()
        await viewModel.refreshAuthorization()

        let count = await authorization.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(viewModel.hasCheckedAuthorization)
    }
}
