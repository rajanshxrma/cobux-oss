import XCTest
@testable import Cobux

/// Regression coverage for the day-to-day Flow repetition fix (2.5.9): a
/// highlight shown recently should be excluded from `recentIDs()`, one
/// outside the window should not, and the persisted payload should stay
/// bounded. `key` mirrors `FlowRecentlyShownStore`'s own private storage key
/// exactly — keep the two in sync if that literal ever changes.
final class FlowRecentlyShownStoreTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let key = "cobux.flow.recentlyShownHighlights"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: key)
    }

    override func tearDown() {
        defaults.removeObject(forKey: key)
        super.tearDown()
    }

    func testRecordedHighlightIsRecent() {
        let id = UUID()
        FlowRecentlyShownStore.recordShown(id)
        XCTAssertTrue(FlowRecentlyShownStore.recentIDs().contains(id))
    }

    func testEntryOutsideThreeDayWindowIsNotRecent() {
        let id = UUID()
        let fourDaysAgo = Date.now.addingTimeInterval(-4 * 24 * 60 * 60).timeIntervalSince1970
        defaults.set([id.uuidString: fourDaysAgo], forKey: key)

        XCTAssertFalse(FlowRecentlyShownStore.recentIDs().contains(id))
    }

    func testEntryWithinThreeDayWindowIsRecent() {
        let id = UUID()
        let oneDayAgo = Date.now.addingTimeInterval(-1 * 24 * 60 * 60).timeIntervalSince1970
        defaults.set([id.uuidString: oneDayAgo], forKey: key)

        XCTAssertTrue(FlowRecentlyShownStore.recentIDs().contains(id))
    }

    func testPersistedEntriesStayBoundedAtMaxEntries() {
        // maxEntries is 300 (private constant) -- keep in sync if it changes.
        for _ in 0..<305 {
            FlowRecentlyShownStore.recordShown(UUID())
        }
        let raw = defaults.dictionary(forKey: key) ?? [:]
        XCTAssertLessThanOrEqual(raw.count, 300)
    }

    func testOverflowEvictsOldestEntryFirst() {
        let oldest = UUID()
        defaults.set([oldest.uuidString: Date.now.addingTimeInterval(-60).timeIntervalSince1970], forKey: key)

        for _ in 0..<300 {
            FlowRecentlyShownStore.recordShown(UUID())
        }

        XCTAssertFalse(FlowRecentlyShownStore.recentIDs().contains(oldest), "the oldest entry should be evicted once the store overflows its cap")
    }
}
