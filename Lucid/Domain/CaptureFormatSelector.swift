import Foundation

/// Chooses a capture format deterministically.
///
/// Deliberately not `sessionPreset`: a preset lets the system change the active
/// format, and a calibration is only valid for the exact format it was made
/// with. The format is picked once, recorded, and re-checked before every
/// measurement.
enum CaptureFormatSelector {

    struct Choice: Equatable, Sendable {
        let format: CaptureFormatDescriptor
        let frameRate: Double
        let score: Int
        let notes: [String]
    }

    /// - Returns: the best format, or `nil` when no format can carry the
    ///   required frame rate.
    static func choose(from formats: [CaptureFormatDescriptor],
                       requirements: CaptureRequirements) -> Choice? {
        var best: Choice?

        for format in formats {
            guard format.supports(frameRate: requirements.targetFrameRate) else { continue }

            var score = 0
            var notes: [String] = []

            if format.width == requirements.targetWidth && format.height == requirements.targetHeight {
                score += 100
                notes.append("exact \(requirements.targetWidth)x\(requirements.targetHeight) match")
            } else {
                // Prefer the closest resolution, penalising oversized formats
                // more than undersized ones: extra pixels cost analyzer time
                // without adding optical information.
                let target = requirements.targetWidth * requirements.targetHeight
                let difference = format.pixelCount - target
                let penalty = difference >= 0 ? difference / 40_000 : (-difference) / 20_000
                score += max(0, 60 - penalty)
                notes.append("resolution \(format.resolutionText)")
            }

            if let rank = requirements.preferredPixelFormats.firstIndex(of: format.pixelFormat) {
                score += 60 - (rank * 15)
                notes.append("pixel format \(format.pixelFormatText)")
            } else {
                // Usable, but the analyzer would have to convert every frame.
                notes.append("non-preferred pixel format \(format.pixelFormatText)")
            }

            if format.isBinned {
                // Binning trades resolution for sensitivity. Useful in a dark
                // shroud, but it changes the effective optical sampling, so it
                // is only a tie-breaker.
                score += 5
                notes.append("binned")
            }

            if format.supportsVideoHDR {
                // HDR applies a scene-dependent tone curve, which breaks the
                // link between pixel value and scattered light.
                score -= 10
                notes.append("HDR-capable; HDR must be disabled")
            }

            let candidate = Choice(format: format,
                                   frameRate: requirements.targetFrameRate,
                                   score: score,
                                   notes: notes)

            if let current = best {
                // Stable tie-break so the same device always picks the same
                // format, which a calibration profile depends on.
                if candidate.score > current.score
                    || (candidate.score == current.score && candidate.format.id < current.format.id) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }
}
