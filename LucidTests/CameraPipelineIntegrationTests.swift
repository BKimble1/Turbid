import SwiftUI
import XCTest
@testable import Lucid

/// The view model driving a scripted camera end to end.
@MainActor
final class CameraPipelineIntegrationTests: XCTestCase {

    private func makeViewModel(
        authorization: CameraAuthorization = .authorized,
        camera: StubCameraService = StubCameraService()
    ) -> (MeasurementViewModel, StubCameraService) {
        let viewModel = MeasurementViewModel(environment: AppEnvironment(
            cameraAuthorization: StubCameraAuthorizationService(initialStatus: authorization),
            camera: camera,
            settingsOpener: StubSettingsOpener(),
            allowsSimulatedData: false
        ))
        return (viewModel, camera)
    }

    // MARK: - Setup

    func testAuthorizedSetupPreparesAndStartsTheSessionThenWaitsForAlignment() async {
        let (viewModel, camera) = makeViewModel()

        await viewModel.startSetup()

        XCTAssertEqual(viewModel.state, .alignment)
        let calls = await camera.calls
        XCTAssertEqual(calls, [.prepare, .start])
    }

    func testDeniedSetupNeverTouchesTheCamera() async {
        let (viewModel, camera) = makeViewModel(authorization: .denied)

        await viewModel.startSetup()

        XCTAssertEqual(viewModel.state, .permissionDenied)
        let calls = await camera.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testNoSuitableCameraReportsUnsupportedHardware() async {
        let camera = StubCameraService(
            prepareError: .noSuitableCamera(reasons: ["Back Camera: no torch"])
        )
        let (viewModel, _) = makeViewModel(camera: camera)

        await viewModel.startSetup()

        XCTAssertEqual(viewModel.state, .unsupportedHardware(reason: "Back Camera: no torch"))
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop, "a failed preparation must still tear down")
    }

    func testAFailedStartSurfacesAsAFailureAndStops() async {
        let camera = StubCameraService(startError: .sessionRuntimeError("the session refused to start"))
        let (viewModel, _) = makeViewModel(camera: camera)

        await viewModel.startSetup()

        guard case .failed(let failure) = viewModel.state else {
            return XCTFail("expected a failure state, got \(viewModel.state)")
        }
        XCTAssertEqual(failure.code, .cameraUnavailable)
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
    }

    // MARK: - Measurement sequence

    func testMeasurementIlluminatesBeforeLockingAndStopsAtTheMissingAnalyzer() async {
        let (viewModel, camera) = makeViewModel()
        await viewModel.startSetup()

        await viewModel.beginMeasurement()

        XCTAssertEqual(viewModel.state, .failed(.analysisUnavailableInThisBuild),
                       "Phase 2 ends where background acquisition would begin")

        let calls = await camera.calls
        XCTAssertEqual(calls, [.prepare, .start, .torch(on: true), .warmUp, .lockControls, .stop])

        guard let torchIndex = calls.firstIndex(of: .torch(on: true)),
              let warmUpIndex = calls.firstIndex(of: .warmUp) else {
            return XCTFail("the torch and warm-up calls are missing")
        }
        XCTAssertLessThan(torchIndex, warmUpIndex,
                          "controls must settle on the illuminated scene, not the ambient one")
    }

    func testMeasurementCannotStartBeforeAlignment() async {
        let (viewModel, camera) = makeViewModel()

        await viewModel.beginMeasurement()

        XCTAssertEqual(viewModel.state, .idle)
        let calls = await camera.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAFailedControlLockStopsTheSessionAndTurnsTheTorchOff() async {
        let camera = StubCameraService(lockError: .controlLockFailed("the camera did not stay locked"))
        let (viewModel, _) = makeViewModel(camera: camera)
        await viewModel.startSetup()

        await viewModel.beginMeasurement()

        guard case .failed(let failure) = viewModel.state else {
            return XCTFail("expected a failure state, got \(viewModel.state)")
        }
        XCTAssertEqual(failure.code, .cameraUnavailable)

        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
        let snapshot = await camera.currentSnapshot()
        XCTAssertFalse(snapshot.torch.isActive)
    }

    func testAnUnavailableTorchFailsBeforeAnythingIsLocked() async {
        let camera = StubCameraService(torchError: .torchUnavailable("the iPhone is too warm"))
        let (viewModel, _) = makeViewModel(camera: camera)
        await viewModel.startSetup()

        await viewModel.beginMeasurement()

        let calls = await camera.calls
        XCTAssertFalse(calls.contains(.lockControls),
                       "there is no point locking controls that will not be illuminated")
        XCTAssertEqual(calls.last, .stop)
    }

    func testATorchBelowTheRequestedLevelStillCompletesButIsRecorded() async {
        // Under thermal duress maxAvailableTorchLevel drops below 1.0.
        let camera = StubCameraService(torchLevel: 0.6)
        let (viewModel, _) = makeViewModel(camera: camera)
        await viewModel.startSetup()

        await viewModel.beginMeasurement()

        XCTAssertEqual(viewModel.state, .failed(.analysisUnavailableInThisBuild))
        let calls = await camera.calls
        XCTAssertTrue(calls.contains(.lockControls))
    }

    // MARK: - Teardown

    func testCancellingStopsTheSessionAndReturnsToIdle() async {
        let (viewModel, camera) = makeViewModel()
        await viewModel.startSetup()

        await viewModel.cancel()

        XCTAssertEqual(viewModel.state, .idle)
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
    }

    func testCancellingTwiceIsSafe() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.startSetup()

        await viewModel.cancel()
        await viewModel.cancel()

        XCTAssertEqual(viewModel.state, .idle)
    }

    func testRevokedPermissionInterruptsALiveSessionAndStops() async {
        let authorization = StubCameraAuthorizationService(initialStatus: .authorized)
        let camera = StubCameraService()
        let viewModel = MeasurementViewModel(environment: AppEnvironment(
            cameraAuthorization: authorization,
            camera: camera,
            settingsOpener: StubSettingsOpener(),
            allowsSimulatedData: false
        ))
        await viewModel.startSetup()
        XCTAssertEqual(viewModel.state, .alignment)

        await authorization.overrideStatus(.denied)
        await viewModel.refreshAuthorization()

        XCTAssertEqual(viewModel.state, .interrupted(.permissionRevoked))
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
    }
}
