import SwiftUI
import UIKit
import AVFoundation
import SwiftData
import WidgetKit

struct ContentView: View {
    @State private var claudeService = ClaudeService()
    @State private var notificationManager = NotificationManager()
    /// Chat, not Library. Rajan: "by def should always open on the chat
    /// always" -- it is what he actually opens the app to do.
    @State private var selectedTab = 2
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    // No `@Query` for books here any more, either.
    //
    // It was the app ROOT holding every `Book` -- and, through SwiftData's
    // change tracking, re-invalidating the entire shell (every tab, the Flow
    // cover, every sheet modifier) whenever anything about any book changed.
    // On a first launch that is 156 seed books plus 32,000 highlights being
    // written, each batch re-rendering the whole app. What it was actually for:
    // ONE `.isEmpty` in `resolveLaunchSheets` (now a `fetchCount`, alongside
    // the chat one right beside it that was fixed for the same reason), and
    // handing rows to a sheet that is presented at most once per install (now
    // fetched by that sheet's own loader, when and only when it appears).
    // Neither wanted a live query; both wanted an answer at one moment.
    // No `@Query` for chat messages here any more. It was an unbounded
    // main-actor fetch of every message ever written (content, vectors, image
    // ids) sitting on the app ROOT, and it re-invalidated this whole view on
    // every insert -- twice per chat turn -- to answer two questions: "is there
    // any chat history?" (a COUNT now, see `hasAnyChatMessages`) and "what
    // should the one-time export prompt export?" (fetched by the prompt itself
    // when, and only when, it is presented -- see `PostUpgradeExportPromptLoader`).
    @AppStorage("hasOfferedPostUpgradeExport") private var hasOfferedPostUpgradeExport = false
    @State private var showingPostUpgradeExportPrompt = false
    private let seedingStatus = SeedingStatus.shared
    private let storeHealthStatus = StoreHealthStatus.shared
    private let updateStatus = UpdateAvailabilityStatus.shared
    @AppStorage("dismissedUpdateBuild") private var dismissedUpdateBuild = ""
    // Empty means "never recorded" -- true only for a build that predates this
    // feature, or the very first `ContentView` appearance right after onboarding.
    // Both cases mean "nothing to compare against yet," so `maybeShowWhatsNew`
    // below silently records the current build rather than treating the empty
    // string as "differs from current" and showing an unwanted sheet the moment
    // onboarding finishes.
    @AppStorage("lastSeenChangelogBuild") private var lastSeenChangelogBuild = ""
    @State private var showingWhatsNew = false
    /// Flow, presented on demand from the Flow button -- as an in-place
    /// overlay (see `flowOverlay`), no longer a `fullScreenCover`.
    @State private var showingFlowOnLaunch = false
    /// Reduce Motion is a hard gate (`CobuxMotion`): the Flow overlay then
    /// arrives by opacity alone, no scale.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shown once, ever. See `WidgetInviteView` for why there is no second ask.
    @AppStorage("cobux.widgetInvite.seen") private var hasSeenWidgetInvite = false
    @State private var showingWidgetInvite = false
    @State private var widgetInviteQuote: (quote: String, book: String, accentHex: String)?
    /// True only while a deep link is closing an open Flow session, so the
    /// widget invite does not appear on that dismissal -- on top of the exact
    /// highlight the user just tapped. Flow used to auto-present on launch,
    /// which was right for "I opened the app" and wrong for "I tapped a
    /// specific highlight" -- Rajan: "when i hit a highlight in the iOS widget
    /// it opens up flow still which should not be the case... it should open up
    /// when the app itself is getting opened." It no longer opens itself at
    /// all, so this is now purely about what follows a dismissal.
    @State private var launchedFromDeepLink = false
    @State private var pendingDeepLinkBookID: UUID?
    /// The specific highlight a widget tap came from, if the URL carried one --
    /// consumed by `ChatView` to pre-fill the composer with that quote.
    @State private var pendingDeepLinkHighlightID: UUID?
    /// Literal text to drop into the composer, for sources that are not a
    /// `Highlight` and so cannot be looked up by id (key lessons, cloze cards).
    @State private var pendingDeepLinkPrefill: String?
    /// Text handed to the system share sheet, set when the widget's share
    /// button routes here. The widget cannot share on its own.
    @State private var pendingShareText: String?
    /// Compose presented from the ROOT, for `cobux://journal/new`.
    ///
    /// It used to be presented by `JournalListView` itself, reached by pushing
    /// a navigation destination under the More tab. That is three fragile
    /// hops -- select tab, push route, then a `.task` inside a view sitting
    /// under a lock gate that swaps its own subtree on every lock transition --
    /// for an action whose entire point is immediacy. Reported twice: "when
    /// journal is opened through the iOS widget... the new entry button does
    /// not work", then again on build 48, "it should... simple open a new
    /// journal entry directly. And i mean directly like a new note opens for
    /// the notes app. It's doesn't load all notes."
    ///
    /// So the widget no longer asks the list to open compose; it opens compose.
    /// The Journal tab is still selected underneath, so dismissing lands on the
    /// journal rather than wherever the user happened to be. Face ID is not
    /// bypassed -- `JournalEntryComposeView` wraps its own body in
    /// `JournalLocked`, so a locked journal still authenticates first, it just
    /// does so over the composer instead of over a list on the way to it.
    @State private var deepLinkCompose: ComposeSession?
    @State private var celebrationCenter = StreakCelebrationCenter.shared
    @State private var autoRestoreStatus = AutoRestoreStatus.shared
    @AppStorage("reviewNudgeEnabled") private var reviewNudgeEnabled = true
    // Defaults OFF. A red count on the app icon is to-do vocabulary on the
    // most prominent surface iOS has -- the same frame as the checkmark he
    // rejected on the journal widget, only louder, and handed to every user
    // unasked. It stays available for anyone who wants it (Reminders >
    // Due-Cards Icon Badge): someone studying for an exam genuinely chose a
    // task system. It is just no longer the default.
    @AppStorage("dueBadgeEnabled") private var dueBadgeEnabled = false

