import CoreVideo
import Foundation

/// The analyzer as the capture pipeline sees it.
///
/// Two entry points on purpose: one that takes a real `CVPixelBuffer` and one
/// that takes an already-normalized `LumaImage`. They run the identical
/// analysis, so a synthetic scenario exercises the same code path the camera
/// does, and a failure found in a test is a failure in production.
protocol FrameAnalyzing: AnyObject {
    var region: AnalysisRegion { get }
    var captureProtocol: CaptureProtocol { get }

    /// Resets all state and anchors the protocol timeline to this timestamp.
    func begin(atTimestamp presentationSeconds: Double)

    /// - Returns: `nil` when the buffer's format cannot be read.
    func analyze(pixelBuffer: CVPixelBuffer, presentationSeconds: Double) -> FrameObservation?

    /// The deterministic entry point. `luma` is a full frame, not a region: the
    /// analyzer crops it exactly as it crops a camera buffer.
    func analyze(luma: LumaImage, presentationSeconds: Double) -> FrameObservation

    /// The verdict for everything analysed since `begin`.
    func quality(thermal: ThermalStatus,
                 systemPressure: SystemPressureLevel,
                 controlsRemainedLocked: Bool,
                 timing: FrameTimingStatistics) -> CaptureQuality
}
