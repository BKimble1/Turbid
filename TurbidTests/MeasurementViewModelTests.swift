import SwiftUI
import XCTest
@testable import Turbid

/// Permission behaviour. The camera pipeline itself is covered by
/// `CameraPipelineIntegrationTests`.
@MainActor
final class MeasurementViewModelTests: XCTestCase {

    private func makeViewModel(
        initialStatus: CameraAuthorization,
        statusAfterRequest: CameraAuthorization? = nil,
        allowsSimulatedData: Bool = false
    ) -> (MeasurementViewModel, StubCameraAuthorizationService, StubSettingsOpener) {
        let authorization = StubCameraAuthorizationService(
            initialStatus: initialStatus,
            statusAfterRequest: statusAfterRequest
        )
        let settings = StubSettingsOpener()
        let viewModel = MeasurementViewModel(environment: AppEnvironment(
            cameraAuthorization: authorization,
            camera: StubCameraService(),
            settingsOpener: settings,
            allowsSimulatedData: allowsSimulatedData
        ))
        return (viewModel, authorization, settings)
    }

    func testRefreshNeverRaisesTheSystemPrompt() async {
        let (viewModel, authorization, _) = makeViewModel(
            initialStatus: .notDetermined, statusAfterRequest: .authorized
        )

        await viewModel.refreshAuthorization()

        XCTAssertEqual(viewModel.authorization, .notDetermined)
        let count = await authorization.requestCount
        XCTAssertEqual(count, 0, "reading the status must never prompt")
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testUndecidedStatusPromptsOnceAndThenReachesAlignment() async {
        let (viewModel, authorization, _) = makeViewModel(
            initialStatus: .notDetermined, statusAfterRequest: .authorized
        )

        await viewModel.startSetup()

        XCTAssertEqual(viewModel.authorization, .authorized)
        let count = await authorization.requestCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(viewModel.state, .alignment)
    }

    func testDeniedStatusNeverPromptsAndLandsInPermissionDenied() async {
        let (viewModel, authorization, _) = makeViewModel(initialStatus: .denied)

        await viewModel.startSetup()

        XCTAssertEqual(viewModel.state, .permissionDenied)
        let count = await authorization.requestCount
        XCTAssertEqual(count, 0)
    }

    func testRestrictedStatusNeverPromptsAndLandsInPermissionRestricted() async {
        let (viewModel, authorization, _) = makeViewModel(initialStatus: .restricted)

        await viewModel.startSetup()

        XCTAssertEqual(viewModel.state, .permissionRestricted)
        let count = await authorization.requestCount
        XCTAssertEqual(count, 0)
    }

    func testRepeatedStartsDoNotRaiseThePromptASecondTime() async {
        let (viewModel, authorization, _) = makeViewModel(
            initialStatus: .notDetermined, statusAfterRequest: .denied
        )

        await viewModel.startSetup()
        await viewModel.startSetup()
        await viewModel.startSetup()

        let count = await authorization.requestCount
        XCTAssertEqual(count, 1, "the system prompt may only ever be raised once")
        XCTAssertEqual(viewModel.state, .permissionDenied)
    }

    func testOpenSettingsIsIgnoredUntilAccessIsActuallyBlocked() async {
        let (viewModel, _, settings) = makeViewModel(
            initialStatus: .notDetermined, statusAfterRequest: .authorized
        )

        viewModel.openSettings()
        XCTAssertEqual(settings.openCount, 0)

        await viewModel.startSetup()
        viewModel.openSettings()
        XCTAssertEqual(settings.openCount, 0, "authorized users have nothing to change")
    }

    func testOpenSettingsWorksOnceAccessIsDenied() async {
        let (viewModel, _, settings) = makeViewModel(initialStatus: .denied)

        await viewModel.refreshAuthorization()
        viewModel.openSettings()

        XCTAssertEqual(settings.openCount, 1)
    }

    func testSimulatedDataIsOffUnlessTheEnvironmentAllowsIt() {
        let (off, _, _) = makeViewModel(initialStatus: .authorized, allowsSimulatedData: false)
        XCTAssertFalse(off.allowsSimulatedData)

        let (on, _, _) = makeViewModel(initialStatus: .authorized, allowsSimulatedData: true)
        XCTAssertTrue(on.allowsSimulatedData)
    }

    func testLiveEnvironmentOnlyAllowsSimulatedDataOnADebugSimulatorBuild() {
        XCTAssertEqual(AppEnvironment.live().allowsSimulatedData,
                       RuntimeEnvironment.isSimulator && RuntimeEnvironment.isDebugBuild)
    }
}
