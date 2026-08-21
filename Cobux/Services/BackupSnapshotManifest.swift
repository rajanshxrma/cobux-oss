import Foundation

/// Small `Codable` sidecar to the real (multi-MB) backup snapshot files --
/// shared by `AutoBackupService` (writes it) and `AutoRestoreService`/Settings
/// (read it) so the two can't disagree on the naming/counting scheme, same
/// anti-drift reasoning `CobuxSchema` already established for the model list.
/// Cheap enough that a restore or a Settings screen can check "is there
/// anything worth downloading" without ever touching the big file.
struct BackupSnapshotManifest: Codable {
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
