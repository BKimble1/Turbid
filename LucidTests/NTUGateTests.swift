import XCTest
@testable import Lucid

/// The gate is the only place an NTU number can come into existence, so every
/// way of failing to earn one is pinned here.
final class NTUGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func evaluate(mode: MeasurementMode = .calibratedFixture,
                          profile: CalibrationProfile?,
                          indexValue: Double = 150,
                          quality: CaptureQuality = CalibrationFactory.quality(),
                          binding: CalibrationBinding? = CalibrationFactory.binding(),
                          date: Date? = nil) -> NTUAvailability {
        let index = RelativeScatteringIndex(
            value: indexValue,
            components: RelativeScatteringIndex.Components(
                bulkContribution: indexValue * 0.6, excessContribution: indexValue * 0.25,
                activeContribution: indexValue * 0.12, speckContribution: indexValue * 0.03),
            weightsVersion: 1, windowCount: 5
        )
        return NTUGate.evaluate(mode: mode, profile: profile, index: index,
                                quality: quality, liveBinding: binding,
                                asOf: date ?? now)
    }

    // MARK: - The happy path exists

    func testAValidCalibratedMeasurementProducesAnEstimateWithUncertaintyAndRange() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let availability = evaluate(profile: profile, indexValue: 150)

        guard case .available(let estimate, let uncertainty, let range) = availability else {
            return XCTFail("expected an estimate, got \(availability)")
        }
        // 150 sits between the 5 NTU standard (index 92) and the 10 NTU one
        // (index 160), so the estimate has to land between them.
        XCTAssertGreaterThan(estimate, 5)
        XCTAssertLessThan(estimate, 10)
        XCTAssertGreaterThan(uncertainty, 0, "an estimate without an uncertainty is not a measurement")
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, 50)
        XCTAssertTrue(availability.displayText.contains("±"))
    }

    // MARK: - Screening Mode can never produce NTU

    func testScreeningModeCannotEmitNTUEvenWithAPerfectCalibration() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let availability = evaluate(mode: .screening, profile: profile)

        XCTAssertEqual(availability, .screeningMode)
        XCTAssertNil(availability.estimate)
        XCTAssertEqual(availability.displayText, "Calibration required")
    }

    func testScreeningModeDoesNotPermitNumericNTUAtTheDomainLevel() {
        XCTAssertFalse(MeasurementMode.screening.permitsNumericNTU)
        XCTAssertTrue(MeasurementMode.calibratedFixture.permitsNumericNTU)
    }

    // MARK: - Missing, expired and incompatible calibrations

    func testNoProfileMeansCalibrationRequired() {
        let availability = evaluate(profile: nil)
        XCTAssertEqual(availability, .calibrationRequired)
        XCTAssertNil(availability.estimate)
    }

    func testAnExpiredProfileCannotEmitNTU() throws {
        let expired = try XCTUnwrap(
            CalibrationFactory.profile(expiresAt: Date(timeIntervalSince1970: 1_700_000_100))
        )
        let availability = evaluate(profile: expired)

        guard case .profileExpired = availability else {
            return XCTFail("expected expiry, got \(availability)")
        }
        XCTAssertNil(availability.estimate)
    }

    func testADifferentCameraMakesTheProfileIncompatible() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let availability = evaluate(profile: profile,
                                    binding: CalibrationFactory.binding(cameraUniqueID: "camera-wide"))

        guard case .incompatibleProfile(let reasons) = availability else {
            return XCTFail("expected incompatibility, got \(availability)")
        }
        XCTAssertTrue(reasons.contains { $0.contains("camera") })
        XCTAssertNil(availability.estimate)
    }

    func testADifferentAlgorithmVersionMakesTheProfileIncompatible() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        var versions = CalibrationFactory.algorithmVersions
        versions = CalibrationBinding.AlgorithmVersions(
            captureProtocol: versions.captureProtocol,
            qualityThresholds: versions.qualityThresholds,
            detector: versions.detector + 1,
            bandPass: versions.bandPass,
            backgroundModel: versions.backgroundModel,
            tracker: versions.tracker,
            classifier: versions.classifier,
            aggregation: versions.aggregation,
            indexWeights: versions.indexWeights
        )
        let availability = evaluate(
            profile: profile,
            binding: CalibrationFactory.binding(algorithmVersions: versions)
        )

        guard case .incompatibleProfile(let reasons) = availability else {
            return XCTFail("expected incompatibility, got \(availability)")
        }
        XCTAssertTrue(reasons.contains { $0.contains("analysis version") },
                      "a changed algorithm describes a different instrument")
    }

    func testAReducedTorchLevelMakesTheProfileIncompatible() throws {
        // The torch drops under thermal load. A calibration made at full output
        // does not describe a measurement made at reduced output.
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let availability = evaluate(profile: profile,
                                    binding: CalibrationFactory.binding(torchLevel: 0.7))

        guard case .incompatibleProfile(let reasons) = availability else {
            return XCTFail("expected incompatibility, got \(availability)")
        }
        XCTAssertTrue(reasons.contains { $0.contains("torch") })
    }

    func testUnknownCaptureSettingsMeanIncompatible() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let availability = evaluate(profile: profile, binding: nil)

        guard case .incompatibleProfile = availability else {
            return XCTFail("expected incompatibility, got \(availability)")
        }
    }

    // MARK: - Quality

    func testAFailedCaptureCannotEmitNTU() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let availability = evaluate(
            profile: profile,
            quality: CalibrationFactory.quality(usable: false, reasons: [.saturatedRegion, .cameraMoved])
        )

        guard case .captureQualityInsufficient(let reasons) = availability else {
            return XCTFail("expected a quality refusal, got \(availability)")
        }
        XCTAssertEqual(Set(reasons), [.saturatedRegion, .cameraMoved])
        XCTAssertNil(availability.estimate)
    }

    // MARK: - Range

    func testAnIndexBelowTheCalibratedRangeIsFlaggedNotExtrapolated() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        // The blank read 2; anything below that was never calibrated.
        let availability = evaluate(profile: profile, indexValue: 0.5)

        guard case .belowValidatedRange(let bound) = availability else {
            return XCTFail("expected a below-range flag, got \(availability)")
        }
        XCTAssertEqual(bound, 0)
        XCTAssertNil(availability.estimate)
        XCTAssertTrue(availability.displayText.contains("Below validated range"))
    }

    func testAnIndexAboveTheCalibratedRangeIsFlaggedNotExtrapolated() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        // The cloudiest standard read 520.
        let availability = evaluate(profile: profile, indexValue: 900)

        guard case .aboveValidatedRange(let bound) = availability else {
            return XCTFail("expected an above-range flag, got \(availability)")
        }
        XCTAssertEqual(bound, 50)
        XCTAssertNil(availability.estimate)
    }

    func testTheEndsOfTheValidatedRangeAreInsideIt() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())

        XCTAssertNotNil(evaluate(profile: profile, indexValue: 2).estimate)
        XCTAssertNotNil(evaluate(profile: profile, indexValue: 520).estimate)
    }

    // MARK: - Every refusal explains itself

    func testEveryUnavailableStateHasDisplayTextAndAnExplanation() {
        let states: [NTUAvailability] = [
            .screeningMode,
            .calibrationRequired,
            .profileExpired(expiredAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .incompatibleProfile(reasons: ["camera differs"]),
            .captureQualityInsufficient(reasons: [.cameraMoved]),
            .belowValidatedRange(lowerBoundNTU: 0),
            .aboveValidatedRange(upperBoundNTU: 50),
            .uncertaintyUnavailable
        ]

        for state in states {
            XCTAssertFalse(state.displayText.isEmpty, "\(state) has no display text")
            XCTAssertFalse(state.explanation.isEmpty, "\(state) has no explanation")
            XCTAssertNil(state.estimate, "\(state) must not carry a number")
        }
    }

    // MARK: - Assembled through the reading

    func testAReadingInScreeningModeNeverCarriesNTU() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let reading = TurbidityReading.make(
            timestamp: now,
            windowSeconds: 9,
            mode: .screening,
            summary: CalibrationFactory.summary(residual: 0.02),
            tracking: CalibrationFactory.tracking(),
            quality: CalibrationFactory.quality(),
            profile: profile,
            liveBinding: CalibrationFactory.binding(),
            algorithmVersions: CalibrationFactory.algorithmVersions
        )

        XCTAssertEqual(reading.ntu, .screeningMode)
        XCTAssertNil(reading.ntu.estimate)
        XCTAssertNil(reading.calibrationProfileID,
                     "a reading with no NTU must not claim a calibration produced it")
        XCTAssertGreaterThan(reading.index.value, 0, "the relative index is still reported")
    }

    func testAReadingRecordsTheVersionsThatProducedIt() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let reading = TurbidityReading.make(
            timestamp: now,
            windowSeconds: 9,
            mode: .calibratedFixture,
            summary: CalibrationFactory.summary(residual: 0.15),
            tracking: CalibrationFactory.tracking(),
            quality: CalibrationFactory.quality(),
            profile: profile,
            liveBinding: CalibrationFactory.binding(),
            algorithmVersions: CalibrationFactory.algorithmVersions
        )

        XCTAssertEqual(reading.algorithmVersions, CalibrationFactory.algorithmVersions)
        XCTAssertEqual(reading.clarityPolicyVersion, ClarityPolicy.screening.version)
        XCTAssertEqual(reading.index.weightsVersion,
                       RelativeScatteringIndex.Weights.screening.version)
        XCTAssertFalse(reading.disclaimer.isEmpty)
    }

    func testConfidenceIsTheWorseOfCaptureAndRepeatability() {
        let reading = TurbidityReading.make(
            timestamp: now,
            windowSeconds: 9,
            mode: .screening,
            summary: CalibrationFactory.summary(residual: 0.02, repeatability: 0.4),
            tracking: CalibrationFactory.tracking(),
            quality: CalibrationFactory.quality(confidence: 0.9),
            profile: nil,
            liveBinding: nil,
            algorithmVersions: CalibrationFactory.algorithmVersions
        )

        XCTAssertEqual(reading.confidence, 0.4, accuracy: 1e-9,
                       "a result is only as good as the worse of how it was captured "
                           + "and whether it would come out the same again")
    }
}
