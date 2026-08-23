import Foundation

/// A seeded pseudo-random generator with no dependency on the system RNG.
///
/// The synthetic harness must produce byte-identical frames from the same seed
/// on every machine and every run: a test that only sometimes reproduces a
/// failure is worse than no test. `SystemRandomNumberGenerator` cannot promise
/// that, so this implements SplitMix64, whose algorithm is fixed and public.
struct DeterministicRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        // Any seed works, including zero: SplitMix64's increment guarantees the
        // sequence advances regardless.
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<1`.
    mutating func nextUnitFloat() -> Float {
        // 24 bits: exactly the mantissa precision of Float, so every value is
        // representable and the distribution stays uniform.
        Float(next() >> 40) / Float(1 << 24)
    }

    /// Uniform in `lower...upper`.
    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextUnitFloat() * (range.upperBound - range.lowerBound)
    }

    /// Standard normal, via the Box-Muller transform.
    mutating func nextGaussian() -> Float {
        // Guard the log against exactly zero, which would give -infinity.
        let u1 = max(nextUnitFloat(), .leastNormalMagnitude)
        let u2 = nextUnitFloat()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
