import Foundation

/// TestFlight builds always expire 90 days after Apple processes the upload —
/// a hard platform rule with no override (see the "why does the app expire"
/// conversation this ships from). iOS doesn't expose that upload timestamp to
/// the app itself, so it's tracked by hand here instead: update `uploadDate`
/// to today whenever a new build is archived and uploaded to App Store
/// Connect (part of the same release checklist as bumping the version
/// number). As long as a new build goes out within any 90-day window,
/// access never actually lapses — this is just visibility into that clock.
enum BuildInfo {
    /// Set this to the actual date of the most recent TestFlight upload,
    /// every time a new build ships.
    static let uploadDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 6
        return Calendar.current.date(from: components) ?? .now
    }()

    private static let expiryWindowDays = 90

    static var daysUntilExpiry: Int {
        let daysSinceUpload = Calendar.current.dateComponents([.day], from: uploadDate, to: .now).day ?? 0
        return max(0, expiryWindowDays - daysSinceUpload)
    }

    /// Hand-maintained release notes, newest first — same discipline as
    /// `uploadDate`: add one entry here as part of shipping each new build,
    /// so testers can actually see what changed instead of guessing.
    static let changelog: [ChangelogEntry] = [
        ChangelogEntry(
            version: "2.1.0",
            build: "1",
            date: "Aug 6, 2026",
            changes: [
                "Added Voice Mode — tap the mic in any chat thread to talk hands-free. Cobux listens, transcribes, and speaks its answer back as it streams in, sentence by sentence, instead of waiting for the whole reply. Text chat is still there too — voice is additive, not a replacement",
                "Added an Apple Watch companion — your streak, due-review count, and a featured quote as watch face complications, plus a small glanceable app. Read-only: nothing to review or grade on the watch, just a nudge to open your phone",
                "Added a Share Extension — capture a quote from Kindle, Books, Safari, or anywhere else that shares text, straight into Cobux. Files it to a book, or leaves it in a new \"Unsorted\" list until you do",
                "Updated the app icon to match the design refreshed in 2.0.0"
            ]
        ),
        ChangelogEntry(
            version: "2.0.1",
            build: "2",
            date: "Aug 5, 2026",
            changes: [
                "Fixed the 8 new books listed in 2.0.0's release notes not actually appearing in your library — a resource-bundling bug meant every book added as JSON silently failed to load on real devices",
                "Fixed the accent color across the app (tab bar, buttons, highlights) not matching the new design — some places were still using the old system color instead of the real brand accent",
                "Fixed Daily Review not showing any of your pre-2.0.0 quiz progress until you'd already re-quizzed it elsewhere first — existing progress now migrates on launch instead of only when a question happens to be individually reviewed",
                "Updated the app icon to the new design",
                "Corrected 2.0.0's release notes — Daily Review and Exam Countdown are the two quiz modes that actually shipped; the other five named alongside them weren't built and have been removed from this list"
            ]
        ),
        ChangelogEntry(
            version: "2.0.0",
            build: "1",
            date: "Aug 5, 2026",
            changes: [
                "Rebuilt quiz scheduling on FSRS-6 (the current Anki default) instead of simple Leitner boxes — smarter, more accurate review timing, with your existing progress carried over automatically",
                "Added free, on-device question generation (no API key or cost) — thousands more cards than before, especially for the two medical textbooks",
                "Added Daily Review (a home queue spanning every book's due cards) and Exam Countdown (set a date, reviews compress automatically so nothing's scheduled past it)",
                "Added an analytics dashboard — retention rate, review forecast, attempt history, and a running spend estimate",
                "Fixed quiz grading bugs: exam-mode application questions always marked wrong, choices never shuffled, timer could gift free time when backgrounded, unanswered questions didn't count against your score",
                "Fixed citation chips sometimes naming the wrong book — the model now declares its own sources instead of it being inferred",
                "Fixed a bug where a single chapter-title typo could silently hide every highlight in that chapter from search and citations",
                "Fixed navigation: tapping the current tab again now returns to its top instead of doing nothing, and More resets when you leave it",
                "New visual design system with real light/dark support and per-book accent color throughout",
                "Added a \"Question Quality\" setting to trade off quiz generation cost vs. depth, plus a background generation option that's roughly half the cost of generating on demand",
                "Added a real COBUX wordmark, book-specific chat suggestions, unified empty states, and a progress indicator during first-launch setup",
                "Added 8 new books to the built-in library",
                "Countless smaller fixes and polish across Library, Wisdom, Chat, and Quiz"
            ]
        ),
        ChangelogEntry(
            version: "1.2.0",
            build: "7",
            date: "Jul 24, 2026",
            changes: [
                "Exam Simulation quizzes now show a Live Activity — countdown and progress right on the Lock Screen and Dynamic Island, no need to keep the app open",
                "The Lock Screen circular widget now shows your daily streak (flame + count) instead of a generic icon"
            ]
        ),
        ChangelogEntry(
            version: "1.2.0",
            build: "5",
            date: "Jul 24, 2026",
            changes: [
                "Wisdom Graph's AI tag merging now runs on Apple's on-device model when your phone supports it — completely free, private, and no API key needed (older devices fall back to the existing Claude-based merge automatically)"
            ]
        ),
        ChangelogEntry(
            version: "1.2.0",
            build: "4",
            date: "Jul 24, 2026",
            changes: [
                "Added haptic feedback throughout the app — saving highlights/chapters, marking a chapter complete, and quiz answer results",
                "Added a daily streak — adding a highlight or finishing a quiz keeps it going, shown in the More tab",
                "Added manual backup/restore in Settings — export your books, chapters, and highlights to a file, restore them later on any device"
            ]
        ),
        ChangelogEntry(
            version: "1.2.0",
            build: "3",
            date: "Jul 24, 2026",
            changes: [
                "Added a Quiz tab — test yourself chapter-by-chapter, by topic, or across a whole book",
                "Exam Simulation mode (single timer, no going back) for the medical textbooks; Practice mode for everything else",
                "Quiz questions are generated once per chapter and cached — re-quizzing the same chapter is free",
                "Added spaced repetition: wrong or low-confidence answers resurface in a Review Queue",
                "Results screen breaks down performance by question type and flags what needs review"
            ]
        ),
        ChangelogEntry(
            version: "1.2.0",
            build: "2",
            date: "Jul 23, 2026",
            changes: [
                "Added persistent, per-book chat threads (tap the title bar to switch)",
                "Fixed the two medical textbooks going invisible to chat when semantic matching failed",
                "Added a search bar to the Wisdom Graph tab",
                "Removed a confusing 'future paid upgrade' info card from Wisdom Graph",
                "Moved Goodreads, Reminders, and Settings into a consolidated More tab",
                "Added a TestFlight renewal countdown to Settings",
                "Added an explanation the first time you try Symposium Mode",
                "Fixed chat not scrolling to a reply that finished while you were on another tab",
                "Added optional AI tag merging to Wisdom Graph (cached, only charges once per tag set)",
                "Added a chapter-by-chapter reading progress tracker to each book",
                "Fixed double-quoted highlight text and hard-to-read italics on long passages",
                "Added this changelog"
            ]
        ),
        ChangelogEntry(
            version: "1.2.0",
            build: "1",
            date: "Jul 23, 2026",
            changes: [
                "Both full medical textbooks (Essentials of Medical Microbiology, Robbins & Cotran Pathologic Basis of Disease) now fully loaded",
                "Fixed a freeze on first launch",
                "Fixed a slow-UI period right after installing",
                "Added real cover art for both new textbooks"
            ]
        )
    ]
}

struct ChangelogEntry: Identifiable {
    var id: String { version + build }
    let version: String
    let build: String
    let date: String
    let changes: [String]
}
