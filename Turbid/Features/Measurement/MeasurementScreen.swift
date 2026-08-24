import SwiftUI

/// The camera screen: the live preview with either the alignment step or the
/// running measurement beneath it.
///
/// One screen rather than two so the preview never moves. The sample is lined
/// up in exactly the frame the measurement then runs on.
struct MeasurementScreen: View {
    let viewModel: MeasurementViewModel
    @State private var showsDiagnostics = false

    var body: some View {
        ScrollView {
            CaptureStageView(viewModel: viewModel)
                .padding(Theme.Spacing.md)
        }
        .screenBackground()
        .navigationTitle(viewModel.state == .alignment ? "Set Up" : "Measuring")
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
}
