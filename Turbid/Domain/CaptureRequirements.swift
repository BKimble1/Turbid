import Foundation

/// What the measurement needs from the camera.
///
/// Held as data so the selection rules can be exercised against different
/// requirement sets, and so a future calibration profile can pin them.
struct CaptureRequirements: Equatable, Sendable {
    let targetWidth: Int
    let targetHeight: Int
    let targetFrameRate: Double
    let preferredPixelFormats: [OSType]
    /// The instructed sample distance. A camera that cannot focus this close
    /// cannot resolve point-like scatter events in the sample volume.
    let workingDistanceMillimetres: Int

    /// The Phase 2 baseline: 1920x1080 at 30 fps.
    ///
    /// Chosen as a starting point rather than a final answer. It is a format
    /// every recent iPhone supports on both the Wide and Ultra Wide cameras,
    /// it leaves headroom to crop a region of interest without upscaling, and
    /// 30 fps is comfortably above the analyzer's initial 15 fps cadence.
    /// Phase 3C re-tunes it against measured analyzer latency.
    static let measurement = CaptureRequirements(
        targetWidth: 1920,
        targetHeight: 1080,
        targetFrameRate: 30,
        preferredPixelFormats: MeasurementPixelFormat.preferred,
        workingDistanceMillimetres: 120
    )
}
