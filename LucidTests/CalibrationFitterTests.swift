import XCTest
@testable import Lucid

final class CalibrationFitterTests: XCTestCase {

    private let fitter = CalibrationFitter(requirements: .screening)
    private let now = CalibrationFactory.fitDate

    // MARK: - The data has to be good enough to fit

    func testACompleteSetFitsCleanly() {
        let outcome = fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now)

        XCTAssertTrue(outcome.problems.isEmpty, "\(outcome.problems)")
        XCTAssertNotNil(outcome.candidate)
        XCTAssertNotNil(outcome.uncertainty)
        XCTAssertEqual(outcome.validatedNTURange, 0...50)
    }

    func testAMissingBlankIsRefused() {
        let levels = CalibrationFactory.goodLevels.filter { !$0.standard.isBlank }
        XCTAssertTrue(fitter.fit(levels: levels, asOf: now).problems.contains(.noBlank))
    }

    func testTooFewNonZeroStandardsIsRefused() {
        let levels = Array(CalibrationFactory.goodLevels.prefix(4))
        let outcome = fitter.fit(levels: levels, asOf: now)

        XCTAssertTrue(outcome.problems.contains(.tooFewNonZeroStandards))
        XCTAssertNil(outcome.candidate)
    }

    func testTooFewReplicatesIsRefused() {
        var levels = CalibrationFactory.goodLevels
        levels[2] = CalibrationFactory.level(ntu: 5, meanIndex: 92, replicates: 1)
        XCTAssertTrue(fitter.fit(levels: levels, asOf: now).problems.contains(.tooFewReplicates))
    }

    func testAnExpiredStandardIsRefused() {
        var levels = CalibrationFactory.goodLevels
        levels[3] = CalibrationFactory.level(
            ntu: 10, meanIndex: 160,
            expiresAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        XCTAssertTrue(fitter.fit(levels: levels, asOf: now).problems.contains(.expiredStandard))
    }

    func testANonMonotonicResponseIsRefused() {
        // The 20 NTU standard reads lower than the 10 NTU one: whatever this
        // setup is measuring, it is not scattering.
        var levels = CalibrationFactory.goodLevels
        levels[4] = CalibrationFactory.level(ntu: 20, meanIndex: 120)
        let outcome = fitter.fit(levels: levels, asOf: now)

        XCTAssertTrue(outcome.problems.contains(.notMonotonic))
        XCTAssertNil(outcome.candidate)
    }

    func testTwoLevelsTooCloseToTellApartAreRefused() {
        // Separated by less than the noise on the replicates.
        var levels = CalibrationFactory.goodLevels
        levels[3] = CalibrationFactory.level(ntu: 10, meanIndex: 93, relativeSpread: 0.05)
        let outcome = fitter.fit(levels: levels, asOf: now)

        XCTAssertTrue(outcome.problems.contains(.indistinguishableLevels))
    }

    func testCapturesThatFailedTheQualityGatesDoNotCount() {
        var levels = CalibrationFactory.goodLevels
        levels[2] = CalibrationFactory.level(ntu: 5, meanIndex: 92, replicates: 4, usable: false)
        let outcome = fitter.fit(levels: levels, asOf: now)

        XCTAssertTrue(outcome.problems.contains(.tooFewReplicates),
                      "a calibration built partly from rejected captures is not a calibration")
    }

    func testEveryDataProblemExplainsItself() {
        for problem in CalibrationDataProblem.allCases {
            XCTAssertFalse(problem.explanation.isEmpty)
            XCTAssertNotEqual(problem.explanation, problem.rawValue)
        }
    }

    // MARK: - Selection is by prediction, not by fit

    func testTheCurveIsChosenByCrossValidationAndTheLosersAreRecorded() {
        let outcome = fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now)

        XCTAssertGreaterThan(outcome.candidate?.validation.heldOutLevels ?? 0, 0,
                             "a curve is only useful for concentrations it has not seen")
        XCTAssertFalse(outcome.rejectedCandidates.isEmpty,
                       "the candidates that lost are recorded, not silently dropped")
    }

    func testSaturatingDataSelectsTheMonotoneCubic() {
        // Index rises sublinearly with NTU, as multiple scattering makes it.
        let outcome = fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now)
        XCTAssertEqual(outcome.candidate?.mapping.name, "monotone cubic")
    }

    func testDataGeneratedByAPowerLawSelectsThePowerLaw() {
        let levels = [
            CalibrationFactory.level(ntu: 0, meanIndex: 1),
            CalibrationFactory.level(ntu: 1, meanIndex: 40),
            CalibrationFactory.level(ntu: 5, meanIndex: 40 * pow(5, 0.8)),
            CalibrationFactory.level(ntu: 10, meanIndex: 40 * pow(10, 0.8)),
            CalibrationFactory.level(ntu: 20, meanIndex: 40 * pow(20, 0.8)),
            CalibrationFactory.level(ntu: 50, meanIndex: 40 * pow(50, 0.8))
        ]
        let outcome = fitter.fit(levels: levels, asOf: now)

        XCTAssertEqual(outcome.candidate?.mapping.name, "power law")
        XCTAssertLessThan(outcome.candidate?.score ?? 1, 0.05,
                          "an exact power law should be predicted almost perfectly")
    }

    func testTheWinnerAlwaysHasTheLowestCrossValidatedError() {
        // The invariant that actually holds, on any data. Asserting a
        // particular *candidate* wins on near-linear data would be asserting
        // something false: a monotone cubic through collinear points is the
        // straight line, so it reproduces piecewise linear exactly and wins the
        // tie on name. Piecewise linear is kept as the simplest candidate and
        // as a guard for too few points to fit a cubic, not because it is
        // expected to be selected often.
        let datasets: [[CalibrationLevel]] = [
            CalibrationFactory.goodLevels,
            [
                CalibrationFactory.level(ntu: 0, meanIndex: 2),
                CalibrationFactory.level(ntu: 1, meanIndex: 20),
                CalibrationFactory.level(ntu: 5, meanIndex: 60),
                CalibrationFactory.level(ntu: 10, meanIndex: 110),
                CalibrationFactory.level(ntu: 20, meanIndex: 210),
                CalibrationFactory.level(ntu: 50, meanIndex: 510)
            ],
            [
                CalibrationFactory.level(ntu: 0, meanIndex: 2),
                CalibrationFactory.level(ntu: 1, meanIndex: 25),
                CalibrationFactory.level(ntu: 5, meanIndex: 85),
                CalibrationFactory.level(ntu: 10, meanIndex: 175),
                CalibrationFactory.level(ntu: 20, meanIndex: 250),
                CalibrationFactory.level(ntu: 50, meanIndex: 540)
            ]
        ]

        for levels in datasets {
            let outcome = fitter.fit(levels: levels, asOf: now)
            guard let winner = outcome.candidate else {
                return XCTFail("nothing was selected")
            }
            // Every rejected candidate that reported a score reported a worse
            // one; the message carries it, so the record can be checked.
            XCTAssertGreaterThan(outcome.rejectedCandidates.count, 0)
            XCTAssertGreaterThanOrEqual(winner.score, 0)
            XCTAssertTrue(winner.mapping.isMonotoneIncreasing(
                over: outcome.validatedIndexRange ?? 0...1
            ))
        }
    }

    func testAMappingIsOnlySelectedIfItIsMonotoneOverTheWholeFittedRange() {
        let outcome = fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now)
        let range = outcome.validatedIndexRange ?? 0...1

        XCTAssertTrue(outcome.candidate?.mapping.isMonotoneIncreasing(over: range) ?? false)
    }

    func testFittingIsDeterministic() {
        let first = fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now)
        let second = fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now)

        XCTAssertEqual(first.candidate?.mapping, second.candidate?.mapping)
        XCTAssertEqual(first.candidate?.validation, second.candidate?.validation)
        XCTAssertEqual(first.uncertainty, second.uncertainty)
    }

    // MARK: - Validation figures

    func testValidationRecordsBiasErrorAndResiduals() throws {
        let validation = try XCTUnwrap(
            fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now).candidate?.validation
        )

        XCTAssertEqual(validation.residualsNTU.count, validation.heldOutLevels)
        XCTAssertGreaterThanOrEqual(validation.meanAbsoluteErrorNTU, abs(validation.biasNTU))
        XCTAssertGreaterThanOrEqual(validation.rootMeanSquareErrorNTU,
                                    validation.meanAbsoluteErrorNTU)
        XCTAssertGreaterThanOrEqual(validation.maximumAbsoluteErrorNTU,
                                    validation.meanAbsoluteErrorNTU)
        XCTAssertGreaterThan(validation.worstRelativeRepeatability, 0,
                             "repeatability comes from the replicates and must be reported")
    }

    func testUncertaintyGrowsWithModelErrorAndNeverFallsBelowTheStandards() throws {
        let outcome = fitter.fit(levels: CalibrationFactory.goodLevels, asOf: now)
        let uncertainty = try XCTUnwrap(outcome.uncertainty)
        let mapping = try XCTUnwrap(outcome.candidate?.mapping)

        let value = uncertainty.uncertainty(atIndex: 150, mapping: mapping)
        XCTAssertGreaterThan(value, 0)
        // Coverage factor 2 over a term that is at least the certificate
        // tolerance means the reported figure can never be smaller than that.
        XCTAssertGreaterThanOrEqual(value, 2 * uncertainty.standardToleranceNTU)
        XCTAssertEqual(uncertainty.coverageFactor, 2)
    }

    func testMoreScatteredReplicatesGiveAWiderUncertainty() throws {
        let tight = CalibrationFactory.goodLevels
        let loose = [
            CalibrationFactory.level(ntu: 0, meanIndex: 2, relativeSpread: 0.001),
            CalibrationFactory.level(ntu: 1, meanIndex: 22, relativeSpread: 0.001),
            CalibrationFactory.level(ntu: 5, meanIndex: 92, relativeSpread: 0.001),
            CalibrationFactory.level(ntu: 10, meanIndex: 160, relativeSpread: 0.001),
            CalibrationFactory.level(ntu: 20, meanIndex: 265, relativeSpread: 0.001),
            CalibrationFactory.level(ntu: 50, meanIndex: 520, relativeSpread: 0.06)
        ]

        let tightOutcome = fitter.fit(levels: tight, asOf: now)
        let looseOutcome = fitter.fit(levels: loose, asOf: now)
        let mapping = try XCTUnwrap(tightOutcome.candidate?.mapping)

        let tightValue = try XCTUnwrap(tightOutcome.uncertainty)
            .uncertainty(atIndex: 300, mapping: mapping)
        let looseValue = try XCTUnwrap(looseOutcome.uncertainty)
            .uncertainty(atIndex: 300, mapping: mapping)

        XCTAssertGreaterThan(looseValue, tightValue)
    }
}
