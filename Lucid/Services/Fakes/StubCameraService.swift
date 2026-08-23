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

    private(set) var calls: [Call] = []

    private var snapshot: CaptureSnapshot = .idle
    private let continuation: AsyncStream<CaptureSnapshot>.Continuation

    nonisolated let snapshots: AsyncStream<CaptureSnapshot>
    nonisolated var previewSession: AVCaptureSession? { nil }

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
         torchLevel: Float = 1.0) {
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
        update {
            $0.runState = .idle
            $0.torch = .off
            $0.lockedControls = nil
        }
    }

    func currentSnapshot() async -> CaptureSnapshot { snapshot }

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
