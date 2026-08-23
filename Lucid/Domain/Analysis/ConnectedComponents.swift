import CoreGraphics
import Foundation

/// Extracts connected bright components and their features.
///
/// Iterative flood fill with an explicit stack, eight-connected. Iterative
/// rather than recursive on purpose: a large connected region in a noisy frame
/// would otherwise recurse once per pixel and overflow the stack.
///
/// The label buffer and the stack are owned by the caller and reused, so a
/// per-frame call allocates only the small output array.
struct ConnectedComponentExtractor: Sendable {

    /// Bounded so one bad frame cannot produce a hundred thousand components.
    /// Anything beyond the cap is counted and reported, never silently dropped.
    let maximumComponents: Int

    init(maximumComponents: Int = 512) {
        self.maximumComponents = max(1, maximumComponents)
    }

    struct Input {
        /// Band-passed response; components are grown where this exceeds
        /// `threshold`.
        let response: [Float]
        /// Positive residual before band-passing, for brightness features.
        let residual: [Float]
        /// The raw normalized frame, for detecting a clipped core.
        let source: [Float]
        let width: Int
        let height: Int
        let mask: RasterizedMask?
        let threshold: Float
        let saturationThreshold: Float
        /// Distance in pixels from each pixel to the nearest excluded pixel or
        /// region border, computed once per region size.
        let exclusionDistance: [Float]
    }

    struct Output {
        var components: [SpeckCandidate] = []
        var totalComponentCount = 0
        var truncatedCount = 0
        /// `true` where the pixel belongs to a component, for the background
        /// model's foreground-aware update.
        var foreground: [Bool] = []
    }

    /// - Parameters:
    ///   - labels: reused buffer, `input.width * input.height`.
    ///   - stack: reused buffer for the flood fill.
    ///   - foreground: reused buffer, written with the foreground mask.
    func extract(_ input: Input,
                 labels: inout [Int32],
                 stack: inout [Int32],
                 foreground: inout [Bool]) -> Output {
        let width = input.width
        let height = input.height
        let count = width * height

        var output = Output()
        guard count > 0,
              labels.count == count,
              foreground.count == count,
              input.response.count == count else { return output }

        for index in 0..<count {
            labels[index] = 0
            foreground[index] = false
        }

        let regionDiagonal = (Double(width * width + height * height)).squareRoot()
        let validArea = Double(input.mask?.validCount ?? count)

        var nextLabel: Int32 = 1
        var candidates: [SpeckCandidate] = []
        candidates.reserveCapacity(min(maximumComponents, 64))

        for seed in 0..<count where labels[seed] == 0 {
            guard input.response[seed] > input.threshold else { continue }
            if let mask = input.mask, !mask.isValid(atIndex: seed) { continue }

            // --- Flood fill -------------------------------------------------
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(seed))
            labels[seed] = nextLabel

            var areaPixels = 0
            var weightSum: Double = 0
            var weightedX: Double = 0
            var weightedY: Double = 0
            var sumX: Double = 0
            var sumY: Double = 0
            var sumXX: Double = 0
            var sumYY: Double = 0
            var sumXY: Double = 0
            var peakResponse: Float = 0
            var integratedResponse: Double = 0
            var peakResidual: Float = 0
            var saturated = false
            var minX = width, maxX = 0, minY = height, maxY = 0

            while let raw = stack.popLast() {
                let index = Int(raw)
                let x = index % width
                let y = index / width

                let response = input.response[index]
                let residual = input.residual[index]
                // Weighted by band-pass response so the centroid follows the
                // bright core rather than the component's outline.
                let weight = Double(max(response, 0))

                areaPixels += 1
                weightSum += weight
                weightedX += weight * Double(x)
                weightedY += weight * Double(y)
                sumX += Double(x)
                sumY += Double(y)
                sumXX += Double(x * x)
                sumYY += Double(y * y)
                sumXY += Double(x * y)
                peakResponse = max(peakResponse, response)
                integratedResponse += Double(response)
                peakResidual = max(peakResidual, residual)
                if input.source[index] >= input.saturationThreshold { saturated = true }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                foreground[index] = true

                for neighbourY in max(0, y - 1)...min(height - 1, y + 1) {
                    for neighbourX in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbour = neighbourY * width + neighbourX
                        guard labels[neighbour] == 0,
                              input.response[neighbour] > input.threshold else { continue }
                        if let mask = input.mask, !mask.isValid(atIndex: neighbour) { continue }
                        labels[neighbour] = nextLabel
                        stack.append(Int32(neighbour))
                    }
                }
            }

            nextLabel += 1
            output.totalComponentCount += 1

            if candidates.count >= maximumComponents {
                output.truncatedCount += 1
                continue
            }

