import SwiftUI
import SwiftData

/// This is the open-source Cobux repo — the actual book content (highlights, chapter
/// summaries) that ships in the private/production build lives in a separate, non-public
/// file and is intentionally not included here, since it's derived from commercially
/// published books. `seedMicrobiology`/`seedRobbins` are stubbed as no-ops so the app
/// still builds and runs cleanly with an empty library on first launch — see the README
/// for `SeedBookDocument`'s JSON schema (`SeedLoader.swift`) if you want to author and
/// bundle your own book content, including public-domain titles.
struct SeedData {
    static func seedMicrobiology(modelContext: ModelContext) {
        // No-op in the public repo -- see the doc comment above.
    }
}
