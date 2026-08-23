import Foundation
import Observation

/// Drives a guided calibration: describe the fixture, enter the standards,
/// measure each of them the required number of times, fit, review, save.
///
/// It does not capture anything itself. Every replicate is an ordinary
/// measurement run by `MeasurementViewModel`, through the same camera, the same
/// gates and the same analysis. A calibration built from a special capture path
/// would calibrate that path and not the one measurements use.
@MainActor
@Observable
final class CalibrationSessionViewModel {

    enum Stage: Equatable {
        case describeSetup
        case enterStandards
        case capture
        case review
        case saved
    }

    /// Editable text for one standard. Kept as strings because that is what a
    /// text field holds; nothing downstream sees a partially typed number.
    struct StandardDraft: Equatable {
        var nominalNTU = ""
        var toleranceNTU = ""
        var manufacturer = ""
        var lotNumber = ""
        var expiryDate = Date()

        var isBlankLevel: Bool { Double(nominalNTU) == 0 }
    }

    struct SetupDraft: Equatable {
        var fixtureIdentifier = ""
        var containerIdentifier = ""
        var fillVolumeMillilitres = ""
        var workingDistanceMillimetres = ""

        var isComplete: Bool {
            !fixtureIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
                && !containerIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
                && (Double(fillVolumeMillilitres) ?? 0) > 0
                && (Double(workingDistanceMillimetres) ?? 0) > 0
        }

        func description() -> FixtureDescription {
            FixtureDescription(
                fixtureIdentifier: fixtureIdentifier.trimmingCharacters(in: .whitespaces),
                fixtureGeometryVersion: 1,
                containerIdentifier: containerIdentifier.trimmingCharacters(in: .whitespaces),
                fillVolumeMillilitres: Double(fillVolumeMillilitres) ?? 0,
                workingDistanceMillimetres: Double(workingDistanceMillimetres) ?? 0
            )
        }
    }

    private(set) var stage: Stage = .describeSetup
    private(set) var standards: [CalibrationStandard] = []
    private(set) var replicates: [CalibrationReplicate] = []
    private(set) var activeStandardIndex = 0
    private(set) var outcome: CalibrationFitter.Outcome?
    private(set) var savedProfile: CalibrationProfile?
    private(set) var problem: String?
    /// One per recorded replicate, so a setup that changed mid-calibration is
    /// caught rather than averaged in.
    private(set) var replicateBindings: [CalibrationBinding] = []

    var setup = SetupDraft()
    var draft = StandardDraft()
    var profileName = ""
    var validForMonths = 6

    let measurement: MeasurementViewModel
    private let library: CalibrationLibrary
    private let fitter: CalibrationFitter
    private let tolerances: CalibrationTolerances
    private let now: @Sendable () -> Date

    init(measurement: MeasurementViewModel,
         library: CalibrationLibrary,
         fitter: CalibrationFitter = CalibrationFitter(),
         tolerances: CalibrationTolerances = .screening,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.measurement = measurement
        self.library = library
        self.fitter = fitter
        self.tolerances = tolerances
        self.now = now
    }

    // MARK: - Requirements, stated up front

    var requirements: CalibrationFitter.Requirements { fitter.requirements }

    var requirementSummary: [String] {
        [
            "A blank: a 0 NTU standard, or the same water the standards were made up in.",
            "At least \(requirements.minimumNonZeroStandards) certified standards above zero, spanning the range you intend to measure.",
            "At least \(requirements.minimumReplicatesPerLevel) separate readings of each one.",
            "Every standard still inside its expiry date.",
            "The fixture reassembled identically for every reading."
        ]
    }

    var estimatedRunCount: Int {
        max(0, standards.count) * requirements.minimumReplicatesPerLevel
    }

    // MARK: - Setup

    func confirmSetup() {
        guard setup.isComplete else {
            problem = "Describe the fixture, the container, the fill volume and the working distance first."
            return
        }
        problem = nil
        measurement.fixtureOverride = setup.description()
        stage = .enterStandards
    }

    // MARK: - Standards

    /// - Returns: the reason the draft was refused, or `nil` when it was added.
    @discardableResult
    func addDraftStandard() -> String? {
        guard let nominal = Double(draft.nominalNTU), nominal >= 0 else {
            return "Enter the certified value in NTU."
        }
        guard let tolerance = Double(draft.toleranceNTU), tolerance >= 0 else {
            return "Enter the certificate's tolerance, as plus or minus NTU."
        }
        let manufacturer = draft.manufacturer.trimmingCharacters(in: .whitespaces)
        let lot = draft.lotNumber.trimmingCharacters(in: .whitespaces)
        guard !manufacturer.isEmpty, !lot.isEmpty else {
            return "Enter the manufacturer and the lot number from the bottle."
        }
        guard draft.expiryDate > now() else {
            return "That standard has expired. A calibration is only as good as the standards it was made from."
        }
        guard !standards.contains(where: { $0.nominalNTU == nominal }) else {
            return "There is already a standard at that value."
        }

        standards.append(CalibrationStandard(nominalNTU: nominal,
                                             toleranceNTU: tolerance,
                                             manufacturer: manufacturer,
                                             lotNumber: lot,
                                             expiryDate: draft.expiryDate))
        standards.sort { $0.nominalNTU < $1.nominalNTU }
        draft = StandardDraft()
        return nil
    }

