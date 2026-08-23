import XCTest
@testable import Lucid

final class MonotonicMappingTests: XCTestCase {

    private let knots = [
        MonotonicMapping.Knot(x: 2, y: 0),
        MonotonicMapping.Knot(x: 22, y: 1),
        MonotonicMapping.Knot(x: 92, y: 5),
        MonotonicMapping.Knot(x: 160, y: 10),
        MonotonicMapping.Knot(x: 265, y: 20),
        MonotonicMapping.Knot(x: 520, y: 50)
    ]

    // MARK: - Every candidate is monotone by construction

    func testEveryCandidateIsMonotoneOverItsFittedRange() throws {
        let range = 2.0...520.0
        for builder in CalibrationFitter.builders {
            let mapping = try XCTUnwrap(builder.build(knots), "\(builder.name) failed to fit")
            XCTAssertTrue(mapping.isMonotoneIncreasing(over: range),
                          "\(builder.name) is not monotone")
        }
    }

    func testTheMonotoneCubicDoesNotOvershootOnAwkwardSpacing() throws {
        // A wide gap followed by a tiny one is exactly where an ordinary cubic
        // spline rings.
        let awkward = [
            MonotonicMapping.Knot(x: 2, y: 0),
            MonotonicMapping.Knot(x: 22, y: 1),
            MonotonicMapping.Knot(x: 92, y: 5),
            MonotonicMapping.Knot(x: 95, y: 5.2),
            MonotonicMapping.Knot(x: 520, y: 50)
        ]
        let mapping = try XCTUnwrap(MonotonicMapping.monotoneCubic(through: awkward))

        XCTAssertTrue(mapping.isMonotoneIncreasing(over: 2...520))
        for step in 0...500 {
            let x = 2 + (520 - 2) * Double(step) / 500
            let y = mapping.ntu(forIndex: x)
            XCTAssertGreaterThanOrEqual(y, -1e-9, "dipped below the data at index \(x)")
            XCTAssertLessThanOrEqual(y, 50 + 1e-9, "overshot the data at index \(x)")
        }
    }

    func testAMappingPassesThroughItsKnots() throws {
        for builder in ["piecewise linear", "monotone cubic"] {
            let mapping = try XCTUnwrap(
                CalibrationFitter.builders.first { $0.name == builder }?.build(knots)
            )
            for knot in knots {
                XCTAssertEqual(mapping.ntu(forIndex: knot.x), knot.y, accuracy: 1e-9,
                               "\(builder) missed its own knot at \(knot.x)")
            }
        }
    }

    // MARK: - Clamping, not extrapolation

    func testEvaluationClampsOutsideTheFittedRange() throws {
        let mapping = try XCTUnwrap(MonotonicMapping.monotoneCubic(through: knots))

        XCTAssertEqual(mapping.ntu(forIndex: -100), 0)
        XCTAssertEqual(mapping.ntu(forIndex: 0), 0)
        XCTAssertEqual(mapping.ntu(forIndex: 10_000), 50)
    }

    // MARK: - Refusing to fit what cannot be fitted

    func testPointsThatDoNotIncreaseCannotBeFitted() {
        let backwards = [
            MonotonicMapping.Knot(x: 100, y: 0),
            MonotonicMapping.Knot(x: 50, y: 1),
            MonotonicMapping.Knot(x: 200, y: 5)
        ]
        XCTAssertNil(MonotonicMapping.piecewiseLinear(through: backwards))
        XCTAssertNil(MonotonicMapping.monotoneCubic(through: backwards))
    }

    func testDuplicateIndicesCannotBeFitted() {
        let duplicated = [
            MonotonicMapping.Knot(x: 10, y: 0),
            MonotonicMapping.Knot(x: 10, y: 1),
            MonotonicMapping.Knot(x: 20, y: 5)
        ]
        XCTAssertNil(MonotonicMapping.piecewiseLinear(through: duplicated))
    }

    func testAPowerLawWithANegativeExponentIsRefused() {
        // Decreasing data would fit a power law with a negative exponent, which
        // is a perfectly good fit and a useless calibration.
        let decreasing = [
            MonotonicMapping.Knot(x: 10, y: 50),
            MonotonicMapping.Knot(x: 100, y: 5),
            MonotonicMapping.Knot(x: 200, y: 1)
        ]
        XCTAssertNil(MonotonicMapping.powerLaw(through: decreasing))
    }

    func testTooFewPointsCannotBeFitted() {
        XCTAssertNil(MonotonicMapping.piecewiseLinear(through: [knots[0]]))
        XCTAssertNil(MonotonicMapping.monotoneCubic(through: Array(knots.prefix(2))))
        XCTAssertNil(MonotonicMapping.powerLaw(through: []))
    }

    // MARK: - Sensitivity

    func testSensitivityIsPositiveAndTracksTheLocalSlope() throws {
        let mapping = try XCTUnwrap(MonotonicMapping.piecewiseLinear(through: knots))

        // Between index 22 and 92 the curve climbs 1 -> 5 NTU: a slope of
        // 4 / 70 per index unit.
        XCTAssertEqual(mapping.sensitivity(atIndex: 50), 4.0 / 70.0, accuracy: 1e-4)
        XCTAssertGreaterThan(mapping.sensitivity(atIndex: 300), 0)
    }

    // MARK: - Persistence

    func testEveryMappingSurvivesACodableRoundTrip() throws {
        for builder in CalibrationFitter.builders {
            let mapping = try XCTUnwrap(builder.build(knots))
            let data = try JSONEncoder().encode(mapping)
            let decoded = try JSONDecoder().decode(MonotonicMapping.self, from: data)

            XCTAssertEqual(decoded, mapping, "\(builder.name) did not survive encoding")
            XCTAssertEqual(decoded.ntu(forIndex: 150), mapping.ntu(forIndex: 150), accuracy: 1e-12)
        }
    }
}
