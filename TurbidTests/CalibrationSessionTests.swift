import XCTest
@testable import Turbid

/// The guided calibration workflow: the rules it enforces before a curve is
/// allowed to exist.
@MainActor
final class CalibrationSessionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSession() -> (CalibrationSessionViewModel, MeasurementViewModel) {
        let environment = AppEnvironment(
            cameraAuthorization: StubCameraAuthorizationService(initialStatus: .authorized),
            camera: StubCameraService(),
            settingsOpener: StubSettingsOpener(),
            allowsSimulatedData: false
        )
        let measurement = MeasurementViewModel(environment: environment,
                                               stallAllowance: .milliseconds(200))
        let now = self.now
        let session = CalibrationSessionViewModel(measurement: measurement,
                                                  library: measurement.calibrations,
                                                  now: { now })
        return (session, measurement)
    }

    private func describeSetup(_ session: CalibrationSessionViewModel) {
        session.setup = CalibrationSessionViewModel.SetupDraft(
            fixtureIdentifier: "shroud-v2",
            containerIdentifier: "vial-20ml",
            fillVolumeMillilitres: "15",
            workingDistanceMillimetres: "45"
        )
        session.confirmSetup()
    }

    private func addStandard(_ session: CalibrationSessionViewModel,
                             ntu: Double) -> String? {
        session.draft = CalibrationSessionViewModel.StandardDraft(
            nominalNTU: String(ntu),
            toleranceNTU: "0.05",
            manufacturer: "Certified Standards Ltd",
            lotNumber: "LOT-\(Int(ntu * 100))",
            expiryDate: now.addingTimeInterval(365 * 86_400)
        )
        return session.addDraftStandard()
    }

    // MARK: - The setup

    func testACalibrationCannotStartWithoutTheFixtureBeingDescribed() {
        let (session, measurement) = makeSession()

        session.confirmSetup()

        XCTAssertEqual(session.stage, .describeSetup)
        XCTAssertNotNil(session.problem)
        XCTAssertNil(measurement.fixtureOverride,
                     "an undescribed fixture must not reach a measurement")
    }

    func testDescribingTheSetupPutsItInForceForEveryReading() {
        let (session, measurement) = makeSession()

        describeSetup(session)

        XCTAssertEqual(session.stage, .enterStandards)
        XCTAssertEqual(measurement.fixtureOverride?.fixtureIdentifier, "shroud-v2")
        XCTAssertEqual(measurement.fixtureOverride?.workingDistanceMillimetres, 45)
        XCTAssertTrue(measurement.fixture.isCalibratable)
    }

    func testAbandoningTheFlowClearsTheFixtureItPutInForce() {
        let (session, measurement) = makeSession()
        describeSetup(session)

        session.abandon()

        XCTAssertNil(measurement.fixtureOverride)
        XCTAssertEqual(measurement.fixture, .none)
    }

    // MARK: - The standards

    func testAnExpiredStandardIsRefusedWithTheReason() {
        let (session, _) = makeSession()
        describeSetup(session)

        session.draft = CalibrationSessionViewModel.StandardDraft(
            nominalNTU: "5", toleranceNTU: "0.05",
            manufacturer: "Certified Standards Ltd", lotNumber: "LOT-1",
            expiryDate: now.addingTimeInterval(-86_400)
        )
        let refusal = session.addDraftStandard()

        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("expired") == true, refusal ?? "")
        XCTAssertTrue(session.standards.isEmpty)
    }

    func testAStandardWithNoCertificateDetailsIsRefused() {
        let (session, _) = makeSession()
        describeSetup(session)

        session.draft = CalibrationSessionViewModel.StandardDraft(
            nominalNTU: "5", toleranceNTU: "0.05",
            manufacturer: "  ", lotNumber: "",
            expiryDate: now.addingTimeInterval(86_400)
        )

        XCTAssertNotNil(session.addDraftStandard(),
                        "a standard with no lot number cannot be audited")
    }

    func testTheSameValueCannotBeEnteredTwice() {
        let (session, _) = makeSession()
        describeSetup(session)

        XCTAssertNil(addStandard(session, ntu: 5))
        XCTAssertNotNil(addStandard(session, ntu: 5))
        XCTAssertEqual(session.standards.count, 1)
    }

    func testStandardsAreKeptInAscendingOrderWhateverOrderTheyWereEntered() {
        let (session, _) = makeSession()
        describeSetup(session)

        for value in [10.0, 0.0, 5.0, 1.0] {
            XCTAssertNil(addStandard(session, ntu: value))
        }

        XCTAssertEqual(session.standards.map(\.nominalNTU), [0, 1, 5, 10])
    }

    func testWhatIsStillMissingIsSaidBeforeAnyMeasuringStarts() {
        let (session, _) = makeSession()
        describeSetup(session)
        XCTAssertNil(addStandard(session, ntu: 1))

        let problems = session.outstandingProblems
        XCTAssertTrue(problems.contains(.noBlank),
                      "a calibration with no blank has no zero point")
        XCTAssertTrue(problems.contains(.tooFewNonZeroStandards))

        session.beginCapture()
        XCTAssertEqual(session.stage, .enterStandards,
                       "measuring must not start on a set that cannot be fitted")
    }

    // MARK: - Recording readings

    private func prepareForCapture(_ session: CalibrationSessionViewModel) {
        describeSetup(session)
        for value in [0.0, 1.0, 5.0, 10.0, 20.0] {
            XCTAssertNil(addStandard(session, ntu: value))
        }
        session.beginCapture()
    }

    func testCaptureStartsAtTheLowestStandard() {
        let (session, _) = makeSession()
        prepareForCapture(session)

        XCTAssertEqual(session.stage, .capture)
        XCTAssertEqual(session.activeStandard?.nominalNTU, 0)
        XCTAssertEqual(session.estimatedRunCount, 15)
    }

    func testACaptureThatFailedTheGatesCannotEnterACalibration() {
        let (session, _) = makeSession()
        prepareForCapture(session)

        let refusal = session.record(reading: CalibrationFactory.reading(usable: false),
                                     binding: CalibrationFactory.binding())

        XCTAssertNotNil(refusal)
        XCTAssertTrue(session.replicates.isEmpty,
                      "a curve fitted partly to rejected captures is not a calibration")
    }

    func testAReadingWithNoKnownCaptureSettingsIsRefused() {
        let (session, _) = makeSession()
        prepareForCapture(session)

        XCTAssertNotNil(session.record(reading: CalibrationFactory.reading(), binding: nil))
        XCTAssertTrue(session.replicates.isEmpty)
    }

    func testASetupThatChangedPartWayThroughStopsTheCalibration() {
        let (session, _) = makeSession()
        prepareForCapture(session)

        XCTAssertNil(session.record(reading: CalibrationFactory.reading(),
                                    binding: CalibrationFactory.binding(fixture: "shroud-v2")))

        let refusal = session.record(reading: CalibrationFactory.reading(),
                                     binding: CalibrationFactory.binding(fixture: "other"))

        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("setup changed") == true, refusal ?? "")
        XCTAssertEqual(session.replicates.count, 1,
                       "a reading taken on a different setup must not be averaged in")
    }

    func testALevelIsOnlyCompleteOnceItHasEnoughReplicates() {
        let (session, _) = makeSession()
        prepareForCapture(session)
        guard let blank = session.activeStandard else { return XCTFail("no active standard") }

        for _ in 0..<2 {
            XCTAssertNil(session.record(reading: CalibrationFactory.reading(),
                                        binding: CalibrationFactory.binding()))
        }
        XCTAssertEqual(session.replicateCount(for: blank), 2)
        XCTAssertFalse(session.activeStandardIsComplete)

        XCTAssertNil(session.record(reading: CalibrationFactory.reading(),
                                    binding: CalibrationFactory.binding()))
        XCTAssertTrue(session.activeStandardIsComplete)
        XCTAssertFalse(session.allStandardsComplete)
    }

    // MARK: - Fitting and saving

    /// Records the replicates a whole calibration needs, with indices that rise
    /// with turbidity the way a real set does.
    private func recordEverything(_ session: CalibrationSessionViewModel) {
        let residuals: [Double: Double] = [0: 0.002, 1: 0.022, 5: 0.092,
                                           10: 0.160, 20: 0.265]
        for standard in session.standards {
            session.selectStandard(standard)
            let residual = residuals[standard.nominalNTU] ?? 0.01
            for replicate in 0..<3 {
                // A small, deterministic spread, so the level has a measurable
                // repeatability rather than a suspiciously perfect one.
                let jitter = 1 + (Double(replicate) - 1) * 0.01
                XCTAssertNil(session.record(
                    reading: CalibrationFactory.reading(residual: residual * jitter),
                    binding: CalibrationFactory.binding()
                ))
            }
        }
    }

    func testACompleteSetFitsACurveAndReportsItsCrossValidatedError() {
        let (session, _) = makeSession()
        prepareForCapture(session)
        recordEverything(session)

        XCTAssertTrue(session.allStandardsComplete)
        session.fit()

        XCTAssertEqual(session.stage, .review)
        guard let candidate = session.outcome?.candidate else {
            return XCTFail("a well-behaved set must fit: \(session.outcome?.problems ?? [])")
        }
        XCTAssertGreaterThan(candidate.validation.heldOutLevels, 0,
                             "a curve nobody held a level out of has not been validated")
        XCTAssertNotNil(session.outcome?.uncertainty)
        XCTAssertNotNil(session.outcome?.validatedNTURange)
    }

    func testSavingRefusesWithoutANameAndSucceedsWithOne() async {
        let (session, _) = makeSession()
        prepareForCapture(session)
        recordEverything(session)
        session.fit()

        session.profileName = "   "
        let refusal = await session.save()
        XCTAssertNotNil(refusal)
        XCTAssertEqual(session.stage, .review)

        session.profileName = "Shroud v2 with 20 mL vial"
        let failure = await session.save()

        XCTAssertNil(failure, failure ?? "")
        XCTAssertEqual(session.stage, .saved)
        guard let saved = session.savedProfile else { return XCTFail("nothing was saved") }
        XCTAssertEqual(saved.name, "Shroud v2 with 20 mL vial")
        XCTAssertEqual(saved.levels.count, 5)
        XCTAssertGreaterThan(saved.expiresAt, saved.createdAt,
                             "a calibration with no end date is one nobody re-checks")
    }

    func testASavedCalibrationBecomesTheOneInUseAndClearsTheFixtureOverride() async {
        let (session, measurement) = makeSession()
        prepareForCapture(session)
        recordEverything(session)
        session.fit()
        session.profileName = "Bench"

        XCTAssertNil(await session.save())

        XCTAssertEqual(measurement.calibrations.selectedProfile?.name, "Bench")
        XCTAssertNil(measurement.fixtureOverride,
                     "the calibration's own binding takes over once it exists")
    }

    func testAnUnfittableSetIsRefusedRatherThanSavedWithAWorseCurve() async {
        let (session, _) = makeSession()
        prepareForCapture(session)
        // Only the blank is measured.
        for _ in 0..<3 {
            XCTAssertNil(session.record(reading: CalibrationFactory.reading(),
                                        binding: CalibrationFactory.binding()))
        }

        session.fit()

        XCTAssertNil(session.outcome?.candidate)
        XCTAssertFalse(session.outcome?.problems.isEmpty ?? true)

        session.profileName = "Nope"
        XCTAssertNotNil(await session.save())
        XCTAssertNil(session.savedProfile)
    }
}