    func removeStandard(_ standard: CalibrationStandard) {
        standards.removeAll { $0.id == standard.id }
        replicates.removeAll { $0.standardNominalNTU == standard.nominalNTU }
        activeStandardIndex = min(activeStandardIndex, max(0, standards.count - 1))
    }

    /// The problems that would stop a fit, evaluated on what has been entered
    /// so far. Shown before any measuring starts, so nobody spends twenty
    /// minutes discovering they were one standard short.
    var outstandingProblems: [CalibrationDataProblem] {
        fitter.validate(levels: levels, asOf: now())
    }

    func beginCapture() {
        guard standards.count > requirements.minimumNonZeroStandards else {
            problem = "Add a blank and at least \(requirements.minimumNonZeroStandards) standards above zero first."
            return
        }
        problem = nil
        activeStandardIndex = 0
        stage = .capture
    }

    // MARK: - Capture

    var activeStandard: CalibrationStandard? {
        standards.indices.contains(activeStandardIndex) ? standards[activeStandardIndex] : nil
    }

    func replicateCount(for standard: CalibrationStandard) -> Int {
        replicates.filter { $0.standardNominalNTU == standard.nominalNTU }.count
    }

    var activeStandardIsComplete: Bool {
        guard let activeStandard else { return false }
        return replicateCount(for: activeStandard) >= requirements.minimumReplicatesPerLevel
    }

    var allStandardsComplete: Bool {
        !standards.isEmpty && standards.allSatisfy {
            replicateCount(for: $0) >= requirements.minimumReplicatesPerLevel
        }
    }

    /// Records the reading currently held by the measurement view model.
    ///
    /// - Returns: the reason it was refused, or `nil` when it was recorded.
    @discardableResult
    func recordCurrentReading() -> String? {
        record(reading: measurement.reading, binding: measurement.liveBinding)
    }

    /// - Returns: the reason the reading was refused, or `nil` when it was
    ///   recorded. Split from `recordCurrentReading()` so the rules can be
    ///   exercised without running a camera.
    @discardableResult
    func record(reading: TurbidityReading?, binding: CalibrationBinding?) -> String? {
        guard let standard = activeStandard else { return "No standard is selected." }
        guard let reading else { return "There is no reading to record." }
        guard reading.validity.isValid else {
            return "That capture did not pass the quality gates, so it cannot go into a calibration."
        }
        guard let binding else {
            return "The capture settings for that reading are unknown."
        }
        if let first = replicateBindings.first {
            let mismatches = CalibrationCompatibility.mismatches(live: binding,
                                                                 calibrated: first,
                                                                 tolerances: tolerances)
            guard mismatches.isEmpty else {
                return "The setup changed since the first reading: "
                    + mismatches.joined(separator: "; ")
                    + ". Start the calibration again."
            }
        }

        replicates.append(CalibrationReplicate(
            recordedAt: now(),
            standardNominalNTU: standard.nominalNTU,
            index: reading.index,
            scattering: reading.scattering,
            tracking: reading.tracking,
            quality: reading.quality
        ))
        replicateBindings.append(binding)
        return nil
    }

    func advanceToNextStandard() {
        guard activeStandardIndex + 1 < standards.count else { return }
        activeStandardIndex += 1
    }

    func selectStandard(_ standard: CalibrationStandard) {
        guard let index = standards.firstIndex(where: { $0.id == standard.id }) else { return }
        activeStandardIndex = index
    }

    // MARK: - Fit and save

    var levels: [CalibrationLevel] {
        standards.map { standard in
            CalibrationLevel(
                standard: standard,
                replicates: replicates.filter { $0.standardNominalNTU == standard.nominalNTU }
            )
        }
    }

    func fit() {
        let result = fitter.fit(levels: levels, asOf: now())
        outcome = result
        problem = result.candidate == nil
            ? result.problems.map(\.explanation).joined(separator: " ")
            : nil
        stage = .review
    }

    /// - Returns: the reason it could not be saved, or `nil` on success.
    @discardableResult
    func save() async -> String? {
        guard let outcome,
              let candidate = outcome.candidate,
              let uncertainty = outcome.uncertainty,
              let indexRange = outcome.validatedIndexRange,
              let ntuRange = outcome.validatedNTURange else {
            return "This data did not produce a usable curve, so there is nothing to save."
        }
        guard let binding = replicateBindings.first else {
            return "The capture settings for this calibration are unknown."
        }

        let name = profileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Give the calibration a name." }

        let created = now()
        guard let expires = Calendar.current.date(byAdding: .month,
                                                  value: validForMonths,
                                                  to: created) else {
            return "The expiry date could not be calculated."
        }

        let profile = CalibrationProfile(
            id: UUID(),
            schemaVersion: CalibrationProfile.currentSchemaVersion,
            name: name,
            createdAt: created,
            expiresAt: expires,
            binding: binding,
            mapping: candidate.mapping,
            uncertainty: uncertainty,
            validation: candidate.validation,
            validatedIndexRange: indexRange,
            validatedNTURange: ntuRange,
            levels: levels
        )

        if let failure = await library.add(profile) {
            problem = failure
            return failure
        }

        savedProfile = profile
        measurement.fixtureOverride = nil
        stage = .saved
        problem = nil
        return nil
    }

    /// Leaves the calibration flow without saving anything.
    func abandon() {
        measurement.fixtureOverride = nil
    }
}
