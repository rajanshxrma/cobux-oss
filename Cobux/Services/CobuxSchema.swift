import Foundation
import SwiftData

/// The single source of truth for which SwiftData models exist in the shared
/// App-Group store. Before this, six different call sites (the main app,
/// `ShareExtensionStore`, `HighlightProvider`/widgets, and four App Intents)
/// each hand-typed their own schema list against the same underlying store,
/// and they'd drifted: the app declared 11 models, the rest declared only 5
/// (`Book, Highlight, Chapter, ChatMessage, Theme`) — `QuizAttempt` and
/// `QuizAnswerRecord` weren't even reachable via relationship closure from
/// that subset. Every process opening the identical store with a different
/// model list is a real migration/consistency hazard, not just duplication.
/// One shared list makes that drift structurally impossible going forward.
enum CobuxSchema {
    static let all: [any PersistentModel.Type] = [
        Book.self, Highlight.self, Chapter.self, ChatMessage.self, Theme.self, Figure.self,
        QuizQuestion.self, HighlightMemory.self, QuizAttempt.self, QuizAnswerRecord.self,
        PersonalWritingEntry.self, JournalAttachment.self, SituationThread.self,
        JournalKeep.self
    ]

    static let appGroupID = "group.com.rajansharma.Cobux"

    /// The App-Group `UserDefaults` suite, resolved in exactly one place.
    ///
    /// This exists because a setting stored in the wrong one of these two
    /// stores is invisible, not broken-looking, and that is precisely how the
    /// ambient-context toggle shipped dead: `@AppStorage` writes to
    /// `UserDefaults.standard` unless it is handed a store, while
    /// `AmbientContextService`/`AmbientContext.cached()` read the group suite.
    /// The flag was set in one store and read from the other, so turning it on
    /// did nothing, forever, with no error anywhere.
    ///
    /// Any value that more than one process must agree on -- the app, the Siri
    /// intent, the Messages extension, the widgets -- belongs here, and every
    /// side of it (including the `@AppStorage` that writes it) must name THIS
    /// property rather than re-opening the suite by literal.
    ///
    /// Computed, not stored: `UserDefaults(suiteName:)` is cheap and returns a
    /// shared instance, and a computed property is usable from any isolation
    /// (the same reason `BookSourceSharing` already writes it this way).
    /// Falls back to `.standard` only if the suite cannot be opened at all,
    /// which on a correctly-entitled build never happens.
    static var groupDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// Every process opening the shared App-Group store (the app itself, the Share
    /// Extension, widgets, App Intents) should build its container through this,
    /// not a hand-typed schema list.
    ///
    /// `cloudKitDatabase: .none` is load-bearing, not stylistic -- see
    /// `ModelContainerFactory`'s doc comment for the full story: the default
    /// `.automatic` silently turns on SwiftData-CloudKit mirroring for any
    /// process whose entitlements carry an iCloud container, and this schema
    /// (deliberately) fails CloudKit's every-attribute-needs-a-default rule,
    /// which crashed the app at launch for four straight builds.
    static func makeAppGroupContainer() -> ModelContainer? {
        try? ModelContainer(
            for: Schema(all),
            configurations: ModelConfiguration(
                schema: Schema(all),
                isStoredInMemoryOnly: false,
                groupContainer: .identifier(appGroupID),
                cloudKitDatabase: .none
            )
        )
    }
}
