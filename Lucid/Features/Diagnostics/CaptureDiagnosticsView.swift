import SwiftUI

/// The debug control panel required for physical-device verification.
///
/// Every value shown here is read from the live `CaptureSnapshot`; none of it
/// is synthesised. It exists so the camera, torch and control locks can be
/// checked on real hardware before any analysis is built on top of them.
struct CaptureDiagnosticsView: View {
    let snapshot: CaptureSnapshot
    let onSetTorch: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                cameraSection
                torchSection
                controlsSection
                frameSection
                healthSection
                if let selection = snapshot.selection, !selection.rejectedCameras.isEmpty {
                    rejectedSection(selection.rejectedCameras)
                }
            }
            .navigationTitle("Capture Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            row("Run state", describe(snapshot.runState))
            if let interruption = snapshot.interruption {
                row("Interruption", interruption.reasonDescription)
                row("Interruption active", interruption.isActive ? "yes" : "no")
            } else {
                row("Interruption", "none")
            }
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        if let selection = snapshot.selection {
            Section("Selected camera") {
                row("Name", selection.cameraName)
                row("Device type", selection.deviceType)
                row("Unique ID", selection.uniqueID)
                row("Virtual device", selection.isVirtualDevice ? "yes" : "no")
                row("Minimum focus distance", selection.minimumFocusDistanceText)
                row("Format", selection.resolution)
                row("Pixel format", selection.pixelFormat)
                row("Frame rate", String(format: "%.0f fps", selection.frameRate))

                DisclosureGroup("Why this camera") {
                    ForEach(Array(selection.rationale.enumerated()), id: \.offset) { _, reason in
                        Text(reason).font(.caption)
                    }
                }
                if !selection.warnings.isEmpty {
                    DisclosureGroup("Warnings") {
                        ForEach(Array(selection.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.warning)
                        }
                    }
                }
            }
        } else {
            Section("Selected camera") {
                Text("The capture session has not been prepared yet.")
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    private var torchSection: some View {
        Section("Torch") {
            row("Available", snapshot.torch.isAvailable ? "yes" : "no")
            row("Active", snapshot.torch.isActive ? "yes" : "no")
            row("Level", String(format: "%.3f", snapshot.torch.level))
            row("Requested level", String(format: "%.3f", snapshot.torch.requestedLevel))
            if snapshot.torch.isActive && !snapshot.torch.deliveredRequestedLevel {
                Text("The device is delivering less than the requested maximum, usually because it is warm. A calibration made at a different level is not valid here.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }
            HStack {
                Button("Torch on") { onSetTorch(true) }
                    .buttonStyle(.bordered)
                Button("Torch off") { onSetTorch(false) }
                    .buttonStyle(.bordered)
            }
            .frame(minHeight: Theme.Layout.minimumTouchTarget)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section("Control lock (last recorded)") {
            if let locked = snapshot.lockedControls {
                row("Focus mode", locked.focusModeDescription)
                row("Lens position", String(format: "%.4f", locked.lensPosition))
                row("Exposure mode", locked.exposureModeDescription)
                row("Exposure", String(format: "%.5f s (1/%.0f)",
                                       locked.exposureSeconds,
                                       locked.exposureSeconds > 0 ? 1 / locked.exposureSeconds : 0))
                row("ISO", String(format: "%.1f", locked.iso))
                row("White balance mode", locked.whiteBalanceModeDescription)
                row("WB gains (R/G/B)", String(format: "%.3f / %.3f / %.3f",
                                               locked.whiteBalanceGains.red,
                                               locked.whiteBalanceGains.green,
                                               locked.whiteBalanceGains.blue))
                if !locked.clampNotes.isEmpty {
                    DisclosureGroup("Clamped values") {
                        ForEach(Array(locked.clampNotes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.caption)
                        }
                    }
                }
            } else {
                Text("Controls have not been locked in this session.")
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    private var frameSection: some View {
        Section("Frames") {
            row("Delivered", "\(snapshot.timing.deliveredFrames)")
            row("Dropped", "\(snapshot.timing.droppedFrames)")
            row("Drop ratio", String(format: "%.2f%%", snapshot.timing.dropRatio * 100))
            row("Measured rate", String(format: "%.1f fps", snapshot.timing.measuredFrameRate))
            row("Median interval", String(format: "%.1f ms", snapshot.timing.medianIntervalSeconds * 1000))
            row("Longest gap", String(format: "%.1f ms", snapshot.timing.maximumIntervalSeconds * 1000))
            row("Continuous", snapshot.timing.isContinuous() ? "yes" : "no")
            row("Span", String(format: "%.1f s", snapshot.timing.spanSeconds))
        }
    }

    private var healthSection: some View {
        Section("Device health") {
            row("Thermal state", snapshot.thermal.displayName)
            row("System pressure", snapshot.systemPressure.rawValue)
            row("Hardware permits measurement",
                snapshot.hardwarePermitsMeasurement ? "yes" : "no")
        }
    }

    private func rejectedSection(_ rejections: [CameraRejection]) -> some View {
        Section("Cameras not used") {
            ForEach(Array(rejections.enumerated()), id: \.offset) { _, rejection in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rejection.cameraName).font(.subheadline)
                    Text(rejection.reason)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
        }
    }

    private func describe(_ state: CaptureRunState) -> String {
        switch state {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .prepared: return "prepared"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .failed(let error): return "failed — \(error.message)"
        }
    }
}

#Preview {
    CaptureDiagnosticsView(snapshot: .idle, onSetTorch: { _ in })
}
