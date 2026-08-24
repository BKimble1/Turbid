import SwiftUI

/// The first thing anyone sees: what Turbid measures, and what it does not.
///
/// Shown once and then recorded, but always reachable again from the main
/// screen. The wording is deliberately plain. Someone testing water they are
/// worried about has to leave this screen knowing that a good result here says
/// nothing about whether the water is safe.
struct OnboardingView: View {
    let onAcknowledge: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                whatItMeasures
                whatItCannotDetect
                modes
                howToGetAGoodReading
                acknowledgement
            }
            .padding(Theme.Spacing.md)
        }
        .screenBackground()
        .accessibilityIdentifier(AccessibilityID.Onboarding.screen)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Image(systemName: "drop.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)

            Text("Turbid")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.Palette.primaryText)

            Text("Optical clarity screening for water samples")
                .font(.title3)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var whatItMeasures: some View {
        SectionCard(title: "What Turbid measures", systemImage: "flashlight.on.fill") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Turbid turns the torch on, watches how much light a water sample scatters back to the camera, and tracks visible specks drifting through a small region of the frame.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.primaryText)

                Text("It reports one of three states, describing the optical clarity it observed:")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)

                ForEach(OpticalClarityClass.allCases, id: \.self) { clarity in
                    BulletRow(systemImage: clarity.symbolName,
                              text: "\(clarity.headline) — \(clarity.qualifier)",
                              tint: Theme.Palette.clarity(clarity))
                }
            }
        }
    }

    private var whatItCannotDetect: some View {
        SectionCard(title: "What Turbid cannot tell you", systemImage: "exclamationmark.shield") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(MeasurementDisclaimer.long)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.primaryText)

                Divider().background(Theme.Palette.separator)

                ForEach(MeasurementDisclaimer.cannotDetect, id: \.self) { item in
                    BulletRow(systemImage: "xmark.circle.fill",
                              text: item,
                              tint: Theme.Palette.critical)
                }

                Text("Clear water can be unsafe, and safe water can look cloudy. If you need to know whether water is safe to drink, have it tested by a laboratory.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
            }
        }
    }

    private var modes: some View {
        SectionCard(title: "Why there is usually no NTU number",
                    systemImage: "number") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("NTU is the unit a laboratory turbidity meter reports. An iPhone is not one: it has no calibrated light source, no fixed sample geometry and no defined detection angle. Turbid will only show an NTU value when it has been calibrated against certified standards on the exact setup being used.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.primaryText)

                ForEach(MeasurementMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text(mode.summary)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var howToGetAGoodReading: some View {
        SectionCard(title: "Getting a usable reading", systemImage: "hand.raised") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(SetupChecklist.items) { item in
                    BulletRow(systemImage: item.symbolName, text: item.instruction)
                }
            }
        }
    }

    private var acknowledgement: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("I understand that Turbid measures optical clarity only, and does not tell me whether water is safe to drink.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.primaryText)
                .accessibilityIdentifier(AccessibilityID.Onboarding.acknowledge)

            PrimaryActionButton(title: "I understand — continue",
                                systemImage: "checkmark.circle.fill") {
                onAcknowledge()
            }
            .accessibilityIdentifier(AccessibilityID.Onboarding.continueButton)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Palette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

#Preview {
    OnboardingView(onAcknowledge: {})
}
