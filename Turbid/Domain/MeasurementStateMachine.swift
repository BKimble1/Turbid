import Foundation

/// Pure reducer over `MeasurementState`.
///
/// `nextState(from:on:)` returns `nil` for an illegal transition, so callers can
/// distinguish "ignored" from "moved" without the machine silently accepting an
/// out-of-order event.
struct MeasurementStateMachine: Equatable, Sendable {
    private(set) var state: MeasurementState

    init(state: MeasurementState = .idle) {
        self.state = state
    }

    /// - Returns: `true` when the event produced a legal transition.
    @discardableResult
    mutating func apply(_ event: MeasurementEvent) -> Bool {
        guard let next = Self.nextState(from: state, on: event) else { return false }
        state = next
        return true
    }

    static func nextState(from state: MeasurementState, on event: MeasurementEvent) -> MeasurementState? {
        // Events that are legal from more than one state are resolved first.
        switch event {
        case .reset, .cancelled:
            return state == .idle ? nil : .idle

        case .failed(let failure):
            return state == .failed(failure) ? nil : .failed(failure)

        case .interrupted(let interruption):
            return state.usesCaptureHardware ? .interrupted(interruption) : nil

        case .thermalLimitReached:
            return state.usesCaptureHardware ? .thermalLimited : nil

        case .qualityFailed(let reasons):
            return state.acceptsQualityRejection ? .lowQuality(reasons: reasons) : nil

        default:
            break
        }

        switch (state, event) {
        case (.idle, .startRequested),
             (.permissionDenied, .startRequested),
             (.permissionRestricted, .startRequested),
             (.failed, .startRequested):
            // Re-entering always re-reads authorization; it never assumes the
            // previous answer still holds.
            return .requestingPermission

        case (.requestingPermission, .permissionResolved(let authorization)):
            switch authorization {
            case .authorized: return .preparingCamera
            case .denied: return .permissionDenied
            case .restricted: return .permissionRestricted
            // The user dismissed the prompt without deciding.
            case .notDetermined: return .idle
            }

        case (.preparingCamera, .cameraReady):
            return .alignment

        case (.preparingCamera, .cameraUnsupported(let reason)):
            return .unsupportedHardware(reason: reason)

        case (.unsupportedHardware, .startRequested):
            return .preparingCamera

        case (.alignment, .alignmentConfirmed):
            return .warmingUp

        case (.warmingUp, .warmUpCompleted):
            return .lockingControls

        case (.lockingControls, .controlsLocked):
            return .acquiringBackground

        case (.acquiringBackground, .backgroundAcquired):
            return .measuring

        case (.measuring, .measurementWindowCompleted):
            return .calculating

        case (.calculating, .calculationFinished):
            return .result

        // Repeat runs and recoveries all return to alignment: the optical path
        // must be re-confirmed before another measurement window is trusted.
        case (.result, .startRequested),
             (.lowQuality, .startRequested),
             (.thermalLimited, .startRequested),
             (.interrupted, .interruptionEnded),
             (.thermalLimited, .thermalRecovered):
            return .alignment

        default:
            return nil
        }
    }
}
