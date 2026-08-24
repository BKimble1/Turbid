import Foundation
import Observation

/// The calibration profiles this device holds, and which one is in force.
///
/// MainActor-isolated because it is read directly by the interface. The store
/// behind it does file I/O, so every call that touches disk is `async` and hops
/// off the main thread to do it.
///
/// The selection is not persisted. It defaults to the most recently created
/// profile that has not expired, which is the only defensible automatic choice:
/// remembering a stale selection across launches would silently attach an old
/// calibration to a new setup, and the compatibility gate is a safety net, not
/// a substitute for choosing deliberately.
@MainActor
@Observable
final class CalibrationLibrary {

    private(set) var profiles: [CalibrationProfile] = []
    private(set) var selectedProfileID: UUID?
    private(set) var loadError: String?
    private(set) var hasLoaded = false

    private let store: any CalibrationStoring
    private let now: @Sendable () -> Date

    init(store: any CalibrationStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    var selectedProfile: CalibrationProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    /// Profiles sorted newest first, which is the order the list is shown in.
    var profilesNewestFirst: [CalibrationProfile] {
        profiles.sorted { $0.createdAt > $1.createdAt }
    }

    func load() async {
        let store = self.store
        let result: Result<[CalibrationProfile], Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try store.load())
            } catch {
                return .failure(error)
            }
        }.value

        hasLoaded = true
        switch result {
        case .success(let loaded):
            profiles = loaded
            loadError = nil
            selectDefaultProfile()
        case .failure(let error):
            profiles = []
            selectedProfileID = nil
            loadError = (error as? CalibrationStoreError)?.message ?? error.localizedDescription
            TurbidLog.calibration.error("Calibrations could not be loaded.")
        }
    }

    func select(_ profile: CalibrationProfile?) {
        selectedProfileID = profile?.id
    }

    /// Adds a completed profile and makes it the selected one.
    ///
    /// - Returns: the reason it could not be saved, or `nil` on success. The
    ///   profile is not added to the in-memory list unless the write succeeded:
    ///   a calibration the app would forget on relaunch must not be presented
    ///   as one it holds.
    @discardableResult
    func add(_ profile: CalibrationProfile) async -> String? {
        var updated = profiles.filter { $0.id != profile.id }
        updated.append(profile)

        if let message = await write(updated) { return message }

        profiles = updated
        selectedProfileID = profile.id
        return nil
    }

    @discardableResult
    func remove(_ profile: CalibrationProfile) async -> String? {
        let updated = profiles.filter { $0.id != profile.id }
        if let message = await write(updated) { return message }

        profiles = updated
        if selectedProfileID == profile.id { selectDefaultProfile() }
        return nil
    }

    /// Why the selected profile cannot be used with the setup described by
    /// `binding`, or an empty array when it can.
    func mismatches(against binding: CalibrationBinding?,
                    tolerances: CalibrationTolerances = .screening) -> [String] {
        guard let profile = selectedProfile else { return ["no calibration is selected"] }
        if profile.isExpired(asOf: now()) {
            return ["the calibration expired on "
                    + profile.expiresAt.formatted(date: .abbreviated, time: .omitted)]
        }
        guard let binding else { return ["the current capture settings are unknown"] }
        return CalibrationCompatibility.mismatches(live: binding,
                                                   calibrated: profile.binding,
                                                   tolerances: tolerances)
    }

    /// Profiles within thirty days of expiry, so the interface can ask for a
    /// re-run before the calibration stops working rather than after.
    func expiringSoon(withinDays days: Int = 30) -> [CalibrationProfile] {
        let deadline = now().addingTimeInterval(Double(days) * 86_400)
        return profiles.filter { !$0.isExpired(asOf: now()) && $0.expiresAt <= deadline }
    }

    func isExpired(_ profile: CalibrationProfile) -> Bool { profile.isExpired(asOf: now()) }

    // MARK: - Private

    private func write(_ updated: [CalibrationProfile]) async -> String? {
        let store = self.store
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try store.save(updated)
                return nil
            } catch let error as CalibrationStoreError {
                return error.message
            } catch {
                return error.localizedDescription
            }
        }.value

        if failure != nil {
            TurbidLog.calibration.error("Calibration could not be saved.")
        }
        return failure
    }

    private func selectDefaultProfile() {
        let date = now()
        selectedProfileID = profiles
            .filter { !$0.isExpired(asOf: date) }
            .max { $0.createdAt < $1.createdAt }?
            .id
    }
}
