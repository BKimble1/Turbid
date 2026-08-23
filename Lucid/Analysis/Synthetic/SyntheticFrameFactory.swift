import CoreGraphics
import Foundation

/// Renders `SyntheticScene` into deterministic `LumaImage` frames.
///
/// The same scene, seed and timestamp always produce the identical frame, on
/// any machine. That is what makes an analyzer regression reproducible instead
/// of merely likely.
struct SyntheticFrameFactory: Sendable {

    /// Renders one frame at a given time.
    ///
    /// Sensor noise is seeded from the scene seed *and* the frame index, so
    /// consecutive frames have independent noise (as a real sensor does) while
    /// the whole sequence stays reproducible.
    static func render(_ scene: SyntheticScene,
                       atTime time: Double,
                       frameIndex: Int) -> LumaImage {
        var image = LumaImage(width: scene.width, height: scene.height, fill: scene.baseLevel)
        guard scene.width > 0, scene.height > 0 else { return image }

        let offset = CGVector(dx: scene.globalTranslation.dx * CGFloat(time),
                              dy: scene.globalTranslation.dy * CGFloat(time))

        applyVignette(to: &image, strength: scene.vignette)

        // Stationary features move with the camera, because they are attached
        // to the container or the lens rather than floating in the liquid.
        for scratch in scene.scratches {
            draw(scratch: scratch, into: &image, offset: offset)
        }
        for blob in scene.stationaryBlobs {
            draw(disc: shift(blob.center, by: offset),
                 radiusPixels: blob.radiusPixels,
                 brightness: blob.brightness,
                 into: &image)
        }
        if let hotspot = scene.hotspot {
            draw(disc: shift(hotspot.center, by: offset),
                 radiusPixels: hotspot.radiusPixels,
                 brightness: hotspot.peakBrightness,
                 into: &image)
        }

        // Suspended features move on their own path *and* with the camera.
        for speck in scene.specks {
            draw(disc: shift(speck.position(atTime: time), by: offset),
                 radiusPixels: speck.radiusPixels,
                 brightness: speck.brightness,
                 into: &image)
        }
        for bubble in scene.risingBubbles {
            draw(disc: shift(bubble.position(atTime: time), by: offset),
                 radiusPixels: bubble.radiusPixels,
                 brightness: bubble.brightness,
                 into: &image)
        }

        let gain = scene.flicker.gain(atTime: time)
        var random = DeterministicRandom(seed: scene.seed &+ UInt64(bitPattern: Int64(frameIndex)))

        for index in image.values.indices {
            let noisy = image.values[index] * gain
                + (scene.noiseSigma > 0 ? random.nextGaussian() * scene.noiseSigma : 0)
            // Clamped last, so a synthetic frame can genuinely clip the same way
            // a real one does and exercise the saturation gate.
            image.values[index] = min(max(noisy, 0), 1)
        }

        return image
    }

    /// Renders a sequence at the given presentation timestamps.
    ///
    /// Timestamps are supplied rather than derived, so a caller can hand in an
    /// irregular or gappy series and get frames whose content matches those
    /// exact times.
    static func sequence(_ scene: SyntheticScene, timestamps: [Double]) -> [(time: Double, image: LumaImage)] {
        timestamps.enumerated().map { index, time in
            (time, render(scene, atTime: time, frameIndex: index))
        }
    }

    // MARK: - Drawing

    private static func shift(_ point: CGPoint, by offset: CGVector) -> CGPoint {
        CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
    }

    private static func applyVignette(to image: inout LumaImage, strength: Float) {
        guard strength > 0 else { return }
        let centerX = Float(image.width) / 2
        let centerY = Float(image.height) / 2
        let maximumRadius = (centerX * centerX + centerY * centerY).squareRoot()
        guard maximumRadius > 0 else { return }

        for y in 0..<image.height {
            let dy = Float(y) - centerY
            for x in 0..<image.width {
                let dx = Float(x) - centerX
                let radius = (dx * dx + dy * dy).squareRoot() / maximumRadius
                image.values[y * image.width + x] *= (1 - strength * radius * radius)
            }
        }
    }

