import CoreGraphics
import XCTest
@testable import Lucid

final class AnalysisRegionTests: XCTestCase {

    // MARK: - Pixel geometry

    func testTheFullFrameRegionCoversEveryPixel() {
        let rect = AnalysisRegion.fullFrame.pixelRect(inWidth: 1920, height: 1080)
        XCTAssertEqual(rect, PixelRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testANormalizedRectangleMapsToWholePixels() {
        let region = AnalysisRegion(normalizedRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        let rect = region.pixelRect(inWidth: 1920, height: 1080)

        XCTAssertEqual(rect?.x, 480)
        XCTAssertEqual(rect?.width, 960)
        XCTAssertEqual(rect?.y, 540)
        XCTAssertEqual(rect?.height, 270)
    }

    func testARegionExtendingOutsideTheFrameIsClamped() {
        let region = AnalysisRegion(normalizedRect: CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5))
        let rect = region.pixelRect(inWidth: 100, height: 100)

        XCTAssertEqual(rect?.x, 80)
        XCTAssertEqual(rect?.width, 20, "must not run past the right edge")
        XCTAssertEqual(rect?.height, 20)
    }

    func testAnEmptyOrOffFrameRegionYieldsNothing() {
        XCTAssertNil(AnalysisRegion(normalizedRect: .zero).pixelRect(inWidth: 100, height: 100))
        XCTAssertNil(AnalysisRegion(normalizedRect: CGRect(x: 2, y: 2, width: 0.5, height: 0.5))
            .pixelRect(inWidth: 100, height: 100))
        XCTAssertNil(AnalysisRegion.fullFrame.pixelRect(inWidth: 0, height: 0))
    }

    func testARegionSmallerThanOnePixelStillYieldsOnePixel() {
        let region = AnalysisRegion(normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        let rect = region.pixelRect(inWidth: 100, height: 100)

        XCTAssertEqual(rect?.width, 1)
        XCTAssertEqual(rect?.height, 1)
    }

    // MARK: - Optical mask

    func testAnEmptyMaskExcludesNothing() {
        let mask = RasterizedMask(description: .none, width: 10, height: 10)
        XCTAssertEqual(mask.validCount, 100)
    }

    func testAnExcludedRectangleRemovesExactlyItsPixels() {
        let description = OpticalMaskDescription(
            excludedRectangles: [CGRect(x: 0, y: 0, width: 1, height: 0.5)],
            excludedEllipses: []
        )
        let mask = RasterizedMask(description: description, width: 10, height: 10)

        XCTAssertEqual(mask.validCount, 50, "the top half must be excluded")
        XCTAssertFalse(mask.isValid(atIndex: 0), "top-left is inside the excluded strip")
        XCTAssertTrue(mask.isValid(atIndex: 99), "bottom-right is outside it")
    }

    func testAnExcludedEllipseRemovesACentredDisc() {
        let description = OpticalMaskDescription(
            excludedRectangles: [],
            excludedEllipses: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)]
        )
        let mask = RasterizedMask(description: description, width: 20, height: 20)

        XCTAssertFalse(mask.isValid(atIndex: 10 * 20 + 10), "the centre is inside the ellipse")
        XCTAssertTrue(mask.isValid(atIndex: 0), "a corner is outside it")
        // A disc of normalized radius 0.25 covers pi * 0.25^2 = 19.6% of the area.
        let excludedFraction = Double(400 - mask.validCount) / 400
        XCTAssertEqual(excludedFraction, 0.196, accuracy: 0.03)
    }

    func testMaskSamplingUsesPixelCentres() {
        // A strip covering exactly the top half of a 4-row image must exclude
        // two whole rows, not two and a half.
        let description = OpticalMaskDescription(
            excludedRectangles: [CGRect(x: 0, y: 0, width: 1, height: 0.5)],
            excludedEllipses: []
        )
        let mask = RasterizedMask(description: description, width: 4, height: 4)
        XCTAssertEqual(mask.validCount, 8)
    }

    func testOutOfBoundsIndicesReadAsInvalidRatherThanCrashing() {
        let mask = RasterizedMask(description: .none, width: 4, height: 4)
        XCTAssertFalse(mask.isValid(atIndex: -1))
        XCTAssertFalse(mask.isValid(atIndex: 16))
    }

    // MARK: - The screening default

    func testTheScreeningRegionSitsWellInsideTheFrame() {
        let region = AnalysisRegion.screeningDefault
        XCTAssertGreaterThan(region.normalizedRect.minX, 0.1,
                             "must clear the container wall on the left")
        XCTAssertLessThan(region.normalizedRect.maxX, 0.9,
                          "must clear the container wall on the right")
        XCTAssertGreaterThan(region.normalizedRect.minY, 0.1)
        XCTAssertLessThan(region.normalizedRect.maxY, 0.9)
    }

    func testTheScreeningRegionMasksTheMeniscusAndTheTorchHotspot() {
        let region = AnalysisRegion.screeningDefault
        XCTAssertFalse(region.mask.isEmpty)
        // The top of the region is the meniscus strip.
        XCTAssertTrue(region.mask.excludes(normalizedX: 0.5, normalizedY: 0.05))
        // The upper centre is the specular reflection of the torch.
        XCTAssertTrue(region.mask.excludes(normalizedX: 0.5, normalizedY: 0.18))
        // The lower part of the sample volume is kept.
        XCTAssertFalse(region.mask.excludes(normalizedX: 0.5, normalizedY: 0.8))
    }

    func testTheScreeningRegionStillLeavesMostOfItsAreaUsable() {
        let mask = RasterizedMask(description: AnalysisRegion.screeningDefault.mask,
                                  width: 100, height: 100)
        XCTAssertGreaterThan(Double(mask.validCount) / 10_000, 0.6,
                             "masking must not consume the region it is protecting")
    }

    func testRegionVersionIsRecordedSoAMeasurementCanBeTracedToItsGeometry() {
        XCTAssertEqual(AnalysisRegion.screeningDefault.version, 1)
        XCTAssertNotEqual(AnalysisRegion.screeningDefault.version, AnalysisRegion.fullFrame.version)
    }

    func testTheRegionSurvivesACodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(AnalysisRegion.screeningDefault)
        let decoded = try JSONDecoder().decode(AnalysisRegion.self, from: encoded)
        XCTAssertEqual(decoded, AnalysisRegion.screeningDefault)
    }
}
