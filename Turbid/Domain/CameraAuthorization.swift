import AVFoundation

/// Application-level camera authorization, decoupled from `AVAuthorizationStatus`
/// so that permission logic can be unit tested without the system prompt.
enum CameraAuthorization: String, Equatable, Sendable, CaseIterable {
    /// The system prompt has never been shown for this app.
    case notDetermined
    case authorized
    case denied
    case restricted

    init(systemStatus: AVAuthorizationStatus) {
        switch systemStatus {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            // Fail closed: an unrecognised status must never be treated as access.
            self = .denied
        }
    }

    /// Capture may only be attempted when this is `true`.
    var allowsCapture: Bool { self == .authorized }

    /// The system prompt may only be raised once, while the status is undecided.
    var canRequestSystemPrompt: Bool { self == .notDetermined }

    /// `true` when the app cannot change the outcome and the user must use Settings.
    var requiresSettingsChange: Bool { self == .denied || self == .restricted }

    /// `restricted` is imposed by device management or parental controls, so the
    /// Settings deep link is often ineffective and should not be the primary advice.
    var settingsLinkIsLikelyEffective: Bool { self == .denied }
}
