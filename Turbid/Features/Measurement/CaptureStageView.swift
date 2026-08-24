import SwiftUI

/// The live preview and whichever step of the run is current.
///
/// Shared by the measurement screen and the calibration workflow so both drive
/// the camera through exactly the same interface. A calibration taken through a
/// different capture screen would be calibrating that screen.
struct CaptureStageView: View {
    let viewModel: MeasurementViewModel

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            preview

            if viewModel.allowsSimulatedData {
                SimulatedDataBanner()
                simulatedSamplePicker
            }

            switch viewModel.state {
            case .alignment:
                SetupWizardView(
                    alignment: viewModel.alignment,
                    mode: viewModel.mode,
                    profile: viewModel.activeProfile,
                    mismatches: viewModel.calibrationMismatches,
                    torchIsOn: viewModel.capture.torch.isActive,
                    onBegin: { Task { await viewModel.beginMeasurement() } },
                    onCancel: { Task { await viewModel.cancel() } }
                )
            default:
                MeasurementProgressView(
                    state: viewModel.state,
                    progress: viewModel.progress,
                    samples: viewModel.chartSamples,
                    onCancel: { Task { await viewModel.cancel() } }
                )
            }
        }
    }

    private var preview: some View {
        CameraPreviewView(session: viewModel.camera.previewSession,
                          regionOfInterest: viewModel.analysisRegion.normalizedRect)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Layout.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(alignment: .topLeading) {
                if viewModel.capture.torch.isActive {
                    StatusChip(text: "Torch on",
                               systemImage: "flashlight.on.fill",
                               tint: Theme.Palette.warning)
                        .padding(Theme.Spacing.sm)
                }
            }
            .accessibilityLabel("Live camera preview with the analysis region outlined")
    }

    /// Simulator only: chooses which synthetic sample the fake camera is
    /// pointed at, so every result state can be reached without hardware.
    private var simulatedSamplePicker: some View {
        SectionCard(title: "Simulated sample", systemImage: "theatermasks.fill") {
            Picker("Simulated sample", selection: Binding(
                get: { viewModel.simulatedSample },
                set: { viewModel.selectSimulatedSample($0) }
            )) {
                ForEach(SimulatedSample.allCases) { sample in
                    Text(sample.title).tag(sample)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
