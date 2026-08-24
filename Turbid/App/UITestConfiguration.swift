import Foundation

/// Launch-argument scenarios for the UI tests.
///
/// A UI test cannot tap through the system camera-permission alert, cannot
/// point a Simulator at a water sample, and cannot make a calibration exist.
/// So the tests ask for a starting state by launch argument, and this builds it.
///
/// Two locks keep it out of anything a person could reach:
///
/// 1. It is only consulted when `RuntimeEnvironment.allowsSimulatedData` is
///    `true`, which requires a debug build *and* the Simulator.
/// 2. It requires an explicit launch argument that nothing but the test harness
///    passes.
///
/// Everything it fabricates is labelled as simulated wherever it is shown.
enum UITestConfiguration {

    static let flag = "-turbid-uitest"
    private static let scenarioFlag = "-turbid-uitest-scenario"

    enum Scenario: String, CaseIterable, Sendable {
        /// Camera permission refused.
        case permissionDenied
        /// Nothing acknowledged yet: the disclosure is shown first.
        case firstLaunch
        /// Authorized, a clear sample, Screening Mode.
        case screening
        /// Authorized, a sample the quality gates reject.
        case lowQuality
        /// Calibrated Fixture Mode with a matching simulated calibration.
        case calibrated
        /// Calibrated Fixture Mode with a calibration for a different fixture.
        case incompatibleCalibration

        var sample: SimulatedSample {
            switch self {
            case .screening, .firstLaunch, .permissionDenied: return .lightlyLoaded
            case .lowQuality: return .unsteady
            case .calibrated, .incompatibleCalibration: return .heavilyLoaded
            }
        }

        var authorization: CameraAuthorization {
            self == .permissionDenied ? .denied : .authorized
        }

        var acknowledgesDisclosure: Bool { self != .firstLaunch }

        var mode: MeasurementMode {
            switch self {
            case .calibrated, .incompatibleCalibration: return .calibratedFixture
            default: return .screening
            }
        }
    }

    static var isActive: Bool {
        RuntimeEnvironment.allowsSimulatedData
            && ProcessInfo.processInfo.arguments.contains(flag)
    }

