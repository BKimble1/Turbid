import SwiftUI
import UIKit

/// The guided calibration workflow.
///
/// Each replicate is an ordinary measurement, taken on the same screen a normal
/// measurement uses, and recorded only if it passed the quality gates. A
/// calibration assembled from captures that would have been rejected as
/// measurements would be a curve fitted to noise.
struct CalibrationRunView: View {
    let viewModel: MeasurementViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var session: CalibrationSessionViewModel
    @State private var message: String?

    @MainActor
    init(viewModel: MeasurementViewModel) {
        self.viewModel = viewModel
        _session = State(initialValue: CalibrationSessionViewModel(
            measurement: viewModel,
            library: viewModel.calibrations
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                progressStrip

                if let message {
                    noticeCard(message, tint: Theme.Palette.warning)
                }
                if let problem = session.problem {
                    noticeCard(problem, tint: Theme.Palette.critical)
                }

                switch session.stage {
                case .describeSetup: setupStep
                case .enterStandards: standardsStep
                case .capture: captureStep
                case .review: reviewStep
                case .saved: savedStep
                }
            }
            .padding(Theme.Spacing.md)
        }
        .screenBackground()
        .navigationTitle("New Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.isCalibrating = true }
        .onDisappear {
            viewModel.isCalibrating = false
            session.abandon()
            Task { await viewModel.cancel() }
        }
    }

    // MARK: - Chrome

    private var progressStrip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            step("Setup", isDone: session.stage != .describeSetup)
            step("Standards", isDone: session.stage == .capture
                 || session.stage == .review || session.stage == .saved)
            step("Measure", isDone: session.stage == .review || session.stage == .saved)
            step("Review", isDone: session.stage == .saved)
        }
        .accessibilityElement(children: .combine)
    }

    private func step(_ title: String, isDone: Bool) -> some View {
        Label(title, systemImage: isDone ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(isDone ? Theme.Palette.positive : Theme.Palette.secondaryText)
            .frame(maxWidth: .infinity)
    }

    private func noticeCard(_ text: String, tint: Color) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.sm)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    // MARK: - Step 1: the setup

    private var setupStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionCard(
                title: "Describe the setup",
                systemImage: "cube",
                footnote: "A calibration belongs to one physical arrangement. If any of this changes, the calibration no longer describes it and Lucid will refuse to use it."
            ) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    labelledField("Fixture or holder", text: $session.setup.fixtureIdentifier,
                                  prompt: "e.g. printed shroud v2")
                    labelledField("Container", text: $session.setup.containerIdentifier,
                                  prompt: "e.g. 20 mL borosilicate vial")
                    labelledField("Fill volume (mL)",
                                  text: $session.setup.fillVolumeMillilitres,
                                  prompt: "e.g. 15", keyboard: .decimalPad)
                    labelledField("Working distance (mm)",
                                  text: $session.setup.workingDistanceMillimetres,
                                  prompt: "e.g. 45", keyboard: .decimalPad)
                }
            }

            SectionCard(title: "What this will take", systemImage: "clock") {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(session.requirementSummary, id: \.self) { item in
                        BulletRow(systemImage: "checkmark.circle", text: item)
                    }
                    Text("Each reading takes about \(SetupWizardView.runLength)s, and the fixture has to be reassembled the same way every time.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }

            PrimaryActionButton(title: "Next: the standards", systemImage: "arrow.right") {
                session.confirmSetup()
            }
        }
    }

    // MARK: - Step 2: the standards

    private var standardsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionCard(
                title: "Add a standard",
                systemImage: "plus.circle",
                footnote: "Read every value off the bottle's certificate. Nothing here is inferred."
            ) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    labelledField("Certified value (NTU)", text: $session.draft.nominalNTU,
                                  prompt: "0 for the blank", keyboard: .decimalPad)
                    labelledField("Certificate tolerance (± NTU)",
                                  text: $session.draft.toleranceNTU,
                                  prompt: "e.g. 0.1", keyboard: .decimalPad)
                    labelledField("Manufacturer", text: $session.draft.manufacturer,
                                  prompt: "e.g. Acme Analytical")
                    labelledField("Lot number", text: $session.draft.lotNumber,
                                  prompt: "from the bottle")
                    DatePicker("Expires", selection: $session.draft.expiryDate,
                               displayedComponents: .date)
                        .font(.subheadline)

                    SecondaryActionButton(title: "Add standard", systemImage: "plus") {
                        message = session.addDraftStandard()
                    }
                }
            }

            SectionCard(title: "Standards in this calibration", systemImage: "list.bullet") {
                if session.standards.isEmpty {
                    EmptyStateView(systemImage: "tray",
                                   title: "Nothing added yet",
                                   message: "Start with the blank, then work upwards.")
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(session.standards) { standard in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: "%.3g NTU ± %.3g",
                                                standard.nominalNTU, standard.toleranceNTU))
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(standard.manufacturer), lot \(standard.lotNumber), expires \(standard.expiryDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.Palette.secondaryText)
                                }
                                Spacer(minLength: Theme.Spacing.sm)
                                Button("Remove", role: .destructive) {
                                    session.removeStandard(standard)
                                }
                                .font(.caption)
                                .frame(minHeight: Theme.Layout.minimumTouchTarget)
                            }
                        }
                    }
                }
            }

            if !session.outstandingProblems.isEmpty {
                SectionCard(title: "Still missing", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(session.outstandingProblems, id: \.rawValue) { problem in
                            Text("• \(problem.explanation)")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                }
            }

            PrimaryActionButton(title: "Start measuring (\(session.estimatedRunCount) readings)",
                                systemImage: "camera.viewfinder") {
                session.beginCapture()
            }
        }
    }

    // MARK: - Step 3: the readings

    private var captureStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionCard(title: "Progress", systemImage: "chart.bar") {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(session.standards) { standard in
                        let count = session.replicateCount(for: standard)
                        let needed = session.requirements.minimumReplicatesPerLevel
                        Button {
                            session.selectStandard(standard)
                        } label: {
                            HStack {
                                Image(systemName: count >= needed
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(count >= needed
                                                     ? Theme.Palette.positive
                                                     : Theme.Palette.secondaryText)
                                Text(String(format: "%.3g NTU", standard.nominalNTU))
                                    .font(.subheadline)
                                Spacer(minLength: Theme.Spacing.sm)
                                Text("\(count) of \(needed)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(standard.id == session.activeStandard?.id
                                                     ? Theme.Palette.accent
                                                     : Theme.Palette.secondaryText)
                            }
                            .frame(minHeight: Theme.Layout.minimumTouchTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: "%.3g NTU, %d of %d readings",
                                                   standard.nominalNTU, count, needed))
                    }
                }
            }

            if let standard = session.activeStandard {
                SectionCard(title: "Now measuring", systemImage: "drop.fill") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(String(format: "%.3g NTU standard — %@, lot %@",
                                    standard.nominalNTU, standard.manufacturer,
                                    standard.lotNumber))
                            .font(.subheadline.weight(.semibold))
                        Text("Rinse and refill the container with this standard, reassemble the fixture exactly as before, then take a reading.")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
            }

            measurementControls

            if session.allStandardsComplete {
                PrimaryActionButton(title: "Fit the curve", systemImage: "function") {
                    session.fit()
                }
            }
        }
    }

    /// The camera lives inline here rather than on a pushed screen: a
    /// calibration is a sequence of readings, and navigating away and back
    /// between every one of them would be fifteen round trips.
    @ViewBuilder
    private var measurementControls: some View {
        if viewModel.state.usesCaptureHardware {
            CaptureStageView(viewModel: viewModel)
        }

        SectionCard(title: "Reading", systemImage: "camera") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                let presentation = MeasurementStatePresentation(state: viewModel.state)
                StatusChip(text: presentation.title,
                           systemImage: presentation.systemImage,
                           tint: presentation.tint)
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)

                if let reading = viewModel.reading {
                    MetricRow(title: "Last reading index",
                              value: reading.index.value
                                  .formatted(.number.precision(.fractionLength(2))),
                              detail: reading.validity.isValid
                                  ? "Passed the quality gates."
                                  : "Rejected: " + reading.validity.reasons
                                      .map(\.explanation).joined(separator: " "))

                    SecondaryActionButton(title: "Record this reading",
                                          systemImage: "tray.and.arrow.down.fill") {
                        message = session.recordCurrentReading()
                        if message == nil, session.activeStandardIsComplete {
                            session.advanceToNextStandard()
                        }
                    }
                }

                if !viewModel.state.usesCaptureHardware {
                    PrimaryActionButton(title: viewModel.reading == nil
                                        ? "Take a reading" : "Take another reading",
                                        systemImage: "camera.fill") {
                        Task { await viewModel.measureAgain() }
                    }
                }
            }
        }
    }

    // MARK: - Step 4: review

    @ViewBuilder
    private var reviewStep: some View {
        if let outcome = session.outcome, let candidate = outcome.candidate {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionCard(
                    title: "Fitted curve",
                    systemImage: "function",
                    footnote: "Chosen by leave-one-concentration-out cross validation. Every candidate reproduces the points it was fitted to; only held-out prediction says anything."
                ) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        MetricRow(title: "Curve", value: candidate.mapping.name)
                        MetricRow(title: "Cross-validated RMSE",
                                  value: String(format: "%.4f NTU",
                                                candidate.validation.rootMeanSquareErrorNTU))
                        MetricRow(title: "Worst held-out level",
                                  value: String(format: "%.4f NTU",
                                                candidate.validation.maximumAbsoluteErrorNTU))
                        MetricRow(title: "Bias",
                                  value: String(format: "%+.4f NTU",
                                                candidate.validation.biasNTU))
                        MetricRow(title: "Worst repeatability",
                                  value: candidate.validation.worstRelativeRepeatability
                                      .formatted(.percent.precision(.fractionLength(1))))
                        MetricRow(title: "Levels held out",
                                  value: "\(candidate.validation.heldOutLevels)")
                    }
                }

                if let uncertainty = outcome.uncertainty,
                   let range = outcome.validatedNTURange {
                    SectionCard(title: "Range and uncertainty", systemImage: "plusminus") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            MetricRow(title: "Validated range",
                                      value: String(format: "%.3g to %.3g NTU",
                                                    range.lowerBound, range.upperBound),
                                      detail: "Nothing outside this has been checked, and nothing outside it will be reported.")
                            MetricRow(title: "Model error",
                                      value: String(format: "%.4f NTU",
                                                    uncertainty.modelErrorNTU))
                            MetricRow(title: "Measurement spread",
                                      value: uncertainty.relativeMeasurementSpread
                                          .formatted(.percent.precision(.fractionLength(1))))
                            MetricRow(title: "Standards' own tolerance",
                                      value: String(format: "± %.3f NTU",
                                                    uncertainty.standardToleranceNTU))
                            MetricRow(title: "Coverage factor",
                                      value: "\(Int(uncertainty.coverageFactor))",
                                      detail: "Roughly a 95% interval, assuming these terms are the whole story. For a screening instrument they are not.")
                        }
                    }
                }

                if !outcome.rejectedCandidates.isEmpty {
                    SectionCard(title: "Curves that were not chosen",
                                systemImage: "arrow.uturn.down") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(outcome.rejectedCandidates, id: \.self) { reason in
                                Text("• \(reason)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                    }
                }

                saveCard
            }
        } else {
            SectionCard(title: "This data cannot become a calibration",
                        systemImage: "xmark.octagon.fill") {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(session.outcome?.problems ?? [], id: \.rawValue) { problem in
                        Text("• \(problem.explanation)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    SecondaryActionButton(title: "Back to the readings",
                                          systemImage: "arrow.left") {
                        session.beginCapture()
                    }
                }
            }
        }
    }

    private var saveCard: some View {
        SectionCard(title: "Save this calibration", systemImage: "square.and.arrow.down") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                labelledField("Name", text: $session.profileName,
                              prompt: "e.g. Shroud v2 with 20 mL vial")

                Stepper("Valid for \(session.validForMonths) months",
                        value: $session.validForMonths, in: 1...24)
                    .font(.subheadline)

                Text("Standards degrade, fixtures shift and phones age. A calibration with no end date is one nobody will ever re-check.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)

                PrimaryActionButton(title: "Save calibration",
                                    systemImage: "checkmark.circle.fill") {
                    Task { message = await session.save() }
                }
            }
        }
    }

    // MARK: - Step 5: saved

    @ViewBuilder
    private var savedStep: some View {
        if let profile = session.savedProfile {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionCard(title: "Calibration saved", systemImage: "checkmark.seal.fill") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(profile.name)
                            .font(.headline)
                        MetricRow(title: "Valid until",
                                  value: profile.expiresAt.formatted(date: .abbreviated,
                                                                     time: .omitted))
                        MetricRow(title: "Validated range",
                                  value: String(format: "%.3g to %.3g NTU",
                                                profile.validatedNTURange.lowerBound,
                                                profile.validatedNTURange.upperBound))
                        Text("Switch to Calibrated Fixture Mode on the main screen to use it. Lucid will still refuse to show NTU if anything about the setup has changed.")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }

                PrimaryActionButton(title: "Done", systemImage: "checkmark") {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Field helper

    private func labelledField(_ title: String,
                               text: Binding<String>,
                               prompt: String,
                               keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .frame(minHeight: Theme.Layout.minimumTouchTarget)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
