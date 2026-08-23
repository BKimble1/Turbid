import XCTest
@testable import Lucid

final class ConstantVelocityFilterTests: XCTestCase {

    private func makeFilter(position: Double = 0) -> ConstantVelocityAxisFilter {
        ConstantVelocityAxisFilter(position: position, processNoise: 400, measurementNoise: 1)
    }

    func testItConvergesOnAConstantVelocity() {
        var filter = makeFilter(position: 0)
        let speed = 50.0
        let dt = 1.0 / 30

        for step in 1...30 {
            filter.predict(seconds: dt)
            filter.update(measurement: speed * dt * Double(step))
        }

        XCTAssertEqual(filter.velocity, speed, accuracy: speed * 0.05)
        XCTAssertEqual(filter.position, speed * dt * 30, accuracy: 1)
    }

    func testIrregularTimeStepsGiveTheSameVelocityAsRegularOnes() {
        // The whole reason the filter takes real timestamps.
        let speed = 50.0

        var regular = makeFilter()
        var time = 0.0
        for _ in 1...30 {
            time += 1.0 / 30
            regular.predict(seconds: 1.0 / 30)
            regular.update(measurement: speed * time)
        }

        var irregular = makeFilter()
        time = 0.0
        let intervals = [0.02, 0.05, 0.033, 0.01, 0.08, 0.033, 0.04, 0.02, 0.06, 0.033,
                         0.02, 0.05, 0.033, 0.01, 0.08, 0.033, 0.04, 0.02, 0.06, 0.033]
        for interval in intervals {
            time += interval
            irregular.predict(seconds: interval)
            irregular.update(measurement: speed * time)
        }

        XCTAssertEqual(irregular.velocity, speed, accuracy: speed * 0.05)
        XCTAssertEqual(irregular.velocity, regular.velocity, accuracy: speed * 0.1)
    }

    func testItSmoothsMeasurementNoise() {
        // A stationary target measured with noise: the estimate must sit far
        // closer to the truth than the measurements do.
        var filter = makeFilter(position: 100)
        var random = DeterministicRandom(seed: 31)
        var worstMeasurement = 0.0

        for _ in 1...60 {
            let noise = Double(random.nextGaussian())
            worstMeasurement = max(worstMeasurement, abs(noise))
            filter.predict(seconds: 1.0 / 30)
            filter.update(measurement: 100 + noise)
        }

        XCTAssertEqual(filter.position, 100, accuracy: 1.0)
        XCTAssertGreaterThan(worstMeasurement, 1.5, "the input really was noisy")
        XCTAssertEqual(filter.velocity, 0, accuracy: 8,
                       "a stationary target must not acquire a velocity from noise")
    }

    func testPredictionLooksAheadWithoutChangingTheState() {
        var filter = makeFilter()
        for step in 1...20 {
            filter.predict(seconds: 1.0 / 30)
            filter.update(measurement: 60.0 * Double(step) / 30)
        }

        let position = filter.position
        let ahead = filter.predictedPosition(after: 0.5)

        XCTAssertEqual(filter.position, position, "a look-ahead must not mutate the filter")
        XCTAssertEqual(ahead, position + filter.velocity * 0.5, accuracy: 1e-9)
    }

    func testUncertaintyGrowsWhilePredictingAndShrinksOnUpdate() {
        var filter = makeFilter()
        let initial = filter.varPosition

        filter.predict(seconds: 0.5)
        let afterPrediction = filter.varPosition
        XCTAssertGreaterThan(afterPrediction, initial,
                             "an unobserved target becomes less certain over time")

        filter.update(measurement: 0)
        XCTAssertLessThan(filter.varPosition, afterPrediction)
    }

    func testAZeroOrNegativeStepIsIgnored() {
        var filter = makeFilter(position: 10)
        filter.predict(seconds: 0)
        filter.predict(seconds: -1)
        XCTAssertEqual(filter.position, 10)
    }
}
