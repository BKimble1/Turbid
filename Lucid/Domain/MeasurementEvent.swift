import Foundation

/// Every input that can move the measurement session forward.
///
/// Keeping transitions event-driven means the reducer is a pure function of
/// (state, event), which is directly testable without any hardware.
enum MeasurementEvent: Equatable, Sendable {
    case startRequested
    case permissionResolved(CameraAuthorization)
    case cameraReady
    case cameraUnsupported(reason: String)
    case alignmentConfirmed
    case warmUpCompleted
    case controlsLocked
    case backgroundAcquired
    case measurementWindowCompleted
    case calculationFinished
    case qualityFailed(reasons: [MeasurementRejectionReason])
    case interrupted(MeasurementInterruption)
    case interruptionEnded
    case thermalLimitReached
    case thermalRecovered
    case failed(MeasurementFailure)
    case cancelled
    case reset
}
