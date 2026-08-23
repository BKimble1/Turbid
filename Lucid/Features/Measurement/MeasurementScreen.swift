import SwiftUI

/// The alignment and measurement screen: live preview, capture status, and the
/// controls that start or cancel a run.
struct MeasurementScreen: View {
    let viewModel: MeasurementViewModel
    @State private var showsDiagnostics = false

    /// The analysis region sits inside the liquid volume, away from the
    /// container edges, the meniscus and the direct torch hotspot. Phase 3A
    /// replaces this constant with the calibrated region and optical mask.
    private static let regionOfInterest = CGRect(x: 0.25, y: 0.28, width: 0.5, height: 0.44)

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            preview
            status
            frameSummary
            controls
        }
        .padding(Theme.Spacing.md)
        .navigationTitle("Measurement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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

    private var preview: some View {
        CameraPreviewView(session: viewModel.camera.previewSession,
                          regionOfInterest: Self.regionOfInterest)
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(alignment: .topLeading) {
                if viewModel.capture.torch.isActive {
                    StatusChip(text: "Torch on",
                               systemImage: "flashlight.on.fill",
                               tint: Theme.Palette.warning)
                        .padding(Theme.Spacing.sm)
                }
            }
    }

    private var status: some View {
        let presentation = MeasurementStatePresentation(state: viewModel.state)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            StatusChip(text: presentation.title,
                       systemImage: presentation.systemImage,
                       tint: presentation.tint)
            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var frameSummary: some View {
        let timing = viewModel.capture.timing
        if timing.deliveredFrames > 0 {
            HStack(spacing: Theme.Spacing.lg) {
                metric("Frame rate", String(format: "%.0f fps", timing.measuredFrameRate))
                metric("Dropped", "\(timing.droppedFrames)")
                metric("Thermal", viewModel.capture.thermal.displayName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.Palette.secondaryText)
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if viewModel.state == .alignment {
                PrimaryActionButton(title: "Start Measurement",
                                    systemImage: "play.fill") {
                    Task { await viewModel.beginMeasurement() }
                }
            }

            Button(role: .cancel) {
                Task { await viewModel.cancel() }
            } label: {
                Label("Stop and turn the torch off", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: Theme.Layout.minimumTouchTarget)
            }
            .buttonStyle(.bordered)

            DisclaimerFootnote()
        }
    }
}
