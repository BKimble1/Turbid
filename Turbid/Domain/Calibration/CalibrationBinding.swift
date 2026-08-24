import Foundation

/// Everything a calibration is tied to.
///
/// A calibration curve is not a property of the app. It is a property of one
/// iPhone, one physical camera, one capture format, one set of locked exposure
/// controls, one torch level, one region of interest, one fixture, one
/// container, one working distance, and one version of every algorithm between
/// the sensor and the index. Change any of those and the curve describes an
/// instrument that no longer exists.
///
/// This type is the fingerprint of that instrument, recorded when the
/// calibration is made and checked before every measurement that would use it.
struct CalibrationBinding: Equatable, Sendable, Codable {

    // Software
    let algorithmVersion: AlgorithmVersions

    // Hardware
    let deviceModelIdentifier: String
    let cameraUniqueID: String
    let cameraDeviceType: String

    // Capture format
    let captureWidth: Int
    let captureHeight: Int
    let pixelFormat: String
    let frameRate: Double

    // Locked controls
    let lensPosition: Float
    let exposureSeconds: Double
    let iso: Float
    let whiteBalanceGains: WhiteBalanceGains
    let torchLevel: Float

    // Optics and geometry
    let analysisRegion: AnalysisRegion
    let fixtureIdentifier: String
    let fixtureGeometryVersion: Int
    let containerIdentifier: String
    let fillVolumeMillilitres: Double
    let workingDistanceMillimetres: Double

    /// Every versioned algorithm between the sensor and the index.
    ///
    /// Bundled rather than listed loose so that adding a new stage forces a
    /// decision about whether existing calibrations survive it.
    struct AlgorithmVersions: Equatable, Sendable, Codable {
        let captureProtocol: Int
        let qualityThresholds: Int
        let detector: Int
        let bandPass: Int
        let backgroundModel: Int
        let tracker: Int
        let classifier: Int
        let aggregation: Int
        let indexWeights: Int
    }
}

/// How closely a live capture must match the calibrated one.
///
/// Continuous quantities need tolerances: focus, exposure and white balance are
/// locked to whatever the camera settled on, and asking two runs to land on
/// bit-identical floats would fail every time. Discrete identities — the
/// camera, the format, the fixture, every algorithm version — must match
/// exactly, because a difference in any of them means a different instrument
/// rather than a slightly different one.
struct CalibrationTolerances: Equatable, Sendable, Codable {
    var lensPosition: Float
    /// Relative, because exposure spans orders of magnitude.
    var relativeExposure: Double
    var relativeISO: Double
    var whiteBalanceGain: Float
    var torchLevel: Float
    var relativeWorkingDistance: Double
    var version: Int

    /// Starting points. Tight enough that a genuinely different setup is
    /// caught, loose enough that the same setup twice is not rejected. Not
    /// validated against repeat set-ups on real hardware, which is the only
    /// thing that could settle them.
    static let screening = CalibrationTolerances(
        lensPosition: 0.02,
        relativeExposure: 0.05,
        relativeISO: 0.05,
        whiteBalanceGain: 0.05,
        // The torch is requested at the maximum available, which drops under
        // thermal load. A calibration made at full output does not describe a
        // measurement made at reduced output.
        torchLevel: 0.02,
        relativeWorkingDistance: 0.05,
        version: 1
    )
}

/// Compares a live binding against a calibrated one.
enum CalibrationCompatibility {

    /// - Returns: the reasons the two do not match, in a form a person can act
    ///   on. Empty means compatible.
    static func mismatches(live: CalibrationBinding,
                           calibrated: CalibrationBinding,
                           tolerances: CalibrationTolerances = .screening) -> [String] {
        var reasons: [String] = []

        func requireEqual<T: Equatable>(_ live: T, _ calibrated: T, _ label: String) {
            if live != calibrated {
                reasons.append("\(label) differs (now \(live), calibrated \(calibrated))")
            }
        }

        func requireClose(_ live: Double, _ calibrated: Double,
                          relative: Double, _ label: String) {
            let allowed = abs(calibrated) * relative
            if abs(live - calibrated) > max(allowed, 1e-9) {
                reasons.append(String(format: "%@ differs (now %.5f, calibrated %.5f)",
                                      label, live, calibrated))
            }
        }

        func requireWithin(_ live: Float, _ calibrated: Float,
                           absolute: Float, _ label: String) {
            if abs(live - calibrated) > absolute {
                reasons.append(String(format: "%@ differs (now %.4f, calibrated %.4f)",
                                      label, live, calibrated))
            }
        }

        // --- Identity: exact ---------------------------------------------
        requireEqual(live.algorithmVersion, calibrated.algorithmVersion, "analysis version")
        requireEqual(live.deviceModelIdentifier, calibrated.deviceModelIdentifier, "iPhone model")
        requireEqual(live.cameraUniqueID, calibrated.cameraUniqueID, "camera")
        requireEqual(live.cameraDeviceType, calibrated.cameraDeviceType, "camera type")
        requireEqual(live.captureWidth, calibrated.captureWidth, "capture width")
        requireEqual(live.captureHeight, calibrated.captureHeight, "capture height")
        requireEqual(live.pixelFormat, calibrated.pixelFormat, "pixel format")
        requireEqual(live.frameRate, calibrated.frameRate, "frame rate")
        requireEqual(live.analysisRegion, calibrated.analysisRegion, "analysis region")
        requireEqual(live.fixtureIdentifier, calibrated.fixtureIdentifier, "fixture")
        requireEqual(live.fixtureGeometryVersion, calibrated.fixtureGeometryVersion,
                     "fixture geometry")
        requireEqual(live.containerIdentifier, calibrated.containerIdentifier, "container")

        // --- Settled values: within tolerance ------------------------------
        requireWithin(live.lensPosition, calibrated.lensPosition,
                      absolute: tolerances.lensPosition, "focus")
        requireClose(live.exposureSeconds, calibrated.exposureSeconds,
                     relative: tolerances.relativeExposure, "exposure")
        requireClose(Double(live.iso), Double(calibrated.iso),
                     relative: tolerances.relativeISO, "ISO")
        requireWithin(live.whiteBalanceGains.red, calibrated.whiteBalanceGains.red,
                      absolute: tolerances.whiteBalanceGain, "white balance (red)")
        requireWithin(live.whiteBalanceGains.green, calibrated.whiteBalanceGains.green,
                      absolute: tolerances.whiteBalanceGain, "white balance (green)")
        requireWithin(live.whiteBalanceGains.blue, calibrated.whiteBalanceGains.blue,
                      absolute: tolerances.whiteBalanceGain, "white balance (blue)")
        requireWithin(live.torchLevel, calibrated.torchLevel,
                      absolute: tolerances.torchLevel, "torch level")
        requireClose(live.fillVolumeMillilitres, calibrated.fillVolumeMillilitres,
                     relative: 0.05, "fill volume")
        requireClose(live.workingDistanceMillimetres, calibrated.workingDistanceMillimetres,
                     relative: tolerances.relativeWorkingDistance, "working distance")

        return reasons
    }
}
