import Foundation

/// One point on the live graph.
///
/// Deliberately small and value-typed: these cross from the processing queue to
/// the MainActor several times a second, and a bounded buffer of them is the
/// only measurement history the UI ever holds.
struct ScatteringSample: Equatable, Sendable, Identifiable {
    let id: Int
    let elapsedSeconds: Double
    /// Running relative scattering index. Raw, as measured.
    let index: Double
    /// Exponentially smoothed, for display only. Never fed back into anything.
    let smoothedIndex: Double
    /// Present only when a calibration is in force and the gate allowed it.
    let ntu: Double?
}

/// A bounded ring of chart samples.
///
/// Fixed capacity rather than an array that grows: a nine-second run at five
/// samples a second is small, but nothing stops a user leaving the measurement
/// screen open, and an ever-growing chart series is the classic way a live
/// graph turns into a memory leak and then a stutter.
struct ScatteringSampleBuffer: Equatable, Sendable {
    private var storage: [ScatteringSample]
    private var writeIndex = 0
    private(set) var count = 0
    private var nextIdentifier = 0
    private var smoothed: Double?

    let capacity: Int
    /// Weight of each new sample in the display smoothing.
    let smoothingFactor: Double

    init(capacity: Int = 240, smoothingFactor: Double = 0.3) {
        self.capacity = max(1, capacity)
        self.smoothingFactor = min(1, max(0, smoothingFactor))
        self.storage = []
        self.storage.reserveCapacity(self.capacity)
    }

    /// Samples in arrival order, oldest first.
    var samples: [ScatteringSample] {
        guard count == capacity else { return storage }
        return Array(storage[writeIndex...] + storage[..<writeIndex])
    }

    var latest: ScatteringSample? {
        guard count > 0 else { return nil }
        return storage[(writeIndex + capacity - 1) % capacity]
    }

    mutating func append(elapsedSeconds: Double, index: Double, ntu: Double?) {
        let value = smoothed.map { smoothingFactor * index + (1 - smoothingFactor) * $0 } ?? index
        smoothed = value

        let sample = ScatteringSample(id: nextIdentifier,
                                      elapsedSeconds: elapsedSeconds,
                                      index: index,
                                      smoothedIndex: value,
                                      ntu: ntu)
        nextIdentifier += 1

        if storage.count < capacity {
            storage.append(sample)
            writeIndex = storage.count % capacity
        } else {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        count = min(count + 1, capacity)
    }

    mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        writeIndex = 0
        count = 0
        smoothed = nil
        nextIdentifier = 0
    }

    /// Range for the chart's value axis, with a little headroom so the newest
    /// point is never pinned to the top edge.
    var indexRange: ClosedRange<Double> {
        let values = samples.map(\.index)
        guard let low = values.min(), let high = values.max(), high > low else {
            return 0...max(1, (values.first ?? 0) * 1.5)
        }
        let padding = (high - low) * 0.15
        return max(0, low - padding)...(high + padding)
    }
}

/// A short, imperative prompt for the person holding the phone.
///
/// Separate from `MeasurementRejectionReason.explanation`, which explains a
/// finished result. Mid-measurement the useful thing is not an explanation but
/// an instruction, and it has to be short enough to read while holding still.
struct LiveQualityHint: Equatable, Sendable, Identifiable {
    var id: String { reason.rawValue }
    let reason: MeasurementRejectionReason
    let prompt: String
    let symbolName: String
}

extension MeasurementRejectionReason {
    /// The imperative form, for use during a measurement.
    var livePrompt: LiveQualityHint? {
        switch self {
        case .saturatedRegion, .torchHotspot:
            return LiveQualityHint(reason: self, prompt: "Reduce glare",
                                   symbolName: "sun.max.fill")
        case .regionTooDark:
            return LiveQualityHint(reason: self, prompt: "Sample too dark",
                                   symbolName: "moon.fill")
        case .regionTooBright:
            return LiveQualityHint(reason: self, prompt: "Move back slightly",
                                   symbolName: "arrow.up.backward.and.arrow.down.forward")
        case .outOfFocus:
            return LiveQualityHint(reason: self, prompt: "Focus not locked",
                                   symbolName: "camera.metering.unknown")
        case .cameraMoved:
            return LiveQualityHint(reason: self, prompt: "Hold steady",
                                   symbolName: "hand.raised.fill")
        case .exposureUnstable, .controlsUnlocked:
            return LiveQualityHint(reason: self, prompt: "Lighting is changing",
                                   symbolName: "light.max")
        case .thermalLimit, .systemPressure:
            return LiveQualityHint(reason: self, prompt: "Device too warm",
                                   symbolName: "thermometer.high")
        case .excessiveDroppedFrames, .frameDeliveryDiscontinuous:
            return LiveQualityHint(reason: self, prompt: "Video is stalling",
                                   symbolName: "wifi.exclamationmark")
        default:
            return nil
        }
    }
}

/// What the UI is told while a measurement runs.
///
/// Published at about five times a second, whatever rate the camera and the
/// analyzer are running at. Everything in it is a value type; nothing here can
/// keep a frame alive.
struct MeasurementProgress: Equatable, Sendable {
    let stage: CaptureStage
    /// `0...1` through the whole run.
    let overallProgress: Double
    /// `0...1` through the current stage.
    let stageProgress: Double
    let elapsedSeconds: Double
    let remainingSeconds: Double
    let framesAnalysed: Int
    let usableFrames: Int
    let backgroundIsReady: Bool
    /// At most a couple of prompts: a wall of warnings is not actionable.
    let hints: [LiveQualityHint]
    let latestSample: ScatteringSample?

    static let idle = MeasurementProgress(
        stage: .torchSettling, overallProgress: 0, stageProgress: 0,
        elapsedSeconds: 0, remainingSeconds: 0, framesAnalysed: 0, usableFrames: 0,
        backgroundIsReady: false, hints: [], latestSample: nil
    )

    /// What the stage means to someone waiting for it.
    var stageDescription: String {
        switch stage {
        case .ambientReference: return "Measuring the room's own light"
        case .torchSettling: return "Letting the light settle"
        case .backgroundAcquisition: return "Learning the container's marks"
        case .measurement: return "Measuring"
        case .complete: return "Finishing"
        }
    }
}