    /// One NavigationPath per tab that actually pushes content, hoisted here
    /// so it can be reset from outside that tab's own view. Fixes two real
    /// navigation bugs: (1) re-tapping the already-active tab did nothing —
    /// standard iOS behavior is to pop that tab to its root; (2) the More tab
    /// kept whatever screen you'd pushed (Settings, Reminders...) even after
    /// switching away and back, since the tab shell keeps every tab's view tree
    /// alive rather than tearing it down (`TabView` did; `UITabBarController`,
    /// which replaced it for interactive paging, does too — the reset below is
    /// still the only thing that clears More). More is a menu, not content, so it
    /// resets on leaving — the other tabs intentionally do NOT reset on leave
    /// (Library shouldn't lose your place in a book just because you glanced
    /// at Chat).
    @State private var libraryPath = NavigationPath()
    @State private var wisdomPath = NavigationPath()
    @State private var quizPath = NavigationPath()
    @State private var morePath = NavigationPath()

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    switch newValue {
                    case 0: libraryPath = NavigationPath()
                    case 1: wisdomPath = NavigationPath()
                    case 3: quizPath = NavigationPath()
                    case 4: morePath = NavigationPath()
                    default: break
                    }
                }
                if selectedTab == 4, newValue != 4 {
                    morePath = NavigationPath()
                }
                selectedTab = newValue
            }
        )
    }

    /// Flow, offered from every tab except the one it would cover.
    ///
    /// Chat simply does not get this modifier -- that is the whole of "hidden
    /// on Chat" now. It used to be a `selectedTab != 2` flag feeding a slot
    /// that had to be collapsed, or, on one OS version, filled with a quieter
    /// button because the slot could not be collapsed at all.
    private var flowLaunch: FlowLaunchInset<FlowLaunchButton> {
        FlowLaunchInset { FlowLaunchButton { openFlow() } }
    }

    /// The tap. Starts the tap-to-first-card clock and inserts the overlay in
    /// the same statement, so nothing sits between the two.
    private func openFlow() {
        SpeedTrace.flowOpenBegan()
        // A cover used to resign the keyboard for us; an overlay does not.
        // With a search field focused, Flow would open under a live keyboard.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        showingFlowOnLaunch = true
    }

    /// Any screen that wants Flow posts this instead of presenting its own
    /// cover (Wisdom's hero card did, and slid). One overlay, one open path.
    static let openFlowNotification = Notification.Name.cobuxOpenFlow

    private func closeFlow() {
        showingFlowOnLaunch = false
    }

    /// FLOW AS AN IN-PLACE OVERLAY (build 60). His words on 59: "opening flow
    /// got faster too but still not right away fast." 58 and 59 took every
    /// piece of work out of the open -- the deck is dealt from `FlowWarmCache`
    /// in the first frame -- and what was left was the `fullScreenCover`'s own
    /// system slide, ~0.4 s of UIKit presentation between the tap and the
    /// card, which no amount of app work could shorten. So Flow is no longer
    /// presented; it is INSERTED, as a layer over the tab shell, already
    /// sized, and arrives by a 0.12 s opacity + 0.98→1.0 scale (opacity alone
    /// under Reduce Motion). Dismissal is the mirror.
    ///
    /// What the deferred-ledger row said this would cost, and what happened
    /// to each:
    ///   1. `@Environment(\.dismiss)` inside `FlowView` stops working. Flow's
    ///      own close button takes `onClose` (this view's `closeFlow`). The
    ///      card footers' "Open Cobux"/"Open Quiz" call `dismiss()` and then
    ///      `openURL` -- and `onOpenURL` below has always closed Flow itself
    ///      (`showingFlowOnLaunch = false`) before routing, so those buttons
    ///      close it through the route they already take; the `dismiss()`
    ///      ahead of it is now a no-op rather than a second dismissal.
    ///   2. The `onDismiss:` widget-invite offer moved to `.onChange` of the
    ///      flag, same guard order (`flowDidClose`).
    ///   3. Flow's Sources sheet and celebration overlay present from this
    ///      view's hierarchy. A `.sheet` on a view inside an overlay presents
    ///      through the window's root presenter, over whichever tab is
    ///      underneath -- and, unlike before, this view's own sheets (a
    ///      widget's compose, the share sheet) can now present while Flow is
    ///      up instead of failing against a cover already in the slot.
    ///   4. The cover's swipe-down-to-close: `fullScreenCover` never had one
    ///      (only `.sheet` does), so nothing is lost.
    ///
    /// The tab shell's paging veto reads `pagingEnabled`, which is false
    /// while this is up (belt; the braces are that the overlay is above the
    /// shell's view in the hit-test order, so its pan never sees the touch).
    /// The Wisdom tab's hero card still presents its own cover
    /// (`WisdomGraphView.showingFlow`, not this lane's file); `FlowView`
    /// keeps `dismiss()` as the fallback for that route.
    @ViewBuilder
    private var flowOverlay: some View {
        // The `ZStack` is the container the transition needs: the `if` has
        // to be evaluated inside a view carrying `.animation(value:)` for
        // the insertion and removal to animate at all.
        ZStack {
            if showingFlowOnLaunch {
                FlowView(onClose: closeFlow)
                    .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: showingFlowOnLaunch)
        .ignoresSafeArea(.keyboard)
    }

    /// What used to be the cover's `onDismiss:`, verbatim in effect: consumes
    /// `launchedFromDeepLink` once, for exactly the one dismissal it was set
    /// to suppress, and offers the widget invite once ever. Guard ORDER is
    /// load-bearing and must stay this way: the deep-link check runs BEFORE
    /// `hasSeenWidgetInvite`, so a suppressed showing returns without ever
    /// touching the persisted seen-flag. `defer` rather than an assignment at
    /// the end: both guards return early, and the deep-link guard is the very
    /// path that most needs the flag reset afterwards.
    private func flowDidClose() {
        defer { launchedFromDeepLink = false }
        // The one moment desire actually exists: he has just finished
        // swiping through the app's best surface. iOS has no API to add a
        // widget for someone, so the only honest tactic is wanting it plus
        // a clear how, offered once. Not after a deep link: `onOpenURL`
        // force-closes Flow, which lands here too -- so the invite could
        // appear on top of the highlight he tapped, and for journal/new it
        // would race the compose sheet for the one presentation slot.
        guard !launchedFromDeepLink else { return }
        guard !hasSeenWidgetInvite, let sample = widgetInviteSample() else { return }
        widgetInviteQuote = sample
        showingWidgetInvite = true
    }

    /// Whether a horizontal drag may page to the next tab right now.
    ///
    /// One of the two independent vetoes behind the swipe (the other is
    /// `PagingTabView`'s own `UINavigationController`-depth check, which also
    /// catches pushes this can't see -- Quiz's two `navigationDestination(item:)`
    /// presenters and Chat's pathless stack). This half is the one computed from
    /// state that lives HERE: paging stops the moment a detail screen is pushed
    /// onto the visible tab.
    ///
    /// That is a decision, not an oversight. At depth the horizontal axis
    /// already belongs to the interactive back gesture, and "back" stops having
    /// one meaning if the same drag can also land in a different tab. Snapchat's
    /// swipe surface is its flat top level too.
    private var pagingEnabled: Bool {
        // Not while Flow covers the shell: a drag on Flow's feed must never
        // reach the pager underneath. See `flowOverlay`.
        guard !showingFlowOnLaunch else { return false }
        switch selectedTab {
        case 0: return libraryPath.isEmpty
        case 1: return wisdomPath.isEmpty
        case 3: return quizPath.isEmpty
        case 4: return morePath.isEmpty
        default: return true
        }
    }

    var body: some View {
        // `Color.clear` is the LAYOUT anchor, and the shell is its background.
        //
        // The shell has to ignore the safe area -- a `UITabBarController` inset
        // to the safe area would lay its own bar out inside an already-inset
        // frame and inset it twice. But every `.overlay` below is anchored to
        // whatever this expression's frame is, and `TabView`'s frame is what
        // they were positioned against. `Color.clear` and `TabView` are both
        // "fill the proposal" views, so they receive the identical frame here,
        // whatever SwiftUI proposes to the root -- which is precisely why the
        // anchor is a separate view instead of `.ignoresSafeArea()` applied to
        // the whole composition, which WOULD move both banners to the screen
        // edge (the top one under the notch).
        //
        // `allowsHitTesting(false)` because `Color.clear` is opaque to touches
        // in SwiftUI -- without it this would swallow every tap in the app.
        Color.clear
            .allowsHitTesting(false)
            .background {
                // Interactive paging with the real iOS 26 tab bar. SwiftUI has
                // no style that does both -- see `PagingTabView`, which records
                // what the SDK actually offers and why this is UIKit.
                // THE CONTRACT WITH THE SHELL (build 59). `PagingTabView`
                // forwards each page's content to its hosting controller ONCE
                // and does not re-forward it on later body passes -- that
                // per-pass reassignment re-diffed all five tabs on every tap
                // and was the largest single cost of a tap. It is safe because
                // everything handed to a tab below is a `Binding` to this
                // view's own `@State` or a reference object, both of which
                // stay live through the State's storage box regardless of
                // which body pass built the view. KEEP IT THAT WAY: a plain
                // value passed here (a `Bool`, a `String`, a struct) would be
                // frozen at its first-pass value inside that tab. Pass a
                // `Binding` instead, or read the value inside the tab.
                PagingTabView(
                    selection: tabSelection,
                    pages: [
                        PagingTabView.Page(
                            title: "Library",
                            systemImage: "books.vertical.fill",
                            content: AnyView(
                                LibraryView(path: $libraryPath)
                                    .modifier(flowLaunch)
                            )
                        ),
                        PagingTabView.Page(
                            title: "Wisdom",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            content: AnyView(
                                WisdomGraphView(claudeService: claudeService, path: $wisdomPath)
                                    .modifier(flowLaunch)
                            )
                        ),
                        PagingTabView.Page(
                            title: "Chat",
                            systemImage: "message.fill",
                            // No `flowLaunch`. Chat deliberately never gets the
                            // Flow button -- that is the whole of "hidden on
                            // Chat", and it stays a missing modifier rather than
                            // a flag. See `flowLaunch`'s own comment.
                            content: AnyView(
                                ChatView(
                                    claudeService: claudeService,
                                    pendingDeepLinkBookID: $pendingDeepLinkBookID,
                                    pendingDeepLinkHighlightID: $pendingDeepLinkHighlightID,
                                    pendingDeepLinkPrefill: $pendingDeepLinkPrefill
                                )
                            )
                        ),
                        PagingTabView.Page(
                            title: "Quiz",
                            // A question mark, matching Quiz's own empty state --
                            // not a tick. A checkmark on the most permanent
                            // surface in the app asserted a task existed, the
                            // exact frame retired from the widget
                            // (`checklist:nothing-grades-the-user`).
                            systemImage: "questionmark.circle.fill",
                            content: AnyView(
                                QuizHomeView(claudeService: claudeService, path: $quizPath)
                                    .modifier(flowLaunch)
                            )
                        ),
                        PagingTabView.Page(
                            title: "More",
                            systemImage: "ellipsis.circle.fill",
                            content: AnyView(
                                MoreView(notificationManager: notificationManager, path: $morePath)
                                    .modifier(flowLaunch)
                            )
                        )
                    ],
                    pagingEnabled: pagingEnabled
                )
                .ignoresSafeArea()
            }
        // The root tint stays the OG violet -- deliberately. `.tint` here
        // cascades into every control in the app, and painting ALL of them
        // red is exactly the "too crazy" he warned against. The red-black
        // identity lives where it reads as identity: the near-black grounds
        // with their crimson cast, and curated machinery chrome (the quiz
        // badges). Violet keeps the interactive world it always owned.
        .tint(Color.cobuxAccent)
        // Flow's launch button is placed per tab (`flowLaunch` above), not
        // here. See `FlowLaunchInset` for the three shapes this has taken and
        // which two of them he reported.
        // NO animation on `selectedTab`. There used to be one here, and it
        // existed for a thing that no longer exists: while the Flow button
        // lived in the system's bottom accessory slot, switching to Chat
        // COLLAPSED that slot, and the 0.2s ease was there to keep the collapse
        // from snapping. The cost was paid on the tab he uses most -- the whole
        // screen, composer included, animated into place every time he opened
        // Chat. He read the mechanism off the screen exactly: "when cobux chat
        // is clicke i think the flow column is marked unvisible which is why
        // there is a delay in the textbox to come into its positon which looks
        // bad ... the button and the chat shold be somhow independent of each
        // other".
        //
        // They are independent now, structurally rather than by timing: the
        // button is a safe-area inset inside each tab that offers it, and Chat
        // simply never applies that modifier (see `flowLaunch`). There is no
        // shared slot left to collapse, so there is nothing to smooth over --
        // and an animation bound to `selectedTab` would now animate every tab
        // switch in the app for no reason at all.
        //
        // Interactive paging did NOT reintroduce one. `PagingTabView` hands the
        // tab bar controller an animation controller only while a finger is
        // actually driving a transition; a tab-bar tap, a deep link and every
        // programmatic write to `selectedTab` get `nil`, which is UIKit's
        // instant swap. The motion is the drag, not the selection -- so opening
        // Chat by tapping Chat is exactly as immediate as it is today.
        .sheet(item: $deepLinkCompose) { _ in
            JournalEntryComposeView()
        }
        .sheet(isPresented: Binding(get: { pendingShareText != nil },
                                    set: { if !$0 { pendingShareText = nil } })) {
            if let text = pendingShareText {
                ShareSheet(items: [text])
            }
        }
        .onOpenURL { url in
            // Set before any routing below: every branch here means the user
            // asked for a specific destination, so Flow must not hijack it.
            launchedFromDeepLink = true
            // And if Flow is open, close it: a deep link is an explicit
            // instruction and wins over whatever is on screen.
            //
            // Flow no longer presents itself on launch (see
            // `presentFlowOnLaunchIfNeeded`), so the only way it can be up here
            // is that the user opened it by hand and then tapped a widget --
            // or tapped a card's own "Open Cobux", which routes through here.
            // Closing it runs `flowDidClose`, which is the one and only reader
            // of `launchedFromDeepLink` -- the flag exists to stop the widget
            // invite appearing there, on top of the highlight he just tapped.
            //
            // Which is why it is retired again immediately when there is no
            // such dismissal coming. Left armed, it survived to whatever Flow
            // session the user opened LATER and ate the invite there instead:
            // a widget cold launch presents no cover at all, so nothing ever
            // cleared it, and the invite is a once-per-install offer. Nothing
            // below this line re-opens Flow, so the answer cannot go stale
            // between here and the end of the routing.
            if showingFlowOnLaunch {
                showingFlowOnLaunch = false
            } else {
                launchedFromDeepLink = false
            }
            // Widget entries carry the specific book a highlight came from
            // (`cobux://book/<uuid>`) so tapping the widget opens THAT book's
            // scoped chat thread, not just the generic Chat tab.
            //
            // Used to gate on `books.contains(where:...)` before routing at all --
            // confirmed real bug, reported live ("clicking the widget just opens
            // Cobux, doesn't navigate anywhere"). A widget tap cold-launches the
            // app, and `onOpenURL` fires once with no retry; if the `@Query`-backed
            // `books` array hasn't populated at that exact instant, `books.contains`
            // was false, and since `url.host` is `"book"` (never `"chat"`), NEITHER
            // branch of the old if/else-if fired at all -- no tab switch, no deep
            // link, just a plain cold launch. Now: always switch tab and record the
            // pending ID for `host == "book"`, no premature validation. If the ID
            // turns out to be genuinely invalid (a deleted book), `ChatView` degrades
            // to an empty book-scoped thread rather than crashing -- never worse than
            // today's silent no-op, and correct in the overwhelmingly common case
            // where the book is just fine and the query was simply not ready yet.
            //
            // A newer widget build appends `/highlight/<uuid>` so the composer
            // can be pre-filled with the exact quote that was tapped. It is
            // parsed as an OPTIONAL suffix, from its own fixed position, so
            // both URL shapes route identically -- a widget whose timeline was
            // built before that change still emits the two-component form, and
            // must keep working rather than falling through to no branch at
            // all, which is the same class of failure as the cold-launch bug
            // described above.
            if url.host == "book", let bookIDString = url.pathComponents.dropFirst().first,
               let bookID = UUID(uuidString: bookIDString) {
                pendingDeepLinkBookID = bookID
                let components = url.pathComponents.dropFirst()
                if components.count >= 3,
                   Array(components)[1] == "highlight",
                   let highlightID = UUID(uuidString: Array(components)[2]) {
                    pendingDeepLinkHighlightID = highlightID
                }
                if let prefill = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "prefill" })?.value,
                   !prefill.isEmpty {
                    pendingDeepLinkPrefill = prefill
                }
                selectedTab = 2
            } else if url.host == "chat" {
                selectedTab = 2
            } else if url.host == "share" {
                // cobux://share/<bookID>/<highlightID> -- the widget's share
                // button. It cannot present a sheet from its own process, so
                // it hands the highlight here and the app shares it.
                let parts = Array(url.pathComponents.dropFirst())
                if parts.count >= 2,
                   let bookID = UUID(uuidString: parts[0]),
                   let highlightID = UUID(uuidString: parts[1]) {
                    pendingShareText = shareText(bookID: bookID, highlightID: highlightID)
                }
            } else if url.host == "quiz" {
                selectedTab = 3
            } else if url.host == "settings" {
                // `cobux://settings` -- the "Open Settings" action on every
                // "API Key Required" alert. Those alerts used to say "add
                // your key in Settings" with no way there: More → Settings is
                // three taps away and "Settings" collides with iOS Settings.
                // Replace rather than append, same as the journal route: land
                // on the screen, not on top of whatever More had open.
                selectedTab = 4
                morePath = NavigationPath()
                morePath.append(MoreRoute.settings)
            } else if url.host == "journal" {
                // `cobux://journal` lands on the list; `cobux://journal/new`
                // opens compose straight away -- the Journal widget's whole
                // purpose ("journal widget direct"), rather than dropping the
                // user on More and making them find it.
                // `cobux://journal/chat?prefill=` -- a passage of his own
                // writing, taken into the journal chat thread from Ebb. Handled
                // before the new-entry branch because it is a different verb
                // entirely: this opens a conversation about something he
                // already wrote, not a blank page.
                if url.pathComponents.dropFirst().first == "chat" {
                    selectedTab = 2
                    pendingDeepLinkBookID = ChatPromptBuilder.journalThreadID
                    if let prefill = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "prefill" })?.value,
                       !prefill.isEmpty {
                        pendingDeepLinkPrefill = prefill
                    }
                    return
                }
                let wantsNewEntry = url.pathComponents.dropFirst().first == "new"
                selectedTab = 4
                // Replace rather than append: a widget tap should land on
                // Journal itself, not stack it on whatever was left open under
                // the More tab from a previous session.
                morePath = NavigationPath()
                // `startingNewEntry: false` even when the widget asked to
                // write. The list is only what sits UNDERNEATH now -- compose
                // comes up from the root, below. Passing true as well would
                // arm both presenters for the same tap, and two sheets racing
                // for one slot is how the original bug behaved.
                morePath.append(MoreRoute.journal(startingNewEntry: false))
                if wantsNewEntry {
                    // Fresh identity every time, so a dropped presentation
                    // costs one more widget tap instead of latching dead.
                    deepLinkCompose = ComposeSession()
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Lowest priority of the three -- an available update is background
            // information, not something that should ever cover up an actual
            // degraded-store or seeding-in-progress state.
            if storeHealthStatus.isDegraded {
                storeHealthBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if updateStatus.updateAvailable && updateStatus.latestBuild != dismissedUpdateBuild {
                updateBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: seedingStatus.isSeeding)
        .animation(.easeInOut(duration: 0.3), value: storeHealthStatus.isDegraded)
        .animation(.easeInOut(duration: 0.3), value: updateStatus.updateAvailable)
        // The overlay's actual visibility above also depends on `dismissedUpdateBuild`
        // (line 160) -- without tracking it here too, tapping the banner's dismiss
        // button changes what's rendered without SwiftUI knowing to animate the
        // change, so it snaps away instead of sliding out like its two siblings.
        .animation(.easeInOut(duration: 0.3), value: dismissedUpdateBuild)
        .onChange(of: scenePhase) { _, newPhase in
            // Refreshed on foreground so the NEXT entry's stamp has something
            // fresh to say. Fire-and-forget, rate-limited to once per half hour
            // inside the service, and it never blocks anything -- the composer
            // reads a cache synchronously and simply omits the context when it
            // is stale. Foreground only: this app never reads location in the
            // background.
            if newPhase == .active { AmbientContextService.shared.refreshIfNeeded() }
            guard newPhase == .active || newPhase == .background else { return }
            // NEVER read the library while the background seed/upgrade merge
            // is in flight — that's the confirmed Build-5 crash class
            // (relationship fault racing the merge, see BookCard's doc
            // comment). These two calls no longer walk relationships at all
            // (both are indexed fetches now), but reading across a mutating
            // merge is still not something to do on purpose. The isSeeding
            // onChange below re-runs both the moment the merge finishes, so
            // nothing is lost by skipping here.
            if !seedingStatus.isSeeding {
                WatchSyncService.sync(modelContext: modelContext)
                updateEngagementNudges()
            }
            if newPhase == .active {
                celebrationCenter.checkForPendingMilestone()
                // Every real foreground is a genuine "open" for Reminders'
                // Smart Timing option -- see AppActivityTracker's own doc
                // comment on why this and the .task below (cold launch)
                // together are what "every real open" actually requires.
                AppActivityTracker.recordOpen()
                // Opening the app IS the engagement -- his rule: the streak
                // should reward showing up, never pressure him into a quiz.
                // Flow records it too, but Flow can be switched off on launch
                // (and a widget deep link skips it), so the streak must not
                // depend on Flow having appeared. Idempotent per day.
                StreakTracker.recordActivityToday()
                celebrationCenter.checkForPendingMilestone()
            }
            // Re-locks Journal the instant the app leaves the foreground --
            // same trigger point as everything else in this handler, and the
            // whole point of a lock: still up in the app switcher (or after
            // Face ID's own screen-lock kicks in) is exactly when it must be
            // covered, not just at a fresh cold launch.
            if newPhase == .background {
                JournalLockStatus.shared.relock()
                // Backgrounding, not foregrounding -- the export reads whatever was
                // just written (a compose sheet dismissing into background is the
                // most common real trigger), and doing it here keeps it off the
                // foreground's critical path.
                //
                // The background-task assertion is what makes it actually run. This
                // used to be a bare `Task { await ... }` started at the instant iOS
                // begins suspending the app; its very first `await` is
                // `UbiquityContainer.documentsURL()`, which does real I/O, so the
                // process got frozen mid-await and the write never happened.
                // Backgrounding reliably STARTED the export and just as reliably
                // prevented it from finishing -- entries written on the phone sat
                // there unexported for days while the Mac side waited on a file that
                // was never going to arrive.
                Task {
                    let app = UIApplication.shared
                    var assertion: UIBackgroundTaskIdentifier = .invalid
                    assertion = app.beginBackgroundTask(withName: "JournalExport") {
                        app.endBackgroundTask(assertion)
                        assertion = .invalid
                    }
                    await JournalAutoExportService.exportIfNeeded(modelContext: modelContext)
                    if assertion != .invalid { app.endBackgroundTask(assertion) }
                }
                // Own throttle/seeding/degraded gates, all checked
                // synchronously before any iCloud work -- safe to call this
                // often. See `AutoBackupService`'s own doc comment.
                AutoBackupService.backupIfNeeded(modelContext: modelContext)
            }
        }
        .overlay {
            if let milestone = celebrationCenter.milestone {
                MilestoneCelebrationView(days: milestone) {
                    celebrationCenter.dismiss()
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let summary = autoRestoreStatus.summary {
                AutoRestoreBanner(
                    summary: summary,
                    canUndo: autoRestoreStatus.canUndo,
                    onUndo: { autoRestoreStatus.undo(modelContext: modelContext) },
                    onDismiss: { autoRestoreStatus.dismiss() }
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(CobuxMotion.snap, value: autoRestoreStatus.summary)
        // Flow, above every banner and this view's own celebration overlay
        // (Flow hosts its own copy of that one). Last in the overlay chain
        // on purpose: what draws later draws on top.
        .overlay { flowOverlay }
        .onReceive(NotificationCenter.default.publisher(for: .cobuxOpenFlow)) { _ in
            if !showingFlowOnLaunch { openFlow() }
        }
        .onChange(of: showingFlowOnLaunch) { wasShowing, isShowing in
            if wasShowing && !isShowing { flowDidClose() }
        }
        // `scenePhase` above only fires on a TRANSITION, and by the time this
        // view's `.onChange` modifier attaches, `scenePhase` is usually already
        // `.active` (a normal foreground launch) -- `.onChange` never fires for
        // the value a view starts with, only a later change from it. So a phone
        // that already had books before this fix shipped had genuinely never
        // synced to a fresh Watch app install, which is exactly Utkarsh's
        // "0 day streak / 0 due" report: not a sync bug in the transport, a sync
        // that had simply never once fired. Covers the two cases the scenePhase
        // trigger can't: data already exists at cold launch, and data that
        // becomes real for the first time once first-run seeding completes.
        .task {
            // THE LAUNCH FRAME. `.task` starts in the same main-actor turn as
            // the first render pass, so everything in this closure used to
            // run BEFORE the app's very first frame existed: `WatchSyncService
            // .sync` (WCSession activation, a column fetch of every scheduled
            // due date, a COUNT and a one-row fetch for the featured quote)
            // and then `updateEngagementNudges()` (the same due-date fetch
            // again, plus notification-center work) -- all of it in front of
            // the first pixel. One `Task.yield()` is the whole fix, exactly as
            // `ChatView`'s own `.task` documents: the frame goes up on this
            // turn and the rest of this chain runs on the next. Nothing below
            // is reordered and nothing leaves the main actor; it is LATE, not
            // concurrent.
            await Task.yield()
            // Same seed-merge guard as the scenePhase handler above — a cold
            // launch runs this .task concurrently with seedDatabase's big
            // first-upgrade transaction, which is exactly the window the
            // Build-5 crash lived in.
            if !seedingStatus.isSeeding {
                WatchSyncService.sync(modelContext: modelContext)
                updateEngagementNudges()
            }
            celebrationCenter.checkForPendingMilestone()
            AppActivityTracker.recordOpen()
            // Opening the app IS the engagement -- the same pair as the
            // scenePhase handler's `:404`/`:410` above, for the same stated
            // reason: the streak rewards showing up and must not depend on
            // Flow having appeared. This `.task` is the ONLY thing that runs on
            // a cold launch (`.onChange` never fires for the value a view
            // starts with -- see the comment above it), so until now a cold
            // launch recorded the open for Smart Timing and did not count the
            // day. Opening the app straight into a widget deep link, which
            // skips Flow entirely, counted for nothing at all.
            //
            // Safe on the launch path: `recordActivityToday` is a handful of
            // App-Group `UserDefaults` reads and writes, no fetch and no I/O,
            // and it returns without writing when today is already recorded
            // (`StreakTracker.swift:80-81`). It sits outside the
            // `!seedingStatus.isSeeding` guard above on purpose -- the streak
            // lives in UserDefaults, not SwiftData, so a seed merge in flight
            // is irrelevant to it.
            StreakTracker.recordActivityToday()
            // Second check, mirroring `:411`: the call above is what CROSSES a
            // milestone, and the check at the top of this task already ran
            // before it. Without this a 7-day milestone reached on a cold
            // launch stayed parked in UserDefaults, invisible until the next
            // time the app was backgrounded and foregrounded again.
            celebrationCenter.checkForPendingMilestone()
            // One-time: re-stamps a key stored by an earlier build so Siri
            // can read it on a locked phone (see `KeychainManager`). Runs
            // here, in the foreground, because the OLD item is only readable
            // while unlocked. Synchronous and a no-op after the first launch.
            KeychainManager.migrateAccessibilityIfNeeded()

            // FIRST, before any iCloud work. Flow is the app's front door and
            // must appear immediately -- Rajan: "the flow opens up first but
            // it took a while for it to show on opening, i don't want that."
            // It used to sit at the END of this chain, behind three awaits
            // that all touch iCloud: the journal export's ubiquity-container
            // lookup (documented by Apple as not-fast), the restore check, and
            // `downloadPendingAttachments`, which waits up to 15 SECONDS PER
            // pending attachment. On a slow-iCloud launch that's the whole
            // reason the app was "introduced" before Flow arrived.
            //
            // Nothing here depends on that work having finished: Flow re-deals
            // itself when seeding completes or the source filter changes, and
            // a restore surfaces through `AutoRestoreBanner` rather than by
            // gating the feed.
            resolveLaunchSheets()

            // Flow's first deck, built before he taps. `FlowWarmCache` waits
            // its own `launchDelay` (1.5 s -- after this tab's first frame and
            // the shell's warm-up passes), never while seeding, never in the
            // background, and keeps the result as values on `FlowPoolProbe`'s
            // executor. This is the call site the cache's doc comment names
            // as "the launch chain"; without it the deck was only ever built
            // after the FIRST Flow close, so the first open of every launch
            // took the cold path.
            FlowWarmCache.shared.scheduleWarm(container: modelContext.container)
            // (61) The Quiz and Wisdom tabs' first-frame numbers, read on
            // the probes' own executors after the shell's warm-up passes
            // and before Flow's deck. The warm frames above build those
            // tabs' trees but cancel their `.task`s on removal, so the two
            // probes never finished during warm-up and ran again on the
            // real first tap; `TabWarmCache` holds their answers as values,
            // independent of any view's lifetime, and the tabs read them
            // synchronously in their first body.
            TabWarmCache.shared.scheduleWarm(container: modelContext.container)

            // Everything below is background housekeeping -- detached so a slow
            // or unreachable iCloud can never again hold the first screen
            // hostage.
            await JournalAutoExportService.exportIfNeeded(modelContext: modelContext)
            // Pulls the Mac-maintained writing archive in automatically, so
            // "all of it in one place" doesn't depend on remembering to run a
            // file picker in Settings. Idempotent and digest-gated, so this is
            // a no-op on the overwhelming majority of launches.
            await PersonalWritingAutoImportService.importIfNeeded(modelContext: modelContext)
            // Cheap, local, and has to run after the user may have gone to Settings and
            // downloaded a better voice -- releases a stale pin on a basic-quality voice so
            // the download actually takes effect.
            VoicePreference.clearStalePinIfBetterVoiceAvailable()
            // Fetches the neural voice once, on Wi-Fi, in the background. Everything about
            // it is best-effort: until it lands, voice mode speaks with the system voice.
            //
            // Its own Task, NOT awaited inline. This chain used to `await` the
            // 327 MB download right here, ahead of auto-backup, auto-restore,
            // attachment download and the update check -- so on a fresh Wi-Fi
            // device (the one case restore matters) restoring the library
            // waited on a voice model. The foreground handler below already
            // wraps the same call this way; the launch path now matches it.
            Task { await NeuralVoiceStore.shared.prepareIfNeeded() }
            AutoBackupService.backupIfNeeded(modelContext: modelContext)
            await AutoRestoreService.restoreIfNeeded(modelContext: modelContext)
            await AutoRestoreService.downloadPendingAttachments(modelContext: modelContext)
            await updateStatus.checkForUpdate()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await updateStatus.checkForUpdate() }
            // Retry the neural voice on every foreground, not only at launch.
            // The download is Wi-Fi-only, so someone who first opened Cobux on
            // cellular kept the robotic system voice until a full relaunch
            // happened to coincide with Wi-Fi. `prepareIfNeeded` is a no-op
            // once ready or already downloading, so this costs nothing.
            Task { await NeuralVoiceStore.shared.prepareIfNeeded() }
        }
        .onChange(of: seedingStatus.isSeeding) { wasSeeding, isSeeding in
            if wasSeeding && !isSeeding {
                WatchSyncService.sync(modelContext: modelContext)
                updateEngagementNudges()
                // Retry the writing import the moment seeding is done.
                //
                // This is why his Apple Notes and Apple Journal archive never
                // appeared, on any build. `importIfNeeded` opens with
                // `guard !SeedingStatus.shared.isSeeding`, and `isSeeding` was
                // set true synchronously at app start and cleared only after
                // the whole seed pass finished -- while the import runs from
                // ContentView's `.task`, which fires inside that window. So it
                // returned immediately and never tried again. Every launch,
                // silently, for weeks, while he asked repeatedly where his
                // writing was.
                //
                // The guard itself is right (the import must not race a
                // mutating merge); what was missing is the retry.
                Task { await PersonalWritingAutoImportService.importIfNeeded(modelContext: modelContext) }
                // Same defect, found by the new busy-guard rule the moment it
                // was written: both of these also skip on isSeeding and had
                // nobody retrying them, so on any launch that seeds -- which is
                // EVERY launch of a new build -- automatic backup and restore
                // were skipped for the whole session and never tried again.
                //
                // Restore is retried ONCE here, at the bottom of this block --
                // this used to fire it a second time as well, and since every
                // guard inside `restoreIfNeeded` ran before its first `await`,
                // both tasks passed them, both imported, and a fresh install
                // with an iCloud backup came up with two copies of the whole
                // journal under the same ids. The service now holds an
                // in-flight flag of its own; one call site is still the right
                // number.
                AutoBackupService.backupIfNeeded(modelContext: modelContext)
                // A foreground that landed mid-seed skips the check below entirely
                // (guarded out rather than deferred) -- retry here once it's
                // actually safe, so a pending batch doesn't sit undelivered until
                // some unrelated future foreground/background transition.
                if scenePhase == .active {
                    checkPendingBatchGeneration()
                }
                // Same deferral, same reason, for the launch sheets -- and this
                // one matters most on exactly the launch What's New exists for.
                // `seedDatabase` sets `isSeeding` on EVERY launch, not just a
                // first run (see its own comment: an upgrade launch is a real
                // mutating merge), and it is started from a `.task` on this very
                // view. So `resolveLaunchSheets`, called from this view's other
                // `.task` below, races the seed flag on every single update
                // launch -- and lost that race meant returning at its first
                // `guard` and never being called again, silently dropping the
                // What's New sheet on the update it was written for. That is the
                // same user-visible outcome 2.5.2's sheet-collision fix set out
                // to prevent, reached by a second path the fix didn't cover.
                // Safe to call twice: every branch of it is guarded on
                // `hasOfferedPostUpgradeExport`/`lastSeenChangelogBuild`, so a
                // launch that already resolved its sheets no-ops here.
                resolveLaunchSheets()
                // Covers "seed finished later" for backup/restore too -- the
                // cold-launch `.task` above only covers "seed already
                // finished by the time it ran." Both gate on `isSeeding`
                // themselves as well; this guard is belt-and-suspenders, not
                // load-bearing on its own.
                AutoBackupService.backupIfNeeded(modelContext: modelContext)
                Task {
                    await AutoRestoreService.restoreIfNeeded(modelContext: modelContext)
                    await AutoRestoreService.downloadPendingAttachments(modelContext: modelContext)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, !seedingStatus.isSeeding else { return }
            checkPendingBatchGeneration()
        }
        .sheet(isPresented: $showingPostUpgradeExportPrompt, onDismiss: {
            hasOfferedPostUpgradeExport = true
            maybeShowWhatsNewThenFlow()
        }) {
            PostUpgradeExportPromptLoader()
        }
        .sheet(isPresented: $showingWhatsNew, onDismiss: {
            lastSeenChangelogBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? lastSeenChangelogBuild
            presentFlowOnLaunchIfNeeded()
        }) {
            WhatsNewSheet(sinceBuild: lastSeenChangelogBuild)
        }
        // Flow itself is `flowOverlay`, up in the overlay chain; its close
        // handling is `flowDidClose`. `launchedFromDeepLink` is consumed
        // there, once, for exactly the one dismissal it was set to suppress:
        // `onOpenURL` is the only writer and `flowDidClose` the only reader;
        // the writer arms the flag only when it is actually closing Flow, and
        // the reader clears it again either way -- belt and braces for a
        // once-per-install offer that a new user has the best chance of
        // wanting in their first session. When nothing cleared it, a single
        // widget tap killed the invite for the entire life of the process.
        .sheet(isPresented: $showingWidgetInvite, onDismiss: {
            // Dismissed forever by any route, including a swipe down. There is
            // deliberately no second ask: a repeat prompt is a nag, and he
            // rejected the mildest engagement tactic in the app today.
            hasSeenWidgetInvite = true
        }) {
            if let sample = widgetInviteQuote {
                WidgetInviteView(quote: sample.quote,
                                 bookTitle: sample.book,
                                 accentHex: sample.accentHex) {
                    hasSeenWidgetInvite = true
                    showingWidgetInvite = false
                }
            }
        }
    }

    /// A real highlight for the invite's mock, never a fabricated one — the
    /// preview has to be honest or the Home Screen exposes it within the hour.
    ///
    /// A COUNT and a handful of one-row fetches at random offsets. It used to
    /// `filter { !$0.highlights.isEmpty }` across every book, which faulted the
    /// ENTIRE highlight table onto the main actor -- 32,125 highlights across
    /// 156 seed books (`scripts/check-corpus-scale.py`, build 52), before a
    /// single word the user wrote themselves -- at the exact moment Flow was
    /// being dismissed. Six random
    /// draws is plenty to find one that reads standalone; if none does, the
    /// first draw is used, matching the old `?? book.highlights.first`.
    private func widgetInviteSample() -> (quote: String, book: String, accentHex: String)? {
        let attached = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.book != nil })
        guard let total = try? modelContext.fetchCount(attached), total > 0 else { return nil }
        var chosen: Highlight?
        for _ in 0..<6 {
            var draw = attached
            draw.fetchOffset = Int.random(in: 0..<total)
            draw.fetchLimit = 1
            guard let highlight = try? modelContext.fetch(draw).first else { continue }
            if FlowQueueBuilder.readsStandalone(highlight.text) {
                chosen = highlight
                break
            }
            if chosen == nil { chosen = highlight }
        }
        guard let highlight = chosen, let book = highlight.book else { return nil }
        return (highlight.text, book.title, book.coverColorHex)
    }

    /// Promotes background quiz generation from "the user has to remember to come back and
    /// tap Check Status" to actually automatic -- checked opportunistically on every
    /// foreground, same pattern as `WatchSyncService.sync` above. A no-op almost always
    /// (`applyResultsIfDone` returns nil immediately if nothing is pending or the batch
    /// isn't done yet), so this is cheap to call this often.
    /// Keeps the two engagement nudges honest on every foreground/background
    /// pass, same cadence as `WatchSyncService.sync`: the evening streak-at-risk
    /// reminder (disarmed automatically once today's activity is recorded) and
    /// tomorrow-morning's "N cards ready" review nudge, computed from the same
    /// question pool the Watch payload derives its due counts from.
    private func updateEngagementNudges() {
        // Sweeps away any streak-at-risk notification a previous build
        // scheduled. See `NotificationManager.cancelStreakAtRiskReminder` for
        // why that feature is gone rather than reworded.
        notificationManager.cancelStreakAtRiskReminder()

        let tomorrowMorning = Calendar.current.nextDate(
            after: .now,
            matching: DateComponents(hour: 9, minute: 0),
            matchingPolicy: .nextTime
        ) ?? .now.addingTimeInterval(24 * 60 * 60)
        // One fetch of one column, shared with the Watch payload. This used to
        // be `books.flatMap(\.chapters).flatMap(\.quizQuestions)` -- every
        // chapter and every question faulted onto the main actor, at launch,
        // on every scenePhase transition and again when seeding ended, to
        // produce two integers.
        let dueDates = WatchSyncService.scheduledDueDates(modelContext: modelContext)
        let dueByMorning = dueDates.filter { $0 <= tomorrowMorning }.count
        notificationManager.updateMorningReviewReminder(dueCount: dueByMorning, enabled: reviewNudgeEnabled)

        let now = Date.now
        let dueNow = dueDates.filter { $0 <= now }.count
        notificationManager.updateDueBadge(dueCount: dueNow, enabled: dueBadgeEnabled)

        // In-app grading changes what's due; keep the home-screen Quick Check
        // card honest on the same cadence as everything else here.
        WidgetCenter.shared.reloadTimelines(ofKind: "CobuxQuickCheckWidget")
    }

    private func checkPendingBatchGeneration() {
        guard BatchGenerationService.pendingBatch != nil else { return }
        Task {
            guard let result = try? await BatchGenerationService.applyResultsIfDone(claudeService: claudeService, modelContext: modelContext) else { return }
            notificationManager.notifyBatchGenerationComplete(bookTitle: result.bookTitle, questionsInserted: result.questionsInserted)
        }
    }

    /// Single entry point for both "first thing you might see this launch" sheets --
    /// the post-upgrade export offer and What's New. These used to be two independent
    /// triggers (`.onAppear` and `.task`), each flipping its own `Bool` `@State` true
    /// with no ordering guarantee between them -- when both applied on the same
    /// upgrade launch, SwiftUI's two independent `.sheet(isPresented:)` modifiers only
    /// ever present one, silently dropping whichever lost the race. Caught live: the
    /// update-banner feature's own "show what changed" half could vanish on exactly
    /// the launch it exists for. Now one deterministic order instead: the export
    /// offer first if it applies (protects against data loss, the higher-stakes
    /// case), with its own `onDismiss` continuing on to `maybeShowWhatsNew()` --
    /// every path through this function reaches the What's New check exactly once,
    /// never both checks racing to present at the same moment.
    ///
    /// Checked from `.task` (which runs once, same as the `.onAppear` this replaced,
    /// since `ContentView` isn't remounted by tab switches) rather than a stronger
    /// "first launch" signal, since first-launch seeding is still asynchronous at
    /// this point (`seedingStatus.isSeeding`) and `books` may not have finished
    /// loading on the very first call.
    /// The quote plus its attribution, matching what Flow's own share button
    /// produces so a highlight reads the same wherever it is shared from.
    /// Falls back to a bare deep link if the highlight cannot be found -- a
    /// deleted highlight should degrade, not present an empty sheet.
    private func shareText(bookID: UUID, highlightID: UUID) -> String {
        var descriptor = FetchDescriptor<Highlight>(
            predicate: #Predicate<Highlight> { $0.id == highlightID }
        )
        descriptor.fetchLimit = 1
        guard let highlight = try? modelContext.fetch(descriptor).first else {
            return CobuxDeepLink.highlightURL(bookID: bookID, highlightID: highlightID).absoluteString
        }
        if let title = highlight.book?.title {
            return "\"\(highlight.text)\"\n\n— \(title), via Cobux"
        }
        return "\"\(highlight.text)\"\n\n— via Cobux"
    }

    /// A COUNT, evaluated only where the decision is made -- and, thanks to
    /// `||` at the call site, only when `books` is empty -- never a resident
    /// array of every message. See the note where `chatMessages` used to be
    /// declared.
    private func hasAnyChatMessages() -> Bool {
        ((try? modelContext.fetchCount(FetchDescriptor<ChatMessage>())) ?? 0) > 0
    }

    private func hasAnyBooks() -> Bool {
        ((try? modelContext.fetchCount(FetchDescriptor<Book>())) ?? 0) > 0
    }

    private func resolveLaunchSheets() {
        // The seeding gate applies to the post-upgrade EXPORT offer only, not to Flow.
        //
        // It used to guard this whole function, and `CobuxApp` sets `isSeeding = true`
        // synchronously on EVERY launch (not just first run), so on a real library Flow
        // waited for the entire seed/merge pass before it could present -- the Library tab
        // showing first, which is precisely what he reported: "the flow opens up first but
        // i tried and it took a while for it to show on opening i don't want that."
        //
        // Flow is safe to present during seeding because it carries its own precondition:
        // Flow no longer presents itself at all; this comment's Flow branch is inert.
        // On an existing install that is true immediately; on a genuinely fresh install it
        // is false until seeding populates the store, and the `isSeeding` onChange re-runs
        // this then. The export offer, by contrast, reads `books` and counts chat messages
        // (`hasAnyChatMessages()`, a bounded `fetchCount` -- the root `@Query chatMessages`
        // it used to read is gone) to decide whether this is an upgrade, and must not read
        // them mid-merge.
        guard !seedingStatus.isSeeding else {
            maybeShowWhatsNewThenFlow()
            return
        }
        guard !hasOfferedPostUpgradeExport else {
            maybeShowWhatsNewThenFlow()
            return
        }
        // `hasAnyBooks()`, not `!books.isEmpty` -- the same bounded `fetchCount`
        // treatment the chat half of this condition already got. It is read
        // once, here, behind the seeding guard above, so a count is exactly as
        // correct as a materialised array and reads nothing.
        guard hasAnyBooks() || hasAnyChatMessages() else {
            hasOfferedPostUpgradeExport = true
            maybeShowWhatsNewThenFlow()
            return
        }
        showingPostUpgradeExportPrompt = true
    }

    /// `maybeShowWhatsNew()` presents at most one sheet. Flow used to take its
    /// turn here when nothing else did; it no longer presents itself at all, so
    /// the trailing call is a no-op kept only to leave the sheet chain's own
    /// ordering comments intact.
    private func maybeShowWhatsNewThenFlow() {
        if !maybeShowWhatsNew() {
            presentFlowOnLaunchIfNeeded()
        }
    }

    /// Flow is the "open the app and get moving" experience Rajan asked to
    /// see first when opening Cobux -- not a 6th tab (`WisdomGraphView`'s own
    /// `flowHeroCard` doc comment already settled that: five tabs is the
    /// ergonomic ceiling, and `FlowView` itself is built as a full-bleed
    /// modal with its own `dismiss()`-driven exit, not a tab-embeddable
    /// screen), so the fix here reuses that exact same modal entry point
    /// and simply triggers it automatically once per cold launch instead of
    /// waiting for a tap on the Wisdom tab's hero card.
    ///
    /// Deliberately every launch, not one-time like the export offer or
    /// What's New above it in the chain -- called from `resolveLaunchSheets`,
    /// which itself only ever runs once per real app launch (see that
    /// function's own doc comment on why `.task` is the right trigger), so
    /// this fires once per open, not once per foreground/tab-switch.
    ///
    /// Skipped when there's nothing to flow through, the same real gate
    /// `flowHeroCard`'s `scope.hasAnyVisibleHighlight` uses -- an empty
    /// full-screen Flow session on a fresh install would be a worse first
    /// impression than no Flow at all.
    /// **Flow no longer opens itself.** Kept as a no-op call site rather than
    /// ripped out, because three separate launch paths call it and each one's
    /// surrounding comment explains a race it was written to settle.
    ///
    /// The auto-open was the whole point of Flow for a while, and it stopped
    /// being worth its cost: building the first batch took a few seconds, and
    /// during those seconds Flow was a full-screen cover over an app he could
    /// not use. His words: "I actually wanna chat and it still waits... till
    /// then I'm not able to use any other buttons before closing only after I
    /// close the flow then I'm able to successfully use the app."
    ///
    /// A surface that good does not need to be forced on anyone. It is now one
    /// tap from every tab except Chat (the button lives inline in `body`), which also removes an
    /// entire class of bug for free: nothing that opens itself can hijack a
    /// widget tap, so the deep-link race and the reopen-after-seeding latch stop
    /// having anything to guard.
    private func presentFlowOnLaunchIfNeeded() { }


    /// Surfaces `ChangelogView` automatically the first time a tester opens the app
    /// on a build newer than the one they last saw it on -- closing the loop with
    /// `updateBanner` below (nudge to update, then show what they got). Empty
    /// `lastSeenChangelogBuild` means "never recorded" (a build from before this
    /// feature shipped, or the very first launch after onboarding) -- treated as
    /// "nothing to compare against yet" and silently recorded, NOT as "differs from
    /// current," so a brand new install never gets an unwanted sheet the moment
    /// onboarding finishes.
    /// Returns whether it actually presented the sheet -- `maybeShowWhatsNewThenFlow`
    /// needs that to decide whether Flow gets its turn immediately or has to
    /// wait for this sheet's own `onDismiss` to hand off to it instead.
    @discardableResult
    private func maybeShowWhatsNew() -> Bool {
        let runningBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard !runningBuild.isEmpty else { return false }
        guard !lastSeenChangelogBuild.isEmpty else {
            lastSeenChangelogBuild = runningBuild
            return false
        }
        guard lastSeenChangelogBuild != runningBuild else { return false }
        showingWhatsNew = true
        return true
    }

    // Glass, not `.cobuxCard()` (2.2.0): a status banner is exactly the floating-
    // overlay case the redesign plan carves out for real glass -- it sits ABOVE
    // tab content at `.overlay(alignment: .bottom)`, not embedded in it, which is
    // the distinction the plan draws between "floating layer" (glass) and content
    // cards (stay flat). `.capsule` matches the plan's own banner spec.
    // Seeding no longer announces itself. It used to float a progress capsule
    // over the app on launch, which told the user about our bookkeeping at the
    // exact moment they came to read, journal, or ask something: "a user's
    // purpose is to open the app so they can do what the app is meant to do."
    // Nothing about seeding needs a decision or an action from them, so it
    // belongs in the background. The store-health banner above deliberately
    // stays -- that one reports that work will NOT be saved, which is not
    // status chrome but something they have to know before they type.

    // Shown only when `ModelContainerFactory` had to fall back to an in-memory
    // store (the real on-disk store failed to open). Honest, not silent -- nothing
    // done in this state survives quitting the app, and the user deserves to know
    // that before they add a highlight or finish a quiz that will just vanish.
    // Tinted `.cobuxWarning`, not accent, so the glass itself reads as urgent —
    // matching the icon/text — rather than looking like an ordinary branded banner.
    private var storeHealthBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.cobuxWarning)
            Text("Couldn't open your saved library — nothing you do right now will be saved. Try closing and reopening Cobux.")
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cobuxGlassFloating(shape: .capsule, tintColor: .cobuxWarning)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // Accent-tinted, not `.cobuxWarning` -- an available update is routine, not an
    // error state, and shouldn't visually compete with `storeHealthBanner`'s real
    // urgency. Tapping opens TestFlight directly via `openURL` rather than gating on
    // `canOpenURL`: `project.yml` declares no `LSApplicationQueriesSchemes`, so
    // `canOpenURL("itms-beta://")` would report false and make the tap silently do
    // nothing even though `open` itself works fine -- the same latent trap already
    // present at `SettingsView.suggestBook`'s mailto handling.
    private var updateBanner: some View {
        HStack(spacing: 10) {
            // The whole leading area is one Button so tapping the text also opens
            // TestFlight -- kept separate from the dismiss Button below rather than
            // an outer `.onTapGesture`, which can swallow or race a nested Button's
            // own tap depending on hit-testing order.
            Button {
                openURL(AppReleaseInfo.testFlightURL) { _ in }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.cobuxAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cobux \(updateStatus.latestVersion ?? "") is ready in TestFlight")
                            .font(.subheadline.weight(.medium))
                        Text("Tap to open TestFlight and update")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                dismissedUpdateBuild = updateStatus.latestBuild ?? dismissedUpdateBuild
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cobuxGlassFloating(shape: .capsule, tintColor: .cobuxAccent)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}

/// The Flow button's bottom placement: a safe-area inset inside EACH TAB,
/// not on the TabView and not in the system's accessory slot.
///
/// Three shapes have been tried, and the history is the reason this one is
/// written down rather than just written:
///
/// 1. A TabView-level `safeAreaInset`. Right pre-iOS 26, where the docked tab
///    bar extends the bottom safe area. On iOS 26 the bar FLOATS and stops
///    doing that, so the same inset put the button on top of it -- "this is
///    still over the buttons", build 51, the sixth report of that bug.
/// 2. `tabViewBottomAccessory`. Overlap-proof by construction (it is the
///    system's own slot above the floating bar) -- but the system draws a
///    full-width glass capsule around whatever goes in it, and the SDK offers
///    no way to turn that off: `ContainerBackgroundPlacement` has `.tabView`,
///    `.navigation`, `.navigationSplitView` and `.window`, and nothing for
///    this slot. His verdict on seeing it: "i love the new purple button of
///    flow and the animation as well. jsut dont like the whole bar that the
///    flow button is in just keep the flow button."
/// 3. This. Tab CONTENT does get a bottom safe area for the floating bar --
///    which is why the chat composer, the last element of its own VStack with
///    no clearance of its own anywhere, has never once sat under the tab bar.
///    So an inset here reserves real space above the bar exactly the way (1)
///    did pre-26: the button cannot overlap anything at any text size, there
///    is no clearance arithmetic to drift, and nothing draws a container
///    around it.
///
/// The rule that survives all three: bottom-anchored app-level chrome goes in
/// a `safeAreaInset`, never an overlay with a hand-computed gap.
private struct FlowLaunchInset<C: View>: ViewModifier {
    @ViewBuilder let content: () -> C

    func body(content base: Content) -> some View {
        base.safeAreaInset(edge: .bottom) {
            content()
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
    }
}

/// The Flow launch button, second edition -- his brief, verbatim shape:
/// "real time floating... dark purple or something and black and lighting
/// theme with a great and nice font... nice highlights and shadow as well."
///
/// The construction is light-on-a-dark-object rather than a colored fill:
/// a black-to-deep-violet ground, a hairline of light along the top edge
/// (where light would actually strike), a slow specular sheen crossing the
/// surface, a violet glow beneath -- and the whole thing breathes on a slow
/// float. Every motion gates on Reduce Motion, per the standing rule in
/// CobuxMotion.
///
/// Both motions are render-server animations: one state flip on appear,
/// `repeatForever`, and SwiftUI interpolates an offset without ever
/// re-evaluating this body. The sheen used to be a
/// `TimelineView(.animation(minimumInterval: 1/30))` that rebuilt a gradient
/// thirty times a second on four of the five tabs for as long as the app was
/// open -- roughly 18,000 body evaluations per ten minutes of reading, for a
/// decoration. Same look, zero per-frame work.
private struct FlowLaunchButton: View {
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var floatPhase = false
    @State private var sheenPhase = false

    var body: some View {
        Button(action: action) {
            fullLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Flow")
    }

    private var fullLabel: some View {
        label(text: .headline, glyph: .subheadline, horizontal: 30, vertical: 14)
            .background { ground }
            // The lighting: a top-edge hairline where light lands.
            .overlay(topLight)
            // The shadow story: violet glow beneath, black anchor under.
            //
            // Both halves are dialled back in dark mode. This button is built
            // as light on a dark OBJECT, which reads as depth against a pale
            // app -- and as neon once the app behind it is dark too, because
            // the glow has nothing bright to sit against and the violet is the
            // only saturated thing on screen. "the flow button in dark mode
            // looks too bold and to opruple wired to eyes". So the glow drops
            // to less than half its light-mode strength and tightens, and the
            // black anchor deepens instead -- the object still lifts off the
            // page, it just stops broadcasting.
            .shadow(color: Color(hex: "#7C3AED").opacity(colorScheme == .dark ? 0.14 : 0.55),
                    radius: colorScheme == .dark ? 9 : 18, y: colorScheme == .dark ? 4 : 8)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.35),
                    radius: colorScheme == .dark ? 8 : 6, y: colorScheme == .dark ? 4 : 3)
            .contentShape(Capsule())
            // The float: a slow breath, two points of travel.
            .offset(y: reduceMotion ? 0 : (floatPhase ? -2 : 2))
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                       value: floatPhase)
            .onAppear { floatPhase = true }
    }

    private func label(text: Font.TextStyle, glyph: Font.TextStyle,
                       horizontal: CGFloat, vertical: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(glyph, design: .rounded).weight(.bold))
            // A serif, letterspaced -- the app's own book face, on the one
            // object in the app that is always dark whatever the theme.
            // Deliberately not `CobuxTypography.display`, which goes sans in
            // dark mode by the chrome rule: this ground is dark in BOTH
            // themes, so switching the face on the app's theme would change
            // the button for no reason a reader could see. Not `passage`
            // either -- that face is reserved for his own writing. It reads as
            // a mark rather than a control, which is what he asked for after
            // the rounded bold: "make the font or somethign even more
            // beatiful".
            Text("Flow")
                .font(.system(text, design: .serif).weight(.semibold))
                .kerning(2.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, horizontal)
        .padding(.vertical, vertical)
    }

    /// The dark ground: black falling into deep violet.
    ///
    /// Two ramps, same shape. The light-mode one is his -- he asked for it and
    /// then said he loved it, so it does not move. The dark-mode one ends a
    /// third of the way back down the violet: on a dark app the surrounding
    /// paper is no longer there to absorb it, so the same end colour reads as
    /// a lit sign rather than a deep object. Same hue family, same top-to-
    /// bottom fall, less shout.
    private var groundGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(hex: "#07070A"), Color(hex: "#180936"), Color(hex: "#2A0E54")]
                : [Color(hex: "#0B0B0F"), Color(hex: "#2E1065"), Color(hex: "#4C1D95")],
            startPoint: .top, endPoint: .bottom)
    }

    private var ground: some View {
        ZStack {
            Capsule().fill(groundGradient)
            // The sheen: a band of light crossing slowly, forever.
            if !reduceMotion {
                sheen.allowsHitTesting(false)
            }
        }
        // Both layers used to be capsules in their own right; the band is a
        // rectangle now, so the stack clips to the same capsule instead.
        .clipShape(Capsule())
    }

    /// A fixed band -- clear, white at 14%, clear, 36% of the width -- whose
    /// centre travels from the leading edge to the trailing edge in four
    /// seconds and starts over. That is the same light the old per-frame
    /// `sheen(at:)` drew (peak at `phase`, fading to clear 0.18 either side,
    /// clipped to the capsule); here the band is built once and only its
    /// offset animates, which SwiftUI interpolates without re-evaluating any
    /// body.
    private var sheen: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(colors: [.clear,
                                    .white.opacity(colorScheme == .dark ? 0.07 : 0.14),
                                    .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.36)
                // Centred in the capsule by the outer frame, then pushed half
                // a width left (centre on the leading edge) or right (centre
                // on the trailing edge).
                .offset(x: sheenPhase ? width / 2 : -width / 2)
                .frame(width: width, height: proxy.size.height)
                .animation(.linear(duration: 4).repeatForever(autoreverses: false),
                           value: sheenPhase)
        }
        .onAppear { sheenPhase = true }
    }

    /// The hairline where light lands. Half strength in dark mode: on a dark
    /// app this rim is the brightest edge on the screen, and a bright rim is
    /// read as boldness even when the fill underneath it has already been
    /// calmed. "should be gentle" -- said twice, which in his shorthand means
    /// it matters, so the whole lighting story steps back, not just the fill.
    private var topLight: some View {
        Capsule().strokeBorder(LinearGradient(
            colors: [.white.opacity(colorScheme == .dark ? 0.22 : 0.45),
                     .white.opacity(colorScheme == .dark ? 0.03 : 0.06),
                     .clear],
            startPoint: .top, endPoint: .bottom), lineWidth: 1)
    }
}

/// The post-upgrade export prompt with its chat history fetched HERE -- when
/// the sheet is actually presented, which is at most once per install --
/// instead of held resident at the app root by a `@Query` for the life of the
/// process. `PostUpgradeExportPromptView` itself is unchanged and still takes
/// plain arrays.
private struct PostUpgradeExportPromptLoader: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatMessages: [ChatMessage]?
    /// Fetched here rather than handed down from `ContentView`.
    ///
    /// `books` used to be a parameter, which meant the app root had to hold a
    /// live `@Query` over the whole library for the life of the process to
    /// supply a sheet that is presented at most once per install. This loader
    /// already existed to defer the chat fetch for exactly that reason; the
    /// books fetch belongs in the same place, on the same `.task`, behind the
    /// same spinner.
    @State private var books: [Book]?

    var body: some View {
        Group {
            if let chatMessages, let books {
                PostUpgradeExportPromptView(books: books, chatMessages: chatMessages)
            } else {
                ProgressView()
            }
        }
        .task {
            books = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
            chatMessages = (try? modelContext.fetch(FetchDescriptor<ChatMessage>())) ?? []
        }
    }
}
