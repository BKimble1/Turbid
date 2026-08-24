import SwiftUI

/// The home screen: what Turbid does, camera permission, the measurement mode,
/// and the way in to a run, a calibration or the last result.
///
/// It shows no measurement of its own. Everything numeric lives on the result
/// screens, which carry the disclaimer with them.
struct RootView: View {

    /// Where the navigation stack can be.
    private enum Route: Hashable {
        case capture
        case result
        case calibration
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: MeasurementViewModel
    @State private var path: [Route] = []
    @State private var showsDiagnostics = false
    @State private var showsOnboarding: Bool

    @MainActor
    init(environment: AppEnvironment) {
        let model = MeasurementViewModel(environment: environment)
        _viewModel = State(initialValue: model)
        _showsOnboarding = State(initialValue: !model.hasAcknowledgedDisclosure)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    header
                    whatTurbidDoes
                    permissionCard
                    modeCard
                    sessionCard
                    lastResultCard

                    if viewModel.allowsSimulatedData {
                        DemoShowcaseView()
                    }

                    DisclaimerFootnote()
                        .padding(.top, Theme.Spacing.sm)
                }
                .padding(Theme.Spacing.md)
            }
            .screenBackground()
            .navigationTitle("Turbid")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.Root.screen)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .capture:
                    MeasurementScreen(viewModel: viewModel)
                case .result:
                    resultScreen
                case .calibration:
                    CalibrationView(viewModel: viewModel)
                }
            }
            .toolbar {
                // Also here, not only on the measurement screen: that screen is
                // popped as soon as the session ends, and the diagnostics have
                // to be readable *after* a run.
                if RuntimeEnvironment.isDebugBuild {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsDiagnostics = true
                        } label: {
                            Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                        }
                    }
                }
            }
            .sheet(isPresented: $showsDiagnostics) {
                CaptureDiagnosticsView(snapshot: viewModel.capture) { on in
                    Task { try? await viewModel.camera.setTorch(on: on) }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView {
                viewModel.acknowledgeDisclosure()
                showsOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .task {
            await viewModel.refreshAuthorization()
            await viewModel.loadCalibrations()
        }
        .onChange(of: viewModel.state) { _, newState in
            updateRoute(for: newState)
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { await viewModel.handleScenePhaseChange(newPhase) }
        }
    }

    // MARK: - Routing

    /// The stack follows the session rather than the other way round: the
    /// camera screen exists exactly while the session holds hardware, and the
    /// result screen exactly while there is a result to show.
    private func updateRoute(for state: MeasurementState) {
        // The calibration workflow owns the camera and its own navigation.
        guard !viewModel.isCalibrating, !path.contains(.calibration) else { return }

        if state.usesCaptureHardware {
            if path != [.capture] { path = [.capture] }
            return
        }

        if viewModel.reading != nil, state.presentsAResult {
            if path != [.result] { path = [.result] }
        } else if !path.isEmpty {
            path = []
        }
    }

    @ViewBuilder
    private var resultScreen: some View {
        if let reading = viewModel.reading {
            QuickViewResultView(
                reading: reading,
                samples: viewModel.chartSamples,
                isSimulated: viewModel.allowsSimulatedData,
                onMeasureAgain: { Task { await viewModel.measureAgain() } },
                onDone: { path = [] }
            )
        } else {
            EmptyStateView(systemImage: "questionmark.circle",
                           title: "No result",
                           message: "This measurement did not produce a reading.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
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

    private var whatTurbidDoes: some View {
        SectionCard(title: "What Turbid does", systemImage: "flashlight.on.fill") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Turbid uses the iPhone camera and torch to observe how much light a water sample scatters, then reports one of three optical-clarity states.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.primaryText)

                Text(MeasurementDisclaimer.long)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)

                Button("Read what Turbid can and cannot tell you") {
                    showsOnboarding = true
                }
                .font(.subheadline)
                .frame(minHeight: Theme.Layout.minimumTouchTarget)
            }
        }
    }

    private var permissionCard: some View {
        SectionCard(title: "Camera access", systemImage: "camera") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                StatusChip(
                    text: viewModel.authorization.presentationTitle,
                    systemImage: viewModel.authorization.presentationSymbol,
                    tint: viewModel.authorization.presentationTint
                )
                .accessibilityIdentifier(AccessibilityID.Root.permissionStatus)

                if let guidance = viewModel.authorization.guidance {
                    Text(guidance)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                if viewModel.authorization.settingsLinkIsLikelyEffective {
                    Button {
                        viewModel.openSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                            .frame(minHeight: Theme.Layout.minimumTouchTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.Root.openSettings)
                }
            }
        }
    }

    private var modeCard: some View {
        SectionCard(
            title: "Measurement mode",
            systemImage: "slider.horizontal.3",
            footnote: viewModel.mode.summary
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Picker("Measurement mode", selection: Binding(
                    get: { viewModel.mode },
                    set: { viewModel.setMode($0) }
                )) {
                    Text("Screening").tag(MeasurementMode.screening)
                    Text("Calibrated").tag(MeasurementMode.calibratedFixture)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.Root.modePicker)

                if viewModel.mode.permitsNumericNTU {
                    if let profile = viewModel.calibrations.selectedProfile {
                        MetricRow(title: "Calibration in use", value: profile.name,
                                  detail: "Valid until \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Label("No calibration is selected, so no NTU value will be shown.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.warning)
                    }
                    ForEach(viewModel.calibrations.expiringSoon()) { profile in
                        Label("\(profile.name) expires \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted)). Plan a re-run.",
                              systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.warning)
                    }
                }

                Button {
                    path = [.calibration]
                } label: {
                    Label("Calibration", systemImage: "ruler")
                        .frame(minHeight: Theme.Layout.minimumTouchTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.Root.calibrationLink)
            }
        }
    }

    private var sessionCard: some View {
        let presentation = MeasurementStatePresentation(state: viewModel.state)

        return SectionCard(title: "Session",
                           systemImage: "gauge.with.dots.needle.33percent") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                StatusChip(
                    text: presentation.title,
                    systemImage: presentation.systemImage,
                    tint: presentation.tint
                )

                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let selection = viewModel.capture.selection {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Camera: \(selection.cameraName)")
                            .font(.caption.weight(.medium))
                        Text("\(selection.resolution) · \(selection.pixelFormat) · \(String(format: "%.0f", selection.frameRate)) fps · focuses at \(selection.minimumFocusDistanceText)")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                PrimaryActionButton(
                    title: startButtonTitle,
                    systemImage: "camera.viewfinder",
                    isEnabled: viewModel.state.isRestartable
                ) {
                    Task { await viewModel.measureAgain() }
                }
                .accessibilityIdentifier(AccessibilityID.Root.start)
            }
        }
    }

    @ViewBuilder
    private var lastResultCard: some View {
        if let reading = viewModel.reading {
            SectionCard(title: "Last result", systemImage: "clock.arrow.circlepath") {
                Button {
                    path = [.result]
                } label: {
                    HStack {
                        Image(systemName: reading.clarity.clarity.symbolName)
                            .foregroundStyle(Theme.Palette.clarity(reading.clarity.clarity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reading.clarity.clarity.headline)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text(reading.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer(minLength: Theme.Spacing.sm)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    .frame(minHeight: Theme.Layout.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Root.lastResult)
            }
        }
    }

    private var startButtonTitle: String {
        switch viewModel.state {
        case .idle:
            return "Start Setup"
        case .permissionDenied, .permissionRestricted:
            return "Check Camera Access Again"
        case .result, .lowQuality:
            return "Measure Again"
        default:
            return "Restart Setup"
        }
    }
}

#Preview("Undecided") {
    RootView(environment: AppEnvironment(
        cameraAuthorization: StubCameraAuthorizationService(initialStatus: .notDetermined,
                                                            statusAfterRequest: .authorized),
        camera: StubCameraService(),
        settingsOpener: StubSettingsOpener(),
        allowsSimulatedData: true
    ))
}

#Preview("Denied") {
    RootView(environment: AppEnvironment(
        cameraAuthorization: StubCameraAuthorizationService(initialStatus: .denied),
        camera: StubCameraService(),
        settingsOpener: StubSettingsOpener(),
        allowsSimulatedData: true
    ))
}
