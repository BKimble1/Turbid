import SwiftUI

/// The home screen: explains what Lucid does, resolves camera permission, and
/// starts the capture session. It shows no result, no NTU and no analysis; the
/// measurement itself lives on `MeasurementScreen`.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: MeasurementViewModel
    @State private var showsDiagnostics = false

    @MainActor
    init(environment: AppEnvironment) {
        _viewModel = State(initialValue: MeasurementViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    header
                    whatLucidDoes
                    permissionCard
                    sessionCard

                    if viewModel.allowsSimulatedData {
                        DemoShowcaseView()
                    }

                    DisclaimerFootnote()
                        .padding(.top, Theme.Spacing.sm)
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle("Lucid")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: showsMeasurementScreen) {
                MeasurementScreen(viewModel: viewModel)
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
        .task {
            await viewModel.refreshAuthorization()
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { await viewModel.handleScenePhaseChange(newPhase) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Lucid")
                .font(.largeTitle.weight(.bold))
            Text("Optical clarity screening for water samples")
                .font(.title3)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var whatLucidDoes: some View {
        SectionCard(title: "What Lucid does", systemImage: "light.beam.max") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Lucid uses the iPhone camera and torch to observe how much light a water sample scatters, then reports one of three optical-clarity states.")
                    .font(.subheadline)

                Text(MeasurementDisclaimer.long)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)

                Divider()

                ForEach(MeasurementMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                        Text(mode.summary)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                }
            }
        }
    }

    private var sessionCard: some View {
        let presentation = MeasurementStatePresentation(state: viewModel.state)

        return SectionCard(title: "Session", systemImage: "gauge.with.dots.needle.33percent") {
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
                    Task { await viewModel.startSetup() }
                }
            }
        }
    }

    /// The measurement screen owns the camera, so it is presented exactly for
    /// the states that hold hardware and dismissed the moment they end.
    private var showsMeasurementScreen: Binding<Bool> {
        Binding(
            get: { viewModel.state.usesCaptureHardware },
            set: { isPresented in
                // Only a user-driven dismissal cancels. When the session ends
                // on its own the state has already left `usesCaptureHardware`,
                // and cancelling here would wipe the result before it is shown.
                guard !isPresented, viewModel.state.usesCaptureHardware else { return }
                Task { await viewModel.cancel() }
            }
        )
    }

    private var startButtonTitle: String {
        switch viewModel.state {
        case .idle:
            return "Start Setup"
        case .permissionDenied, .permissionRestricted:
            return "Check Camera Access Again"
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
