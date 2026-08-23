import CoreGraphics
import Foundation

/// Shapes excluded from analysis, in coordinates normalized to the region of
/// interest (`0...1` on each axis).
///
/// Resolution-independent on purpose: the same description is valid whichever
/// capture format is active, and it is rasterized once when the working size
/// becomes known.
struct OpticalMaskDescription: Equatable, Sendable, Codable {
    var excludedRectangles: [CGRect]
    var excludedEllipses: [CGRect]

    static let none = OpticalMaskDescription(excludedRectangles: [], excludedEllipses: [])

    var isEmpty: Bool { excludedRectangles.isEmpty && excludedEllipses.isEmpty }

    func excludes(normalizedX x: Double, normalizedY y: Double) -> Bool {
        let point = CGPoint(x: x, y: y)
        if excludedRectangles.contains(where: { $0.contains(point) }) { return true }

        return excludedEllipses.contains { ellipse in
            guard ellipse.width > 0, ellipse.height > 0 else { return false }
            let normalizedDX = (x - ellipse.midX) / (ellipse.width / 2)
            let normalizedDY = (y - ellipse.midY) / (ellipse.height / 2)
            return normalizedDX * normalizedDX + normalizedDY * normalizedDY <= 1
        }
    }
}

/// A rasterized mask at one working resolution.
struct RasterizedMask: Equatable, Sendable {
    let width: Int
    let height: Int
    /// `true` where the pixel may be analyzed.
    let isValid: [Bool]
    let validCount: Int

    init(description: OpticalMaskDescription, width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)

        var flags = [Bool](repeating: true, count: self.width * self.height)
        var valid = flags.count

        if !description.isEmpty && self.width > 0 && self.height > 0 {
            for y in 0..<self.height {
                // Sample at pixel centres so a mask edge falls between pixels
                // rather than arbitrarily including or excluding a whole row.
                let normalizedY = (Double(y) + 0.5) / Double(self.height)
                for x in 0..<self.width {
                    let normalizedX = (Double(x) + 0.5) / Double(self.width)
                    if description.excludes(normalizedX: normalizedX, normalizedY: normalizedY) {
                        flags[y * self.width + x] = false
                        valid -= 1
                    }
                }
            }
        }

        self.isValid = flags
        self.validCount = valid
    }

    func isValid(atIndex index: Int) -> Bool {
        index >= 0 && index < isValid.count ? isValid[index] : false
    }
}

/// Where in the frame the measurement is made.
///
/// The region must sit inside the liquid volume, clear of the container walls,
/// the meniscus, any label, the direct torch hotspot and known reflections.
/// The concrete geometry is a property of the fixture and container, so a
/// calibration profile carries its own (Phase 3D). The value below is a
/// documented starting point for screening, not a validated constant.
struct AnalysisRegion: Equatable, Sendable, Codable {
    /// Normalized to the full frame, top-left origin.
    var normalizedRect: CGRect
    /// Normalized to `normalizedRect`, not to the frame.
    var mask: OpticalMaskDescription
    /// Bumped whenever the geometry changes, so a measurement can record which
    /// region produced it and a calibration can refuse a mismatched one.
    var version: Int

    init(normalizedRect: CGRect,
         mask: OpticalMaskDescription = .none,
         version: Int = 1) {
        self.normalizedRect = normalizedRect
        self.mask = mask
        self.version = version
    }

    /// Screening default.
    ///
    /// A centred rectangle covering about half the frame width, biased slightly
    /// below centre because the torch sits above the rear lens on every current
    /// iPhone, which puts the specular hotspot in the upper part of the frame.
    /// The excluded ellipse covers that hotspot; the excluded top strip covers
    /// the meniscus.
    static let screeningDefault = AnalysisRegion(
        normalizedRect: CGRect(x: 0.25, y: 0.28, width: 0.50, height: 0.44),
        mask: OpticalMaskDescription(
            excludedRectangles: [
                // Meniscus and the air-water boundary above the sample.
                CGRect(x: 0, y: 0, width: 1, height: 0.12)
            ],
            excludedEllipses: [
                // Direct torch reflection off the near container wall.
                CGRect(x: 0.30, y: 0.02, width: 0.40, height: 0.34)
            ]
        ),
        version: 1
    )

    /// The whole frame with nothing masked. Used by tests that want to reason
    /// about every pixel they wrote.
    static let fullFrame = AnalysisRegion(
        normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
        mask: .none,
        version: 0
    )

    /// Converts the normalized rectangle to whole pixels, clamped to the frame.
    ///
    /// - Returns: `nil` when the region would be empty at this resolution.
    func pixelRect(inWidth frameWidth: Int, height frameHeight: Int) -> PixelRect? {
        guard frameWidth > 0, frameHeight > 0 else { return nil }

        let clamped = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }

        let x = Int((clamped.minX * CGFloat(frameWidth)).rounded(.down))
        let y = Int((clamped.minY * CGFloat(frameHeight)).rounded(.down))
        let maxX = Int((clamped.maxX * CGFloat(frameWidth)).rounded(.up))
        let maxY = Int((clamped.maxY * CGFloat(frameHeight)).rounded(.up))

        let width = min(maxX, frameWidth) - x
        let height = min(maxY, frameHeight) - y
        guard width > 0, height > 0 else { return nil }

        return PixelRect(x: x, y: y, width: width, height: height)
    }
}

struct PixelRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var pixelCount: Int { width * height }
}
