import Foundation

/// One axis of a constant-velocity Kalman filter.
///
/// Two separate one-dimensional filters rather than one four-state filter: for
/// a constant-velocity model with independent axis noise the four-state
/// covariance is block-diagonal, so the two halves never interact. Splitting
/// them turns 4x4 matrix algebra into a handful of scalar lines that can be
/// checked by eye and tested exactly.
///
/// The state is (position, velocity). Time steps come from real presentation
/// timestamps, so an irregular or dropped frame produces the right prediction
/// instead of one based on an assumed frame interval.
struct ConstantVelocityAxisFilter: Equatable, Sendable {
    private(set) var position: Double
    private(set) var velocity: Double

    // Symmetric 2x2 covariance.
    private(set) var varPosition: Double
    private(set) var covariance: Double
    private(set) var varVelocity: Double

    /// Spectral density of the unmodelled acceleration. Larger values let the
    /// filter follow a manoeuvring target more closely at the cost of noise.
    let processNoise: Double
    /// Variance of a position measurement.
    let measurementNoise: Double

    init(position: Double,
         processNoise: Double,
         measurementNoise: Double,
         initialVelocityVariance: Double = 1e4) {
        self.position = position
        self.velocity = 0
        // The first measurement pins the position, so its variance starts at
        // the measurement variance; the velocity is entirely unknown.
        self.varPosition = measurementNoise
        self.covariance = 0
        self.varVelocity = initialVelocityVariance
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
    }

    /// Advances the state by `seconds`.
    mutating func predict(seconds dt: Double) {
        guard dt > 0 else { return }

        position += velocity * dt

        // P' = F P F' + Q, with F = [[1, dt], [0, 1]] and the continuous
        // white-noise-acceleration Q = q * [[dt^3/3, dt^2/2], [dt^2/2, dt]].
        let newVarPosition = varPosition + 2 * dt * covariance + dt * dt * varVelocity
            + processNoise * dt * dt * dt / 3
        let newCovariance = covariance + dt * varVelocity + processNoise * dt * dt / 2
        let newVarVelocity = varVelocity + processNoise * dt

        varPosition = newVarPosition
        covariance = newCovariance
        varVelocity = newVarVelocity
    }

    /// Folds in a position measurement.
    mutating func update(measurement: Double) {
        let innovationVariance = varPosition + measurementNoise
        guard innovationVariance > 0 else { return }

        let gainPosition = varPosition / innovationVariance
        let gainVelocity = covariance / innovationVariance
        let innovation = measurement - position

        position += gainPosition * innovation
        velocity += gainVelocity * innovation

        // P = (I - K H) P, with H = [1, 0]. The old covariance term is needed
        // for the velocity variance, so it is read before being overwritten.
        let oldCovariance = covariance
        varPosition = (1 - gainPosition) * varPosition
        covariance = (1 - gainPosition) * covariance
        varVelocity -= gainVelocity * oldCovariance
    }

    /// Where the filter expects the target to be after `seconds`, without
    /// changing the state.
    func predictedPosition(after seconds: Double) -> Double {
        position + velocity * seconds
    }
}
