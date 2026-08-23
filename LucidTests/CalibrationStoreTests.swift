import XCTest
@testable import Lucid

final class CalibrationStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucidCalibrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_700_000_000))
    -> FileCalibrationStore {
        FileCalibrationStore(url: directory.appendingPathComponent("calibrations.json"),
                             now: { now })
    }

    // MARK: - Round trip

    func testAProfileSurvivesBeingSavedAndLoaded() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let store = makeStore()

        try store.save([profile])
        let loaded = try store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, profile)
    }

    func testEverythingNeededToAuditAndRefitIsPreserved() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let store = makeStore()
        try store.save([profile])
        let loaded = try XCTUnwrap(try store.load().first)

        // The replicates, not just the curve: a profile that kept only its
        // final numbers could never be re-fitted or checked.
        XCTAssertEqual(loaded.levels.count, profile.levels.count)
        XCTAssertEqual(loaded.levels.flatMap(\.replicates).count,
                       profile.levels.flatMap(\.replicates).count)
        XCTAssertEqual(loaded.validation, profile.validation)
        XCTAssertEqual(loaded.uncertainty, profile.uncertainty)
        XCTAssertEqual(loaded.binding, profile.binding)
        XCTAssertEqual(loaded.validatedIndexRange, profile.validatedIndexRange)
    }

    func testAReloadedCurvePredictsIdenticallyToTheOriginal() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let store = makeStore()
        try store.save([profile])
        let loaded = try XCTUnwrap(try store.load().first)

        for index in stride(from: 5.0, through: 500.0, by: 5.0) {
            XCTAssertEqual(loaded.mapping.ntu(forIndex: index),
                           profile.mapping.ntu(forIndex: index),
                           accuracy: 1e-9)
        }
    }

    func testLoadingWhenNothingHasBeenSavedReturnsNothing() throws {
        XCTAssertTrue(try makeStore().load().isEmpty)
    }

    func testEncodingIsStableSoASavedCalibrationCanBeDiffed() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try CalibrationArchiveCoder.encode([profile], at: date)
        let second = try CalibrationArchiveCoder.encode([profile], at: date)
        XCTAssertEqual(first, second)
    }

    // MARK: - Migration and refusal

    func testAnArchiveFromANewerVersionIsRefusedRatherThanHalfRead() throws {
        let json = """
        {"schemaVersion": 999, "writtenAt": "2024-01-01T00:00:00Z", "profiles": []}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try CalibrationArchiveCoder.decode(json)) { error in
            guard case CalibrationStoreError.unsupportedSchema(let found, let supported) = error else {
                return XCTFail("expected an unsupported-schema error, got \(error)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, CalibrationArchive.currentSchemaVersion)
        }
    }

    func testAProfileFromAnOlderFormatIsDiscardedNotSilentlyMigrated() throws {
        // A calibration is an empirical claim about a specific instrument. A
        // format change that alters what a field means invalidates the claim,
        // so the profile is dropped and the standards have to be re-run.
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let data = try CalibrationArchiveCoder.encode([profile], at: Date())
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["schemaVersion"] = 0
        object["profiles"] = profiles

        let mutated = try JSONSerialization.data(withJSONObject: object)
        let result = try CalibrationArchiveCoder.decode(mutated)

        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertEqual(result.discarded, 1)
    }

    func testCorruptDataFailsLoudly() {
        let rubbish = Data("this is not a calibration".utf8)

        XCTAssertThrowsError(try CalibrationArchiveCoder.decode(rubbish)) { error in
            guard case CalibrationStoreError.corruptData = error else {
                return XCTFail("expected a corrupt-data error, got \(error)")
            }
        }
    }

    func testEveryStoreErrorExplainsItself() {
        let errors: [CalibrationStoreError] = [
            .unsupportedSchema(found: 2, supported: 1),
            .corruptData("truncated"),
            .writeFailed("disk full")
        ]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    // MARK: - Overwriting

    func testSavingReplacesWhatWasThereBefore() throws {
        let store = makeStore()
        let first = try XCTUnwrap(CalibrationFactory.profile(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        ))
        let second = try XCTUnwrap(CalibrationFactory.profile(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        ))

        try store.save([first])
        try store.save([second])

        XCTAssertEqual(try store.load().map(\.id), [second.id])
    }

    // MARK: - The in-memory store behaves the same

    func testTheInMemoryStoreRoundTrips() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let store = InMemoryCalibrationStore()

        try store.save([profile])
        XCTAssertEqual(try store.load(), [profile])
    }

    func testAFailedSaveLeavesTheStoreUnchanged() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())
        let store = InMemoryCalibrationStore(profiles: [profile])
        store.failNextSave = true

        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try store.load(), [profile])
    }

    // MARK: - Expiry

    func testExpiryIsCheckedAgainstTheDateNotJustStored() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile(
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        XCTAssertFalse(profile.isExpired(asOf: Date(timeIntervalSince1970: 1_750_000_000)))
        XCTAssertTrue(profile.isExpired(asOf: Date(timeIntervalSince1970: 1_850_000_000)))
    }

    func testTheProfileSummarisesTheStandardsItWasMadeFrom() throws {
        let profile = try XCTUnwrap(CalibrationFactory.profile())

        XCTAssertTrue(profile.standardsSummary.contains("0 NTU"))
        XCTAssertTrue(profile.standardsSummary.contains("50 NTU"))
        XCTAssertTrue(profile.standardsSummary.contains("x4"),
                      "the replicate count is part of what makes a calibration credible")
    }
}
