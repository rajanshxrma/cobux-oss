import SwiftUI
import SwiftData

/// The private build seeds two hand-written medical-textbook chapters (Robbins & Cotran
/// Pathologic Basis of Disease, Sherris Medical Microbiology) authored from books the
/// developer owns -- real, copyrighted textbook content that can't be redistributed in a
/// public repo. Stubbed as a no-op here; the app builds and runs correctly with an empty
/// library on first launch (verified before publishing, not assumed). See this repo's
/// README "Content" section for how to add your own book content instead.
extension SeedData {
    static func seedMicrobiology(modelContext: ModelContext) {
        // No-op in the public repo.
    }
}
