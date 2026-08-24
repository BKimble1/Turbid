import XCTest
@testable import Turbid

/// The calibrations this device holds, and which one is in force.
@MainActor
final class CalibrationLibraryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func library(_ profiles: [CalibrationProfile] = [],
                         store: InMemoryCalibrationStore? = nil) -> (CalibrationLibrary,
                                                                     InMemoryCalibrationStore) {
        let backing = store ?? InMemoryCalibrationStore(profiles: profiles)
        let now = self.now
        return (CalibrationLibrary(store: backing, now: { now }), backing)
    }

    private func profile(name: String,
                         createdAt: TimeInterval,
                         expiresAt: TimeInterval,
                         id: UUID,
                         binding: CalibrationBinding? = nil) throws -> CalibrationProfile {
        try XCTUnwrap(
            CalibrationFactory.profile(
                binding: binding,
                name: name,
                createdAt: Date(timeIntervalSince1970: createdAt),
                expiresAt: Date(timeIntervalSince1970: expiresAt),
                id: id
            ),
            "the factory's calibration levels must produce a usable curve"
        )
    }

    private func newest() throws -> CalibrationProfile {
        try profile(name: "Newest", createdAt: 1_740_000_000, expiresAt: 1_800_000_000,
                    id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001") ?? UUID())
    }

    private func older() throws -> CalibrationProfile {
        try profile(name: "Older", createdAt: 1_700_000_000, expiresAt: 1_800_000_000,
                    id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002") ?? UUID())
    }

    private func expired() throws -> CalibrationProfile {
        try profile(name: "Expired", createdAt: 1_745_000_000, expiresAt: 1_746_000_000,
                    id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000003") ?? UUID())
    }

    // MARK: - Loading and selection

    func testLoadingSelectsTheNewestCalibrationThatHasNotExpired() async throws {
        let (library, _) = library([try older(), try newest(), try expired()])

        await library.load()

        XCTAssertEqual(library.profiles.count, 3)
        XCTAssertEqual(library.selectedProfile?.name, "Newest")
    }

    func testAnExpiredCalibrationIsNeverSelectedAutomatically() async throws {
        let (library, _) = library([try expired()])

        await library.load()

        XCTAssertNil(library.selectedProfile,
                     "an expired calibration must not be applied silently")
        XCTAssertTrue(library.isExpired(try expired()))
    }

    func testAnEmptyLibraryLoadsCleanlyAndSelectsNothing() async throws {
        let (library, _) = library()

        await library.load()

        XCTAssertTrue(library.hasLoaded)
        XCTAssertNil(library.loadError)
        XCTAssertNil(library.selectedProfile)
    }

    func testProfilesAreListedNewestFirst() async throws {
        let (library, _) = library([try older(), try newest()])

        await library.load()

        XCTAssertEqual(library.profilesNewestFirst.map(\.name), ["Newest", "Older"])
    }

    // MARK: - Adding and removing

    func testAddingAProfileWritesItAndPutsItInUse() async throws {
        let (library, store) = library()
        await library.load()

        let failure = await library.add(try newest())

        XCTAssertNil(failure)
        XCTAssertEqual(library.selectedProfile?.id, try newest().id)
        XCTAssertEqual(try? store.load().count, 1, "it has to survive a relaunch")
    }

    func testAProfileThatCouldNotBeSavedIsNotPresentedAsHeld() async throws {
        let store = InMemoryCalibrationStore()
        store.failNextSave = true
        let (library, _) = library(store: store)
        await library.load()

        let failure = await library.add(try newest())

        XCTAssertNotNil(failure, "a failed write must be reported, not swallowed")
        XCTAssertTrue(library.profiles.isEmpty,
                      "a calibration the app would forget must not be shown as held")
        XCTAssertNil(library.selectedProfile)
    }

    func testRemovingTheSelectedProfileFallsBackToTheNextUsableOne() async throws {
        let (library, _) = library([try older(), try newest()])
        await library.load()
        XCTAssertEqual(library.selectedProfile?.name, "Newest")

        let failure = await library.remove(try newest())

        XCTAssertNil(failure)
        XCTAssertEqual(library.profiles.count, 1)
        XCTAssertEqual(library.selectedProfile?.name, "Older")
    }

    // MARK: - Compatibility

    func testNoSelectionIsReportedAsAReasonRatherThanAsCompatibility() async throws {
        let (library, _) = library()
        await library.load()

        let reasons = library.mismatches(against: CalibrationFactory.binding())
        XCTAssertEqual(reasons, ["no calibration is selected"])
    }

    func testAnUnknownLiveSetupIsNeverTreatedAsAMatch() async throws {
        let (library, _) = library([try newest()])
        await library.load()

        let reasons = library.mismatches(against: nil)
        XCTAssertEqual(reasons, ["the current capture settings are unknown"])
    }

    func testAnExpiredSelectionIsRefusedBeforeAnythingElseIsCompared() async throws {
        let (library, _) = library([try expired()])
        await library.load()
        library.select(try expired())

        let reasons = library.mismatches(against: CalibrationFactory.binding())
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("expired"), reasons[0])
    }

    func testAMatchingSetupProducesNoReasons() async throws {
        let binding = CalibrationFactory.binding()
        let matching = try profile(name: "Matching", createdAt: 1_740_000_000,
                                   expiresAt: 1_800_000_000,
                                   id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-00000000000A") ?? UUID(),
                                   binding: binding)
        let (library, _) = library([matching])
        await library.load()

        XCTAssertTrue(library.mismatches(against: binding).isEmpty)
    }

    func testADifferentFixtureIsReportedInWordsSomeoneCanActOn() async throws {
        let calibrated = CalibrationFactory.binding(fixture: "shroud-v1")
        let matching = try profile(name: "Shroud v1", createdAt: 1_740_000_000,
                                   expiresAt: 1_800_000_000,
                                   id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-00000000000B") ?? UUID(),
                                   binding: calibrated)
        let (library, _) = library([matching])
        await library.load()

        let reasons = library.mismatches(against: CalibrationFactory.binding(fixture: "shroud-v2"))
        XCTAssertTrue(reasons.contains { $0.contains("fixture") }, "\(reasons)")
    }

    // MARK: - Expiry warnings

    func testCalibrationsCloseToExpiryAreFlaggedBeforeTheyStopWorking() async throws {
        let soon = try profile(name: "Soon", createdAt: 1_740_000_000,
                               // Ten days after `now`.
                               expiresAt: 1_750_000_000 + 10 * 86_400,
                               id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-00000000000C") ?? UUID())
        let (library, _) = library([soon, try older()])
        await library.load()

        XCTAssertEqual(library.expiringSoon().map(\.name), ["Soon"])
        XCTAssertTrue(library.expiringSoon(withinDays: 1).isEmpty)
    }
}
