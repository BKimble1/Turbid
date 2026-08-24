import Foundation

/// Small-scale Difference of Gaussians.
///
/// Emphasises point-like bright events at the scale of a few pixels while
/// removing anything that varies slowly across the frame: an illumination
/// gradient, a residual vignette, or the whole-frame brightness change that
/// exposure flicker produces. Those are exactly the things that would otherwise
/// be mistaken for scattered light.
///
/// The response peaks for a blob of radius roughly `narrowSigma * sqrt(2)`,
/// which is why the narrow scale is set near one pixel: a suspended speck is
/// imaged across two or three.
///
/// This is the reference implementation the design calls for: correct,
/// readable, and directly comparable against the Python cross-check. It is
/// separable, so cost is linear in the kernel radius rather than quadratic.
/// Whether it needs to move to Accelerate or a Metal kernel is a question for
/// on-device profiling, not for a guess made here; the golden tests do not
/// change when it does.
struct BandPassFilter: Sendable {

    struct Configuration: Equatable, Sendable, Codable {
        var narrowSigma: Double
        var wideSigma: Double
        var version: Int

        static let screening = Configuration(narrowSigma: 1.0, wideSigma: 2.5, version: 1)
    }

    let configuration: Configuration
    private let narrowKernel: [Float]
    private let wideKernel: [Float]

    /// Half-width of the wide kernel, in pixels. Anything within this distance
    /// of a masked pixel or the region border carries an edge artefact rather
    /// than a real response.
    var wideKernelRadius: Int { wideKernel.count / 2 }

    init(configuration: Configuration = .screening) {
        self.configuration = configuration
        narrowKernel = Self.gaussianKernel(sigma: configuration.narrowSigma)
        wideKernel = Self.gaussianKernel(sigma: configuration.wideSigma)
    }

    /// Truncated at three standard deviations, where the tail holds about 0.3%
    /// of the weight, and renormalised so the kernel still sums to one.
    static func gaussianKernel(sigma: Double) -> [Float] {
        guard sigma > 0 else { return [1] }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: radius * 2 + 1)
        var total: Double = 0

        for offset in -radius...radius {
            let value = exp(-Double(offset * offset) / (2 * sigma * sigma))
            kernel[offset + radius] = Float(value)
            total += value
        }
        guard total > 0 else { return [1] }
        for index in kernel.indices { kernel[index] /= Float(total) }
        return kernel
    }

    /// Writes `narrowBlur - wideBlur` into `destination`.
    ///
    /// `scratchA` and `scratchB` are caller-owned working buffers of the same
    /// size, so a per-frame call allocates nothing.
    func apply(to source: [Float],
               width: Int,
               height: Int,
               destination: inout [Float],
               scratchA: inout [Float],
               scratchB: inout [Float]) {
        let count = width * height
        guard count > 0,
              source.count == count,
              destination.count == count,
              scratchA.count == count,
              scratchB.count == count else { return }

        // Narrow blur into scratchB, via scratchA.
        Self.convolveHorizontally(source, width: width, height: height,
                                  kernel: narrowKernel, into: &scratchA)
        Self.convolveVertically(scratchA, width: width, height: height,
                                kernel: narrowKernel, into: &scratchB)

        // Wide blur into destination, reusing scratchA.
        Self.convolveHorizontally(source, width: width, height: height,
                                  kernel: wideKernel, into: &scratchA)
        Self.convolveVertically(scratchA, width: width, height: height,
                                kernel: wideKernel, into: &destination)

        for index in 0..<count {
            destination[index] = scratchB[index] - destination[index]
        }
    }

    /// Edges are handled by clamping to the nearest real sample. Zero-padding
    /// would create an artificial dark border, and the band-pass would report
    /// that border as a feature.
    static func convolveHorizontally(_ source: [Float],
                                     width: Int,
                                     height: Int,
                                     kernel: [Float],
                                     into destination: inout [Float]) {
        let radius = kernel.count / 2
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var total: Float = 0
                for tap in 0..<kernel.count {
                    let sampleX = min(max(x + tap - radius, 0), width - 1)
                    total += source[row + sampleX] * kernel[tap]
                }
                destination[row + x] = total
            }
        }
    }

    static func convolveVertically(_ source: [Float],
                                   width: Int,
                                   height: Int,
                                   kernel: [Float],
                                   into destination: inout [Float]) {
        let radius = kernel.count / 2
        for y in 0..<height {
            for x in 0..<width {
                var total: Float = 0
                for tap in 0..<kernel.count {
                    let sampleY = min(max(y + tap - radius, 0), height - 1)
                    total += source[sampleY * width + x] * kernel[tap]
                }
                destination[y * width + x] = total
            }
        }
    }
}
