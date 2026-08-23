import SwiftUI

/// The alignment step: everything the user needs to settle before committing to
/// a measurement window, and live feedback on whether the view is good enough.
///
/// The Start button is never disabled by the quality gates. They are engineering
/// starting points, not validated limits, and a gate that is slightly wrong must
/// not be able to lock someone out of their own device. What it does instead is
/// say plainly whether the view is currently good, so starting anyway is a
/// choice rather than an accident.
struct SetupWizardView: View {
    let alignment: AlignmentStatus
    let mode: MeasurementMode
    let profile: CalibrationProfile?
    let mismatches: [String]
    let torchIsOn: Bool
    let onBegin: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            readiness
            if !alignment.hints.isEmpty {
                HintBanner(hints: alignment.hints)
                    .accessibilityIdentifier(AccessibilityID.Setup.hint)
            }
            modeCard
            checklist
            actions
            DisclaimerFootnote()
        }
        .accessibilityIdentifier(AccessibilityID.Setup.screen)
    }

    private var readiness: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatusChip(text: readinessTitle,
                       systemImage: readinessSymbol,
                       tint: readinessTint)
            if !torchIsOn {
                StatusChip(text: "Torch off",
                           systemImage: "flashlight.off.fill",
                           tint: Theme.Palette.warning)
            }
            Spacer(minLength: 0)
        }
    }

    private var readinessTitle: String {
        if alignment.isReadyToMeasure { return "View looks good" }
        if alignment.passesGates { return "Settling" }
        if alignment.steadyFrames == 0 && alignment.hints.isEmpty { return "Looking at the sample" }
        return "Not ready yet"
    }

    private var readinessSymbol: String {
        if alignment.isReadyToMeasure { return "checkmark.circle.fill" }
        if alignment.passesGates { return "hourglass" }
        return "exclamationmark.triangle.fill"
    }

    private var readinessTint: Color {
        if alignment.isReadyToMeasure { return Theme.Palette.positive }
        if alignment.passesGates { return Theme.Palette.accent }
        return Theme.Palette.warning
    }

    @ViewBuilder
    private var modeCard: some View {
        SectionCard(title: mode.title, systemImage: mode.permitsNumericNTU ? "ruler" : "eye") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(mode.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)

                if mode.permitsNumericNTU {
                    if let profile {
                        MetricRow(title: "Calibration", value: profile.name,
                                  detail: "Covers \(profile.validatedNTURange.lowerBound.formatted(.number.precision(.significantDigits(2)))) to \(profile.validatedNTURange.upperBound.formatted(.number.precision(.significantDigits(2)))) NTU")
                        if mismatches.isEmpty {
                            Label("This setup matches the calibration.",
                                  systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.positive)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("No NTU will be shown for this run:",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.warning)
                                ForEach(mismatches, id: \.self) { reason in
                                    Text("• \(reason)")
                                        .font(.caption)
                                        .foregroundStyle(Theme.Palette.secondaryText)
                                }
                            }
                        }
                    } else {
                        Label("No calibration is selected, so this run will report relative clarity only.",
                              systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
            }
        }
    }

    private var checklist: some View {
        SectionCard(title: "Before you start", systemImage: "list.bullet") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(SetupChecklist.items) { item in
                    BulletRow(systemImage: item.symbolName, text: item.instruction)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Setup.checklist)
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            PrimaryActionButton(title: "Start Measurement", systemImage: "play.fill") {
                onBegin()
            }
            .accessibilityIdentifier(AccessibilityID.Setup.begin)
            .accessibilityHint(alignment.isReadyToMeasure
                               ? "Runs a 12 and a half second measurement."
                               : "The view is not steady yet. You can start anyway.")

            SecondaryActionButton(title: "Stop and turn the torch off",
                                  systemImage: "stop.fill",
                                  role: .cancel) {
                onCancel()
            }
            .accessibilityIdentifier(AccessibilityID.Setup.cancel)
        }
    }
}

#Preview("Ready") {
    ScrollView {
        SetupWizardView(
            alignment: AlignmentStatus(hints: [], passesGates: true, steadyFrames: 20,
                                       meanLevel: 0.2, sharpness: 0.01, motion: 0.0005),
            mode: .screening,
            profile: nil,
            mismatches: [],
            torchIsOn: true,
            onBegin: {},
            onCancel: {}
        )
        .padding()
    }
}

#Preview("Needs work") {
    ScrollView {
        SetupWizardView(
            alignment: AlignmentStatus(
                hints: [LiveQualityHint(reason: .cameraMoved, prompt: "Hold steady",
                                        symbolName: "hand.raised.fill")],
                passesGates: false, steadyFrames: 0,
                meanLevel: 0.2, sharpness: 0.01, motion: 0.05
            ),
            mode: .calibratedFixture,
            profile: nil,
            mismatches: [],
            torchIsOn: false,
            onBegin: {},
            onCancel: {}
        )
        .padding()
    }
}
