import CoreGraphics
import Foundation

/// A stationary defect on the container or lens: a scratch.
///
/// Static scratches are the thing background subtraction exists to remove, so
/// the harness has to be able to draw one that does not move at all.
struct SyntheticScratch: Equatable, Sendable {
    /// Endpoints in normalized frame coordinates.
    var start: CGPoint
    var end: CGPoint
    var brightness: Float
    var widthPixels: Float
}

/// A bright blob that never moves: a trapped bubble or a fixed reflection.
struct SyntheticStationaryBlob: Equatable, Sendable {
    var center: CGPoint
    var radiusPixels: Float
    var brightness: Float
}

/// A small suspended particle drifting on a curved path.
///
/// Real suspended specks in a settling sample follow slow, curved, locally
/// coherent trajectories rather than straight lines, so the synthetic version
/// moves on a circle with a slow drift superimposed.
struct SyntheticSpeck: Equatable, Sendable {
    var center: CGPoint
    /// Radius of the circular component of the path, in normalized units.
    var orbitRadius: Double
    /// Radians per second.
    var angularSpeed: Double
    var initialPhase: Double
    /// Normalized units per second, added to the orbit.
    var drift: CGVector
    var radiusPixels: Float
    var brightness: Float

    func position(atTime time: Double) -> CGPoint {
        let angle = initialPhase + angularSpeed * time
        return CGPoint(
            x: center.x + CGFloat(orbitRadius * cos(angle)) + drift.dx * CGFloat(time),
            y: center.y + CGFloat(orbitRadius * sin(angle)) + drift.dy * CGFloat(time)
        )
    }
}

/// A larger air bubble rising steadily.
///
/// Bubbles are the main false positive: bright, round, and moving. They differ
/// from suspended specks by being larger, faster, and persistently vertical.
struct SyntheticRisingBubble: Equatable, Sendable {
    var startPosition: CGPoint
    /// Normalized units per second. Negative moves up the image.
    var riseSpeed: Double
    var radiusPixels: Float
    var brightness: Float

    func position(atTime time: Double) -> CGPoint {
        CGPoint(x: startPosition.x, y: startPosition.y + CGFloat(riseSpeed * time))
    }
}

/// Sinusoidal exposure variation, as mains-frequency flicker produces.
struct SyntheticFlicker: Equatable, Sendable {
    var amplitude: Float
    var frequencyHertz: Double
    var phase: Double

    static let none = SyntheticFlicker(amplitude: 0, frequencyHertz: 0, phase: 0)

    func gain(atTime time: Double) -> Float {
        guard amplitude != 0 else { return 1 }
        return 1 + amplitude * Float(sin(2 * .pi * frequencyHertz * time + phase))
    }
}

/// A saturated specular highlight, as the torch reflecting off glass produces.
struct SyntheticHotspot: Equatable, Sendable {
    var center: CGPoint
    var radiusPixels: Float
    var peakBrightness: Float
}

/// The complete description of a synthetic capture.
///
/// Everything the analyzer must cope with is expressible here, so a failing
/// scenario can be written down, replayed exactly, and kept as a regression.
struct SyntheticScene: Equatable, Sendable {
    var width: Int
    var height: Int
    /// Uniform background level before any feature is drawn.
    var baseLevel: Float
    /// Standard deviation of the additive Gaussian sensor noise.
    var noiseSigma: Float
    /// Strength of the radial falloff, `0` for none.
    var vignette: Float

    var scratches: [SyntheticScratch]
    var stationaryBlobs: [SyntheticStationaryBlob]
    var specks: [SyntheticSpeck]
    var risingBubbles: [SyntheticRisingBubble]
    var hotspot: SyntheticHotspot?
    var flicker: SyntheticFlicker
    /// Whole-frame translation in normalized units per second: the phone moving.
    var globalTranslation: CGVector

    var seed: UInt64

    init(width: Int = 160,
         height: Int = 120,
         baseLevel: Float = 0.12,
         noiseSigma: Float = 0.004,
         vignette: Float = 0,
         scratches: [SyntheticScratch] = [],
         stationaryBlobs: [SyntheticStationaryBlob] = [],
         specks: [SyntheticSpeck] = [],
         risingBubbles: [SyntheticRisingBubble] = [],
         hotspot: SyntheticHotspot? = nil,
         flicker: SyntheticFlicker = .none,
         globalTranslation: CGVector = .zero,
         seed: UInt64 = 0x5EED) {
        self.width = width
        self.height = height
        self.baseLevel = baseLevel
        self.noiseSigma = noiseSigma
        self.vignette = vignette
        self.scratches = scratches
        self.stationaryBlobs = stationaryBlobs
        self.specks = specks
        self.risingBubbles = risingBubbles
        self.hotspot = hotspot
        self.flicker = flicker
        self.globalTranslation = globalTranslation
        self.seed = seed
    }

    /// A clean, well-exposed, perfectly still sample. The baseline every other
    /// scenario is a modification of.
    static let clean = SyntheticScene()
}