            // --- Features ---------------------------------------------------
            let area = Double(areaPixels)
            let centroidX = weightSum > 0 ? weightedX / weightSum : sumX / area
            let centroidY = weightSum > 0 ? weightedY / weightSum : sumY / area

            let meanX = sumX / area
            let meanY = sumY / area
            let varianceX = max(0, sumXX / area - meanX * meanX)
            let varianceY = max(0, sumYY / area - meanY * meanY)
            let covariance = sumXY / area - meanX * meanY

            let equivalentDiameter = 2 * (area / .pi).squareRoot()
            let boundingBox = PixelRect(x: minX, y: minY,
                                        width: maxX - minX + 1,
                                        height: maxY - minY + 1)
            let distance = Double(input.exclusionDistance.isEmpty
                                  ? Float(min(min(minX, minY), min(width - 1 - maxX, height - 1 - maxY)))
                                  : input.exclusionDistance[
                                      min(count - 1, max(0, Int(centroidY.rounded()) * width
                                                            + Int(centroidX.rounded())))
                                    ])

            candidates.append(SpeckCandidate(
                centroidX: centroidX,
                centroidY: centroidY,
                normalizedCentroid: CGPoint(x: centroidX / Double(width),
                                            y: centroidY / Double(height)),
                areaPixels: areaPixels,
                normalizedArea: validArea > 0 ? area / validArea : 0,
                equivalentDiameterPixels: equivalentDiameter,
                normalizedDiameter: regionDiagonal > 0 ? equivalentDiameter / regionDiagonal : 0,
                peakResponse: peakResponse,
                integratedResponse: integratedResponse,
                peakResidual: peakResidual,
                localContrast: input.threshold > 0 ? Double(peakResponse) / Double(input.threshold) : 0,
                eccentricity: Self.eccentricity(varianceX: varianceX,
                                                varianceY: varianceY,
                                                covariance: covariance),
                fillRatio: boundingBox.pixelCount > 0
                    ? area / Double(boundingBox.pixelCount) : 0,
                boundingBox: boundingBox,
                distanceToExclusionPixels: distance,
                normalizedDistanceToExclusion: regionDiagonal > 0 ? distance / regionDiagonal : 0,
                containsSaturatedPixel: saturated
            ))
        }

        output.components = candidates
        return output
    }

    /// Eccentricity from the second central moments of the pixel positions.
    ///
    /// Uses the eigenvalues of the position covariance matrix, which needs no
    /// perimeter tracing and is stable for components only a few pixels across
    /// — where a perimeter-based circularity is dominated by which pixels
    /// happen to be on the boundary.
    static func eccentricity(varianceX: Double, varianceY: Double, covariance: Double) -> Double {
        let trace = varianceX + varianceY
        guard trace > 0 else { return 0 }
        let difference = varianceX - varianceY
        let root = (difference * difference + 4 * covariance * covariance).squareRoot()
        let major = (trace + root) / 2
        let minor = (trace - root) / 2
        guard major > 0 else { return 0 }
        // A single pixel, or a perfectly symmetric blob, has minor == major.
        return (1 - minor / major).squareRoot()
    }

    /// Chebyshev distance transform to the nearest excluded pixel or border.
    ///
    /// Two passes over the buffer, which is exact for the eight-connected
    /// (chessboard) metric. Computed once per region size, not per frame.
    static func exclusionDistanceMap(width: Int, height: Int, mask: RasterizedMask?) -> [Float] {
        let count = width * height
        guard count > 0 else { return [] }

        let large = Float(width + height)
        var distance = [Float](repeating: large, count: count)

        func isExcluded(_ x: Int, _ y: Int) -> Bool {
            if x < 0 || y < 0 || x >= width || y >= height { return true }
            guard let mask else { return false }
            return !mask.isValid(atIndex: y * width + x)
        }

        for y in 0..<height {
            for x in 0..<width where isExcluded(x, y) {
                distance[y * width + x] = 0
            }
        }

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                var best = distance[index]
                for dy in -1...0 {
                    for dx in -1...1 {
                        if dy == 0 && dx >= 0 { continue }
                        let nx = x + dx, ny = y + dy
                        let neighbour = (nx < 0 || ny < 0 || nx >= width) ? 0 : distance[ny * width + nx] + 1
                        best = min(best, neighbour)
                    }
                }
                distance[index] = best
            }
        }

        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let index = y * width + x
                var best = distance[index]
                for dy in 0...1 {
                    for dx in -1...1 {
                        if dy == 0 && dx <= 0 { continue }
                        let nx = x + dx, ny = y + dy
                        let neighbour = (nx < 0 || ny >= height || nx >= width) ? 0 : distance[ny * width + nx] + 1
                        best = min(best, neighbour)
                    }
                }
                distance[index] = best
            }
        }

        return distance
    }
}
