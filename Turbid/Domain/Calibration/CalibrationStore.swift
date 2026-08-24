import Foundation

/// What can go wrong loading or saving calibrations.
enum CalibrationStoreError: Error, Equatable, Sendable {
    /// The file was written by a newer version of Turbid.
    case unsupportedSchema(found: Int, supported: Int)
    case corruptData(String)
    case writeFailed(String)

    var message: String {
        switch self {
        case .unsupportedSchema(let found, let supported):
            return "These calibrations were saved by a newer version of Turbid (format \(found), this version reads \(supported)). Update Turbid to use them."
        case .corruptData(let detail):
            return "The saved calibrations could not be read. \(detail)"
        case .writeFailed(let detail):
            return "The calibration could not be saved. \(detail)"
        }
    }
}

/// The on-disk shape.
///
/// Wrapped in an envelope with its own schema version rather than encoding an
/// array directly, so that a future format change has somewhere to record what
/// it is, and so that reading a newer file fails loudly instead of silently
/// producing profiles with missing fields.
struct CalibrationArchive: Equatable, Sendable, Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let writtenAt: Date
    let profiles: [CalibrationProfile]

    init(profiles: [CalibrationProfile], writtenAt: Date) {
        self.schemaVersion = Self.currentSchemaVersion
        self.writtenAt = writtenAt
        self.profiles = profiles
    }
}

protocol CalibrationStoring: Sendable {
    func load() throws -> [CalibrationProfile]
    func save(_ profiles: [CalibrationProfile]) throws
}

/// Decoding and validation, separated from where the bytes live so both the
/// file store and the tests exercise the identical logic.
enum CalibrationArchiveCoder {

    static func encode(_ profiles: [CalibrationProfile], at date: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so the same profiles always produce the same bytes, which
        // makes a diff of a saved calibration meaningful.
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(CalibrationArchive(profiles: profiles, writtenAt: date))
        } catch {
            throw CalibrationStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Decodes and drops anything this build must not use.
    ///
    /// A profile whose own schema version does not match is discarded rather
    /// than migrated silently. There is no automatic migration path, and that
    /// is deliberate: a calibration is an empirical claim about a specific
    /// instrument, and a format change that alters what any field means
    /// invalidates the claim. Re-running the standards is the only correct
    /// answer, so the app asks for it instead of guessing.
    static func decode(_ data: Data) throws -> (profiles: [CalibrationProfile], discarded: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let archive: CalibrationArchive
        do {
            archive = try decoder.decode(CalibrationArchive.self, from: data)
        } catch {
            throw CalibrationStoreError.corruptData(error.localizedDescription)
        }

        guard archive.schemaVersion <= CalibrationArchive.currentSchemaVersion else {
            throw CalibrationStoreError.unsupportedSchema(
                found: archive.schemaVersion,
                supported: CalibrationArchive.currentSchemaVersion
            )
        }

        let usable = archive.profiles.filter {
            $0.schemaVersion == CalibrationProfile.currentSchemaVersion
        }
        return (usable, archive.profiles.count - usable.count)
    }
}

/// Stores calibrations as a single JSON file.
struct FileCalibrationStore: CalibrationStoring {
    let url: URL
    private let now: @Sendable () -> Date

    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// The app's own support directory, which is backed up and not visible to
    /// the user. A calibration is app state, not a user document.
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try fileManager.url(for: .applicationSupportDirectory,
                                            in: .userDomainMask,
                                            appropriateFor: nil,
                                            create: true)
        let folder = directory.appendingPathComponent("Turbid", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("calibrations.json")
    }

    func load() throws -> [CalibrationProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CalibrationStoreError.corruptData(error.localizedDescription)
        }

        let result = try CalibrationArchiveCoder.decode(data)
        if result.discarded > 0 {
            TurbidLog.calibration.notice(
                "Discarded \(result.discarded, privacy: .public) calibration profile(s) written in an older format."
            )
        }
        return result.profiles
    }

    func save(_ profiles: [CalibrationProfile]) throws {
        let data = try CalibrationArchiveCoder.encode(profiles, at: now())
        do {
            // Atomic, so a crash mid-write cannot leave a half-written file
            // that would read as a corrupt calibration.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CalibrationStoreError.writeFailed(error.localizedDescription)
        }
    }
}

/// In-memory store, for tests and for the Simulator.
final class InMemoryCalibrationStore: CalibrationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CalibrationProfile]
    /// Set to make the next `save` fail, so error handling can be exercised.
    var failNextSave = false

    init(profiles: [CalibrationProfile] = []) {
        storage = profiles
    }

    func load() throws -> [CalibrationProfile] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func save(_ profiles: [CalibrationProfile]) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextSave {
            failNextSave = false
            throw CalibrationStoreError.writeFailed("simulated failure")
        }
        storage = profiles
    }
}
