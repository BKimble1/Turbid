import AVFoundation
import Foundation

/// `AVCaptureDevice`-backed implementation of `CameraAuthorizing`.
struct SystemCameraAuthorizationService: CameraAuthorizing {
    func currentStatus() async -> CameraAuthorization {
        CameraAuthorization(systemStatus: AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestAccess() async -> CameraAuthorization {
        let existing = CameraAuthorization(systemStatus: AVCaptureDevice.authorizationStatus(for: .video))

        // iOS shows the prompt at most once per install; calling again on a
        // resolved status is a no-op that would only add latency and confusion.
        guard existing.canRequestSystemPrompt else {
            LucidLog.permission.info(
                "Skipping camera prompt, status already resolved: \(existing.rawValue, privacy: .public)"
            )
            return existing
        }

        let granted = await AVCaptureDevice.requestAccess(for: .video)
        let resolved = CameraAuthorization(systemStatus: AVCaptureDevice.authorizationStatus(for: .video))
        LucidLog.permission.info(
            "Camera prompt completed granted=\(granted, privacy: .public) status=\(resolved.rawValue, privacy: .public)"
        )
        return resolved
    }
}