    static var scenario: Scenario {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: scenarioFlag),
              arguments.indices.contains(index + 1),
              let scenario = Scenario(rawValue: arguments[index + 1]) else {
            return .screening
        }
        return scenario
    }

    /// The environment for the requested scenario.
    ///
    /// Frames run twelve times faster than real time. Presentation timestamps
    /// advance at the true rate, so the analyzer sees exactly the sequence it
    /// would see on a device; only the wall clock is compressed, which turns a
    /// thirteen-second run into about one.
    static func environment(scenario: Scenario) -> AppEnvironment {
        let source = SimulatedFrameSource(sample: scenario.sample,
                                          frameRate: 30,
                                          timeScale: 12)
        let profiles = calibrationProfiles(for: scenario)

        return AppEnvironment(
            cameraAuthorization: StubCameraAuthorizationService(
                initialStatus: scenario.authorization
            ),
            camera: StubCameraService(summary: .simulatedFeed, frameSource: source),
            settingsOpener: StubSettingsOpener(),
            disclosure: InMemoryDisclosureRecorder(
                acknowledged: scenario.acknowledgesDisclosure
            ),
            calibrationStore: InMemoryCalibrationStore(profiles: profiles),
            // The default assumed-portrait gravity, not Core Motion: a
            // Simulator has no accelerometer, so measuring would fall back to
            // the assumption anyway, more slowly.
            makePipeline: { MeasurementPipeline() },
            initialMode: scenario.mode,
            allowsSimulatedData: true
        )
    }

    // MARK: - Fabricated calibrations

    private static func calibrationProfiles(for scenario: Scenario) -> [CalibrationProfile] {
        switch scenario {
        case .calibrated:
            return [simulatedProfile(matchingLiveSetup: true)]
        case .incompatibleCalibration:
            return [simulatedProfile(matchingLiveSetup: false)]
        default:
            return []
        }
    }

    /// A profile built from the same inputs a simulated run produces, so it
    /// either matches exactly or differs in exactly one named way.
    private static func simulatedProfile(matchingLiveSetup: Bool) -> CalibrationProfile {
        let fixture = FixtureDescription(
            fixtureIdentifier: matchingLiveSetup ? "simulated-fixture" : "some-other-fixture",
            fixtureGeometryVersion: 1,
            containerIdentifier: "simulated vial",
            fillVolumeMillilitres: 15,
            workingDistanceMillimetres: 45
        )
        let binding = CalibrationBindingBuilder.make(
            selection: .simulatedFeed,
            locked: .stub,
            torchLevel: 1.0,
            region: .screeningDefault,
            fixture: fixture,
            deviceModelIdentifier: CalibrationBindingBuilder.deviceModelIdentifier(),
            algorithmVersions: CalibrationBindingBuilder.algorithmVersions()
        )

        let knots = [
            MonotonicMapping.Knot(x: 0, y: 0),
            MonotonicMapping.Knot(x: 25, y: 1),
            MonotonicMapping.Knot(x: 60, y: 5),
            MonotonicMapping.Knot(x: 120, y: 10),
            MonotonicMapping.Knot(x: 260, y: 50)
        ]
        let mapping = MonotonicMapping.piecewiseLinear(knots: knots)

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return CalibrationProfile(
            id: UUID(uuidString: "00000000-0000-4000-8000-00000000C0DE") ?? UUID(),
            schemaVersion: CalibrationProfile.currentSchemaVersion,
            name: "SIMULATED CALIBRATION — NOT A REAL CALIBRATION",
            createdAt: created,
            // Far enough out that a test never trips the expiry path by accident.
            expiresAt: created.addingTimeInterval(60 * 60 * 24 * 3_650),
            binding: binding ?? fallbackBinding(fixture: fixture),
            mapping: mapping,
            uncertainty: UncertaintyModel(
                modelErrorNTU: 0.25,
                relativeMeasurementSpread: 0.04,
                standardToleranceNTU: 0.1,
                coverageFactor: 2,
                version: 1
            ),
            validation: CalibrationValidation(
                biasNTU: 0.01,
                meanAbsoluteErrorNTU: 0.18,
                rootMeanSquareErrorNTU: 0.25,
                maximumAbsoluteErrorNTU: 0.44,
                residualsNTU: [0.1, -0.2, 0.3, -0.44, 0.05],
                worstRelativeRepeatability: 0.04,
                heldOutLevels: 5
            ),
            validatedIndexRange: 0...260,
            validatedNTURange: 0...50,
            levels: []
        )
    }

    /// Only reachable if the summary's resolution text ever stops parsing.
    /// Present so the fabricated profile can never be built from a force
    /// unwrap, not because it is expected to run.
    private static func fallbackBinding(fixture: FixtureDescription) -> CalibrationBinding {
        CalibrationBinding(
            algorithmVersion: CalibrationBindingBuilder.algorithmVersions(),
            deviceModelIdentifier: CalibrationBindingBuilder.deviceModelIdentifier(),
            cameraUniqueID: CameraSelectionSummary.simulatedFeed.uniqueID,
            cameraDeviceType: CameraSelectionSummary.simulatedFeed.deviceType,
            captureWidth: 320,
            captureHeight: 240,
            pixelFormat: "420f",
            frameRate: 30,
            lensPosition: LockedCameraControls.stub.lensPosition,
            exposureSeconds: LockedCameraControls.stub.exposureSeconds,
            iso: LockedCameraControls.stub.iso,
            whiteBalanceGains: LockedCameraControls.stub.whiteBalanceGains,
            torchLevel: 1.0,
            analysisRegion: .screeningDefault,
            fixtureIdentifier: fixture.fixtureIdentifier,
            fixtureGeometryVersion: fixture.fixtureGeometryVersion,
            containerIdentifier: fixture.containerIdentifier,
            fillVolumeMillilitres: fixture.fillVolumeMillilitres,
            workingDistanceMillimetres: fixture.workingDistanceMillimetres
        )
    }
}
