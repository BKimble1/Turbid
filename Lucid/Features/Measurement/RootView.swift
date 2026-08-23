import SwiftUI

/// Phase 1 scaffold screen: explains the app, resolves camera permission, and
/// exposes the defined lifecycle hook. It contains no measurement, no NTU and no
/// analysis of any kind.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: MeasurementViewModel

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
        }
        .task {
            await viewModel.refreshAuthorization()
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
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

                CameraPreviewView(regionOfInterest: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .overlay(alignment: .bottom) {
                        Text("Live preview is added in Phase 2")
                            .font(.caption)
                            .padding(Theme.Spacing.xs)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(Theme.Spacing.sm)
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
        settingsOpener: StubSettingsOpener(),
        allowsSimulatedData: true
    ))
}

#Preview("Denied") {
    RootView(environment: AppEnvironment(
        cameraAuthorization: StubCameraAuthorizationService(initialStatus: .denied),
        settingsOpener: StubSettingsOpener(),
        allowsSimulatedData: true
    ))
}
