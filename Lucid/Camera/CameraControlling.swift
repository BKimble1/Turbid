import AVFoundation
import Foundation

/// The capture pipeline as the rest of the app sees it.
///
/// Everything crossing this boundary is a value type, except `previewSession`,
/// which exists only so `AVCaptureVideoPreviewLayer` can display the feed. The
/// preview pixels are never used for analysis.
protocol CameraControlling: Sendable {
    /// Rate-limited snapshots of the pipeline. Never publishes faster than the
    /// UI needs.
    var snapshots: AsyncStream<CaptureSnapshot> { get }

    /// The session backing the preview layer, or `nil` before `prepare()`.
    var previewSession: AVCaptureSession? { get }

    /// Probes the hardware, picks a camera and format, and configures the
    /// session. Safe to call more than once; later calls are no-ops.
    func prepare() async throws -> CameraSelectionSummary

    /// Starts the session off the main thread. Idempotent.
    func start() async throws

    /// Puts focus, exposure and white balance into their continuous modes and
    /// waits, within a bounded timeout, for the camera to stop adjusting.
    ///
    /// - Returns: `true` if the camera settled, `false` if the timeout expired
    ///   first and the values are still moving.
    @discardableResult
    func warmUp() async throws -> Bool

    /// Locks focus, exposure and white balance at the values the camera reached
    /// during warm-up, and reads back what it actually locked to.
    func lockControls() async throws -> LockedCameraControls

    /// Turns the torch on at the current maximum available level.
    @discardableResult
    func setTorch(on: Bool) async throws -> TorchStatus

    /// Stops the session and turns the torch off. Idempotent, and safe to call
    /// from any state including a failed one.
    func stop() async

    func currentSnapshot() async -> CaptureSnapshot
}
