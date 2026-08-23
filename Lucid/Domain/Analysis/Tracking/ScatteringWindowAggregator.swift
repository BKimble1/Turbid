import Foundation

/// One completed sub-window of a measurement.
struct ScatteringWindow: Equatable, Sendable, Codable {
    let startSeconds: Double
    let endSeconds: Double
    let frameCount: Int
    let meanPositiveResidual: Double
    let upperPercentileExcess: Double
    let activeForegroundFraction: Double
    let speckEventsPerSecond: Double

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

/// Robust summary across the sub-windows, plus a repeatability figure.
struct ScatteringSummary: Equatable, Sendable, Codable {
    let windowCount: Int
    /// Medians across windows, not across frames: each window is a small
    /// independent measurement, and a median over them is unmoved by one
    /// window spoiled by a bubble or a nudge.
    let medianPositiveResidual: Double
    let medianUpperPercentileExcess: Double
    let medianActiveForegroundFraction: Double
    let medianSpeckEventsPerSecond: Double

    /// Spread of the per-window residual relative to its median, `0` being
    /// perfectly repeatable. This is the honest measure of how much a repeat of
    /// the same measurement would differ, and it is reported rather than
    /// smoothed away.
    let residualRelativeSpread: Double
    /// `0...1`, derived from the spread. High spread means low confidence.
    let repeatabilityConfidence: Double

    static let empty = ScatteringSummary(
        windowCount: 0, medianPositiveResidual: 0, medianUpperPercentileExcess: 0,
        medianActiveForegroundFraction: 0, medianSpeckEventsPerSecond: 0,
        residualRelativeSpread: 0, repeatabilityConfidence: 0
    )
}

/// Splits a measurement into overlapping sub-windows and summarises them.
///
/// Overlapping so a slow event straddling a boundary is still wholly inside
/// some window. Bounded so a long run cannot grow: only the most recent windows
/// are retained, and each window holds running sums rather than its frames.
///
/// The raw per-window results are kept alongside the summary. Smoothing is
/// applied only to what is displayed — the numbers used for validation are
/// never the smoothed ones.
struct ScatteringWindowAggregator: Equatable, Sendable {

    struct Configuration: Equatable, Sendable, Codable {
        var windowSeconds: Double
        /// How far apart consecutive windows start. Below `windowSeconds`, so
        /// they overlap.
        var strideSeconds: Double
        var maximumWindows: Int
        /// Relative spread at which repeatability confidence reaches zero.
        var spreadAtZeroConfidence: Double
        var version: Int

        static let screening = Configuration(
            windowSeconds: 3.0,
            strideSeconds: 1.5,
            maximumWindows: 16,
            spreadAtZeroConfidence: 0.5,
            version: 1
        )
    }

    let configuration: Configuration
    private(set) var windows: [ScatteringWindow] = []

    private var openStart: Double?
    private var frameCount = 0
    private var totalResidual: Double = 0
    private var totalUpperExcess: Double = 0
    private var totalActiveFraction: Double = 0
    private var speckEvents = 0
    private var lastTimestamp: Double = 0
    /// Frames belonging to the overlapping tail, replayed into the next window
    /// so overlap costs one small buffer rather than a full frame history.
    private var carried: [(timestamp: Double, residual: Double, upper: Double,
                           active: Double, specks: Int)] = []

    init(configuration: Configuration = .screening) {
        self.configuration = configuration
    }

    mutating func reset() {
        windows.removeAll(keepingCapacity: true)
        carried.removeAll(keepingCapacity: true)
        openStart = nil
        frameCount = 0
        totalResidual = 0
        totalUpperExcess = 0
        totalActiveFraction = 0
        speckEvents = 0
    }

