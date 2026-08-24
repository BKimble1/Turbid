import SwiftUI

/// The calibration library: what calibrations exist, whether the selected one
/// applies right now, and how to make another.
///
/// The safety notice is first and cannot be dismissed. Formazin, the reference
/// turbidity standard, is made from hydrazine sulfate — acutely toxic and a
/// suspected carcinogen. Turbid never explains how to prepare a standard and
/// never will. Calibration uses standards bought ready-made and handled
/// according to the manufacturer's own instructions.
struct CalibrationView: View {
    let viewModel: MeasurementViewModel

    @State private var showsRun = false
    @State private var message: String?

    private var library: CalibrationLibrary { viewModel.calibrations }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                safetyNotice
                if let loadError = library.loadError {
                    errorCard(loadError)
                }
                if let message {
                    errorCard(message)
                }
                compatibility
                profiles
                requirements
                startButton
                DisclaimerFootnote()
            }
            .padding(Theme.Spacing.md)
        }
        .screenBackground()
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(AccessibilityID.Calibration.screen)
        .task { await viewModel.loadCalibrations() }
        .navigationDestination(isPresented: $showsRun) {
            CalibrationRunView(viewModel: viewModel)
        }
    }

    // MARK: - Sections

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Use bought, certified standards only", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.Palette.critical)

            Text("Turbidity standards must be commercially prepared and certified — formazin, or a certified styrene-divinylbenzene equivalent. Follow the manufacturer's safety and handling instructions, including disposal.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.primaryText)

            Text("Never attempt to prepare formazin yourself. It is made from hydrazine sulfate, which is acutely toxic and a suspected carcinogen. Turbid does not provide preparation instructions.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Palette.critical.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Calibration.safetyNotice)
    }

    private func errorCard(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(Theme.Palette.critical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.sm)
            .background(Theme.Palette.critical.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    @ViewBuilder
    private var compatibility: some View {
        SectionCard(title: "Does a calibration apply right now?",
                    systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if library.selectedProfile == nil {
                    Text("No calibration is selected, so measurements report relative optical clarity only.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryText)
                } else if viewModel.liveBinding == nil {
                    Text("Compatibility can only be checked once a measurement has locked the camera controls. Run one measurement and come back.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryText)
                } else {
                    let mismatches = library.mismatches(against: viewModel.liveBinding)
                    if mismatches.isEmpty {
                        Label("The last measured setup matches the selected calibration.",
                              systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Palette.positive)
                    } else {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Label("The last measured setup does not match:",
                                  systemImage: "xmark.octagon.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.Palette.critical)
                            ForEach(mismatches, id: \.self) { reason in
                                Text("• \(reason)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Calibration.compatibility)
    }

    @ViewBuilder
    private var profiles: some View {
        SectionCard(title: "Saved calibrations", systemImage: "tray.full") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if library.profilesNewestFirst.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "No calibrations yet",
                        message: "Without one, Turbid reports optical clarity but no NTU value."
                    )
                } else {
                    ForEach(library.profilesNewestFirst) { profile in
                        CalibrationProfileRow(
                            profile: profile,
                            isSelected: library.selectedProfileID == profile.id,
                            isExpired: library.isExpired(profile),
                            expiresSoon: library.expiringSoon().contains { $0.id == profile.id },
                            onSelect: { library.select(profile) },
                            onDelete: {
                                Task { message = await library.remove(profile) }
                            }
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Calibration.profileList)
    }

    private var requirements: some View {
        let fitter = CalibrationFitter()
        return SectionCard(
            title: "What a calibration needs",
            systemImage: "list.number",
            footnote: "The curve is chosen by leave-one-concentration-out cross validation, not by how well it fits the points it was built from."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                BulletRow(systemImage: "drop",
                          text: "A blank: a 0 NTU standard, or the water the standards were made up in.")
                BulletRow(systemImage: "number.circle",
                          text: "At least \(fitter.requirements.minimumNonZeroStandards) certified standards above zero, spanning the range you intend to measure.")
                BulletRow(systemImage: "repeat",
                          text: "At least \(fitter.requirements.minimumReplicatesPerLevel) separate readings of each one.")
                BulletRow(systemImage: "calendar",
                          text: "Every standard still inside its expiry date.")
                BulletRow(systemImage: "cube",
                          text: "The same fixture, container, fill volume and working distance every time.")
            }
        }
        .accessibilityIdentifier(AccessibilityID.Calibration.requirements)
    }

    private var startButton: some View {
        PrimaryActionButton(title: "Start a calibration", systemImage: "plus.circle.fill") {
            showsRun = true
        }
        .accessibilityIdentifier(AccessibilityID.Calibration.startRun)
    }
}

/// One saved calibration, with everything needed to decide whether to trust it.
struct CalibrationProfileRow: View {
    let profile: CalibrationProfile
    let isSelected: Bool
    let isExpired: Bool
    let expiresSoon: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Made \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                Spacer(minLength: Theme.Spacing.sm)
                if isSelected {
                    StatusChip(text: "In use", systemImage: "checkmark.circle.fill",
                               tint: Theme.Palette.accent)
                }
            }

            if isExpired {
                Label("Expired \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted)). Repeat it before using NTU again.",
                      systemImage: "xmark.octagon.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.critical)
            } else if expiresSoon {
                Label("Expires \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted)). Plan a re-run.",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.warning)
            } else {
                Text("Valid until \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }

            MetricRow(title: "Curve", value: profile.mapping.name)
            MetricRow(title: "Validated range",
                      value: String(format: "%.3g to %.3g NTU",
                                    profile.validatedNTURange.lowerBound,
                                    profile.validatedNTURange.upperBound))
            MetricRow(title: "Cross-validated error",
                      value: String(format: "%.3f NTU RMSE",
                                    profile.validation.rootMeanSquareErrorNTU),
                      detail: String(format: "Worst held-out level off by %.3f NTU",
                                     profile.validation.maximumAbsoluteErrorNTU))
            MetricRow(title: "Worst repeatability",
                      value: profile.validation.worstRelativeRepeatability
                          .formatted(.percent.precision(.fractionLength(1))))
            MetricRow(title: "Standards", value: profile.standardsSummary)
            MetricRow(title: "Fixture",
                      value: profile.binding.fixtureIdentifier,
                      detail: "\(profile.binding.containerIdentifier), \(profile.binding.fillVolumeMillilitres.formatted()) mL, \(profile.binding.workingDistanceMillimetres.formatted()) mm")

            HStack(spacing: Theme.Spacing.sm) {
                Button(isSelected ? "Selected" : "Use this one", action: onSelect)
                    .buttonStyle(.bordered)
                    .tint(Theme.Palette.accent)
                    .disabled(isSelected || isExpired)
                    .frame(minHeight: Theme.Layout.minimumTouchTarget)

                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .frame(minHeight: Theme.Layout.minimumTouchTarget)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Palette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}
