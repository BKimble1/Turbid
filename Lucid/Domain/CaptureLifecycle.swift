import Foundation

/// Lifecycle of the capture session itself, separate from the measurement
/// session state.
///
/// Modelled explicitly because the acceptance criteria require repeated
/// start/stop calls to be safe: without a state, a second `start()` would add a
/// duplicate input or leave a torch on after `stop()`.
enum CaptureRunState: Equatable, Sendable {
    case idle
    case preparing
    case prepared
    case starting
    case running
    case stopping
    case failed(CameraError)

    /// The AVCaptureSession is configured and owns hardware.
    var holdsHardware: Bool {
        switch self {
        case .prepared, .starting, .running, .stopping:
            return true
        case .idle, .preparing, .failed:
            return false
        }
    }

    var isRunning: Bool { self == .running }
}

enum CaptureLifecycleEvent: Equatable, Sendable {
    case prepareRequested
    case prepareSucceeded
    case startRequested
    case startSucceeded
    case stopRequested
    case stopFinished
    case failed(CameraError)
}

/// Pure reducer. Returns `nil` for a request that is already satisfied or not
/// legal, which is exactly what makes `start()` and `stop()` idempotent.
struct CaptureLifecycleMachine: Equatable, Sendable {
    private(set) var state: CaptureRunState

    init(state: CaptureRunState = .idle) {
        self.state = state
    }

    @discardableResult
    mutating func apply(_ event: CaptureLifecycleEvent) -> Bool {
        guard let next = Self.nextState(from: state, on: event) else { return false }
        state = next
        return true
    }

    static func nextState(from state: CaptureRunState,
                          on event: CaptureLifecycleEvent) -> CaptureRunState? {
        switch event {
        case .failed(let error):
            return state == .failed(error) ? nil : .failed(error)

        case .stopRequested:
            // Stopping is legal from anything that owns hardware, and a no-op
            // otherwise, so a redundant stop never throws or double-tears-down.
            return state.holdsHardware && state != .stopping ? .stopping : nil

        case .stopFinished:
            return state == .stopping ? .idle : nil

        case .prepareRequested:
            switch state {
            case .idle, .failed:
                return .preparing
            // Already prepared or running: preparing again would add a second
            // input to the session.
            case .preparing, .prepared, .starting, .running, .stopping:
                return nil
            }

        case .prepareSucceeded:
            return state == .preparing ? .prepared : nil

        case .startRequested:
            return state == .prepared ? .starting : nil

        case .startSucceeded:
            return state == .starting ? .running : nil
        }
    }
}
