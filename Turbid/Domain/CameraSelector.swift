import Foundation

/// The outcome of choosing a camera for a measurement.
struct CameraSelection: Equatable, Sendable {
    let capabilities: CameraCapabilities
    let format: CaptureFormatDescriptor
    let frameRate: Double
    let score: Int
    /// Why this camera won, in the order the points were awarded.
    let rationale: [String]
    /// Things that are acceptable but worth surfacing.
    let warnings: [String]
}

/// Why a camera was excluded.
struct CameraRejection: Equatable, Sendable {
    let cameraName: String
    let reason: String
}

/// Picks the single physical camera that can hold a repeatable optical path.
///
/// Selection is capability-driven, never model-name driven. "Ultra Wide" is not
/// preferred because of its name; it tends to win because it usually reports the
/// shortest minimum focus distance. On a device where the Ultra Wide camera has
/// no torch, or cannot lock its controls, it loses and the Wide camera is used
/// at a longer working distance.
struct CameraSelector: Sendable {
    let requirements: CaptureRequirements

    init(requirements: CaptureRequirements = .measurement) {
        self.requirements = requirements
    }

    struct Outcome: Equatable, Sendable {
        let selection: CameraSelection?
        let rejections: [CameraRejection]
    }

    func select(from cameras: [CameraCapabilities]) -> Outcome {
        var rejections: [CameraRejection] = []
        var best: CameraSelection?

        for camera in cameras {
            if let reason = disqualification(for: camera) {
                rejections.append(CameraRejection(cameraName: camera.localizedName, reason: reason))
                continue
            }

            guard let choice = CaptureFormatSelector.choose(from: camera.formats,
                                                            requirements: requirements) else {
                rejections.append(CameraRejection(
                    cameraName: camera.localizedName,
                    reason: "no format supports \(Int(requirements.targetFrameRate)) fps"
                ))
                continue
            }

            var score = choice.score
            var rationale: [String] = ["format: " + choice.notes.joined(separator: ", ")]
            var warnings: [String] = []

            // --- Close focus is the strongest signal ---------------------------
            if let distance = camera.minimumFocusDistanceMillimetres {
                if distance <= requirements.workingDistanceMillimetres {
                    score += 120
                    rationale.append("focuses at \(distance) mm, within the \(requirements.workingDistanceMillimetres) mm working distance")
                } else {
                    // Not disqualifying: the fixture can hold the sample further
                    // away, at the cost of collecting less scattered light.
                    let excess = distance - requirements.workingDistanceMillimetres
                    score += max(0, 60 - excess / 5)
                    warnings.append("minimum focus distance \(distance) mm exceeds the \(requirements.workingDistanceMillimetres) mm working distance; the sample must sit further from the lens")
                }
            } else {
                warnings.append("minimum focus distance not reported; the working distance must be confirmed by eye")
            }

            // --- A stable optical path ---------------------------------------
            if camera.isVirtualDevice {
                // A virtual device can switch constituent cameras mid-capture,
                // which silently changes the optical path a calibration is
                // bound to.
                score -= 200
                warnings.append("virtual device: the optical path can change mid-measurement")
            } else {
                score += 80
                rationale.append("single physical camera, so the optical path cannot switch")
            }

            // --- Control precision -------------------------------------------
            if camera.supportsCustomLensPositionLock {
                score += 40
                rationale.append("focus can be locked at a measured lens position")
            }
            if camera.supportsNearFocusRangeRestriction {
                score += 25
                rationale.append("autofocus can be restricted to the near range")
            }
            if camera.supportsCustomExposure {
                score += 30
                rationale.append("exposure duration and ISO can be set explicitly")
            } else {
                warnings.append("exposure can only be locked at whatever the camera chose, not set explicitly")
            }
            if camera.supportsCustomWhiteBalanceGainsLock {
                score += 20
                rationale.append("white-balance gains can be locked to explicit values")
            }

            let candidate = CameraSelection(
                capabilities: camera,
                format: choice.format,
                frameRate: choice.frameRate,
                score: score,
                rationale: rationale,
                warnings: warnings
            )

            if let current = best {
                if candidate.score > current.score
                    || (candidate.score == current.score
                        && candidate.capabilities.uniqueID < current.capabilities.uniqueID) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return Outcome(selection: best, rejections: rejections)
    }

    /// Hard requirements. A camera failing any of these cannot produce a
    /// measurement at all, so it is excluded rather than scored down.
    private func disqualification(for camera: CameraCapabilities) -> String? {
        if !camera.hasTorch {
            return "no torch"
        }
        if !camera.supportsTorchOnMode {
            return "torch cannot be switched on under app control"
        }
        if !camera.supportsLockedFocus {
            return "focus cannot be locked"
        }
        if !(camera.supportsLockedExposure || camera.supportsCustomExposure) {
            return "exposure cannot be locked"
        }
        if !camera.supportsLockedWhiteBalance {
            return "white balance cannot be locked"
        }
        if camera.formats.isEmpty {
            return "reports no capture formats"
        }
        return nil
    }
}
