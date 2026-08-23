import XCTest
@testable import Lucid

/// Every gate must be able to fire, and a failing window must produce no
/// number at all. Phase 3A is not complete until these pass.
final class FrameQualityEvaluatorTests: XCTestCase {

    private let evaluator = FrameQualityEvaluator(thresholds: .screening)

    /// A window that comfortably clears every gate.
    private func healthyInput() -> QualityEvaluationInput {
        QualityEvaluationInput(
            statistics: LumaStatistics(
                sampleCount: 100_000,
                mean: 0.30,
                standardDeviation: 0.05,
                minimum: 0.1,
                maximum: 0.6,
                percentile01: 0.15,
                percentile50: 0.29,
                percentile99: 0.55,
                saturatedFraction: 0.0001,
                nearBlackFraction: 0.001,
                brightestTileShare: 0.08,
                sharpness: 0.01,
                noiseSigma: 0.004
            ),
            globalMotionScore: 0.0001,
            exposureVariation: 0.004,
            controlsRemainedLocked: true,
            usableFrames: 268,
            evaluatedFrames: 270,
            droppedFrameRatio: 0.01,
            frameDeliveryIsContinuous: true,
            thermal: .nominal,
            systemPressure: .nominal,
            backgroundStability: nil,
            calibrationProfileIsCompatible: nil,
            analysisRegionVersion: 1,
            captureProtocolVersion: 1
        )
    }

    private func assertInvalid(_ input: QualityEvaluationInput,
                               because reason: MeasurementRejectionReason,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        let quality = evaluator.evaluate(input)
        XCTAssertFalse(quality.isUsable, "expected \(reason) to invalidate the window",
                       file: file, line: line)
        XCTAssertTrue(quality.verdict.reasons.contains(reason),
                      "expected \(reason), got \(quality.verdict.reasons)",
                      file: file, line: line)
        XCTAssertEqual(quality.confidence, 0,
                       "an invalid window must carry no confidence",
                       file: file, line: line)
        XCTAssertFalse(quality.explanations.isEmpty,
                       "every rejection must be explainable to the user",
                       file: file, line: line)
    }

    // MARK: - The baseline

    func testAHealthyWindowIsUsableWithHighConfidence() {
        let quality = evaluator.evaluate(healthyInput())

        XCTAssertEqual(quality.verdict, .usable)
        XCTAssertTrue(quality.isUsable)
        XCTAssertGreaterThan(quality.confidence, 0.2)
        XCTAssertTrue(quality.explanations.isEmpty)
    }

    func testTheWindowRecordsWhichThresholdsAndGeometryProducedIt() {
        let quality = evaluator.evaluate(healthyInput())

        XCTAssertEqual(quality.thresholdsVersion, QualityThresholds.screening.version)
        XCTAssertEqual(quality.analysisRegionVersion, 1)
        XCTAssertEqual(quality.captureProtocolVersion, 1)
    }

    // MARK: - Illumination and level

    func testTooMuchClippingInvalidatesTheWindow() {
        var input = healthyInput()
        input.statistics = with(input.statistics) { $0.saturatedFraction = 0.02 }
        assertInvalid(input, because: .saturatedRegion)
    }

    func testAConcentratedTorchHotspotInvalidatesTheWindow() {
        var input = healthyInput()
        input.statistics = with(input.statistics) { $0.brightestTileShare = 0.6 }
        assertInvalid(input, because: .torchHotspot)
    }

    func testAUniformlyBrightRegionIsNotMistakenForAHotspot() {
        var input = healthyInput()
        // Evenly lit: a 4x4 grid spreads the signal at 1/16 per tile.
        input.statistics = with(input.statistics) {
            $0.mean = 0.55
            $0.brightestTileShare = 0.0625
        }
        let quality = evaluator.evaluate(input)
        XCTAssertFalse(quality.verdict.reasons.contains(.torchHotspot))
    }

    func testADarkRegionInvalidatesTheWindow() {
        var input = healthyInput()
        input.statistics = with(input.statistics) { $0.mean = 0.005 }
        assertInvalid(input, because: .regionTooDark)
    }

    func testABrightRegionInvalidatesTheWindow() {
        var input = healthyInput()
        input.statistics = with(input.statistics) { $0.mean = 0.85 }
        assertInvalid(input, because: .regionTooBright)
    }

