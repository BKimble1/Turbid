import SwiftUI
import XCTest
@testable import Turbid

/// The view model driving a scripted camera end to end.
@MainActor
final class CameraPipelineIntegrationTests: XCTestCase {

    private func makeViewModel(
        authorization: CameraAuthorization = .authorized,
        camera: StubCameraService = StubCameraService(),
        gravity: GravityProviding = AssumedPortraitGravityProvider()
    ) -> (MeasurementViewModel, StubCameraService) {
        let viewModel = MeasurementViewModel(
            environment: AppEnvironment(
                cameraAuthorization: StubCameraAuthorizationService(initialStatus: authorization),
                camera: camera,
                settingsOpener: StubSettingsOpener(),
                gravity: gravity,
                allowsSimulatedData: false
            ),
            // These stubs deliver no frames, so the run is meant to stall. A
            // short allowance keeps that from costing four seconds a test.
            stallAllowance: .milliseconds(200)
        )
        return (viewModel, camera)
    }

    // MARK: - Setup

    func testAuthorizedSetupPreparesAndStartsTheSessionThenWaitsForAlignment() async {
        let (viewModel, camera) = makeViewModel()

        await viewModel.startSetup()

        XCTAssertEqual(viewModel.state, .alignment)
        let calls = await camera.calls
        XCTAssertEqual(calls, [.prepare, .start, .torch(on: true)],
                       "the torch comes on for alignment: a dark preview cannot be lined up")
        XCTAssertEqual(camera.consumerLog.latest, true,
                       "the alignment monitor watches the preview")
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

    func testMeasurementIlluminatesBeforeLockingAndGivesUpWhenNoFramesArrive() async {
        let (viewModel, camera) = makeViewModel()
        await viewModel.startSetup()

        await viewModel.beginMeasurement()

        XCTAssertEqual(viewModel.state, .failed(.frameDeliveryStopped),
                       "a window that was never filled is not a shorter measurement")

        let calls = await camera.calls
        XCTAssertEqual(calls, [.prepare, .start, .torch(on: true),
                               .torch(on: true), .warmUp, .lockControls, .stop])

        guard let torchIndex = calls.firstIndex(of: .torch(on: true)),
              let warmUpIndex = calls.firstIndex(of: .warmUp) else {
            return XCTFail("the torch and warm-up calls are missing")
        }
        XCTAssertLessThan(torchIndex, warmUpIndex,
                          "controls must settle on the illuminated scene, not the ambient one")
        XCTAssertEqual(camera.consumerLog.latest, false,
                       "no consumer may stay attached to a finished run")
        XCTAssertGreaterThan(camera.timingResets.count, 0,
                             "frame statistics belong to the window, not to the alignment")
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

        XCTAssertEqual(viewModel.state, .failed(.frameDeliveryStopped))
        let calls = await camera.calls
        XCTAssertTrue(calls.contains(.lockControls))
    }

    // MARK: - Gravity

    /// Bubble rejection depends on how much of gravity lies in the image plane.
    /// Device motion takes a moment to produce its first sample, so it has to be
    /// running before the window starts, and it must not be left running after.
    func testGravityIsMeasuredWhileTheCameraIsOnAndStoppedWithIt() async {
        let gravity = SpyGravityProvider()
        let (viewModel, _) = makeViewModel(gravity: gravity)

        await viewModel.startSetup()
        XCTAssertEqual(gravity.starts, 1,
                       "gravity must be measured from alignment, not from the first frame")
        XCTAssertEqual(gravity.stops, 0)

        await viewModel.cancel()
        XCTAssertGreaterThanOrEqual(gravity.stops, 1,
                                    "device motion must not outlive the session")
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
        let viewModel = MeasurementViewModel(
            environment: AppEnvironment(
                cameraAuthorization: authorization,
                camera: camera,
                settingsOpener: StubSettingsOpener(),
                allowsSimulatedData: false
            ),
            stallAllowance: .milliseconds(200)
        )
        await viewModel.startSetup()
        XCTAssertEqual(viewModel.state, .alignment)

        await authorization.overrideStatus(.denied)
        await viewModel.refreshAuthorization()

        XCTAssertEqual(viewModel.state, .interrupted(.permissionRevoked))
        let calls = await camera.calls
        XCTAssertEqual(calls.last, .stop)
    }
}