    /// Draws a soft-edged bright disc, added to whatever is already there.
    ///
    /// Additive rather than replacing, because scattered light adds to the
    /// background rather than masking it, and a soft edge because a real point
    /// source is spread by the lens point-spread function over a few pixels.
    private static func draw(disc center: CGPoint,
                             radiusPixels: Float,
                             brightness: Float,
                             into image: inout LumaImage) {
        guard radiusPixels > 0, image.width > 0, image.height > 0 else { return }

        let centerX = Float(center.x) * Float(image.width)
        let centerY = Float(center.y) * Float(image.height)
        // One extra pixel of reach for the soft edge.
        let extent = Int(radiusPixels.rounded(.up)) + 1

        let minX = max(0, Int(centerX) - extent)
        let maxX = min(image.width - 1, Int(centerX) + extent)
        let minY = max(0, Int(centerY) - extent)
        let maxY = min(image.height - 1, Int(centerY) + extent)
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            let dy = Float(y) + 0.5 - centerY
            for x in minX...maxX {
                let dx = Float(x) + 0.5 - centerX
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= radiusPixels + 1 else { continue }
                // Gaussian-like falloff, full brightness at the centre and
                // tapering to zero one pixel past the nominal radius.
                let falloff = max(0, 1 - (distance / (radiusPixels + 1)))
                image.values[y * image.width + x] += brightness * falloff * falloff
            }
        }
    }

    private static func draw(scratch: SyntheticScratch,
                             into image: inout LumaImage,
                             offset: CGVector) {
        let start = shift(scratch.start, by: offset)
        let end = shift(scratch.end, by: offset)

        let startX = Float(start.x) * Float(image.width)
        let startY = Float(start.y) * Float(image.height)
        let endX = Float(end.x) * Float(image.width)
        let endY = Float(end.y) * Float(image.height)

        let length = ((endX - startX) * (endX - startX) + (endY - startY) * (endY - startY)).squareRoot()
        let steps = max(1, Int(length.rounded(.up)))

        for step in 0...steps {
            let t = Float(step) / Float(steps)
            let x = (startX + (endX - startX) * t) / Float(image.width)
            let y = (startY + (endY - startY) * t) / Float(image.height)
            draw(disc: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                 radiusPixels: max(0.5, scratch.widthPixels / 2),
                 brightness: scratch.brightness,
                 into: &image)
        }
    }
}

/// Generates presentation-timestamp series, including the awkward ones.
///
/// Timing is a first-class input to the analyzer, so the harness has to be able
/// to produce jitter and gaps as easily as a clean 30 fps stream.
enum SyntheticTimestamps {

    /// Perfectly regular delivery.
    static func regular(count: Int, frameRate: Double, start: Double = 0) -> [Double] {
        guard count > 0, frameRate > 0 else { return [] }
        return (0..<count).map { start + Double($0) / frameRate }
    }

    /// Regular delivery with bounded random jitter, as a real camera produces.
    static func jittered(count: Int,
                         frameRate: Double,
                         jitterSeconds: Double,
                         seed: UInt64 = 0x1177E5,
                         start: Double = 0) -> [Double] {
        guard count > 0, frameRate > 0 else { return [] }
        var random = DeterministicRandom(seed: seed)
        var timestamps: [Double] = []
        timestamps.reserveCapacity(count)

        var time = start
        for index in 0..<count {
            let jitter = index == 0 ? 0 : Double(random.nextFloat(in: -1...1)) * jitterSeconds
            // Clamped so the series stays strictly increasing: a presentation
            // timestamp that goes backwards is not something a camera does.
            time += max(1e-6, 1 / frameRate + jitter)
            timestamps.append(index == 0 ? start : time)
        }
        return timestamps
    }

    /// Regular delivery with whole frames missing at the given indices.
    static func withDrops(count: Int,
                          frameRate: Double,
                          droppedIndices: Set<Int>,
                          start: Double = 0) -> [Double] {
        regular(count: count, frameRate: frameRate, start: start)
            .enumerated()
            .filter { !droppedIndices.contains($0.offset) }
            .map(\.element)
    }

    /// Regular delivery interrupted by one long stall.
    static func withStall(count: Int,
                          frameRate: Double,
                          stallAfterIndex: Int,
                          stallSeconds: Double,
                          start: Double = 0) -> [Double] {
        guard count > 0, frameRate > 0 else { return [] }
        return (0..<count).map { index in
            let base = start + Double(index) / frameRate
            return index > stallAfterIndex ? base + stallSeconds : base
        }
    }
}
