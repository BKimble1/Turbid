import XCTest
@testable import Lucid

final class ClarityCategoryEngineTests: XCTestCase {

    private let policy = ClarityPolicy.screening

    private func index(_ value: Double) -> RelativeScatteringIndex {
        RelativeScatteringIndex(
            value: value,
            components: RelativeScatteringIndex.Components(
                bulkContribution: value * 0.6, excessContribution: value * 0.25,
                activeContribution: value * 0.12, speckContribution: value * 0.03),
            weightsVersion: 1, windowCount: 5
        )
    }

    private func availableNTU(_ value: Double) -> NTUAvailability {
        .available(estimateNTU: value, uncertaintyNTU: 0.2, validatedRange: 0...50)
    }

    // MARK: - Screening bands

    func testScreeningUsesTheIndexAndDescribesObservedScattering() {
        let clear = ClarityCategoryEngine.classify(index: index(2), ntu: .screeningMode,
                                                   policy: policy)
        XCTAssertEqual(clear.clarity, .crystalClear)
        XCTAssertEqual(clear.basis, .relativeScatteringIndex)
        XCTAssertEqual(clear.description, "Low observed scattering")

        let middle = ClarityCategoryEngine.classify(index: index(20), ntu: .screeningMode,
                                                    policy: policy)
        XCTAssertEqual(middle.clarity, .slightlyTurbid)
        XCTAssertEqual(middle.description, "Moderate observed scattering")

        let high = ClarityCategoryEngine.classify(index: index(200), ntu: .screeningMode,
                                                  policy: policy)
        XCTAssertEqual(high.clarity, .highParticleCount)
        XCTAssertEqual(high.description, "High observed scattering")
    }

    func testScreeningWordingNeverDescribesAConcentration() {
        for value in [1.0, 20.0, 200.0] {
            let verdict = ClarityCategoryEngine.classify(index: index(value),
                                                         ntu: .screeningMode, policy: policy)
            XCTAssertTrue(verdict.description.localizedCaseInsensitiveContains("scattering"),
                          "screening must describe what was observed, not what is in the water")
            XCTAssertFalse(verdict.description.localizedCaseInsensitiveContains("NTU"))
        }
    }

    // MARK: - Calibrated bands

    func testCalibratedModeUsesTheNTUBandsWhenANumberExists() {
        XCTAssertEqual(
            ClarityCategoryEngine.classify(index: index(400), ntu: availableNTU(0.4),
                                           policy: policy).clarity,
            .crystalClear,
            "a calibrated number outranks a high index"
        )
        XCTAssertEqual(
            ClarityCategoryEngine.classify(index: index(1), ntu: availableNTU(3),
                                           policy: policy).clarity,
            .slightlyTurbid
        )
        XCTAssertEqual(
            ClarityCategoryEngine.classify(index: index(1), ntu: availableNTU(20),
                                           policy: policy).clarity,
            .highParticleCount
        )
    }

    func testCalibratedVerdictsRecordThatNTUDecidedThem() {
        let verdict = ClarityCategoryEngine.classify(index: index(100), ntu: availableNTU(2),
                                                     policy: policy)
        XCTAssertEqual(verdict.basis, .calibratedNTU)
        XCTAssertEqual(verdict.description, OpticalClarityClass.slightlyTurbid.qualifier)
    }

    // MARK: - Falling back honestly

    func testAWithheldNTUFallsBackToTheIndexAndSaysSo() {
        // Every way of failing to earn an NTU must classify on the index and
        // record that it did, rather than implying a calibrated judgement.
        let withheld: [NTUAvailability] = [
            .calibrationRequired,
            .profileExpired(expiredAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .incompatibleProfile(reasons: ["camera differs"]),
            .captureQualityInsufficient(reasons: [.cameraMoved]),
            .belowValidatedRange(lowerBoundNTU: 0),
            .aboveValidatedRange(upperBoundNTU: 50),
            .uncertaintyUnavailable
        ]

        for state in withheld {
            let verdict = ClarityCategoryEngine.classify(index: index(20), ntu: state,
                                                         policy: policy)
            XCTAssertEqual(verdict.basis, .relativeScatteringIndex, "\(state)")
            XCTAssertEqual(verdict.clarity, .slightlyTurbid)
        }
    }

    // MARK: - Provenance and boundaries

    func testEveryVerdictRecordsThePolicyThatProducedIt() {
        let verdict = ClarityCategoryEngine.classify(index: index(5), ntu: .screeningMode,
                                                     policy: policy)
        XCTAssertEqual(verdict.policyVersion, policy.version)
    }

    func testTheBandEdgesFallOnTheLowerSide() {
        // Exactly at an edge belongs to the band below it, consistently.
        XCTAssertEqual(
            ClarityCategoryEngine.classify(index: index(policy.screeningLowIndexCeiling),
                                           ntu: .screeningMode, policy: policy).clarity,
            .slightlyTurbid
        )
        XCTAssertEqual(
            ClarityCategoryEngine.classify(index: index(policy.screeningHighIndexFloor),
                                           ntu: .screeningMode, policy: policy).clarity,
            .highParticleCount
        )
        XCTAssertEqual(
            ClarityCategoryEngine.classify(index: index(1),
                                           ntu: availableNTU(policy.calibratedGoodNTUCeiling),
                                           policy: policy).clarity,
            .slightlyTurbid
        )
    }

    func testACustomPolicyIsHonouredAndVersioned() {
        var strict = ClarityPolicy.screening
        strict.screeningLowIndexCeiling = 1
        strict.screeningHighIndexFloor = 2
        strict.version = 99

        let verdict = ClarityCategoryEngine.classify(index: index(5), ntu: .screeningMode,
                                                     policy: strict)
        XCTAssertEqual(verdict.clarity, .highParticleCount)
        XCTAssertEqual(verdict.policyVersion, 99)
    }

    func testTheThreeStatesKeepTheirProductLabelsAndCarryAShapeCue() {
        XCTAssertEqual(OpticalClarityClass.crystalClear.headline, "Crystal Clear")
        XCTAssertEqual(OpticalClarityClass.crystalClear.qualifier, "Good optical clarity")
        XCTAssertEqual(OpticalClarityClass.slightlyTurbid.headline, "Slightly Turbid")
        XCTAssertEqual(OpticalClarityClass.slightlyTurbid.qualifier, "Fair optical clarity")
        XCTAssertEqual(OpticalClarityClass.highParticleCount.headline, "High Particle Count")
        XCTAssertEqual(OpticalClarityClass.highParticleCount.qualifier, "Poor optical clarity")

        // Colour is never the only cue.
        let symbols = OpticalClarityClass.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, OpticalClarityClass.allCases.count)
    }

    func testNoLabelClaimsTheWaterIsSafe() {
        let forbidden = ["safe", "drink", "potable", "pure", "clean", "healthy"]
        for clarity in OpticalClarityClass.allCases {
            for word in forbidden {
                XCTAssertFalse(clarity.headline.localizedCaseInsensitiveContains(word),
                               "\(clarity.headline) implies \(word)")
                XCTAssertFalse(clarity.qualifier.localizedCaseInsensitiveContains(word),
                               "\(clarity.qualifier) implies \(word)")
            }
        }
        XCTAssertTrue(MeasurementDisclaimer.short.localizedCaseInsensitiveContains("not"))
    }
}
