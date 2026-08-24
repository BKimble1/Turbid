import SwiftUI

/// Everything behind the headline: the numbers, the gates that judged them, and
/// the exact versions of everything that produced them.
///
/// Presented as a sheet with medium and large detents so it can be glanced at
/// and then opened fully. Nothing here is computed in the view — every value
/// comes from the reading, so what is on screen can always be traced back to a
/// documented calculation.
/// One labelled number in the Deep Dive.
///
/// These lists are longer than a view builder's ten-child limit, so they are
/// built as data and rendered with `ForEach` rather than written out as rows.
struct DeepDiveMetric: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let value: String
    var detail: String?
}

struct DeepDiveView: View {
    let reading: TurbidityReading
    let samples: [ScatteringSample]
    let isSimulated: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if isSimulated { SimulatedDataBanner() }
                    graph
                    indexBreakdown
                    scattering
                    tracking
                    captureQuality
                    calibrationSection
                    provenance
                    limitations
                }
                .padding(Theme.Spacing.md)
            }
            .screenBackground()
            .navigationTitle("Deep Dive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.DeepDive.close)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier(AccessibilityID.DeepDive.screen)
    }

    // MARK: - Sections

    private var graph: some View {
        SectionCard(title: "Index during the run", systemImage: "chart.xyaxis.line") {
            ScatteringChartView(samples: samples, finalNTU: reading.ntu, isLive: false)
        }
    }

    private var indexBreakdown: some View {
        let components = reading.index.components
        return SectionCard(
            title: "How the index was built",
            systemImage: "square.stack.3d.up",
            footnote: "Weights are an engineering starting point, not a validated model. They are versioned so a calibration can refuse a run made under different ones."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                MetricRow(title: "Bulk residual",
                          value: components.bulkContribution.formatted(.number.precision(.fractionLength(2))))
                MetricRow(title: "Upper-percentile excess",
                          value: components.excessContribution.formatted(.number.precision(.fractionLength(2))))
                MetricRow(title: "Active foreground",
                          value: components.activeContribution.formatted(.number.precision(.fractionLength(2))))
                MetricRow(title: "Tracked specks",
                          value: components.speckContribution.formatted(.number.precision(.fractionLength(2))),
                          detail: "Secondary by design: a camera cannot resolve the material that dominates real turbidity.")
                Divider().background(Theme.Palette.separator)
                MetricRow(title: "Total index",
                          value: reading.index.value.formatted(.number.precision(.fractionLength(2))))
            }
        }
    }

    private var scattering: some View {
        SectionCard(title: "Scattering windows", systemImage: "square.grid.3x3") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                MetricRow(title: "Sub-windows aggregated",
                          value: "\(reading.scattering.windowCount)")
                MetricRow(title: "Median positive residual",
                          value: reading.scattering.medianPositiveResidual
                              .formatted(.number.precision(.fractionLength(5))))
                MetricRow(title: "Median upper-percentile excess",
                          value: reading.scattering.medianUpperPercentileExcess
                              .formatted(.number.precision(.fractionLength(5))))
                MetricRow(title: "Median active foreground",
                          value: reading.scattering.medianActiveForegroundFraction
                              .formatted(.percent.precision(.fractionLength(3))))
                MetricRow(title: "Window-to-window spread",
                          value: reading.scattering.residualRelativeSpread
                              .formatted(.percent.precision(.fractionLength(1))))
                MetricRow(title: "Repeatability confidence",
                          value: reading.scattering.repeatabilityConfidence
                              .formatted(.percent.precision(.fractionLength(0))))
            }
        }
    }

    private var tracking: some View {
        SectionCard(
            title: "Visible particles (tracked)",
            systemImage: "dot.viewfinder",
            footnote: "Counts of bright events the camera could resolve and follow across frames. This is not a particle concentration and cannot be converted to one."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                MetricRow(title: "Confirmed tracks",
                          value: "\(reading.tracking.confirmedSpeckCount)")
                MetricRow(title: "Events per second",
                          value: reading.tracking.speckEventsPerSecond
                              .formatted(.number.precision(.fractionLength(2))))
                MetricRow(title: "Events per second per megapixel",
                          value: reading.tracking.speckEventsPerSecondPerMegapixel
                              .formatted(.number.precision(.fractionLength(1))))
                MetricRow(title: "Rejected as rising bubbles",
                          value: "\(reading.tracking.bubbleRejectionCount)")
                MetricRow(title: "Rejected as static defects",
                          value: "\(reading.tracking.staticDefectCount)")
                MetricRow(title: "Unclassified",
                          value: "\(reading.tracking.ambiguousCount)")
                MetricRow(title: "Phone motion compensated",
                          value: reading.tracking.globalMotionWasCompensated ? "Yes" : "No",
                          detail: String(format: "Estimated speed %.4f, confidence %.2f",
                                         reading.tracking.globalMotionSpeed,
                                         reading.tracking.globalMotionConfidence))
                if reading.tracking.tracksDroppedForCapacity > 0 {
                    MetricRow(title: "Dropped for capacity",
                              value: "\(reading.tracking.tracksDroppedForCapacity)",
                              detail: "Every count above is a lower bound.")
                }
            }
        }
    }

    private var captureQuality: some View {
        let quality = reading.quality
        return SectionCard(title: "Capture quality", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                StatusChip(text: verdictTitle,
                           systemImage: quality.isUsable ? "checkmark.circle.fill" : "xmark.octagon.fill",
                           tint: quality.isUsable ? Theme.Palette.positive : Theme.Palette.critical)

                ForEach(quality.verdict.reasons, id: \.rawValue) { reason in
                    BulletRow(systemImage: "exclamationmark.circle.fill",
                              text: reason.explanation,
                              tint: Theme.Palette.warning)
                }

                ForEach(captureQualityMetrics) { metric in
                    MetricRow(title: metric.title, value: metric.value, detail: metric.detail)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.DeepDive.qualitySection)
    }

    /// Built as data rather than as a stack of rows: a view builder takes at
    /// most ten children, and this list is longer than that and will grow.
    private var captureQualityMetrics: [DeepDiveMetric] {
        let quality = reading.quality
        var metrics: [DeepDiveMetric] = [
            DeepDiveMetric(title: "Usable frames",
                           value: "\(quality.usableFrames) of \(quality.evaluatedFrames)"),
            DeepDiveMetric(title: "Dropped frames",
                           value: quality.droppedFrameRatio
                               .formatted(.percent.precision(.fractionLength(1)))),
            DeepDiveMetric(title: "Frame delivery continuous",
                           value: quality.frameDeliveryIsContinuous ? "Yes" : "No"),
            DeepDiveMetric(title: "Mean level",
                           value: Double(quality.meanLuma)
                               .formatted(.number.precision(.fractionLength(3)))),
            DeepDiveMetric(title: "Saturated pixels",
                           value: quality.saturatedFraction
                               .formatted(.percent.precision(.fractionLength(3)))),
            DeepDiveMetric(title: "Brightest tile share",
                           value: quality.brightestTileShare
                               .formatted(.percent.precision(.fractionLength(1)))),
            DeepDiveMetric(title: "Sharpness",
                           value: quality.sharpness
                               .formatted(.number.precision(.fractionLength(5)))),
            DeepDiveMetric(title: "Exposure stability",
                           value: quality.exposureStability
                               .formatted(.number.precision(.fractionLength(3)))),
            DeepDiveMetric(title: "Controls stayed locked",
                           value: quality.controlsRemainedLocked ? "Yes" : "No")
        ]

        if let stability = quality.backgroundStability {
            metrics.append(DeepDiveMetric(
                title: "Background settled",
                value: stability.formatted(.percent.precision(.fractionLength(1))),
                detail: "How much of the view held still while the background model was built. Reported, not gated on: suspended material moving through the frame lowers it just as a shifting container does."
            ))
        }

        metrics.append(DeepDiveMetric(title: "Thermal state",
                                      value: quality.thermal.displayName))
        metrics.append(DeepDiveMetric(title: "System pressure",
                                      value: quality.systemPressure.rawValue))
        return metrics
    }

    private var verdictTitle: String {
        switch reading.quality.verdict {
        case .usable: return "Usable"
        case .usableWithLowConfidence: return "Usable, low confidence"
        case .invalid: return "Not usable"
        }
    }

    @ViewBuilder
    private var calibrationSection: some View {
        SectionCard(title: "Calibration", systemImage: "ruler") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                MetricRow(title: "NTU", value: reading.ntu.displayText)
                Text(reading.ntu.explanation)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)

                if case .available(_, let uncertainty, let range) = reading.ntu {
                    MetricRow(title: "Expanded uncertainty",
                              value: String(format: "± %.2f NTU", uncertainty),
                              detail: "Coverage factor 2, from cross-validation error, replicate spread and the standards' own certificate tolerance.")
                    MetricRow(title: "Validated range",
                              value: String(format: "%.3g to %.3g NTU",
                                            range.lowerBound, range.upperBound))
                }

                if let identifier = reading.calibrationProfileID {
                    MetricRow(title: "Profile", value: identifier.uuidString)
                }
            }
        }
    }

    private var provenance: some View {
        let versions = reading.algorithmVersions
        return SectionCard(
            title: "Provenance",
            systemImage: "signature",
            footnote: "Recorded so any result can be reproduced, and so a calibration can refuse a run made by different code."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(provenanceMetrics(versions)) { metric in
                    MetricRow(title: metric.title, value: metric.value)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.DeepDive.provenanceSection)
    }

    /// Also data rather than rows, and for the same reason: there are thirteen
    /// of them and a view builder takes ten.
    private func provenanceMetrics(
        _ versions: CalibrationBinding.AlgorithmVersions
    ) -> [DeepDiveMetric] {
        [
            DeepDiveMetric(title: "Measured at",
                           value: reading.timestamp.formatted(date: .abbreviated,
                                                              time: .standard)),
            DeepDiveMetric(title: "Window length",
                           value: String(format: "%.1f s",
                                         reading.measurementWindowSeconds)),
            DeepDiveMetric(title: "Capture protocol", value: "v\(versions.captureProtocol)"),
            DeepDiveMetric(title: "Quality thresholds", value: "v\(versions.qualityThresholds)"),
            DeepDiveMetric(title: "Detector", value: "v\(versions.detector)"),
            DeepDiveMetric(title: "Band-pass", value: "v\(versions.bandPass)"),
            DeepDiveMetric(title: "Background model", value: "v\(versions.backgroundModel)"),
            DeepDiveMetric(title: "Tracker", value: "v\(versions.tracker)"),
            DeepDiveMetric(title: "Classifier", value: "v\(versions.classifier)"),
            DeepDiveMetric(title: "Aggregation", value: "v\(versions.aggregation)"),
            DeepDiveMetric(title: "Index weights", value: "v\(versions.indexWeights)"),
            DeepDiveMetric(title: "Clarity bands", value: "v\(reading.clarityPolicyVersion)"),
            DeepDiveMetric(title: "Analysis region",
                           value: "v\(reading.quality.analysisRegionVersion)")
        ]
    }

    private var limitations: some View {
        SectionCard(title: "Known limitations", systemImage: "exclamationmark.shield") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(MeasurementDisclaimer.limitations, id: \.self) { limitation in
                    BulletRow(systemImage: "minus.circle",
                              text: limitation,
                              tint: Theme.Palette.secondaryText)
                }
                Text(MeasurementDisclaimer.long)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }
}
