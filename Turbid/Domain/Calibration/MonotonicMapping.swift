import Foundation

/// A fitted, monotone map from the relative scattering index to NTU.
///
/// Every candidate is monotone **by construction**, not by luck. A mapping that
/// can wiggle would let a slightly larger index produce a smaller NTU, which is
/// not a calibration error but a nonsense result — and with only five or six
/// standards, an unconstrained fit wiggles readily.
///
/// This is also why there is no high-degree polynomial here. A quartic through
/// six points fits them beautifully and says nothing about anything in between.
enum MonotonicMapping: Equatable, Sendable, Codable {

    /// Straight lines between the calibration points. Cannot oscillate, cannot
    /// overshoot, and makes no claim about the shape between standards beyond
    /// "it goes up".
    case piecewiseLinear(knots: [Knot])

    /// Fritsch-Carlson monotone cubic. Smooth, and provably free of the
    /// overshoot an ordinary cubic spline produces between unevenly spaced
    /// points.
    case monotoneCubic(knots: [Knot], slopes: [Double])

    /// `NTU = exp(intercept) * index^slope`, fitted by least squares on the
    /// logarithms. Physically motivated: scattered intensity follows a power
    /// law in particle concentration over a limited range, and the exponent is
    /// exactly what the fit measures rather than assumes. Monotone whenever the
    /// slope is positive, which the fitter enforces.
    case powerLaw(logIntercept: Double, slope: Double)

    struct Knot: Equatable, Sendable, Codable {
        /// Relative scattering index.
        let x: Double
        /// NTU.
        let y: Double
    }

    var name: String {
        switch self {
        case .piecewiseLinear: return "piecewise linear"
        case .monotoneCubic: return "monotone cubic"
        case .powerLaw: return "power law"
        }
    }

    /// Knots, for the mappings that have them.
    var knots: [Knot] {
        switch self {
        case .piecewiseLinear(let knots): return knots
        case .monotoneCubic(let knots, _): return knots
        case .powerLaw: return []
        }
    }

    /// Evaluates the mapping.
    ///
    /// Outside the fitted range this **clamps to the end value** rather than
    /// extrapolating. Extrapolation is where a calibration invents numbers, and
    /// the caller is expected to have checked the validated range first and
    /// reported "below" or "above" instead of reading this value.
    func ntu(forIndex index: Double) -> Double {
        switch self {
        case .piecewiseLinear(let knots):
            return Self.interpolateLinear(index, knots: knots)

        case .monotoneCubic(let knots, let slopes):
            return Self.interpolateCubic(index, knots: knots, slopes: slopes)

        case .powerLaw(let logIntercept, let slope):
            guard index > 0 else { return 0 }
            return exp(logIntercept + slope * log(index))
        }
    }

    /// Local sensitivity `dNTU/dIndex`, used to turn the spread of repeat
    /// readings into an NTU uncertainty.
    func sensitivity(atIndex index: Double) -> Double {
        let step = max(1e-6, abs(index) * 1e-4)
        return (ntu(forIndex: index + step) - ntu(forIndex: index - step)) / (2 * step)
    }

    // MARK: - Evaluation

    static func interpolateLinear(_ x: Double, knots: [Knot]) -> Double {
        guard let first = knots.first, let last = knots.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }

