import Foundation

/// Small `Codable` sidecar to the real (multi-MB) backup snapshot files --
/// shared by `AutoBackupService` (writes it) and `AutoRestoreService`/Settings
/// (read it) so the two can't disagree on the naming/counting scheme, same
/// anti-drift reasoning `CobuxSchema` already established for the model list.
/// Cheap enough that a restore or a Settings screen can check "is there
/// anything worth downloading" without ever touching the big file.
struct BackupSnapshotManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, latestFilename, latestDigest, latestDate, bookCount
        case personalWritingEntryCount, attachmentsPending, personCount
    }

    var schemaVersion: Int
    var latestFilename: String
    var latestDigest: String
    var latestDate: Date
    var bookCount: Int
    var personalWritingEntryCount: Int
    /// How many sidecar attachment files this run still hadn't gotten to
    /// copying (see `AutoBackupService`'s per-run cap) -- lets a resumable
    /// pass know there's more to do without re-scanning every entry.
    var attachmentsPending: Int
    /// `JournalPerson` rows in the snapshot (People, build 62). Defaulted so
    /// a manifest written before the field existed still decodes, and so the
    /// writer that predates it still compiles until it passes the count.
    var personCount: Int = 0

    private static let filename = "manifest.json"

    static func read(from directory: URL) -> BackupSnapshotManifest? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupSnapshotManifest.self, from: data)
    }

    func write(to directory: URL) {
        let url = directory.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// In an extension, not the struct body, so the memberwise initialiser
/// `AutoBackupService` builds the manifest with survives.
extension BackupSnapshotManifest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        latestFilename = try container.decode(String.self, forKey: .latestFilename)
        latestDigest = try container.decode(String.self, forKey: .latestDigest)
        latestDate = try container.decode(Date.self, forKey: .latestDate)
        bookCount = try container.decode(Int.self, forKey: .bookCount)
        personalWritingEntryCount = try container.decode(Int.self, forKey: .personalWritingEntryCount)
        attachmentsPending = try container.decode(Int.self, forKey: .attachmentsPending)
        personCount = try container.decodeIfPresent(Int.self, forKey: .personCount) ?? 0
    }
}
