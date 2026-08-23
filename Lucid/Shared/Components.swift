import SwiftUI

/// A titled container used for every block on the scaffold screen.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .foregroundStyle(Theme.Palette.primaryText)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// Status pill that always pairs colour with an icon and text.
struct StatusChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
    }
}

struct PrimaryActionButton: View {
    let title: String
    var systemImage: String = "play.fill"
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.minimumTouchTarget)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.Palette.accent)
        .disabled(!isEnabled)
    }
}

/// Unmissable marker for content that is illustrative rather than measured.
struct SimulatedDataBanner: View {
    var body: some View {
        Label {
            Text("SIMULATED DATA — NOT A MEASUREMENT")
                .font(.caption.weight(.bold))
        } icon: {
            Image(systemName: "theatermasks.fill")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(Theme.Palette.simulated.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .foregroundStyle(Theme.Palette.simulated)
        .accessibilityLabel("Simulated data. Not a measurement.")
    }
}

/// The screening disclaimer. Calm, but always present alongside any result.
struct DisclaimerFootnote: View {
    var body: some View {
        Text(MeasurementDisclaimer.short)
            .font(.footnote)
            .foregroundStyle(Theme.Palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
