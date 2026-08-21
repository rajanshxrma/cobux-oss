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
        components.day = 20
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
            version: "2.5.13",
            build: "26",
            date: "Aug 20, 2026",
            changes: [
                "New: Cobux now backs up your whole library to iCloud automatically -- three rotating snapshots, private to your account, restored silently if you ever reinstall. A manual restore option is in Settings too",
                "Fixed a real gap: restoring a backup onto a phone that already had its books seeded used to skip them entirely, silently dropping quiz progress and notes on restore. Now it merges in properly",
                "Journal has a new look: entries are grouped by day, photos get a proper card treatment, and the writing itself reads in a warmer serif face",
                "A handful of quieter fixes: smoother widget resonance cards, less redundant background syncing, and a couple of small efficiency cleanups"
            ]
        ),
        ChangelogEntry(
            version: "2.5.12",
            build: "25",
            date: "Aug 20, 2026",
            changes: [
                "Journal entries now back themselves up to iCloud automatically in the background, once a day -- silent, no setup needed",
                "Moved the home screen widget's shuffle button to the bottom, easier to reach one-handed"
            ]
        ),
        ChangelogEntry(
            version: "2.5.11",
            build: "24",
            date: "Aug 19, 2026",
            changes: [
                "New: Smart Timing for Wisdom Reminders -- learns when you actually open Cobux and sends reminders around those hours instead of a fixed time you set by hand",
                "Chat replies now better match the length and shape of what you actually asked -- a quick question gets a quick answer, and replies no longer end with a reflexive \u{201C}let me know if you have questions\u{201D}",
                "Added 7 new books: Pushing to the Front, The Science of Getting Rich, Acres of Diamonds, The Game of Life and How to Play It, Self-Help, The Art of Money Getting, and A Message to Garcia"
            ]
        ),
        ChangelogEntry(
            version: "2.5.10",
            build: "23",
            date: "Aug 19, 2026",
            changes: [
                "Flow: Go Deeper and Share no longer disappear on highlights that haven't been filed to a book yet",
                "Flow: book/chapter now shows above the quote instead of below it",
                "Flow now shows its own name at the top of the page",
                "Flow: highlights should feel less repetitive day to day -- the feed now favors ones it hasn't shown recently",
                "Moved the Journal compose button to a floating button at the bottom-right, easier to reach one-handed"
            ]
        ),
        ChangelogEntry(
            version: "2.5.9",
            build: "22",
            date: "Aug 18, 2026",
            changes: [
                "Opening Cobux (which opens straight to Flow) now earns your streak on its own -- quiz and highlights still count too, just no longer the only way",
                "Added a Chat button to the bottom of Flow, so there's always a clear way from a highlight into a full conversation about it",
                "Quiz's per-book \u{201C}N due\u{201D} badge is no longer styled as a warning -- reworded to \u{201C}N to review\u{201D} with a calmer color",
                "Moved the Voice Mode button from the top-right toolbar to right next to the chat text field, matching the mic-where-send-goes convention",
                "Voice Mode's live captions now reveal sentence by sentence with a smooth animation, instead of one block of text that silently grows"
            ]
        ),
        ChangelogEntry(
            version: "2.5.8",
            build: "21",
            date: "Aug 18, 2026",
            changes: [
                "Fixed the \u{201C}two books, one idea\u{201D} resonance card in Flow never offering Go Deeper or Share on either highlight, unlike every other card in the feed"
            ]
        ),
        ChangelogEntry(
            version: "2.5.7",
            build: "20",
            date: "Aug 18, 2026",
            changes: [
                "New: share a highlight — from Flow or the home screen widget (medium/large), send a quote to anyone. If they have Cobux, opening it jumps straight to that exact highlight"
            ]
        ),
        ChangelogEntry(
            version: "2.5.6",
            build: "19",
            date: "Aug 18, 2026",
            changes: [
                "Fixed book covers not showing for anyone who'd already updated past the version that bundled them — a naming mismatch meant every bundled cover silently failed to load and fell back to a blank gradient instead of the old remote fetch",
                "New: Journal now shows a streak — separate from your main streak, just for days you've actually written",
                "New: attach photos to a journal entry — add up to 10 from your library, shown right in the entry, and included in backup/restore",
                "Journal's Face ID lock now actually covers reading and continuing an old entry, not just the list — backgrounding mid-entry used to leave it fully visible with no prompt at all",
                "Fixed the journal editor's cursor/keyboard focus not always landing reliably, and blocked saving an entry with nothing actually written in it",
                "Home screen widget now rotates through your books far more evenly — it was effectively always showing whatever book you're currently highlighting in",
                "Flow now opens automatically when you open Cobux, instead of needing a tap on the Wisdom tab first",
                "Fixed the Apple Journal importer risking a crash on real exports, taking the export/uncompress date instead of the entry's real date, and under-counting duplicates on a repeat import",
                "Fixed a small diagnostic log silently writing nothing on a fresh install, and crash-report cleanup deleting the newest old reports instead of the oldest"
            ]
        ),
        ChangelogEntry(
            version: "2.5.5",
            build: "18",
            date: "Aug 18, 2026",
            changes: [
                "Journal: a new entry now starts with the current time already on the first line, cursor ready on the line under it",
                "Journal: opening an old entry to add more now works like a real notebook — Continue Entry appends a fresh timestamp to the end and drops you right under it, instead of dropping you back wherever the text last ended"
            ]
        ),
        ChangelogEntry(
            version: "2.5.4",
            build: "17",
            date: "Aug 16, 2026",
            changes: [
                "All 26 built-in books now show a real cover — bundled directly in the app instead of fetched from three different websites, so covers load instantly and never break if one of those sites changes something. Fixed two that were quietly broken this whole time (As a Man Thinketh had no cover at all; The Denial of Death showed a tiny, blurry placeholder)",
                "New: Journal — write entries right in Cobux (More > Journal), searchable, and usable in chat the same way your book highlights already are. Locked behind Face ID by default (Settings has a toggle to turn that off)",
                "New: a one-time importer for anyone with existing entries in Apple's own Journal app — export from Journal, uncompress in Files, then Import from Apple Journal in Settings",
                "Crash reports now say which build they're from, and separate ones from your current build from older ones you've already moved past",
                "Added a small local diagnostic log (visible in Diagnostics under More, in debug builds) so a hang or a stuck screen leaves real evidence behind, not just a crash"
            ]
        ),
        ChangelogEntry(
            version: "2.5.3",
            build: "16",
            date: "Aug 13, 2026",
            changes: [
                "Much faster tab switching — the Wisdom and Quiz tabs were recalculating every count on screen dozens of times each time you opened them, which is why they took a moment to appear on a large library. Same numbers, worked out once",
                "\"Include All Books\" and the all-books-off warning now sit at the top of Flow and Wisdom Sources, instead of below every book in your library",
                "Life examples in chat now use real names by default — turn it off in Settings to go back to roles only (\"a friend\", \"someone you wrote about\")",
                "Fixed the What's New sheet being able to skip the very update it was written for, if the library sync was still finishing at launch"
            ]
        ),
        ChangelogEntry(
            version: "2.5.2",
            build: "15",
            date: "Aug 13, 2026",
            changes: [
                "Closed a couple more of the same class of crash risk fixed in 2.5.1, before they had a chance to show up",
                "The update-ready and What's New pop-ups could occasionally hide one another right after an update — now they always both show, in order",
                "The update-available banner now slides away smoothly when dismissed",
                "Fixed a widget-graded quiz card occasionally not saving, and the app now notices right away when a card is graded from the widget",
                "Fixed a Wisdom Graph screen not always refreshing after Unsorted highlights changed",
                "Onboarding now tells you clearly if your API key couldn't be saved, instead of silently continuing",
                "Rebuilding the Wisdom Graph or regenerating quiz questions now shows a real error if something goes wrong, instead of reporting success either way"
            ]
        ),
        ChangelogEntry(
            version: "2.5.1",
            build: "14",
            date: "Aug 13, 2026",
            changes: [
                "Fixed a launch crash — a much larger content update (10 new books) widened a rare timing bug into a reliable one, so the app could fail to open at all",
                "The 10 public-domain books added recently now show their real covers in the library instead of a plain color block"
            ]
        ),
        ChangelogEntry(
            version: "2.5.0",
            build: "13",
            date: "Aug 13, 2026",
            changes: [
                "Cobux now tells you right in the app when a new TestFlight build is ready, instead of relying only on Apple's email or push notification — a small banner appears with a tap-through straight to TestFlight",
                "After updating, a What's New sheet shows exactly what changed in the build you just installed"
            ]
        ),
        ChangelogEntry(
            version: "2.4.0",
            build: "12",
            date: "Aug 12, 2026",
            changes: [
                "New: 10 public-domain classics added to the library — Epictetus's Enchiridion, Seneca's On the Shortness of Life, Thoreau's Walden, both volumes of Emerson's Essays, Arnold Bennett's How to Live on 24 Hours a Day and The Human Machine, La Rochefoucauld's Reflections and Moral Maxims, Bacon's Essays, and a curated selection from Montaigne's Essays",
                "Fixed a rare crash opening Library search, Quiz, or Chat during the first-launch or upgrade content sync",
                "Fixed the Watch face showing fake example numbers (streak, due cards) before your first real sync",
                "Fixed widget colors sometimes rendering wrong in light or dark mode",
                "Fixed a silent failure where a bad API key save or remove in Settings looked like it worked when it hadn't",
                "Fixed the chat Stop button occasionally getting stuck if you switched threads mid-reply",
                "Fixed onboarding icons clipping at larger accessibility text sizes",
                "Fixed duplicate highlights that could appear after a content update",
                "Fixed the streak occasionally over-crediting after a timezone change or clock adjustment",
                "Removed the personal Goodreads-sync section — this app is for everyone now",
                "Added a way to keep Flow and the Wisdom graph focused on the books you actually want them drawing from",
                "Various smaller crash and reliability fixes throughout Quiz, Library, Notifications, and the widgets"
            ]
        ),
        ChangelogEntry(
            version: "2.3.0",
            build: "11",
            date: "Aug 8, 2026",
            changes: [
                "New: Flow — a full-screen, swipeable feed of your own library, opened from the big card on the Wisdom tab. Quotes, chapter lessons, quick self-checks (which feed your real review schedule), weak-topic callouts, and book progress, endlessly",
                "New: Quick Check widget — one due quiz card straight on your home screen. Tap Reveal, grade it with Got it / Missed (a real review, scheduled exactly like in-app ones, and it counts for your streak), and the next card slides in. An optional app-icon badge shows how many cards are waiting",
                "Chat can now draw on your imported personal writing as brief lived examples woven into an answer where one genuinely fits — people from your journals are referred to only by role, never by name, unless you explicitly enable real names in Settings",
                "Your streak can now survive a missed day — every 7 straight active days banks a streak freeze (up to 2) that's spent automatically when you miss, and 7/30/100/365-day milestones get a proper celebration",
                "Two new optional nudges: an evening heads-up when today would break a streak of 3+, and a 9 AM note on days you have cards waiting (toggle in Reminders). Delivered quietly — no permission popup if you never opted into notifications",
                "Finishing a quiz session now actually feels like finishing — confetti, and callouts when you set a new personal best day or week",
                "The home screen widget grew back/forward arrows, so you can return to a quote after shuffling past it (they only appear when there's somewhere to go)",
                "Fixed the chat thread picker showing almost every book under \"Other\" — books added before categories existed now pick up their category automatically",
                "Onboarding now asks what brings you to Cobux (exam prep, remembering what you read, or building a daily habit) and tunes its framing to match — changeable anytime in Settings, and every choice keeps the full feature set",
                "Fixed a launch-window crash that could hit devices upgrading a large library (especially with an Apple Watch paired) — the app no longer reads the library while the background upgrade is mid-write, and the Quiz tab shows a brief sync screen instead of racing it",
                "Voice Mode and Spoken Quiz no longer crash if the microphone is taken away mid-session (phone call, Siri, Bluetooth switch) — they now end the turn gracefully",
                "Big memory diet on older devices: chat figures now decode at display size, and the widgets read far less data. If the app ever does crash, it now captures its own diagnostic report — it appears in Settings so you can share it straight to the developer"
            ]
        ),
        ChangelogEntry(
            version: "2.2.2",
            build: "10",
            date: "Aug 8, 2026",
            changes: [
                "The home screen widget is now interactive — tap the small shuffle icon to see a different quote or highlight right on the widget, without opening the app. Tapping the rest of the widget still opens the specific book it's from",
                "Modernized the app icon with real depth (a gradient and a soft highlight) instead of a flat single color background",
                "Simplified the Quiz tab down to one clear recommended action instead of six-plus equally-weighted options, with your streak shown right at the top — every mode and book is still there, just easier to find your way into",
                "Added a way to suggest a book you'd like to see in Cobux from Settings"
            ]
        ),
        ChangelogEntry(
            version: "2.2.1",
            build: "9",
            date: "Aug 8, 2026",
            changes: [
                "Chat can now show a real diagram or photo from a book alongside its reply, when one from the chapter you're asking about actually exists — the same figures used in Figure ID quizzes",
                "The chat thread picker now groups your library into categories (Medical Reference, Psychology & Self-Development, Philosophy, and more) instead of one long alphabetical list — search still works the same as before",
                "Added the ability to import your own personal writing (journal entries, reflections) so chat can draw on them the same way it already cites book highlights — off by default in the sense that nothing is imported until you choose to, with a visible toggle and a way to delete everything you've imported",
                "Fixed chat, quiz generation, and Goodreads sync waiting up to two minutes before showing an error when you're offline — they now fail immediately with a clear message instead"
            ]
        ),
        ChangelogEntry(
            version: "2.2.0",
            build: "8",
            date: "Aug 8, 2026",
            changes: [
                "Started a visual refresh toward Liquid Glass — the status banners at the bottom of the screen, and the progress/answer bar during a quiz, now float as glass panels instead of sitting flush with the background",
                "Redesigned Settings and the More tab with a consistent type scale and icon-badged rows instead of default system list styling — the More tab is now grouped into Progress/Library instead of one flat list",
                "Includes everything from build 7"
            ]
        ),
        ChangelogEntry(
            version: "2.1.0",
            build: "7",
            date: "Aug 7, 2026",
            changes: [
                "Fixed the iPhone widget not actually opening the book its quote came from when tapped — a real device report caught a race condition build 6 missed",
                "Fixed chat not actually resuming your last-read position in the common case (switching tabs and coming back) — build 6's fix only worked in a narrower case than intended",
                "Made the Voice Mode button in chat actually stand out — it was easy to miss despite being a real feature"
            ]
        ),
        ChangelogEntry(
            version: "2.1.0",
            build: "6",
            date: "Aug 7, 2026",
            changes: [
                "Fixed the app crashing shortly after launch",
                "Fixed chat crashing on every message for some users",
                "Fixed on-device cloze quiz questions being graded against the wrong answer most of the time — this could show as an incorrect answer counting as correct or vice versa",
                "Quiz generation no longer gives up on an entire chapter batch the moment one chapter hits a network error — it retries automatically and reports exactly which chapters (if any) still need a manual retry",
                "The iPhone widget now opens directly to the book its quote is from, instead of a generic chat screen",
                "The Apple Watch complication now actually opens the app when tapped",
                "Fixed the Apple Watch showing \"0\" for streak and due count with no way to tell whether that's real or just never synced — it now shows a clear un-synced state instead, and syncs correctly on a normal app launch",
                "Chat now resumes where you last left off in a thread instead of always reopening at the top",
                "Several additional crash-risk fixes across quiz sessions, on-device search, and backup import"
            ]
        ),
        ChangelogEntry(
            version: "2.1.0",
            build: "5",
            date: "Aug 6, 2026",
            changes: [
                "Added Figure ID, a new quiz mode that shows a real diagram or clinical photo from the medical textbooks and asks you to identify it — 1,597 real figures across Robbins and Microbiology, each captioned and mapped to its real chapter"
            ]
        ),
        ChangelogEntry(
            version: "2.1.0",
            build: "4",
            date: "Aug 6, 2026",
            changes: [
                "Fixed a data bug where a book's chapter list could show only one chapter instead of all of them",
                "Fixed a latent bug where a generated quiz question could attach to the wrong highlight"
            ]
        ),
        ChangelogEntry(
            version: "2.1.0",
            build: "3",
            date: "Aug 6, 2026",
            changes: [
                "Added a voice picker to Settings so Voice Mode can use a higher-quality system voice instead of always the default",
                "Fixed Spoken Quiz sessions not updating your daily streak or the Watch complication"
            ]
        ),
        ChangelogEntry(
            version: "2.1.0",
            build: "2",
            date: "Aug 6, 2026",
            changes: [
                "Fixed the first chat message (or the first message after leaving the app idle for a few minutes) sometimes timing out entirely instead of replying"
            ]
        ),
        ChangelogEntry(
            version: "2.1.0",
            build: "1",
            date: "Aug 6, 2026",
            changes: [
                "Added Voice Mode — tap the mic in any chat thread to talk hands-free. Cobux listens, transcribes, and speaks its answer back as it streams in, sentence by sentence, instead of waiting for the whole reply. Text chat is still there too — voice is additive, not a replacement",
                "Added an Apple Watch companion — your streak, due-review count, and a featured quote as watch face complications, plus a small glanceable app. Read-only: nothing to review or grade on the watch, just a nudge to open your phone",
                "Added a Share Extension — capture a quote from Kindle, Books, Safari, or anywhere else that shares text, straight into Cobux. Files it to a book, or leaves it in a new \"Unsorted\" list until you do",
                "Added four new ways to practice from the Quiz tab: Rapid Recall (a short review-only top-up), Discrimination Drills (questions you tend to confuse, pulled from what you've actually gotten wrong), Chapter Cram (pick any chapter across any book and drill it directly), and Weak Spots (targeted practice on your lowest-retention topics) — plus Spoken Quiz, an eyes-free mode that reads questions aloud and grades your spoken answer",
                "Fixed Daily Review never actually surfacing newly generated questions — including every free on-device cloze card — so it only ever showed pre-existing progress",
                "Fixed quiz progress (spaced-repetition scheduling state) being silently lost when a chapter's questions regenerated, with no way to recover it — now included in backup/restore",
                "Fixed Exam Countdown's date cap not applying to cards reviewed through Daily Review",
                "Fixed the per-book due-review counts on the Quiz tab sometimes disagreeing with Daily Review's count for the same book",
                "Replaced open-ended question self-grading (\"did you get it right?\") with real grading — your typed or spoken answer is now compared against the reference answer automatically",
                "Added a one-tap backup prompt the first time you open the app after this update, since it changes how quiz progress is stored",
                "Added a mastery view and a weakest-topics view to Quiz Analytics",
                "Fixed the book picker in Chat not scrolling reliably once your library grows past about 15 books — it's a proper searchable list now",
                "Finished applying the visual design refresh from 2.0.0 to the Quiz tab and a few remaining screens that were missed the first time",
                "Extended each book's own accent color into its chat thread and quiz sessions, not just its library page",
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
