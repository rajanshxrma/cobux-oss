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
        PersonalWritingEntry.self, JournalAttachment.self
    ]

    static let appGroupID = "group.com.rajansharma.Cobux"

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
