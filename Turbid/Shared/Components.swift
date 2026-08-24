import SwiftUI

/// The app's ground colour, applied behind a scrolling screen.
struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background.ignoresSafeArea())
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}

/// A titled container used for every block in the app.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .foregroundStyle(Theme.Palette.primaryText)

            content

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
        )
    }
}

/// Status pill. Colour is never the only signal: there is always a symbol and
/// a word as well.
struct StatusChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(tint.opacity(0.18), in: Capsule())
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

struct SecondaryActionButton: View {
    let title: String
    var systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.minimumTouchTarget)
        }
        .buttonStyle(.bordered)
        .tint(role == .destructive ? Theme.Palette.critical : Theme.Palette.accent)
    }
}

/// A label and a value on one row, read by VoiceOver as a single phrase.
struct MetricRow: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)
                Spacer(minLength: Theme.Spacing.sm)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.Palette.primaryText)
                    .multilineTextAlignment(.trailing)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title), \(value). \($0)" } ?? "\(title), \(value)")
    }
}

/// A short bulleted line with a symbol, used for instructions and findings.
struct BulletRow: View {
    let systemImage: String
    let text: String
    var tint: Color = Theme.Palette.accent

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An in-the-moment instruction shown while a measurement is running.
struct HintBanner: View {
    let hints: [LiveQualityHint]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(hints) { hint in
                Label(hint.prompt, systemImage: hint.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Palette.warning.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hints.map(\.prompt).joined(separator: ". "))
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
        .background(Theme.Palette.simulated.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
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

/// An empty-state block: what is missing, and what to do about it.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Theme.Palette.secondaryText)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.Palette.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.lg)
        .accessibilityElement(children: .combine)
    }
}