    // MARK: - Optics

    func testABlurredRegionInvalidatesTheWindow() {
        var input = healthyInput()
        input.statistics = with(input.statistics) { $0.sharpness = 0.00001 }
        assertInvalid(input, because: .outOfFocus)
    }

    func testCameraMotionInvalidatesTheWindow() {
        var input = healthyInput()
        input.globalMotionScore = 0.01
        assertInvalid(input, because: .cameraMoved)
    }

    // MARK: - Capture stability

    func testExposureFlickerInvalidatesTheWindow() {
        var input = healthyInput()
        input.exposureVariation = 0.15
        assertInvalid(input, because: .exposureUnstable)
    }

    func testControlsComingUnlockedInvalidatesTheWindow() {
        var input = healthyInput()
        input.controlsRemainedLocked = false
        assertInvalid(input, because: .controlsUnlocked)
    }

    // MARK: - Frame delivery

    func testTooFewFramesInvalidatesTheWindow() {
        var input = healthyInput()
        input.evaluatedFrames = 5
        input.usableFrames = 5
        assertInvalid(input, because: .insufficientUsableFrames)
    }

    func testTooFewUsableFramesInvalidatesTheWindow() {
        var input = healthyInput()
        input.evaluatedFrames = 270
        input.usableFrames = 100
        assertInvalid(input, because: .insufficientUsableFrames)
    }

    func testTooManyDroppedFramesInvalidatesTheWindow() {
        var input = healthyInput()
        input.droppedFrameRatio = 0.4
        assertInvalid(input, because: .excessiveDroppedFrames)
    }

    func testAStallInFrameDeliveryInvalidatesTheWindow() {
        var input = healthyInput()
        input.frameDeliveryIsContinuous = false
        assertInvalid(input, because: .frameDeliveryDiscontinuous)
    }

    // MARK: - Device

    func testThermalLimitsInvalidateTheWindow() {
        var input = healthyInput()
        input.thermal = .serious
        assertInvalid(input, because: .thermalLimit)
    }

    func testSystemPressureInvalidatesTheWindow() {
        var input = healthyInput()
        input.systemPressure = .critical
        assertInvalid(input, because: .systemPressure)
    }

    // MARK: - Gates whose inputs arrive in later phases

    func testBackgroundStabilityIsNotGatedWhenItCannotBeMeasured() {
        var input = healthyInput()
        input.backgroundStability = nil
        let quality = evaluator.evaluate(input)

        XCTAssertTrue(quality.isUsable)
        XCTAssertNil(quality.backgroundStability,
                     "nil must mean unmeasured, never zero")
    }

    /// Background stability is recorded, never gated on. It cannot tell
    /// suspended material drifting through the field from the container
    /// creeping, and gating on it rejected exactly the turbid samples the app
    /// exists to identify. Container movement is the motion gate's job.
    func testALowBackgroundStabilityIsRecordedButNeverRejectsTheWindow() {
        var input = healthyInput()
        input.backgroundStability = 0.2
        let quality = evaluator.evaluate(input)

        XCTAssertTrue(quality.isUsable,
                      "a sample full of particles must not be rejected for being full of particles")
        XCTAssertEqual(quality.backgroundStability, 0.2,
                       "the number is still reported, so a run can be judged on it afterwards")
    }

    func testAnIncompatibleCalibrationProfileInvalidatesTheWindow() {
        var input = healthyInput()
        input.calibrationProfileIsCompatible = false
        assertInvalid(input, because: .calibrationProfileMismatch)
    }

    func testACompatibleCalibrationProfileDoesNotFire() {
        var input = healthyInput()
        input.calibrationProfileIsCompatible = true
        XCTAssertTrue(evaluator.evaluate(input).isUsable)
    }

    // MARK: - Low confidence is not the same as invalid

    func testAMarginalReadingIsUsableButFlaggedRatherThanRejected() {
        var input = healthyInput()
        // 0.0045 is just under the 0.005 saturation limit: inside the band.
        input.statistics = with(input.statistics) { $0.saturatedFraction = 0.0045 }
        let quality = evaluator.evaluate(input)

        XCTAssertTrue(quality.isUsable, "a marginal window still produces a number")
        guard case .usableWithLowConfidence(let notes) = quality.verdict else {
            return XCTFail("expected low confidence, got \(quality.verdict)")
        }
        XCTAssertTrue(notes.contains(.saturatedRegion))
        XCTAssertLessThan(quality.confidence, 0.25)
    }

