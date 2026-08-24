import XCTest
@testable import Turbid

final class RelativeScatteringIndexTests: XCTestCase {

    private func index(residual: Double,
                       excess: Double? = nil,
                       active: Double? = nil,
                       speckRate: Double = 2) -> RelativeScatteringIndex {
        let summary = ScatteringSummary(
            windowCount: 5,
            medianPositiveResidual: residual,
            medianUpperPercentileExcess: excess ?? residual * 1.6,
            medianActiveForegroundFraction: active ?? residual * 0.4,
            medianSpeckEventsPerSecond: speckRate,
            residualRelativeSpread: 0.05,
            repeatabilityConfidence: 0.9
        )
        return RelativeScatteringIndex.make(summary: summary,
                                            tracking: CalibrationFactory.tracking(speckRate: speckRate))
    }

    // MARK: - Monotonicity

    func testTheIndexRisesMonotonicallyWithScattering() {
        // The one property the index is required to have.
        var previous = -1.0
        for step in 0...200 {
            let residual = Double(step) * 0.001
            let value = index(residual: residual).value
            XCTAssertGreaterThanOrEqual(value, previous,
                                        "index fell at residual \(residual)")
            previous = value
        }
    }

    func testEachInputMovesTheIndexInTheRightDirection() {
        let base = index(residual: 0.02, excess: 0.03, active: 0.01, speckRate: 2)

        XCTAssertGreaterThan(index(residual: 0.04, excess: 0.03, active: 0.01, speckRate: 2).value,
                             base.value, "more bulk residual must raise the index")
        XCTAssertGreaterThan(index(residual: 0.02, excess: 0.06, active: 0.01, speckRate: 2).value,
                             base.value, "more upper-percentile excess must raise the index")
        XCTAssertGreaterThan(index(residual: 0.02, excess: 0.03, active: 0.02, speckRate: 2).value,
                             base.value, "more active foreground must raise the index")
        XCTAssertGreaterThan(index(residual: 0.02, excess: 0.03, active: 0.01, speckRate: 8).value,
                             base.value, "more tracked specks must raise the index")
    }

    func testANonScatteringSampleReadsZero() {
        let empty = RelativeScatteringIndex.make(summary: .empty, tracking: .empty)
        XCTAssertEqual(empty.value, 0)
    }

    func testNegativeInputsCannotProduceANegativeIndex() {
        // Nothing should produce a negative residual, but a negative index
        // would be meaningless if something did.
        let summary = ScatteringSummary(
            windowCount: 3, medianPositiveResidual: -0.05,
            medianUpperPercentileExcess: -0.02, medianActiveForegroundFraction: -0.01,
            medianSpeckEventsPerSecond: 0, residualRelativeSpread: 0, repeatabilityConfidence: 0
        )
        XCTAssertEqual(RelativeScatteringIndex.make(summary: summary, tracking: .empty).value, 0)
    }

    // MARK: - The bulk channel dominates

    func testTheBulkTermsCarryMostOfTheWeight() {
        // Turbidity is a bulk optical measurement, so the tracked-speck term is
        // secondary by design.
        let weights = RelativeScatteringIndex.Weights.screening
        XCTAssertGreaterThan(weights.bulk, weights.specks * 5)
        XCTAssertGreaterThan(weights.bulk + weights.excess + weights.active,
                             weights.specks * 4)
        XCTAssertEqual(weights.total, 1.0, accuracy: 1e-9)
    }

    func testAnEnormousSpeckRateCannotDominateAClearSample() {
        let clearWithManySpecks = index(residual: 0.001, speckRate: 500)
        let cloudyWithNone = index(residual: 0.05, speckRate: 0)

        XCTAssertLessThan(clearWithManySpecks.value, cloudyWithNone.value,
                          "a count-driven index would be measuring the wrong thing")
    }

    // MARK: - Traceability

    func testTheComponentsSumToTheIndex() {
        let value = index(residual: 0.03)
        let total = value.components.bulkContribution + value.components.excessContribution
            + value.components.activeContribution + value.components.speckContribution

        XCTAssertEqual(total, value.value, accuracy: 1e-9,
                       "every displayed index must be traceable to its parts")
    }

    func testTheIndexRecordsWhichWeightsProducedIt() {
        XCTAssertEqual(index(residual: 0.02).weightsVersion,
                       RelativeScatteringIndex.Weights.screening.version)
        XCTAssertEqual(index(residual: 0.02).windowCount, 5)
    }

    func testTheIndexSurvivesACodableRoundTrip() throws {
        let original = index(residual: 0.037)
        let decoded = try JSONDecoder().decode(
            RelativeScatteringIndex.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: - It is not NTU

    func testTheIndexIsOnItsOwnScaleAndNotConfusableWithNTU() {
        // A sample that would read a fraction of an NTU produces an index in
        // the tens: the two scales are visibly different, which is deliberate.
        let clear = index(residual: 0.002)
        XCTAssertGreaterThan(clear.value, 1)
        XCTAssertEqual(RelativeScatteringIndex.scale, 1000)
    }
}
