import Foundation

/// SwiftData doesn't propagate a cross-process write to a running app's `@Query` — a save made
/// by the Share Extension or `CaptureQuoteIntent` (each its own sandboxed process) is invisible
/// to a `LibraryView`/`ChatView` already on screen in the host app until something tells it to
/// refetch. This is that something: a shared App Group flag the writer sets and the app checks
/// on `scenePhase == .active`, alongside the existing `WidgetCenter.reloadAllTimelines()` (which
/// only refreshes the widget's own timeline, not the host app's in-memory `@Query` results).
enum CrossProcessSync {
    private static let defaults = UserDefaults(suiteName: "group.com.rajansharma.Cobux") ?? .standard
    private static let dirtyKey = "cobux.crossProcessSync.dirty"

    /// Call from any process other than the main app after a store write it needs the main
    /// app to notice (the Share Extension, `CaptureQuoteIntent`).
    static func markDirty() {
        defaults.set(true, forKey: dirtyKey)
    }

    /// Call from the main app when it becomes active. Returns whether a refetch is actually
    /// needed — clears the flag either way, so a later call without an intervening write is a
    /// cheap no-op rather than refetching every single foreground.
    @discardableResult
    static func consumeDirtyFlag() -> Bool {
        let wasDirty = defaults.bool(forKey: dirtyKey)
        if wasDirty {
            defaults.set(false, forKey: dirtyKey)
        }
        return wasDirty
    }
}
