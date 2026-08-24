import SwiftUI

/// User-facing presentation of `MeasurementState`, kept out of the domain type.
struct MeasurementStatePresentation {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    init(state: MeasurementState) {
        switch state {
        case .idle:
            title = "Ready"
            detail = "Setup has not started."
            systemImage = "circle.dashed"
            tint = Theme.Palette.secondaryText

        case .requestingPermission:
            title = "Checking camera access"
            detail = "Waiting for your answer to the system permission prompt."
            systemImage = "hourglass"
            tint = Theme.Palette.accent

        case .permissionDenied:
            title = "Camera access denied"
            detail = "Turbid cannot observe a sample without the camera."
            systemImage = "video.slash.fill"
            tint = Theme.Palette.critical

        case .permissionRestricted:
            title = "Camera access restricted"
            detail = "A device policy such as Screen Time or an MDM profile is blocking the camera."
            systemImage = "lock.fill"
            tint = Theme.Palette.critical

        case .preparingCamera:
            title = "Preparing camera"
            detail = "Selecting a camera and configuring the capture session."
            systemImage = "camera.fill"
            tint = Theme.Palette.accent

        case .alignment:
            title = "Align the sample"
            detail = "Position the phone so the sample fills the analysis region."
            systemImage = "viewfinder"
            tint = Theme.Palette.accent

        case .warmingUp:
            title = "Warming up"
            detail = "Letting focus, exposure and white balance settle."
            systemImage = "thermometer.medium"
            tint = Theme.Palette.accent

        case .lockingControls:
            title = "Locking controls"
            detail = "Fixing focus, exposure, ISO and white balance for the measurement."
            systemImage = "lock.rotation"
            tint = Theme.Palette.accent

        case .acquiringBackground:
            title = "Learning the background"
            detail = "Recording stationary marks and reflections so they are not counted."
            systemImage = "square.stack.3d.down.right"
            tint = Theme.Palette.accent

        case .measuring:
            title = "Measuring"
            detail = "Hold the phone still until the measurement window completes."
            systemImage = "waveform"
            tint = Theme.Palette.accent

        case .calculating:
            title = "Calculating"
            detail = "Aggregating the measurement window."
            systemImage = "function"
            tint = Theme.Palette.accent

        case .result:
            title = "Result ready"
            detail = MeasurementDisclaimer.short
            systemImage = "checkmark.seal.fill"
            tint = Theme.Palette.positive

        case .lowQuality(let reasons):
            title = "Capture quality too low"
            detail = reasons.isEmpty
                ? "The measurement window did not meet the capture-quality gates."
                : reasons.map(\.rawValue).joined(separator: ", ")
            systemImage = "exclamationmark.triangle.fill"
            tint = Theme.Palette.warning

        case .interrupted(let interruption):
            title = "Measurement stopped"
            detail = interruption.message
            systemImage = "pause.circle.fill"
            tint = Theme.Palette.warning

        case .thermalLimited:
            title = "Device too warm"
            detail = "Torch output and capture are limited until the iPhone cools down."
            systemImage = "flame.fill"
            tint = Theme.Palette.warning

        case .unsupportedHardware(let reason):
            title = "Unsupported hardware"
            detail = reason
            systemImage = "xmark.octagon.fill"
            tint = Theme.Palette.critical

        case .failed(let failure):
            title = "Setup stopped"
            detail = [failure.message, failure.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " ")
            systemImage = "info.circle.fill"
            tint = Theme.Palette.warning
        }
    }
}

extension CameraAuthorization {
    var presentationTitle: String {
        switch self {
        case .notDetermined: return "Not requested yet"
        case .authorized: return "Camera access granted"
        case .denied: return "Camera access denied"
        case .restricted: return "Camera access restricted"
        }
    }

    var presentationSymbol: String {
        switch self {
        case .notDetermined: return "questionmark.circle.fill"
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "video.slash.fill"
        case .restricted: return "lock.fill"
        }
    }

    var presentationTint: Color {
        switch self {
        case .notDetermined: return Theme.Palette.secondaryText
        case .authorized: return Theme.Palette.positive
        case .denied, .restricted: return Theme.Palette.critical
        }
    }

    var guidance: String? {
        switch self {
        case .notDetermined:
            return nil
        case .authorized:
            return nil
        case .denied:
            return "Open Settings, then turn Camera on for Turbid."
        case .restricted:
            return "Camera use is blocked by a device policy such as Screen Time or a management profile. Only whoever manages this device can change it."
        }
    }
}
