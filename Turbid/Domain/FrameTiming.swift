import Foundation

/// What the capture pipeline observed about frame delivery.
struct FrameTimingStatistics: Equatable, Sendable {
    let deliveredFrames: Int
    let droppedFrames: Int
    let measuredFrameRate: Double
    let medianIntervalSeconds: Double
    let maximumIntervalSeconds: Double
    let firstTimestampSeconds: Double?
    let lastTimestampSeconds: Double?

    static let empty = FrameTimingStatistics(
        deliveredFrames: 0, droppedFrames: 0, measuredFrameRate: 0,
        medianIntervalSeconds: 0, maximumIntervalSeconds: 0,
        firstTimestampSeconds: nil, lastTimestampSeconds: nil
    )

    var totalFrames: Int { deliveredFrames + droppedFrames }

    var dropRatio: Double {
        totalFrames == 0 ? 0 : Double(droppedFrames) / Double(totalFrames)
    }

    var spanSeconds: Double {
        guard let first = firstTimestampSeconds, let last = lastTimestampSeconds else { return 0 }
        return max(0, last - first)
    }

    /// A gap far larger than the typical interval means frames stalled, which
    /// invalidates a measurement window even if the average rate looks healthy.
    ///
    /// - Parameter tolerance: multiples of the median interval that still count
    ///   as continuous.
    func isContinuous(tolerance: Double = 3.0) -> Bool {
        guard deliveredFrames >= 3, medianIntervalSeconds > 0 else { return false }
        return maximumIntervalSeconds <= medianIntervalSeconds * tolerance
    }
}

/// Accumulates frame arrival times over a bounded window.
///
/// Two properties matter and are both enforced here:
///
/// 1. Intervals come from real presentation timestamps, never from an assumed
///    constant frame period. A camera that quietly drops to 24 fps under
///    thermal load must show up as 24 fps.
/// 2. Storage is a fixed-size ring buffer, so a long session cannot grow the
///    heap or hide a processing backlog behind an ever-lengthening array.
struct FrameTimingCollector: Equatable, Sendable {
    private var intervals: [Double]
    private var writeIndex = 0
    private var filled = 0

    private(set) var deliveredFrames = 0
    private(set) var droppedFrames = 0
    private(set) var firstTimestampSeconds: Double?
    private(set) var lastTimestampSeconds: Double?

    let capacity: Int

    init(capacity: Int = 240) {
        self.capacity = max(1, capacity)
        self.intervals = Array(repeating: 0, count: self.capacity)
    }

    /// - Parameter presentationSeconds: the sample buffer's presentation
    ///   timestamp. Non-finite or out-of-order values are ignored rather than
    ///   allowed to poison the statistics.
    mutating func record(presentationSeconds: Double) {
        guard presentationSeconds.isFinite else { return }

        if let last = lastTimestampSeconds {
            let interval = presentationSeconds - last
            guard interval > 0 else { return }
            intervals[writeIndex] = interval
            writeIndex = (writeIndex + 1) % capacity
            filled = min(filled + 1, capacity)
        } else {
            firstTimestampSeconds = presentationSeconds
        }

        lastTimestampSeconds = presentationSeconds
        deliveredFrames += 1
    }

    mutating func recordDrop() {
        droppedFrames += 1
    }

    mutating func reset() {
        intervals = Array(repeating: 0, count: capacity)
        writeIndex = 0
        filled = 0
        deliveredFrames = 0
        droppedFrames = 0
        firstTimestampSeconds = nil
        lastTimestampSeconds = nil
    }

    func statistics() -> FrameTimingStatistics {
        let window = Array(intervals.prefix(filled))
        let sorted = window.sorted()

        let median: Double
        if sorted.isEmpty {
            median = 0
        } else if sorted.count % 2 == 1 {
            median = sorted[sorted.count / 2]
        } else {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }

        // Derived from the median rather than the mean so one long stall does
        // not drag the reported rate down and mask an otherwise steady stream.
        let rate = median > 0 ? 1.0 / median : 0

        return FrameTimingStatistics(
            deliveredFrames: deliveredFrames,
            droppedFrames: droppedFrames,
            measuredFrameRate: rate,
            medianIntervalSeconds: median,
            maximumIntervalSeconds: sorted.last ?? 0,
            firstTimestampSeconds: firstTimestampSeconds,
            lastTimestampSeconds: lastTimestampSeconds
        )
    }
}

/// Thread-safe wrapper so the sample-buffer queue can write while the session
/// queue reads a snapshot.
final class FrameTimingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collector: FrameTimingCollector

    init(capacity: Int = 240) {
        collector = FrameTimingCollector(capacity: capacity)
    }

    func record(presentationSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        collector.record(presentationSeconds: presentationSeconds)
    }

    func recordDrop() {
        lock.lock()
        defer { lock.unlock() }
        collector.recordDrop()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        collector.reset()
    }

    func statistics() -> FrameTimingStatistics {
        lock.lock()
        defer { lock.unlock() }
        return collector.statistics()
    }
}