    func testConfidenceTracksTheWeakestGateNotTheAverage() {
        var strong = healthyInput()
        strong.globalMotionScore = 0.00001
        let strongConfidence = evaluator.evaluate(strong).confidence

        var weak = healthyInput()
        // Everything else is pristine; one gate is nearly at its limit.
        weak.globalMotionScore = 0.00117
        let weakConfidence = evaluator.evaluate(weak).confidence

        XCTAssertLessThan(weakConfidence, strongConfidence,
                          "one weak gate must drag confidence down on its own")
    }

    // MARK: - Multiple failures

    func testEveryFailedGateIsReportedNotJustTheFirst() {
        var input = healthyInput()
        input.statistics = with(input.statistics) {
            $0.saturatedFraction = 0.5
            $0.sharpness = 0.0
        }
        input.globalMotionScore = 0.05
        input.thermal = .critical

        let quality = evaluator.evaluate(input)
        let reasons = Set(quality.verdict.reasons)

        XCTAssertTrue(reasons.contains(.saturatedRegion))
        XCTAssertTrue(reasons.contains(.outOfFocus))
        XCTAssertTrue(reasons.contains(.cameraMoved))
        XCTAssertTrue(reasons.contains(.thermalLimit))
        XCTAssertEqual(quality.explanations.count, quality.verdict.reasons.count)
    }

    func testEveryRejectionReasonHasHumanReadableText() {
        let allReasons: [MeasurementRejectionReason] = [
            .saturatedRegion, .torchHotspot, .regionTooDark, .regionTooBright,
            .outOfFocus, .cameraMoved, .exposureUnstable, .controlsUnlocked,
            .insufficientUsableFrames, .excessiveDroppedFrames,
            .frameDeliveryDiscontinuous, .thermalLimit, .systemPressure,
            .calibrationProfileMismatch
        ]

        for reason in allReasons {
            XCTAssertNotEqual(reason.explanation, reason.rawValue,
                              "\(reason.rawValue) has no user-facing explanation")
            XCTAssertFalse(reason.explanation.isEmpty)
        }
    }

    // MARK: - Helper

    private func with(_ statistics: LumaStatistics,
                      _ mutate: (inout MutableStatistics) -> Void) -> LumaStatistics {
        var mutable = MutableStatistics(statistics)
        mutate(&mutable)
        return mutable.value
    }

    /// `LumaStatistics` is immutable by design, so tests build variants here
    /// rather than the production type gaining setters it does not need.
    private struct MutableStatistics {
        var sampleCount: Int
        var mean: Float
        var standardDeviation: Float
        var minimum: Float
        var maximum: Float
        var percentile01: Float
        var percentile50: Float
        var percentile99: Float
        var saturatedFraction: Double
        var nearBlackFraction: Double
        var brightestTileShare: Double
        var sharpness: Double
        var noiseSigma: Double

        init(_ statistics: LumaStatistics) {
            sampleCount = statistics.sampleCount
            mean = statistics.mean
            standardDeviation = statistics.standardDeviation
            minimum = statistics.minimum
            maximum = statistics.maximum
            percentile01 = statistics.percentile01
            percentile50 = statistics.percentile50
            percentile99 = statistics.percentile99
            saturatedFraction = statistics.saturatedFraction
            nearBlackFraction = statistics.nearBlackFraction
            brightestTileShare = statistics.brightestTileShare
            sharpness = statistics.sharpness
            noiseSigma = statistics.noiseSigma
        }

        var value: LumaStatistics {
            LumaStatistics(
                sampleCount: sampleCount, mean: mean,
                standardDeviation: standardDeviation, minimum: minimum,
                maximum: maximum, percentile01: percentile01,
                percentile50: percentile50, percentile99: percentile99,
                saturatedFraction: saturatedFraction,
                nearBlackFraction: nearBlackFraction,
                brightestTileShare: brightestTileShare, sharpness: sharpness,
                noiseSigma: noiseSigma
            )
        }
    }
}
