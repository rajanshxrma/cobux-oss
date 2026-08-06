import Foundation

/// Broadcasts first-launch seeding progress to the UI. Before this, a fresh
/// install ran `CobuxApp.seedDatabase` entirely invisibly on a background
/// context while the user was already looking at `LibraryView`'s empty
/// state -- indistinguishable from "this app has nothing in it," when what
/// was actually true was "give it a few seconds, ~1,300 highlights across
/// two medical textbooks are still being written." Scoped to the seed pass
/// itself (books/chapters/highlights landing), not the slower embeddings
/// backfill that continues after -- that part degrades gracefully to
/// keyword search already, so it doesn't need to block "ready."
@MainActor
@Observable
final class SeedingStatus {
    static let shared = SeedingStatus()
    private init() {}

    var isSeeding = false
    var message = "Setting up your library…"
}
