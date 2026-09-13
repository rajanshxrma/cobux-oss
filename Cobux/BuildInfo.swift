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
        components.month = 9
        components.day = 13
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
            version: "3.3.0",
            build: "60",
            date: "Sep 13, 2026",
            changes: [
                "Flow opens in place, no slide. The first card is already there when you tap",
                "The other tabs are built before you reach them, so a switch is a switch",
                "The warm red-black room is on every tab in the dark, and a Crimson appearance in Settings wears it on a light phone too",
                "The icon and the COBUX wordmark carry a light tint of red",
                "Go Deeper sets the same thought beside a line from another tradition",
                "On phones with less memory the app keeps a smaller footprint; it will not start a 327 MB voice download or seed images without room to spare",
                "Diagnostics has a Speed section: the last tab switch and Flow open in milliseconds",
                "The widget's cycle tap carries no optional value any more — one variable removed on the way to the answer",
            ]),
        ChangelogEntry(
            version: "3.2.1",
            build: "59",
            date: "Sep 13, 2026",
            changes: [
                "The Wisdom tab opens again. 58 asked the database a question in a shape it could not answer, and it fell over instead of saying so",
                "A voice note shows up the moment you stop recording — with play and remove — and sits at the bottom of the entry once saved. The entry's line says how long it is instead of counting its words",
                "Voice notes get a transcript, written on the phone after you save, with your names and book titles spelled your way",
                "Tapping a tab no longer redraws all five tabs, and the other four are ready before you get to them",
                "The mark on the settings page: the rings breathe and turn on their own now, and the dialog is titled with your name",
                "The archive deck turns so you can see it turn from the corner of your eye",
                "Weather and place, smart reminder timing, the advice note and the rest of 58 carry forward",
            ]),
        ChangelogEntry(
            version: "3.2.0",
            build: "58",
            date: "Sep 12, 2026",
            changes: [
                "Voice notes record again. The recorder had been asking the microphone for a mode meant for playback, and swallowing the refusal",
                "The journal opens with Face ID only. There is no passcode as a second door any more",
                "The journal thread can reach all of your writing now — it tells you how many entries there are and how far back they go before it quotes from them",
                "Photos in the journal keep their shape. A tall picture is cropped a little, never squashed",
                "The journal has its warm ground in the dark too",
                "Journal context in chat starts off, and the first time you unlock the journal it comes on and stays on. Turning it back on after you turn it off asks for Face ID",
                "Tapping the calendar's month opens the whole calendar, every month back to the first entry",
                "Volumes moved up, into the journal's menu and beside the calendar",
                "The library can be a list. Tap the title to choose",
                "Swiping between tabs works over lists now. The pager had been losing every drag to the list underneath it",
                "In Messages, tapping the field opens the roomier pane and the keyboard comes with it. And the pane can now Ask Cobux: a reply you can drop straight into the conversation",
                "A lock-screen control for a new journal entry. Add it in Customize Lock Screen, in the corner where the torch lives",
                "Diagnostics knows the phone it is on: model, system, free space, memory, heat",
                "A note on advice, in Settings",
                "Flow opens the moment you tap it again. It had been reading the whole library — thirty-three thousand lines — every forty cards; now it draws what it needs and no more",
                "The Quiz tab, Reminders, the New Entry sheet, a book's page and search all stopped reading the whole library on the way in. Search runs off the thread that draws the screen",
                "Weather and place beside the time are on for everyone now. The first entry asks once for your location, after saying why",
                "Reminders keep their smart timing by default",
                "Under a quiz's Needs Review, a question can be retired for good: Never ask me this again",
            ]),
        ChangelogEntry(
            version: "3.1.0",
            build: "57",
            date: "Sep 12, 2026",
            changes: [
                "Your library says what it holds at the end of the shelf again. It had been reading the count once, during setup, getting zero, and never asking again",
                "Liked highlights is a real shelf now, not a plain list — each line carries its book, and the page has a shape",
                "The journal list reads at the same voice as an open entry, a point larger on every line",
                "The journal keeps its warmth in the dark: the same living background Ebb and chat already have, at reading strength",
                "The card that told you how many words you wrote is gone. Under the calendar, your archive moves on its own now and never runs out",
                "The widget is back in the face you liked from 2.6 — the italic serif — at the margins you approved later",
                "The widget setup screen opens at once, and no longer offers to put itself off",
                "The mark on the settings page never stops moving, and tapping it opens a dialog in the middle of the screen that says what the drawing is made of",
                "COBUX sits back toward the middle of the chat bar",
                "Journal context is on by default. The line above the composer says so, and turns it off",
                "Reminders arrive twice a day, as promised. They had been arriving forty-eight times a day, and they no longer pile up",
                "The Messages sheet looks like Cobux now, and the send button wears the app's colour instead of iOS blue",
                "Ebb's pages are all the same size, its type registers with the page margin, and a book's line sits behind its own thread with a credit",
                "Adding a photo or a voice note to a journal entry works again. Both buttons had been quietly switched off whenever the journal was locked — from the widget, from Messages, and after every return to the app — and said nothing. They ask for Face ID now and carry on",
                "The journal thread can reach all of your writing, not just what you wrote since the seventh. Imported entries were invisible to it until a background index caught up",
                "A crash on a friend's phone, traced: opening a Wisdom theme after the graph had been rebuilt underneath it. The screen holds no stale model now and cannot trap",
            ]),
        ChangelogEntry(
            version: "3.0.3",
            build: "56",
            date: "Sep 7, 2026",
            changes: [
                "The tab bar could stop responding after a swipe, with no way back but force-quitting. That was ours, from yesterday, and it cannot happen again",
                "Flow opens the moment you tap it again. It stalled in the last build, and that was ours",
                "Swipe between the five tabs the way you swipe anywhere else. The bar stays exactly where it is",
                "Everything scrolls at speed now — the quiz's shelf, the library, your journal, your liked highlights",
                "Wisdom has its entries on screen the moment it opens, instead of a beat later",
                "The widget's quote tap is rebuilt on the shape that provably worked in build 51. The last build claimed this fixed and was wrong, so this one only claims the rebuild",
                "Ebb is its own place now: your writing sits on a page, where Flow is open air",
                "The copy button on a reply no longer reads as one more book beside it",
                "The month name on Ebb's chapter dividers is readable on the darkest months of the year",
                "Situations says its name on the chat bar instead of wearing an icon you had to guess at",
                "Cobux can tell you it is back when the credits return. It was writing that message and never showing it",
                "The copy button on a reply picks its own text colour so it reads on any book's cover, pale ones included",
            ]),
        ChangelogEntry(
            version: "3.0.0",
            build: "53",
            date: "Sep 6, 2026",
            changes: [
                "Tapping the highlight widget shuffles again. It stopped in the last build, and that was ours",
                "Ninety-six new books arrived in the last build, bringing the library to 156. Its notes undercounted them; the books were always there",
                "Weather and place could never actually turn on. It works now, and it explains itself before it asks for anything",
                "The Flow button floats on its own — no bar drawn around it, its name set in the reading face, and far calmer in the dark",
                "Your writing reads at a book's size in the journal, not larger than everything else in the app",
                "One spacing rhythm from the top of the journal to the last entry, and the empty gap under the archive card is gone",
                "Come back to an entry within ten minutes and it simply carries on — no new time stamp, the cursor where you left it",
                "The hints and the passage from your archive stay put now. They change what they show instead of closing",
                "Your journal already keeps three rotating copies in your iCloud, restored if you ever reinstall. The app finally says so",
                "Your journal can leave as plain text through Shortcuts — into Apple Notes, or anywhere else you keep things",
                "A calendar you can walk back through, month by month and year by year, straight to a day you wrote",
                "Reflect on this in Chat carries the entry with it now",
                "Photos attach in chat and in the journal, with something to look at while they load",
                "A copy button on replies, and the books a reply drew on read as quiet labels instead of a wall of them",
                "Chat stopped calling itself a place to ask about books. Bring it whatever you are actually working through",
                "Every screen opens on the frame you tapped — Diagnostics, the widget help, the library, Wisdom, a book's page",
                "Empty screens explain what they are for, everywhere, the way Situations already did",
                "Every way into Cobux is written down in Settings — the widget, Siri, Messages, the share sheet, the Watch",
                "Quiz wears the same dark palette as the rest of the app",
                "A book's author is no longer half-hidden behind the card below it",
                "The Messages and Watch icons are the 3.0 mark, like everything else",
                "Your library says what it holds at the end of the shelf",
            ]),
        ChangelogEntry(
            version: "3.0.0",
            build: "52",
            date: "Sep 4, 2026",
            changes: [
                "Cobux now shows you what it can do — quiet hints where each feature lives, gone the moment you use it. Never a popup, never a tour you're trapped in",
                "Open your journal for the first time and it shows you what it becomes — real examples of on-this-day, your words beside the books, keeps, and answering your past self — with one tap to bring in your existing writing",
                "A new depth to the dark look: the ground falls toward true black with a breath of crimson in it, and the app's own controls carry the red — while the violet you know keeps everything it always had",
                "A new mark. Cobux's icon is now its own signature — the quote, set in violet light on black",
                "The Flow button floats now — black and deep violet, lit from above, with a slow sheen crossing it",
                "Cobux 3.0. The whole app has been rebuilt to feel the way Flow feels — one living design language on every screen",
                "Ninety-six new books, bringing the library to 156 -- from the Instruction of Ptah-Hotep and Okakura's Book of Tea to Arabian Wisdom, the Cynic's Breviary, Nietzsche's Twilight of the Idols and Al-Ghazzali",
                "Everything is faster, especially the first minutes. Setting up a new install now happens genuinely in the background, so the app is fluid while your library builds itself",
                "Sending a chat message never hesitates under your finger again, however big your library and history are",
                "A chat can draw on what you've said in your other conversations — only your own words, never Cobux's, and it always says which conversation it's remembering from. There's a switch in Settings",
                "Long-press any message to copy or share it. Copies keep their formatting in Notes and arrive clean in Messages",
                "When Cobux drafts you a reply to send someone, one tap makes it warmer, shorter, or more direct",
                "The thread picker shows where each conversation left off — except your journal, which shows nothing there, not even a date",
                "Ebb is redesigned top to bottom: your writing sits composed mid-screen in a book face, behind the month's own light",
                "The card under your journal calendar swipes both ways now, and can take a passage straight into chat or keep it for later",
                "Quiz has color again — every book carries its own spine, every mode its own badge",
                "More is reorganised, and Journal finally looks like what it is there",
                "The Flow button sits with the tab bar properly on iOS 26 instead of over it",
                "Month arrows join the calendar swipe, so going back through months never triggers the system back gesture",
                "The archive card appears instantly on return visits instead of loading late",
                "Write back to an old entry. Wherever your past writing meets you — reading it, or a card that brings it — you can answer it. The answer is an ordinary entry joined to the one it answers, dated on both ends, and over time the journal becomes a correspondence with yourself",
                "Attach photos in chat — up to three per message, the way you'd expect from any modern AI chat. They're downscaled on your device before anything is sent, to keep usage light",
                "Each journal entry quietly remembers where it was written — shown in its colophon, kept on your device",
                "Held, under Saved: every passage you're currently keeping, in one quiet place. Nothing there is due or counted — it just shows what you chose to hold",
                "Bind a volume. Pick a stretch of months and Cobux sets your own passages — with the library lines that sit closest to them — into a private book: a real PDF in the reading face, dated in your months' own colors. It stays on your device unless you choose to share it",
            ]
        ),
        ChangelogEntry(
            version: "2.9.0",
            build: "51",
            date: "Sep 4, 2026",
            changes: [
                "The card under your journal calendar is a window now — tap it to turn through a few things from your own writing, ending in a door into Ebb",
                "Keep a passage from any entry, and Cobux brings it back after a week, then a month, then longer. You can attach a question to your future self; nothing is ever scored or marked done",
                "Set a keep down whenever you want. The passage and the entry stay exactly where they are — Cobux just stops bringing it back",
                "Quiet words: add a name or word in Settings and nothing containing it will ever surface on its own again. Nothing is deleted — Cobux just stops bringing it to you",
                "Situations has its own place in the top bar of Chat, so an ongoing thing with someone is one tap away instead of buried",
                "Your Cobux, at the top of Settings: a mark grown from everything you've written and asked here. It only ever grows, and it never leaves your device",
                "Flow is a button in the middle of the screen now, and it looks like something worth pressing",
                "The journal calendar swipes back through months again",
                "Ask Cobux about your own journals and it actually reads them, quoting entries with their dates",
                "A brand-new install is far more responsive while it sets itself up",
            ]
        ),
        ChangelogEntry(
            version: "2.8.0",
            build: "50",
            date: "Sep 3, 2026",
            changes: [
                "Situations: give an ongoing thing with someone its own chat thread, so the context stays together instead of dissolving between book questions. Nothing is stored about anyone — only what you write there, and deleting the thread deletes all of it",
                "On a day you wrote something a year ago, Flow opens with it — your own words, before the library's",
                "Six more books, bringing the library to 60: Sun Tzu's The Art of War, Machiavelli's The Prince, Mill's On Liberty, Paine's Common Sense, Nietzsche's Beyond Good and Evil, and the Analects of Confucius — 1,633 highlights between them, every one checked word-for-word against the source",
                "Flow no longer opens itself. It waited a few seconds before appearing and the app couldn't be used until you closed it — now there's a Flow button on every tab except Chat, and the app opens on Chat",
                "Ebb — the journal's answer to Flow. Open it from the journal and walk backwards through your own writing, a chapter at a time, ending when the deck ends. Your passages can meet the line from your library closest to them, and anything can be taken straight into chat",
                "Under your journal calendar, a passage you wrote can now appear beside the line from your library closest to it in meaning — found on your device, from your own books",
                "Your journal's calendar is rebuilt as a Skyline — one row of bars per month, taller where you wrote more. Streaks read as unbroken runs, empty days are quiet, and your writing starts above the fold again",
                "Last night's sleep is actually last night. It had been adding up every stretch of sleep in a day and a half, so an evening reading counted the night before and any nap too",
                "Adding photos to an entry works. The picker was clearing its selection before the photos finished loading, so they silently vanished",
                "Your writing streak is visible on every month of the calendar instead of only the current one",
                "Entries from past years show their year, so two Aprils are no longer identical",
                "The temperature comes with the date on each new entry — and the city, but only when you're somewhere unusual",
                "Cobux is better at real situations. Ask what to say to someone and you get messages you can actually send, in your own voice, drawn from the library",
                "Chat is softer to read: replies sit on the page in a book's face rather than in outlined boxes, and quotes are cards you can copy",
                "Chat no longer answers a question you asked days ago alongside your new one",
                "Nothing in Cobux tells you that you're behind any more — no checkmarks, no streak warnings, no red badge by default. The streak is yours to enjoy, not a chore",
                "Flow opens on a real highlight instead of a loading screen",
                "The app starts faster, and the journal no longer recomputes your whole archive as you type",
            ]
        ),
        ChangelogEntry(
            version: "2.7.0",
            build: "49",
            date: "Sep 2, 2026",
            changes: [
                "20 new books, bringing the library to 53 -- Marcus Aurelius, Epictetus, Montaigne, Bacon, Emerson, Thoreau, Chesterfield's letters and more, every highlight checked word-for-word against the source",
                "Books now carry which tradition they come from, so counsel, strategy and memoir aren't all read in the same voice",
                "The Journal is rebuilt. Entries look like writing instead of rows: your first line leads, short notes are set as notes and long entries as long reads, and every day is headed by its own date rather than a repeated month",
                "A calendar above the journal shows how much you wrote and how many days you kept going, and takes you to any day you tap",
                "One card under the calendar brings back something you wrote before -- your words and the date, nothing else",
                "Every entry says where it came from -- Cobux, Notes, Apple Journal, Messages or a voice note",
                "Journal entries can no longer be deleted from inside Cobux. This writing goes back years; if something really needs to go, it goes from the app you wrote it in and Cobux follows",
                "Writing near the bottom of an entry no longer jumps around when the keyboard reaches it -- the editor now handles the keyboard itself instead of two things fighting over it",
                "Flow has one row of buttons at the bottom instead of two. Open Cobux takes the highlight you're looking at into chat with you",
                "Tapping anywhere on the highlight widget moves to the next highlight. The empty space around the words used to open the app instead",
                "The Journal widget opens a blank entry straight away, from the home screen and the lock screen, instead of landing you on the list",
                "The lock-screen journal widget is a single icon now -- one tap and you're writing",
                "Tapping anywhere on a Quick Check answer answers it",
                "When Cobux AI runs out of credits it says so plainly, and tells you when it's working again",
            ]
        ),
        ChangelogEntry(
            version: "2.6.0",
            build: "46",
            date: "Aug 31, 2026",
            changes: [
                "Cobux has its own voice now. iOS never lets an app use the good system voices, so it carries a neural one that runs entirely on your device -- no network, no cost, and it works offline once it downloads",
                "Journal writes like Notes: leaving the screen saves, typing at the bottom stays put, and entries reach iCloud the moment you save instead of waiting on a timer",
                "Journal from Siri -- \"Hey Siri, journal in Cobux\" -- or from the new Cobux panel inside Messages",
                "Widget: tap the quote to change it, and the buttons underneath are actually tappable again",
                "Flow stops showing fragments that make no sense on their own, and every card can go to chat",
                "Chat applies your books to what you're actually dealing with, instead of only answering questions about them"
            ]
        ),

        ChangelogEntry(
            version: "2.5.21",
            build: "34",
            date: "Aug 25, 2026",
            changes: [
                // Deliberately generic. The original named the archive's size and
                // its exact sources, and What's New is shown to EVERY tester -- so it
                // described Rajan's private writing to Utkarsh and Gulab. The entries
                // themselves never leave his Apple ID, but a changelog does, and a
                // description of someone's journal is still information about it.
                "Your writing archive now arrives on its own -- dated and in order, with no file picker to hunt down, and it keeps itself up to date"
            ]
        ),
        ChangelogEntry(
            version: "2.5.20",
            build: "33",
            date: "Aug 24, 2026",
            changes: [
                "Fixed the \"Open Cobux\" button sitting on top of Go Deeper and Share in Flow -- they were overlapping outright",
                "New: double-tap any highlight in Flow to like it, with the heart burst and haptic you would expect. Double-tap only ever likes, never un-likes, so a stray tap can't lose something you wanted to keep",
                "Fixed the Journal text box: the cursor could jump away mid-sentence, and once an entry got long the line you were writing scrolled out of view",
                "New: the Journal tab now has a month calendar with a dot on every day you wrote. Swipe it to look back through previous months"
            ]
        ),
        ChangelogEntry(
            version: "2.5.19",
            build: "32",
            date: "Aug 24, 2026",
            changes: [
                "Your streak is back. It didn't lapse because you missed days -- the app was crashing on launch, so you couldn't open it. Cobux now forgives a streak gap it can prove it caused",
                "Flow opens immediately instead of making you wait -- it was queued behind iCloud syncing that could take several seconds",
                "New: Like any highlight in Flow, and find them all under More > Saved > Liked",
                "Widget highlights no longer get cut off mid-sentence -- long quotes now scale to fit",
                "The widget only shows books you have switched on. Turned-off books were still appearing there",
                "Tapping a highlight in the widget goes to that highlight instead of opening Flow over it",
                "Widget share button moved to the top-right, out of the way of the quote mark",
                "New: Extended thinking toggle in Settings (off by default) -- keeps your API costs down, turn it on for genuinely hard questions"
            ]
        ),
        ChangelogEntry(
            version: "2.5.18",
            build: "31",
            date: "Aug 23, 2026",
            changes: [
                "New Journal widget -- put it on your home screen and one tap drops you straight into writing today's entry, with your streak right there. No more app, More, Journal, compose",
                "The streak card in Flow now greets you once a day instead of every single time you reopen Flow, and the flame springs in with a glow",
                "Spoken Quiz finally uses the voice you picked in Settings -- it had been ignoring it and falling back to the old robotic one",
                "FLOW is centered at the top of the feed",
                "New: when you write a journal entry, Cobux can now show your mindful minutes and last night's sleep from Apple Health right beside it -- so your writing sits next to how your body actually was. Read-only, stays on your device, and it asks first"
            ]
        ),
        ChangelogEntry(
            version: "2.5.17",
            build: "30",
            date: "Aug 21, 2026",
            changes: [
                "Covers for all 7 newest books -- Acres of Diamonds, The Art of Money Getting, The Game of Life, A Message to Garcia, Pushing to the Front, The Science of Getting Rich, and Self-Help all shipped with no thumbnail. A test now fails the build if any book ever ships cover-less again",
                "The streak card in Flow now greets you once a DAY, not every single time you reopen Flow",
                "The streak flame actually animates now -- springs in with a warm glow instead of sitting still",
                "Spoken Quiz now uses your chosen voice from Settings. It was ignoring it and falling back to the old robotic system voice, while Voice Mode used the good one",
                "The FLOW label at the top of the feed is centered",
                "Everything from 2.5.13-2.5.16 that never actually reached you: the book title at the top of Flow cards, the bigger \"Open Cobux\" button, automatic iCloud backup and restore, the redesigned Journal, and the widget's button moved to the right side"
            ]
        ),
        ChangelogEntry(
            version: "2.5.16",
            build: "29",
            date: "Aug 21, 2026",
            changes: [
                "THE actual launch-crash fix, confirmed from your real crash logs this time: adding iCloud file storage in a recent build silently switched the database into a CloudKit sync mode it was never built for, killing the app a tenth of a second after launch -- on every build since. CloudKit mirroring is now explicitly off",
                "If the database ever fails to open again, the app now records exactly why instead of dying silently"
            ]
        ),
        ChangelogEntry(
            version: "2.5.15",
            build: "28",
            date: "Aug 21, 2026",
            changes: [
                "Fixed a real launch crash: the automatic journal iCloud sync was accidentally touching your library from the wrong thread on every cold launch, which could crash the app before it ever opened -- found and fixed after real-device testing surfaced it",
                "Closed two related races around first-launch setup that could let background syncing collide with your library while it was still being prepared",
                "Fixed the widget's fresh-data button to actually be on the right side, easier to reach one-handed"
            ]
        ),
        ChangelogEntry(
            version: "2.5.14",
            build: "27",
            date: "Aug 21, 2026",
            changes: [
                "Fixed the streak celebration popping up again if you closed Flow while it was showing and came back later -- it now stays settled",
                "The streak flame now has a subtle pulse instead of sitting static",
                "The journal's \"continue entry\" button now has its own icon and label instead of looking identical to starting a brand-new entry"
            ]
        ),
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
