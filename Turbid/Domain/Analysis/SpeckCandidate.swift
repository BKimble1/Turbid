import CoreGraphics
import Foundation

/// One connected bright event extracted from the band-passed residual.
///
/// Every size and position is available in both pixels and normalized units.
/// The normalized values are what the filters and later phases use: a threshold
/// expressed in pixels would silently mean something different on a different
/// capture format or a different region size.
struct SpeckCandidate: Equatable, Sendable {
    /// Intensity-weighted centroid, in pixels within the analysis region.
    let centroidX: Double
    let centroidY: Double
    /// Centroid as a fraction of the region, `0...1` on each axis.
    let normalizedCentroid: CGPoint

    let areaPixels: Int
    /// Area as a fraction of the region's valid area.
    let normalizedArea: Double
    /// Diameter of a circle with the same area.
    let equivalentDiameterPixels: Double
    /// Equivalent diameter as a fraction of the region's diagonal.
    let normalizedDiameter: Double

    /// Largest band-passed response in the component.
    let peakResponse: Float
    /// Sum of the band-passed response over the component.
    let integratedResponse: Double
    /// Largest raw positive residual in the component, before band-passing.
    let peakResidual: Float
    /// Peak band-passed response divided by the detection threshold: how far
    /// above the noise floor this event stands, in units of the noise itself.
    ///
    /// Both terms are in band-pass units. Dividing the *raw* residual by a
    /// threshold measured on the band-passed image would mix two different
    /// scales and produce a number that means nothing.
    let localContrast: Double

    /// `0` for a perfect circle, approaching `1` for a line. Derived from the
    /// second moments of the pixel positions, which needs no perimeter tracing.
    let eccentricity: Double
    /// Area divided by the bounding box area. A compact blob approaches `pi/4`;
    /// a diagonal streak is far lower.
    let fillRatio: Double

    let boundingBox: PixelRect

    /// Distance from the centroid to the nearest masked or out-of-region pixel.
    let distanceToExclusionPixels: Double
    let normalizedDistanceToExclusion: Double

    /// `true` when the component contains a clipped pixel. A clipped core has
    /// lost its monotonic relationship to scattered light, so its brightness
    /// cannot be used even though its position is still valid.
    let containsSaturatedPixel: Bool
}

/// Why a candidate was discarded.
///
/// Counted rather than merely dropped: a run that rejects most of what it finds
/// is telling you something about the capture, and silently discarding them
/// would hide it.
struct CandidateRejection: Equatable, Sendable, Hashable {
    let rawValue: String

    static let tooSmall = CandidateRejection(rawValue: "candidate.tooSmall")
    static let tooLarge = CandidateRejection(rawValue: "candidate.tooLarge")
    static let tooElongated = CandidateRejection(rawValue: "candidate.tooElongated")
    static let saturatedCore = CandidateRejection(rawValue: "candidate.saturatedCore")
    static let tooCloseToExclusion = CandidateRejection(rawValue: "candidate.tooCloseToExclusion")
    static let lowContrast = CandidateRejection(rawValue: "candidate.lowContrast")
}

/// Normalized limits for candidate acceptance.
///
/// Every limit is a fraction of the region, never a pixel count, so the same
/// configuration means the same physical thing at any capture resolution.
/// Values are engineering starting points, versioned, and unvalidated against
/// real samples.
struct CandidateFilterConfiguration: Equatable, Sendable, Codable {
    /// Smallest accepted area, as a fraction of the region's valid area.
    ///
    /// Deliberately tiny. The point of the band-pass and the noise-scaled
    /// threshold is that they already suppress noise, so this exists only to
    /// drop single-pixel sensor artefacts. Setting it higher would erase the
    /// smallest genuine scatter events, which are the ones that matter most.
    var minimumNormalizedArea: Double
    /// Absolute floor in pixels, for the same reason.
    var minimumAreaPixels: Int
    /// Largest accepted equivalent diameter, as a fraction of the region
    /// diagonal. Above this an event is a bubble, a reflection or a smear,
    /// not a suspended particle.
    var maximumNormalizedDiameter: Double
    /// Above this, the component is a streak rather than a point.
    var maximumEccentricity: Double
    /// The band-passed peak must stand at least this many multiples of the
    /// detection threshold. Every extracted component clears the threshold
    /// somewhere by construction, so this rejects the ones that only just did.
    var minimumLocalContrast: Double
    /// Candidates whose centroid is nearer than this to a masked pixel are
    /// dropped: the band-pass response near a mask edge is an artefact of the
    /// edge, not of the sample.
    ///
    /// Enforced together with a pixel-domain minimum taken from the band-pass
    /// kernel radius, and the larger of the two wins. The extent of an edge
    /// artefact is set by the kernel, which is measured in pixels, so a purely
    /// normalized margin would be too small at low resolution and needlessly
    /// large at high resolution.
    var minimumNormalizedDistanceToExclusion: Double
    /// A clipped core cannot be measured, only located.
    var rejectsSaturatedCores: Bool
    var version: Int

    static let screening = CandidateFilterConfiguration(
        minimumNormalizedArea: 0,
        minimumAreaPixels: 2,
        // 4% of the region diagonal. At a 960x475 region that is about 42 px,
        // far larger than any suspended speck and comfortably inside the size
        // of a rising bubble.
        maximumNormalizedDiameter: 0.04,
        maximumEccentricity: 0.95,
        minimumLocalContrast: 1.2,
        minimumNormalizedDistanceToExclusion: 0.01,
        rejectsSaturatedCores: true,
        version: 1
    )
}
