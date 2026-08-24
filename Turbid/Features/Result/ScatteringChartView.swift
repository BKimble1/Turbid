import Charts
import Foundation
import SwiftUI

/// The live graph of the relative scattering index.
///
/// It plots the index and nothing else, even in Calibrated Fixture Mode. A
/// running NTU would have to be produced before the capture-quality verdict
/// exists, and a number that appears, moves, and is then withheld at the end is
/// worse than no number at all. The NTU estimate belongs to the finished
/// reading, and appears there.
///
/// Two series are drawn: the raw running index, and the display smoothing of
/// it. They are distinguished by weight and dash as well as by colour, so the
/// difference survives monochrome and colour-blind viewing. The smoothed line
/// is presentation only — nothing computes from it.
struct ScatteringChartView: View {
    let samples: [ScatteringSample]
    /// Shown under the chart when the run has finished with a number.
    var finalNTU: NTUAvailability?
    var isLive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if samples.isEmpty {
                EmptyStateView(
                    systemImage: "chart.xyaxis.line",
                    title: isLive ? "Waiting for frames" : "No graph for this run",
                    message: isLive
                        ? "The graph starts once the camera begins delivering frames."
                        : "The measurement ended before any window was aggregated."
                )
                .frame(height: Theme.Layout.chartHeight)
            } else {
                chart
                legend
            }

            if let finalNTU {
                Text(finalNTU.displayText)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Seconds", sample.elapsedSeconds),
                    y: .value("Index", sample.index),
                    series: .value("Series", "Measured")
                )
                .foregroundStyle(Theme.Palette.chartRaw)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Seconds", sample.elapsedSeconds),
                    y: .value("Index", sample.smoothedIndex),
                    series: .value("Series", "Smoothed")
                )
                .foregroundStyle(Theme.Palette.chartSmoothed)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: domain)
        .chartXAxisLabel("Seconds")
        .chartYAxisLabel("Relative scattering index")
        .chartLegend(.hidden)
        .frame(height: Theme.Layout.chartHeight)
        .animation(Theme.Motion.progress(reduceMotion: reduceMotion), value: samples.count)
        .accessibilityIdentifier(AccessibilityID.Measurement.chart)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relative scattering index over time")
        .accessibilityValue(accessibilitySummary)
    }

    private var legend: some View {
        HStack(spacing: Theme.Spacing.md) {
            legendItem(title: "Measured", color: Theme.Palette.chartRaw, dashed: true)
            legendItem(title: "Smoothed (display only)",
                       color: Theme.Palette.chartSmoothed, dashed: false)
        }
        .font(.caption2)
        .foregroundStyle(Theme.Palette.secondaryText)
        .accessibilityHidden(true)
    }

    private func legendItem(title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Capsule()
                .strokeBorder(color, style: StrokeStyle(lineWidth: dashed ? 1 : 2.5,
                                                        dash: dashed ? [3, 2] : []))
                .frame(width: 18, height: 3)
            Text(title)
        }
    }

    /// Padded so the newest point is never pinned to the top edge, and never
    /// degenerate, which would make the chart refuse to draw.
    private var domain: ClosedRange<Double> {
        let values = samples.map(\.index) + samples.map(\.smoothedIndex)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        guard high > low else { return max(0, low - 1)...(high + 1) }
        let padding = (high - low) * 0.15
        return max(0, low - padding)...(high + padding)
    }

    /// VoiceOver gets the shape of the series, not a list of points: reading two
    /// hundred numbers aloud is not a description of anything.
    private var accessibilitySummary: String {
        guard let first = samples.first, let last = samples.last else { return "No data yet." }
        let values = samples.map(\.index)
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 0
        let direction: String
        if last.index > first.index * 1.05 {
            direction = "rising"
        } else if last.index < first.index * 0.95 {
            direction = "falling"
        } else {
            direction = "steady"
        }
        return String(
            format: "%d points over %.0f seconds, %@. Now %.1f, ranging from %.1f to %.1f.",
            samples.count, last.elapsedSeconds, direction, last.index, lowest, highest
        )
    }
}

/// Sample data for previews only. Never reachable from the app.
private enum ChartPreviewData {
    static func rising() -> [ScatteringSample] {
        var buffer = ScatteringSampleBuffer(capacity: 120)
        for step in 0..<60 {
            let time = Double(step) * 0.2
            buffer.append(elapsedSeconds: time,
                          index: 12 + 6 * sin(time) + Double(step) * 0.2,
                          ntu: nil)
        }
        return buffer.samples
    }
}

#Preview("Live") {
    ScatteringChartView(samples: ChartPreviewData.rising()).padding()
}

#Preview("Empty") {
    ScatteringChartView(samples: []).padding()
}
