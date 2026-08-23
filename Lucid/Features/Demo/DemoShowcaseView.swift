import SwiftUI

/// Simulator-only preview of the three result states.
///
/// This view is only reachable when `AppEnvironment.allowsSimulatedData` is
/// `true`, which requires both a debug build and the Simulator.
struct DemoShowcaseView: View {
    var body: some View {
        SectionCard(title: "Simulator demo", systemImage: "theatermasks") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SimulatedDataBanner()

                Text("These are example result states so the layout can be reviewed without hardware. No camera, torch or analysis is running.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)

                ForEach(DemoScenario.all) { scenario in
                    DemoScenarioRow(scenario: scenario)
                }
            }
        }
    }
}

private struct DemoScenarioRow: View {
    let scenario: DemoScenario

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scenario.clarity.headline) (example)")
                        .font(.subheadline.weight(.semibold))
                    Text(scenario.clarity.qualifier)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            } icon: {
                Image(systemName: scenario.clarity.symbolName)
                    .foregroundStyle(Theme.Palette.simulated)
            }

            Text(scenario.explanation)
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryText)

            HStack(spacing: Theme.Spacing.md) {
                exampleMetric("Scattering", scenario.relativeScatteringExample)
                exampleMetric("Tracked specks", scenario.trackedSpecksExample)
                exampleMetric("Estimated NTU", scenario.estimatedNTUText)
            }
        }
        .padding(Theme.Spacing.sm)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Theme.Palette.simulated.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Simulated example: \(scenario.clarity.headline), \(scenario.clarity.qualifier)")
    }

    private func exampleMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.Palette.secondaryText)
            Text(value)
                .font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ScrollView { DemoShowcaseView().padding() }
}
