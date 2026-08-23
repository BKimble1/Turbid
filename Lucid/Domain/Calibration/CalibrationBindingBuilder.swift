import Foundation

/// What the fixture and container are, for a run.
///
/// Screening Mode has no fixture, and says so rather than inventing an
/// identifier: a calibration made against `none` would match any loose setup,
/// which is exactly the thing the binding exists to prevent.
struct FixtureDescription: Equatable, Sendable, Codable {
    let fixtureIdentifier: String
    let fixtureGeometryVersion: Int
    let containerIdentifier: String
    let fillVolumeMillilitres: Double
    let workingDistanceMillimetres: Double

    /// Phone-only use: no fixture, no known container, no fixed distance.
    static let none = FixtureDescription(
        fixtureIdentifier: "none",
        fixtureGeometryVersion: 0,
        containerIdentifier: "unspecified",
        fillVolumeMillilitres: 0,
        workingDistanceMillimetres: 0
    )

    var isCalibratable: Bool { fixtureIdentifier != FixtureDescription.none.fixtureIdentifier }
}

/// Builds the fingerprint of the instrument as it is right now.
///
/// Every version here has to be read from the configuration that actually ran,
/// not written as a literal, or a changed algorithm would silently keep
/// matching an old calibration.
enum CalibrationBindingBuilder {

    static func algorithmVersions(
        captureProtocol: CaptureProtocol = .screening,
        thresholds: QualityThresholds = .screening,
        detector: SpeckDetector.Configuration = .screening,
        tracker: MultiObjectTracker.Configuration = .screening,
        classifier: TrackClassifier.Configuration = .screening,
        aggregation: ScatteringWindowAggregator.Configuration = .screening,
        weights: RelativeScatteringIndex.Weights = .screening
    ) -> CalibrationBinding.AlgorithmVersions {
        CalibrationBinding.AlgorithmVersions(
            captureProtocol: captureProtocol.version,
            qualityThresholds: thresholds.version,
            detector: detector.version,
            bandPass: detector.bandPass.version,
            backgroundModel: detector.background.version,
            tracker: tracker.version,
            classifier: classifier.version,
            aggregation: aggregation.version,
            indexWeights: weights.version
        )
    }

    /// - Returns: `nil` when the camera has not been selected or the controls
    ///   have not been locked, because a fingerprint missing either of those
    ///   describes nothing.
    static func make(selection: CameraSelectionSummary?,
                     locked: LockedCameraControls?,
                     torchLevel: Float,
                     region: AnalysisRegion,
                     fixture: FixtureDescription,
                     deviceModelIdentifier: String,
                     algorithmVersions: CalibrationBinding.AlgorithmVersions)
    -> CalibrationBinding? {
        guard let selection, let locked else { return nil }

        let dimensions = selection.resolution.split(separator: "x").compactMap { Int($0) }
        guard dimensions.count == 2 else { return nil }

        return CalibrationBinding(
            algorithmVersion: algorithmVersions,
            deviceModelIdentifier: deviceModelIdentifier,
            cameraUniqueID: selection.uniqueID,
            cameraDeviceType: selection.deviceType,
            captureWidth: dimensions[0],
            captureHeight: dimensions[1],
            pixelFormat: selection.pixelFormat,
            frameRate: selection.frameRate,
            lensPosition: locked.lensPosition,
            exposureSeconds: locked.exposureSeconds,
            iso: locked.iso,
            whiteBalanceGains: locked.whiteBalanceGains,
            torchLevel: torchLevel,
            analysisRegion: region,
            fixtureIdentifier: fixture.fixtureIdentifier,
            fixtureGeometryVersion: fixture.fixtureGeometryVersion,
            containerIdentifier: fixture.containerIdentifier,
            fillVolumeMillilitres: fixture.fillVolumeMillilitres,
            workingDistanceMillimetres: fixture.workingDistanceMillimetres
        )
    }

    /// The hardware string, e.g. `iPhone16,1`.
    ///
    /// Read from the kernel rather than from a marketing name, because that is
    /// what identifies the optics.
    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
