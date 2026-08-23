import Foundation

/// The stages of a single measurement run, in order.
enum CaptureStage: String, Equatable, Sendable, CaseIterable, Codable {
    /// Optional torch-off reference, captured after the controls are locked so
    /// it is directly comparable with the illuminated frames.
    case ambientReference
    /// Torch on, waiting for the illumination and the sensor to settle.
    case torchSettling
    /// Building the background model of stationary marks and reflections.
    case backgroundAcquisition
    /// The frames the result is computed from.
    case measurement
    case complete

    /// Stages whose frames feed the background model or the result. Frames
    /// outside these are still quality-checked but never contribute.
    var contributesToResult: Bool {
        self == .backgroundAcquisition || self == .measurement
    }
}

/// The standard capture protocol: how long each stage lasts.
///
/// Durations are engineering starting points, not validated constants. They are
/// versioned so that a measurement records which protocol produced it, and so a
/// calibration profile can refuse a profile made under a different one.
struct CaptureProtocol: Equatable, Sendable, Codable {
    /// `0` skips the ambient block entirely.
    var ambientReferenceSeconds: Double
    var torchSettlingSeconds: Double
    var backgroundAcquisitionSeconds: Double
    var measurementWindowSeconds: Double
    var version: Int

    /// Screening default.
    ///
    /// * No ambient reference. Nothing in the analysis subtracts one, and a
    ///   stage that spent a second capturing frames labelled *ambient* while
    ///   the torch was on would put a false record in every reading. It is
    ///   zero until there is code that uses it.
    /// * 1.5 s of torch settling: an LED torch reaches steady output quickly,
    ///   but the sensor's own noise and the ISP's internal state take longer.
    /// * 2.0 s of background acquisition at 30 fps gives about 60 frames, which
    ///   is enough for a robust temporal median over stationary defects.
    /// * A 9 s measurement window sits in the 8–10 s range the design calls
    ///   for: long enough for slow-moving specks to cross the region, short
    ///   enough that the phone does not heat up mid-measurement.
    ///
    /// All of these are to be re-tuned empirically once real repeatability data
    /// exists. The version is what a calibration profile is bound to, so any
    /// change here invalidates every existing calibration by design.
    static let screening = CaptureProtocol(
        ambientReferenceSeconds: 0,
        torchSettlingSeconds: 1.5,
        backgroundAcquisitionSeconds: 2.0,
        measurementWindowSeconds: 9.0,
        version: 2
    )

    var totalSeconds: Double {
        ambientReferenceSeconds + torchSettlingSeconds
            + backgroundAcquisitionSeconds + measurementWindowSeconds
    }

    var capturesAmbientReference: Bool { ambientReferenceSeconds > 0 }
}

/// Maps a frame's presentation timestamp onto a capture stage.
///
/// Driven by presentation timestamps rather than a wall clock or a frame count:
/// a dropped frame, a thermal throttle or a slow analyzer must shorten the
/// number of frames in a stage, never the stage's duration.
struct CaptureProtocolTimeline: Equatable, Sendable {
    let captureProtocol: CaptureProtocol
    /// Presentation timestamp of the first frame in the run.
    let startSeconds: Double

    init(captureProtocol: CaptureProtocol = .screening, startSeconds: Double) {
        self.captureProtocol = captureProtocol
        self.startSeconds = startSeconds
    }

    /// Stage boundaries as elapsed seconds from `startSeconds`.
    var ambientEnd: Double { captureProtocol.ambientReferenceSeconds }
    var torchSettlingEnd: Double { ambientEnd + captureProtocol.torchSettlingSeconds }
    var backgroundEnd: Double { torchSettlingEnd + captureProtocol.backgroundAcquisitionSeconds }
    var measurementEnd: Double { backgroundEnd + captureProtocol.measurementWindowSeconds }

    func elapsed(at presentationSeconds: Double) -> Double {
        presentationSeconds - startSeconds
    }

    func stage(at presentationSeconds: Double) -> CaptureStage {
        let elapsed = self.elapsed(at: presentationSeconds)

        // A timestamp before the start belongs to the first stage: it means a
        // frame already in flight arrived just after the run began.
        if elapsed < ambientEnd {
            return captureProtocol.capturesAmbientReference ? .ambientReference : .torchSettling
        }
        if elapsed < torchSettlingEnd { return .torchSettling }
        if elapsed < backgroundEnd { return .backgroundAcquisition }
        if elapsed < measurementEnd { return .measurement }
        return .complete
    }

    /// Overall progress through the run, clamped to `0...1`.
    func progress(at presentationSeconds: Double) -> Double {
        guard captureProtocol.totalSeconds > 0 else { return 1 }
        let fraction = elapsed(at: presentationSeconds) / captureProtocol.totalSeconds
        return min(max(fraction, 0), 1)
    }

    /// Progress through the current stage, clamped to `0...1`.
    func stageProgress(at presentationSeconds: Double) -> Double {
        let elapsed = self.elapsed(at: presentationSeconds)
        let (start, end): (Double, Double)

        switch stage(at: presentationSeconds) {
        case .ambientReference: (start, end) = (0, ambientEnd)
        case .torchSettling: (start, end) = (ambientEnd, torchSettlingEnd)
        case .backgroundAcquisition: (start, end) = (torchSettlingEnd, backgroundEnd)
        case .measurement: (start, end) = (backgroundEnd, measurementEnd)
        case .complete: return 1
        }

        guard end > start else { return 1 }
        return min(max((elapsed - start) / (end - start), 0), 1)
    }

    func isComplete(at presentationSeconds: Double) -> Bool {
        stage(at: presentationSeconds) == .complete
    }

    /// The number of frames a stage should contain at a given delivery rate.
    /// Used to decide whether a stage collected enough usable frames.
    func expectedFrameCount(for stage: CaptureStage, atFrameRate frameRate: Double) -> Int {
        guard frameRate > 0 else { return 0 }
        let seconds: Double
        switch stage {
        case .ambientReference: seconds = captureProtocol.ambientReferenceSeconds
        case .torchSettling: seconds = captureProtocol.torchSettlingSeconds
        case .backgroundAcquisition: seconds = captureProtocol.backgroundAcquisitionSeconds
        case .measurement: seconds = captureProtocol.measurementWindowSeconds
        case .complete: seconds = 0
        }
        return Int((seconds * frameRate).rounded(.down))
    }
}
