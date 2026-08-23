import SwiftUI

/// The result, at a glance.
///
/// Three things are non-negotiable on this screen: the headline says *optical
/// clarity*, the NTU line says why there is no number when there is none, and
/// the disclaimer is present. Everything else is detail and lives in the Deep
/// Dive.
struct QuickViewResultView: View {
    let reading: TurbidityReading
    /// The run's chart series, handed straight to the Deep Dive.
    let samples: [ScatteringSample]
    let isSimulated: Bool
    let onMeasureAgain: () -> Void
    let onDone: () -> Void

    @State private var showsDeepDive = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if isSimulated { SimulatedDataBanner() }
                if !reading.validity.isValid { rejectionBanner }

                headline
                numbers
                confidence
                actions

                Text(reading.disclaimer)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.Result.disclaimer)
            }
            .padding(Theme.Spacing.md)
        }
        .screenBackground()
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(AccessibilityID.Result.screen)
        .sheet(isPresented: $showsDeepDive) {
            DeepDiveView(reading: reading, samples: samples, isSimulated: isSimulated)
        }
    }

    // MARK: - Sections

    private var rejectionBanner: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("This capture did not meet the quality gates",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.Palette.warning)

            Text("The clarity state below describes what was seen, but the capture was not good enough to rely on. Fix the problems and measure again.")
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryText)

            ForEach(reading.validity.reasons, id: \.rawValue) { reason in
                Text("• \(reason.explanation)")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.warning.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Result.lowQuality)
    }

    private var headline: some View {
        let clarity = reading.clarity.clarity
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Image(systemName: clarity.symbolName)
                .font(.system(size: 52))
                .foregroundStyle(Theme.Palette.clarity(clarity))
                .accessibilityHidden(true)

            Text(clarity.headline)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.Palette.primaryText)

            Text(clarity.qualifier)
                .font(.title3)
                .foregroundStyle(Theme.Palette.secondaryText)

            Text(reading.clarity.description)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Result.headline)
        .accessibilityLabel("\(clarity.headline). \(clarity.qualifier). \(reading.clarity.description).")
    }

    private var numbers: some View {
        SectionCard(title: "What was measured", systemImage: "ruler") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    MetricRow(title: "Estimated turbidity",
                              value: reading.ntu.displayText)
                        .accessibilityIdentifier(AccessibilityID.Result.ntu)
                    Text(reading.ntu.explanation)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                Divider().background(Theme.Palette.separator)

                MetricRow(title: "Relative scattering index",
                          value: reading.index.value.formatted(.number.precision(.fractionLength(1))),
                          detail: "Dimensionless. Comparable only between runs made the same way.")
                    .accessibilityIdentifier(AccessibilityID.Result.index)

                MetricRow(title: "Visible particles (tracked)",
                          value: String(format: "%.1f per second",
                                        reading.trackedSpeckEventsPerSecond),
                          detail: "Bright events the camera could resolve and follow. Not a particle concentration.")

                MetricRow(title: "Mode", value: reading.mode.title)
            }
        }
    }

    private var confidence: some View {
        SectionCard(title: "How much to trust this", systemImage: "gauge.with.dots.needle.33percent") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                MetricRow(title: "Confidence",
                          value: reading.confidence.formatted(.percent.precision(.fractionLength(0))),
                          detail: "The lower of capture quality and repeatability across sub-windows.")

                MetricRow(title: "Repeatability",
                          value: reading.scattering.residualRelativeSpread
                              .formatted(.percent.precision(.fractionLength(1))),
                          detail: "How much the sub-windows of this run disagreed.")

                if reading.tracking.tracksDroppedForCapacity > 0 {
                    Label("The tracker hit its capacity, so the particle count is a lower bound.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            SecondaryActionButton(title: "Deep Dive", systemImage: "chart.bar.doc.horizontal") {
                showsDeepDive = true
            }
            .accessibilityIdentifier(AccessibilityID.Result.deepDive)

            PrimaryActionButton(title: "Measure Again", systemImage: "arrow.clockwise") {
                onMeasureAgain()
            }
            .accessibilityIdentifier(AccessibilityID.Result.measureAgain)

            Button("Done", action: onDone)
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.minimumTouchTarget)
                .accessibilityIdentifier(AccessibilityID.Result.done)
        }
    }
}
