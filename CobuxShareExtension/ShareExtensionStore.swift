import SwiftData

/// Opens the same App-Group `ModelContainer` the host app and `CaptureQuoteIntent` use —
/// factored out so `ShareViewController`/`ShareQuoteView` don't each carry their own copy of
/// the schema list. Delegates to `CobuxSchema` rather than hand-typing a model list here: this
/// used to declare only 5 of the app's 10 models, a real schema-drift hazard against a store
/// three other processes open with the full set.
enum ShareExtensionStore {
    static func makeContainer() -> ModelContainer? {
        CobuxSchema.makeAppGroupContainer()
    }
}
