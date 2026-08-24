import CoreGraphics
import Foundation

/// Whole-frame motion between two frames, in analysis-region pixels per second.
///
/// Region pixels rather than normalized units because the region is not square:
/// normalizing each axis separately would make a diagonal movement's two
/// components incomparable. Normalization by the region diagonal happens once,
/// at the metric boundary.
struct GlobalFlow: Equatable, Sendable {
    let dxPixelsPerSecond: Double
    let dyPixelsPerSecond: Double
    /// Fraction of measured patches that agreed with the robust median.
    ///
    /// Low confidence means the patches disagreed, which happens when the
    /// region has too little texture to match or when something other than the
    /// camera moved. A low-confidence flow must not be subtracted from anything.
    let confidence: Double
    let patchesUsed: Int
    let patchesOffered: Int

    static let none = GlobalFlow(dxPixelsPerSecond: 0, dyPixelsPerSecond: 0,
                                 confidence: 0, patchesUsed: 0, patchesOffered: 0)

    var speedPixelsPerSecond: Double {
        (dxPixelsPerSecond * dxPixelsPerSecond
            + dyPixelsPerSecond * dyPixelsPerSecond).squareRoot()
    }

    func normalizedSpeed(regionDiagonal: Double) -> Double {
        regionDiagonal > 0 ? speedPixelsPerSecond / regionDiagonal : 0
    }

    /// Displacement over an interval, for accumulating a stabilised frame.
    func displacement(over seconds: Double) -> CGVector {
        CGVector(dx: dxPixelsPerSecond * seconds, dy: dyPixelsPerSecond * seconds)
    }
}

/// Which way is up, in image space.
///
/// Bubbles rise along gravity. Whether that shows up as motion *in the image*
/// depends on how the phone is held: with the camera pointing horizontally at a
/// vessel, gravity lies in the image plane and a rising bubble moves up the
/// frame; with the phone lying flat and the camera pointing down, gravity is
/// almost perpendicular to the image plane and a rising bubble barely moves at
/// all. Claiming to separate bubbles from specks by direction in that second
/// case would be claiming something the geometry cannot support.
struct GravityReference: Equatable, Sendable {
    /// Unit vector in image space pointing against gravity. Image `y` increases
    /// downwards, so "up the frame" is negative `y`.
    let imageUp: CGVector
    /// How much of gravity lies in the image plane, `0...1`.
    ///
    /// `1` means the image plane contains gravity and vertical motion is fully
    /// visible. Near `0` means the camera is looking along gravity and vertical
    /// motion is invisible, so direction carries no information.
    let inPlaneFraction: Double

    /// The portrait-locked default: no gravity measurement, assume the phone is
    /// upright and the camera is pointing horizontally at the sample.
    static let portraitAssumed = GravityReference(
        imageUp: CGVector(dx: 0, dy: -1), inPlaneFraction: 1
    )

    /// Direction evidence below this is too weak to classify on.
    static let minimumUsableInPlaneFraction = 0.35

    var directionIsInformative: Bool {
        inPlaneFraction >= Self.minimumUsableInPlaneFraction
    }

    /// Builds a reference from a device-frame gravity vector for a
    /// portrait-locked rear camera.
    ///
    /// In the device frame `+x` is towards the right edge, `+y` towards the top
    /// edge and `+z` out of the screen. For the rear camera in portrait, image
    /// `+x` follows device `+x` and image `+y` points towards the device's
    /// bottom edge, so image up is device `+y`.
    static func portraitRearCamera(deviceGravityX x: Double,
                                   deviceGravityY y: Double,
                                   deviceGravityZ z: Double) -> GravityReference {
        let magnitude = (x * x + y * y + z * z).squareRoot()
        guard magnitude > 1e-6 else { return .portraitAssumed }

        // Gravity points down, so up is its negation.
        let upX = -x / magnitude
        let upY = -y / magnitude
        let inPlane = (upX * upX + upY * upY).squareRoot()

        guard inPlane > 1e-6 else {
            // Gravity is along the optical axis: there is no "up" in the image.
            return GravityReference(imageUp: CGVector(dx: 0, dy: -1), inPlaneFraction: 0)
        }

        // Device +y is towards the top edge; image +y is downwards.
        return GravityReference(
            imageUp: CGVector(dx: upX / inPlane, dy: -upY / inPlane),
            inPlaneFraction: min(1, inPlane)
        )
    }
}