    /// Records one measurement frame.
    ///
    /// - Parameter newSpeckEvents: confirmed specks that first appeared in this
    ///   frame, so a speck visible for many frames contributes one event.
    mutating func record(timestampSeconds: Double,
                         bulk: BulkScatteringMetrics,
                         newSpeckEvents: Int) {
        if openStart == nil { openStart = timestampSeconds }
        lastTimestamp = timestampSeconds

        frameCount += 1
        totalResidual += bulk.meanPositiveResidual
        totalUpperExcess += bulk.upperPercentileExcess
        totalActiveFraction += bulk.activeForegroundFraction
        speckEvents += newSpeckEvents

        guard let start = openStart else { return }
        // Retain the tail that the next window will overlap.
        if timestampSeconds - start >= configuration.strideSeconds {
            carried.append((timestampSeconds, bulk.meanPositiveResidual,
                            bulk.upperPercentileExcess, bulk.activeForegroundFraction,
                            newSpeckEvents))
        }

        if timestampSeconds - start >= configuration.windowSeconds {
            closeWindow(at: timestampSeconds)
        }
    }

    /// Closes any partial window, so a run shorter than one full window still
    /// produces a result.
    mutating func finish() {
        guard frameCount > 0 else { return }
        closeWindow(at: lastTimestamp)
    }

    private mutating func closeWindow(at end: Double) {
        guard let start = openStart, frameCount > 0 else { return }
        let duration = max(end - start, 1e-6)

        windows.append(ScatteringWindow(
            startSeconds: start,
            endSeconds: end,
            frameCount: frameCount,
            meanPositiveResidual: totalResidual / Double(frameCount),
            upperPercentileExcess: totalUpperExcess / Double(frameCount),
            activeForegroundFraction: totalActiveFraction / Double(frameCount),
            speckEventsPerSecond: Double(speckEvents) / duration
        ))
        if windows.count > configuration.maximumWindows {
            windows.removeFirst(windows.count - configuration.maximumWindows)
        }

        // Restart from the carried tail so windows overlap.
        let tail = carried
        carried.removeAll(keepingCapacity: true)
        openStart = tail.first?.timestamp
        frameCount = tail.count
        totalResidual = tail.reduce(0) { $0 + $1.residual }
        totalUpperExcess = tail.reduce(0) { $0 + $1.upper }
        totalActiveFraction = tail.reduce(0) { $0 + $1.active }
        speckEvents = tail.reduce(0) { $0 + $1.specks }
        for entry in tail where entry.timestamp - (openStart ?? entry.timestamp) >= configuration.strideSeconds {
            carried.append(entry)
        }
    }

    func summary() -> ScatteringSummary {
        guard !windows.isEmpty else { return .empty }

        let residuals = windows.map(\.meanPositiveResidual)
        let median = Self.median(residuals)

        // Median absolute deviation rather than a standard deviation: with only
        // a handful of windows, one spoiled by a bubble would dominate a
        // standard deviation and understate the repeatability of the rest.
        let spread: Double
        if residuals.count >= 3, median > 0 {
            let deviations = residuals.map { abs($0 - median) }
            spread = Self.median(deviations) * 1.4826 / median
        } else {
            spread = 0
        }

        let confidence = residuals.count >= 3
            ? max(0, 1 - spread / max(configuration.spreadAtZeroConfidence, 1e-9))
            : 0

        return ScatteringSummary(
            windowCount: windows.count,
            medianPositiveResidual: median,
            medianUpperPercentileExcess: Self.median(windows.map(\.upperPercentileExcess)),
            medianActiveForegroundFraction: Self.median(windows.map(\.activeForegroundFraction)),
            medianSpeckEventsPerSecond: Self.median(windows.map(\.speckEventsPerSecond)),
            residualRelativeSpread: spread,
            repeatabilityConfidence: min(1, confidence)
        )
    }

    /// Exponentially weighted average of the per-window residual, for display
    /// only. Never fed back into the measurement.
    func smoothedResidualForDisplay(factor: Double = 0.4) -> Double {
        guard let first = windows.first else { return 0 }
        var value = first.meanPositiveResidual
        for window in windows.dropFirst() {
            value = factor * window.meanPositiveResidual + (1 - factor) * value
        }
        return value
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
