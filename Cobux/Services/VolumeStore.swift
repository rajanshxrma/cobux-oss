import Foundation

/// Where bound volumes live: `Application Support/Volumes/` — the
/// `JournalDraftStore` root convention for regenerable artifacts. A volume
/// is a RENDERING of the journal, not the record: removable, re-bindable,
/// excluded from every backup so the concentrated artifact never rides a
/// cloud copy. The writing itself stays in the journal, untouchable.
enum VolumeStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Volumes", isDirectory: true)
    }

    private static let counterKey = "cobux.volumes.nextNumber"

    /// The next volume's numeral. Incremented only on a successful bind —
    /// printings, growth-only, never docked by a removal.
    static var nextNumber: Int {
        max(1, UserDefaults.standard.integer(forKey: counterKey) == 0
            ? 1 : UserDefaults.standard.integer(forKey: counterKey))
    }

    struct BoundVolume: Identifiable {
        let url: URL
        var id: URL { url }
        let name: String
        let boundDate: Date
    }

    @discardableResult
    static func save(pdf: Data, title: String, volumeNumber: Int) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The filename is content at the share boundary -- it names the book.
        let name = "Volume \(roman(volumeNumber)) · \(title).pdf"
        var url = directory.appendingPathComponent(name)
        try pdf.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        UserDefaults.standard.set(volumeNumber + 1, forKey: counterKey)
        return url
    }

    static func all() -> [BoundVolume] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension == "pdf" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return BoundVolume(url: url,
                                   name: url.deletingPathExtension().lastPathComponent,
                                   boundDate: date)
            }
            .sorted { $0.boundDate > $1.boundDate }
    }

    /// Removes the rendering. The writing itself stays in the journal.
    static func remove(_ volume: BoundVolume) {
        try? FileManager.default.removeItem(at: volume.url)
    }

    private static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                                      (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                      (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = max(1, n), out = ""
        for (value, glyph) in table {
            while n >= value { out += glyph; n -= value }
        }
        return out
    }
}
