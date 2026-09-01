import Foundation

/// Crash-safe drafts for `JournalEntryComposeView`.
///
/// Exists because of two real losses in one week (his own entries): *"Bruh my
/// fucking journal entry didn't get saved"* (26 Aug) and *"Cobux crashed mid
/// journal writing"* (28 Aug). Compose keeps everything in `@State` until
/// Save -- correct for Cancel semantics, but it means a crash mid-write takes
/// the whole session with it. This store is the middle ground: the editor's
/// live contents are mirrored to a small JSON file as the user types, the
/// file is deleted on BOTH Save (committed) and Cancel (explicitly
/// discarded), so the only way a draft survives is the app dying mid-write --
/// exactly the case where the next compose open should silently pick the text
/// back up.
///
/// One draft per target: a brand-new entry drafts under `"new"`, continuing
/// an existing entry drafts under that entry's UUID. Deliberately files in
/// Application Support (like `CrashReportCollector`/`DiagnosticLog`), not
/// UserDefaults: an entry can be many KB of prose, and defaults are neither
/// meant for that nor safely enumerable for cleanup.
enum JournalDraftStore {
    struct Draft: Codable {
        var entryID: UUID?
        var title: String
        var text: String
        var updated: Date
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JournalDrafts", isDirectory: true)
    }

    private static func fileURL(entryID: UUID?) -> URL {
        directory.appendingPathComponent("draft-\(entryID?.uuidString ?? "new").json")
    }

    /// Throttle: at most one disk write per interval per draft. A keystroke
    /// costs nothing; the write only happens when the last one is stale, so a
    /// crash loses at most this many seconds of typing.
    private static let writeInterval: TimeInterval = 2
    private static var lastWrite: [String: Date] = [:]

    static func save(entryID: UUID?, title: String, text: String) {
        let key = entryID?.uuidString ?? "new"
        if let last = lastWrite[key], Date.now.timeIntervalSince(last) < writeInterval { return }
        lastWrite[key] = .now

        let draft = Draft(entryID: entryID, title: title, text: text, updated: .now)
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(entryID: entryID), options: .atomic)
    }

    static func load(entryID: UUID?) -> Draft? {
        guard let data = try? Data(contentsOf: fileURL(entryID: entryID)) else { return nil }
        return try? JSONDecoder().decode(Draft.self, from: data)
    }

    static func clear(entryID: UUID?) {
        lastWrite[entryID?.uuidString ?? "new"] = nil
        try? FileManager.default.removeItem(at: fileURL(entryID: entryID))
    }
}
