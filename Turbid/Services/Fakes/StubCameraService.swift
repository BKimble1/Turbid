import AVFoundation
import Foundation

/// A scripted `CameraControlling` that touches no hardware.
///
/// Used by unit tests and by the Simulator, where no camera or torch exists.
/// It records the order of the calls it receives so tests can assert that the
/// torch is turned off before the session is torn down.
actor StubCameraService: CameraControlling {

    enum Call: Equatable, Sendable {
        case prepare
        case start
        case warmUp
        case lockControls
        case torch(on: Bool)
        case stop
    }

    /// The awaited calls, in order.
    ///
    /// Consumer attachment and timing resets are deliberately *not* here: they
    /// arrive synchronously from whatever thread the pipeline is on, so mixing
    /// them into this list would make its order depend on scheduling and turn
    /// every ordering assertion into a flake. They are recorded separately.
    private(set) var calls: [Call] = []

    nonisolated let consumerLog = StubEventLog()
    nonisolated let timingResets = StubEventLog()

    private var snapshot: CaptureSnapshot = .idle
    private let continuation: AsyncStream<CaptureSnapshot>.Continuation

    nonisolated let snapshots: AsyncStream<CaptureSnapshot>
    nonisolated var previewSession: AVCaptureSession? { nil }

    /// Present only when the stub is asked to behave like a camera that
    /// actually delivers frames. Unit tests that do not need frames leave it
    /// `nil`. `nonisolated` so the frame consumer can be attached without an
    /// actor hop, which is what the real service does too.
    private nonisolated let frameSource: SimulatedFrameSource?

    // Scripted outcomes.
    private let summary: CameraSelectionSummary
    private let prepareError: CameraError?
    private let startError: CameraError?
    private let warmUpError: CameraError?
    private let lockError: CameraError?
    private let settlesDuringWarmUp: Bool
    private let torchError: CameraError?
    private let torchLevel: Float

    init(summary: CameraSelectionSummary = .stubUltraWide,
         prepareError: CameraError? = nil,
         startError: CameraError? = nil,
         warmUpError: CameraError? = nil,
         lockError: CameraError? = nil,
         settlesDuringWarmUp: Bool = true,
         torchError: CameraError? = nil,
         torchLevel: Float = 1.0,
         frameSource: SimulatedFrameSource? = nil) {
        self.frameSource = frameSource
        self.summary = summary
        self.prepareError = prepareError
        self.startError = startError
        self.warmUpError = warmUpError
        self.lockError = lockError
        self.settlesDuringWarmUp = settlesDuringWarmUp
        self.torchError = torchError
        self.torchLevel = torchLevel

        let (stream, continuation) = AsyncStream<CaptureSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.snapshots = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func prepare() async throws -> CameraSelectionSummary {
        calls.append(.prepare)
        if let prepareError { throw prepareError }
        update {
            $0.runState = .prepared
            $0.selection = summary
        }
        return summary
    }

    func start() async throws {
        calls.append(.start)
        if let startError { throw startError }
        update { $0.runState = .running }
        frameSource?.start()
    }

    @discardableResult
    func warmUp() async throws -> Bool {
        calls.append(.warmUp)
        if let warmUpError { throw warmUpError }
        return settlesDuringWarmUp
    }

    func lockControls() async throws -> LockedCameraControls {
        calls.append(.lockControls)
        if let lockError { throw lockError }
        let locked = LockedCameraControls.stub
        update { $0.lockedControls = locked }
        return locked
    }

    @discardableResult
    func setTorch(on: Bool) async throws -> TorchStatus {
        calls.append(.torch(on: on))
        if let torchError { throw torchError }
        let status = TorchStatus(
            isAvailable: true,
            isActive: on,
            level: on ? torchLevel : 0,
            requestedLevel: on ? 1.0 : 0
        )
        update { $0.torch = status }
        return status
    }

    func stop() async {
        calls.append(.stop)
        frameSource?.stop()
        update {
            $0.runState = .idle
            $0.torch = .off
            $0.lockedControls = nil
        }
    }

    /// Merged with the frame source's real delivery statistics, so a simulated
    /// run's reading is judged on frames that actually arrived rather than on
    /// an empty record.
    func currentSnapshot() async -> CaptureSnapshot {
        guard let frameSource else { return snapshot }
        var copy = snapshot
        copy.timing = frameSource.frameStatistics()
        return copy
    }

    nonisolated func resetFrameStatistics() {
        timingResets.record(true)
        frameSource?.resetFrameStatistics()
    }

    nonisolated func setFrameConsumer(_ consumer: CaptureFrameConsuming?) {
        consumerLog.record(consumer != nil)
        frameSource?.attach(consumer)
    }

    /// Selects which synthetic sample the simulated camera is pointed at.
    /// Does nothing when there is no frame source, which is the unit-test case.
    nonisolated func setSimulatedSample(_ sample: SimulatedSample) {
        frameSource?.setSample(sample)
    }

    /// Lets a test drive thermal, pressure and interruption states.
    func applyOverride(_ mutate: (inout CaptureSnapshot) -> Void) {
        update(mutate)
    }

    private func update(_ mutate: (inout CaptureSnapshot) -> Void) {
        var copy = snapshot
        mutate(&copy)
        snapshot = copy
        continuation.yield(copy)
    }
}

extension CameraSelectionSummary {
    static let stubUltraWide = CameraSelectionSummary(
        cameraName: "Stub Ultra Wide Camera",
        deviceType: "AVCaptureDeviceTypeBuiltInUltraWideCamera",
        uniqueID: "stub-ultra-wide",
        isVirtualDevice: false,
        minimumFocusDistanceMillimetres: 20,
        resolution: "1920x1080",
        pixelFormat: "420f",
        frameRate: 30,
        rationale: ["stubbed selection"],
        warnings: [],
        rejectedCameras: []
    )
}

/// A thread-safe list of events recorded from outside the actor.
final class StubEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Bool] = []

    func record(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(value)
    }

    var all: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var count: Int { all.count }
    var latest: Bool? { all.last }
}

extension CameraSelectionSummary {
    /// Describes the simulated feed truthfully: the frames really are 320x240,
    /// so a calibration binding recorded on the Simulator records that and
    /// cannot be mistaken for one made on a physical camera.
    static let simulatedFeed = CameraSelectionSummary(
        cameraName: "Simulated Camera",
        deviceType: "AVCaptureDeviceTypeBuiltInUltraWideCamera",
        uniqueID: "simulated-feed",
        isVirtualDevice: false,
        minimumFocusDistanceMillimetres: 20,
        resolution: "320x240",
        pixelFormat: "420f",
        frameRate: 30,
        rationale: ["simulated frame source; no camera hardware is present"],
        warnings: ["Frames are generated, not captured."],
        rejectedCameras: []
    )
}

extension LockedCameraControls {
    static let stub = LockedCameraControls(
        lensPosition: 0.42,
        exposureSeconds: 1.0 / 60.0,
        iso: 200,
        whiteBalanceGains: WhiteBalanceGains(red: 1.8, green: 1.0, blue: 1.6),
        focusModeDescription: "locked",
        exposureModeDescription: "custom",
        whiteBalanceModeDescription: "locked",
        clampNotes: [],
        lockedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}