        for index in 1..<knots.count where x <= knots[index].x {
            let low = knots[index - 1]
            let high = knots[index]
            let span = high.x - low.x
            guard span > 0 else { return low.y }
            return low.y + (high.y - low.y) * (x - low.x) / span
        }
        return last.y
    }

    static func interpolateCubic(_ x: Double, knots: [Knot], slopes: [Double]) -> Double {
        guard knots.count >= 2, slopes.count == knots.count,
              let first = knots.first, let last = knots.last else {
            return interpolateLinear(x, knots: knots)
        }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }

        for index in 1..<knots.count where x <= knots[index].x {
            let low = knots[index - 1]
            let high = knots[index]
            let h = high.x - low.x
            guard h > 0 else { return low.y }

            // Cubic Hermite basis.
            let t = (x - low.x) / h
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2

            return h00 * low.y + h10 * h * slopes[index - 1]
                 + h01 * high.y + h11 * h * slopes[index]
        }
        return last.y
    }

    // MARK: - Fitting

    /// Fritsch-Carlson slopes: the standard construction that makes a cubic
    /// Hermite interpolant monotone.
    ///
    /// Where the data changes direction the slope is set to zero, and elsewhere
    /// a weighted harmonic mean of the neighbouring secants is used, which is
    /// never large enough to make the cubic overshoot.
    static func monotoneSlopes(knots: [Knot]) -> [Double] {
        let count = knots.count
        guard count >= 2 else { return Array(repeating: 0, count: count) }

        var widths = [Double](repeating: 0, count: count - 1)
        var secants = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            widths[index] = knots[index + 1].x - knots[index].x
            secants[index] = widths[index] > 0
                ? (knots[index + 1].y - knots[index].y) / widths[index]
                : 0
        }

        var slopes = [Double](repeating: 0, count: count)
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]

        for index in 1..<(count - 1) {
            let left = secants[index - 1]
            let right = secants[index]
            if left * right <= 0 {
                // A local extremum: a zero slope is what keeps the cubic from
                // overshooting through it.
                slopes[index] = 0
            } else {
                let hLeft = widths[index - 1]
                let hRight = widths[index]
                let weight = 2 * hRight + hLeft
                let weightOther = hRight + 2 * hLeft
                slopes[index] = (weight + weightOther) / (weight / left + weightOther / right)
            }
        }

        // Endpoint limiting, so the ends cannot overshoot either.
        for index in [0, count - 1] {
            let secant = index == 0 ? secants[0] : secants[count - 2]
            if secant == 0 {
                slopes[index] = 0
            } else if slopes[index] / secant > 3 {
                slopes[index] = 3 * secant
            } else if slopes[index] < 0 {
                slopes[index] = 0
            }
        }

        return slopes
    }

    /// - Returns: `nil` when the points are not strictly increasing in `x`,
    ///   which no monotone mapping can represent.
    static func piecewiseLinear(through points: [Knot]) -> MonotonicMapping? {
        guard points.count >= 2, isStrictlyIncreasingInX(points) else { return nil }
        return .piecewiseLinear(knots: points)
    }

    static func monotoneCubic(through points: [Knot]) -> MonotonicMapping? {
        guard points.count >= 3, isStrictlyIncreasingInX(points) else { return nil }
        return .monotoneCubic(knots: points, slopes: monotoneSlopes(knots: points))
    }

    /// Least-squares fit of `log(y) = slope * log(x) + intercept`.
    ///
    /// - Returns: `nil` when any point is non-positive (a logarithm needs
    ///   positive values, so the blank cannot take part) or when the fitted
    ///   slope is not positive, which would make the mapping decreasing.
    static func powerLaw(through points: [Knot]) -> MonotonicMapping? {
        let usable = points.filter { $0.x > 0 && $0.y > 0 }
        guard usable.count >= 2 else { return nil }

        let logsX = usable.map { log($0.x) }
        let logsY = usable.map { log($0.y) }
        let n = Double(usable.count)
        let meanX = logsX.reduce(0, +) / n
        let meanY = logsY.reduce(0, +) / n

        var covariance: Double = 0
        var variance: Double = 0
        for index in usable.indices {
            covariance += (logsX[index] - meanX) * (logsY[index] - meanY)
            variance += (logsX[index] - meanX) * (logsX[index] - meanX)
        }
        guard variance > 0 else { return nil }

        let slope = covariance / variance
        guard slope > 0 else { return nil }
        return .powerLaw(logIntercept: meanY - slope * meanX, slope: slope)
    }

    static func isStrictlyIncreasingInX(_ points: [Knot]) -> Bool {
        guard points.count >= 2 else { return false }
        for index in 1..<points.count where points[index].x <= points[index - 1].x {
            return false
        }
        return true
    }

    /// Checks monotonicity by sampling, which catches an overshoot the
    /// construction was supposed to prevent.
    func isMonotoneIncreasing(over range: ClosedRange<Double>, samples: Int = 200) -> Bool {
        guard samples >= 2, range.upperBound > range.lowerBound else { return true }
        var previous = -Double.greatestFiniteMagnitude
        for step in 0...samples {
            let x = range.lowerBound
                + (range.upperBound - range.lowerBound) * Double(step) / Double(samples)
            let y = ntu(forIndex: x)
            // A tiny tolerance, because floating point can produce an
            // insignificant dip where the maths says flat.
            if y < previous - 1e-9 { return false }
            previous = y
        }
        return true
    }
}
