import XCTest
@testable import Lucid

/// The fingerprint of the instrument a measurement was taken with.
final class CalibrationBindingBuilderTests: XCTestCase {

    private func make(selection: CameraSelectionSummary? = .stubUltraWide,
                      locked: LockedCameraControls? = .stub,
                      torchLevel: Float = 1.0,
                      fixture: FixtureDescription = .none) -> CalibrationBinding? {
        CalibrationBindingBuilder.make(
            selection: selection,
            locked: locked,
            torchLevel: torchLevel,
            region: .screeningDefault,
            fixture: fixture,
            deviceModelIdentifier: "iPhone16,1",
            algorithmVersions: CalibrationBindingBuilder.algorithmVersions()
        )
    }

    // MARK: - Refusals

    func testNoBindingWithoutACameraOrLockedControls() {
        XCTAssertNil(make(selection: nil),
                     "a fingerprint with no camera in it describes nothing")
        XCTAssertNil(make(locked: nil),
                     "unlocked controls are not a setting a calibration can be tied to")
    }

    func testAnUnreadableResolutionProducesNoBindingRatherThanAGuess() {
        var broken = CameraSelectionSummary.stubUltraWide
        broken = CameraSelectionSummary(
            cameraName: broken.cameraName, deviceType: broken.deviceType,
            uniqueID: broken.uniqueID, isVirtualDevice: broken.isVirtualDevice,
            minimumFocusDistanceMillimetres: broken.minimumFocusDistanceMillimetres,
            resolution: "unknown", pixelFormat: broken.pixelFormat,
            frameRate: broken.frameRate, rationale: broken.rationale,
            warnings: broken.warnings, rejectedCameras: broken.rejectedCameras
        )

        XCTAssertNil(make(selection: broken))
    }

    // MARK: - Contents

    func testTheBindingCarriesEverythingTheCaptureWasFixedBy() {
        guard let binding = make(fixture: FixtureDescription(
            fixtureIdentifier: "shroud-v2",
            fixtureGeometryVersion: 2,
            containerIdentifier: "vial-20ml",
            fillVolumeMillilitres: 15,
            workingDistanceMillimetres: 45
        )) else {
            return XCTFail("a complete setup must produce a binding")
        }

        XCTAssertEqual(binding.captureWidth, 1920)
        XCTAssertEqual(binding.captureHeight, 1080)
        XCTAssertEqual(binding.pixelFormat, "420f")
        XCTAssertEqual(binding.cameraUniqueID, "stub-ultra-wide")
        XCTAssertEqual(binding.lensPosition, LockedCameraControls.stub.lensPosition)
        XCTAssertEqual(binding.torchLevel, 1.0)
        XCTAssertEqual(binding.analysisRegion, .screeningDefault)
        XCTAssertEqual(binding.fixtureIdentifier, "shroud-v2")
        XCTAssertEqual(binding.workingDistanceMillimetres, 45)
        XCTAssertEqual(binding.deviceModelIdentifier, "iPhone16,1")
    }

    func testTheSameSetupTwiceProducesTheSameFingerprint() {
        XCTAssertEqual(make(), make())
    }

    func testTorchOutputThatDroppedUnderThermalLoadIsNotTheSameInstrument() {
        guard let full = make(torchLevel: 1.0), let reduced = make(torchLevel: 0.8) else {
            return XCTFail("both bindings must be buildable")
        }

        let mismatches = CalibrationCompatibility.mismatches(live: reduced, calibrated: full)
        XCTAssertTrue(mismatches.contains { $0.contains("torch level") },
                      "a calibration made at full output does not describe a dimmer one")
    }

    // MARK: - Algorithm versions

    func testEveryVersionIsReadFromTheConfigurationThatWillActuallyRun() {
        let versions = CalibrationBindingBuilder.algorithmVersions()

        XCTAssertEqual(versions.captureProtocol, CaptureProtocol.screening.version)
        XCTAssertEqual(versions.qualityThresholds, QualityThresholds.screening.version)
        XCTAssertEqual(versions.detector, SpeckDetector.Configuration.screening.version)
        XCTAssertEqual(versions.bandPass, SpeckDetector.Configuration.screening.bandPass.version)
        XCTAssertEqual(versions.backgroundModel,
                       SpeckDetector.Configuration.screening.background.version)
        XCTAssertEqual(versions.tracker, MultiObjectTracker.Configuration.screening.version)
        XCTAssertEqual(versions.classifier, TrackClassifier.Configuration.screening.version)
        XCTAssertEqual(versions.aggregation,
                       ScatteringWindowAggregator.Configuration.screening.version)
        XCTAssertEqual(versions.indexWeights, RelativeScatteringIndex.Weights.screening.version)
    }

    func testAChangedProtocolChangesTheFingerprintAndInvalidatesOldCalibrations() {
        var newer = CaptureProtocol.screening
        newer.version += 1

        let before = CalibrationBindingBuilder.algorithmVersions()
        let after = CalibrationBindingBuilder.algorithmVersions(captureProtocol: newer)

        XCTAssertNotEqual(before, after)

        guard let live = make(),
              let calibrated = CalibrationBindingBuilder.make(
                selection: .stubUltraWide, locked: .stub, torchLevel: 1.0,
                region: .screeningDefault, fixture: .none,
                deviceModelIdentifier: "iPhone16,1", algorithmVersions: after) else {
            return XCTFail("both bindings must be buildable")
        }

        let mismatches = CalibrationCompatibility.mismatches(live: live, calibrated: calibrated)
        XCTAssertTrue(mismatches.contains { $0.contains("analysis version") },
                      "a changed algorithm must invalidate the calibration it was fitted under")
    }

    func testTheDeviceModelComesFromTheKernelAndIsNeverEmpty() {
        let identifier = CalibrationBindingBuilder.deviceModelIdentifier()
        XCTAssertFalse(identifier.isEmpty)
        XCTAssertFalse(identifier.contains("\0"),
                       "the machine string must be trimmed at its terminator")
    }

    // MARK: - Fixtures

    func testAScreeningRunDeclaresNoFixtureRatherThanInventingOne() {
        XCTAssertFalse(FixtureDescription.none.isCalibratable)
        XCTAssertEqual(FixtureDescription.none.fixtureIdentifier, "none")
        XCTAssertEqual(FixtureDescription.none.workingDistanceMillimetres, 0)
    }
}
