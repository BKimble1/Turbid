import SwiftUI

/// What is shown while a run is in progress.
///
/// The run is driven by frame presentation timestamps, so the progress bar and
/// the countdown come from the capture timeline rather than from a wall clock:
/// if the camera throttles, the bar slows down with it instead of promising a
/// finish that will not arrive.
struct MeasurementProgressView: View {
    let state: MeasurementState
    let progress: MeasurementProgress
    let samples: [ScatteringSample]
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            stageHeader
            progressBar
            if !progress.hints.isEmpty {
                HintBanner(hints: progress.hints)
                    .accessibilityIdentifier(AccessibilityID.Measurement.hints)
            }
            chart
            frameCounts
            SecondaryActionButton(title: "Stop and turn the torch off",
                                  systemImage: "stop.fill",
                                  role: .cancel) {
                onCancel()
            }
            .accessibilityIdentifier(AccessibilityID.Measurement.cancel)
            DisclaimerFootnote()
        }
        .accessibilityIdentifier(AccessibilityID.Measurement.screen)
    }

    private var stageHeader: some View {
        let presentation = MeasurementStatePresentation(state: state)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            StatusChip(text: presentation.title,
                       systemImage: presentation.systemImage,
                       tint: presentation.tint)
            Text(progress.stageDescription)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.Measurement.stage)
        .accessibilityElement(children: .combine)
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ProgressView(value: progress.overallProgress)
                .tint(Theme.Palette.accent)
                .animation(Theme.Motion.progress(reduceMotion: reduceMotion),
                           value: progress.overallProgress)

            HStack {
                Text(progress.stageDescription)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                Spacer(minLength: Theme.Spacing.sm)
                Text(remainingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Measurement.progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Measurement progress")
        .accessibilityValue("\(Int((progress.overallProgress * 100).rounded())) percent. \(progress.stageDescription). \(remainingText).")
    }

    private var remainingText: String {
        progress.remainingSeconds <= 0
            ? "finishing"
            : String(format: "%.0f s left", progress.remainingSeconds.rounded(.up))
    }

    private var chart: some View {
        SectionCard(title: "Scattering so far", systemImage: "chart.xyaxis.line",
                    footnote: "A relative index, not NTU. It settles as the window fills.") {
            ScatteringChartView(samples: samples)
        }
    }

    private var frameCounts: some View {
        HStack(spacing: Theme.Spacing.lg) {
            MetricRow(title: "Frames analysed", value: "\(progress.framesAnalysed)")
            MetricRow(title: "Usable", value: "\(progress.usableFrames)")
        }
    }
}

#Preview {
    ScrollView {
        MeasurementProgressView(
            state: .measuring,
            progress: MeasurementProgress(
                stage: .measurement, overallProgress: 0.42, stageProgress: 0.2,
                elapsedSeconds: 5.2, remainingSeconds: 7.3,
                framesAnalysed: 78, usableFrames: 76, backgroundIsReady: true,
                hints: [], latestSample: nil
            ),
            samples: [],
            onCancel: {}
        )
        .padding()
    }
}
