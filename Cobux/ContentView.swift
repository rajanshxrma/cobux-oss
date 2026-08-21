import SwiftUI
import SwiftData
import WidgetKit

struct ContentView: View {
    @State private var claudeService = ClaudeService()
    @State private var notificationManager = NotificationManager()
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var books: [Book]
    @Query private var chatMessages: [ChatMessage]
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
    /// Auto-presented at the end of `resolveLaunchSheets`'s chain -- see that
    /// function and `presentFlowOnLaunchIfNeeded` for why this waits its turn
    /// behind the two one-time sheets instead of racing them.
    @State private var showingFlowOnLaunch = false
    @State private var pendingDeepLinkBookID: UUID?
    /// The specific highlight a widget tap came from, if the URL carried one --
    /// consumed by `ChatView` to pre-fill the composer with that quote.
    @State private var pendingDeepLinkHighlightID: UUID?
    @State private var celebrationCenter = StreakCelebrationCenter.shared
    @State private var autoRestoreStatus = AutoRestoreStatus.shared
    @AppStorage("reviewNudgeEnabled") private var reviewNudgeEnabled = true
    @AppStorage("dueBadgeEnabled") private var dueBadgeEnabled = true

    /// One NavigationPath per tab that actually pushes content, hoisted here
    /// so it can be reset from outside that tab's own view. Fixes two real
    /// navigation bugs: (1) re-tapping the already-active tab did nothing —
    /// standard iOS behavior is to pop that tab to its root; (2) the More tab
    /// kept whatever screen you'd pushed (Settings, Reminders...) even after
    /// switching away and back, since TabView keeps every tab's view tree
    /// alive rather than tearing it down. More is a menu, not content, so it
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

    var body: some View {
        TabView(selection: tabSelection) {
            LibraryView(path: $libraryPath)
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }
                .tag(0)

            WisdomGraphView(claudeService: claudeService, path: $wisdomPath)
                .tabItem {
                    Label("Wisdom", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(1)

            ChatView(
                claudeService: claudeService,
                pendingDeepLinkBookID: $pendingDeepLinkBookID,
                pendingDeepLinkHighlightID: $pendingDeepLinkHighlightID
            )
                .tabItem {
                    Label("Chat", systemImage: "message.fill")
                }
                .tag(2)

            QuizHomeView(claudeService: claudeService, path: $quizPath)
                .tabItem {
                    Label("Quiz", systemImage: "checkmark.circle.fill")
                }
                .tag(3)

            MoreView(notificationManager: notificationManager, path: $morePath)
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle.fill")
                }
                .tag(4)
        }
        .tint(Color.cobuxAccent)
        .onOpenURL { url in
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
                selectedTab = 2
            } else if url.host == "chat" {
                selectedTab = 2
            }
        }
        .overlay(alignment: .bottom) {
            // Lowest priority of the three -- an available update is background
            // information, not something that should ever cover up an actual
            // degraded-store or seeding-in-progress state.
            if storeHealthStatus.isDegraded {
                storeHealthBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if seedingStatus.isSeeding {
                seedingBanner
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
            guard newPhase == .active || newPhase == .background else { return }
            // NEVER traverse the library's relationships while the background
            // seed/upgrade merge is in flight — that's the confirmed Build-5
            // crash class (relationship fault racing the merge, see BookCard's
            // doc comment), and these two calls fault every chapter, question,
            // and highlight. The isSeeding onChange below re-runs both the
            // moment the merge finishes, so nothing is lost by skipping here.
            if !seedingStatus.isSeeding {
                WatchSyncService.sync(books: books)
                updateEngagementNudges()
            }
            if newPhase == .active {
                celebrationCenter.checkForPendingMilestone()
                // Every real foreground is a genuine "open" for Reminders'
                // Smart Timing option -- see AppActivityTracker's own doc
                // comment on why this and the .task below (cold launch)
                // together are what "every real open" actually requires.
                AppActivityTracker.recordOpen()
            }
            // Re-locks Journal the instant the app leaves the foreground --
            // same trigger point as everything else in this handler, and the
            // whole point of a lock: still up in the app switcher (or after
            // Face ID's own screen-lock kicks in) is exactly when it must be
            // covered, not just at a fresh cold launch.
            if newPhase == .background {
                JournalLockStatus.shared.relock()
                // Backgrounding, not foregrounding -- the export reads
                // whatever was just written (a compose sheet dismissing into
                // background is the most common real trigger), and doing it
                // here keeps it off the foreground's critical path. Wrapped
                // in a Task since exportIfNeeded is async now (its own
                // throttle check runs first and returns immediately on the
                // overwhelmingly common no-op call, before touching iCloud).
                Task { await JournalAutoExportService.exportIfNeeded(modelContext: modelContext) }
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
            // Same seed-merge guard as the scenePhase handler above — a cold
            // launch runs this .task concurrently with seedDatabase's big
            // first-upgrade transaction, which is exactly the window the
            // Build-5 crash lived in.
            if !seedingStatus.isSeeding {
                WatchSyncService.sync(books: books)
                updateEngagementNudges()
            }
            celebrationCenter.checkForPendingMilestone()
            AppActivityTracker.recordOpen()
            await JournalAutoExportService.exportIfNeeded(modelContext: modelContext)
            AutoBackupService.backupIfNeeded(modelContext: modelContext)
            // Restore before its own backfill pass, and both before the rest
            // of launch -- a fresh install with a real iCloud backup should
            // recover its data as early in the cold-launch path as possible,
            // same reasoning `resolveLaunchSheets` already follows for its
            // own one-time launch state.
            await AutoRestoreService.restoreIfNeeded(modelContext: modelContext)
            await AutoRestoreService.downloadPendingAttachments(modelContext: modelContext)
            resolveLaunchSheets()
            await updateStatus.checkForUpdate()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await updateStatus.checkForUpdate() }
        }
        .onChange(of: seedingStatus.isSeeding) { wasSeeding, isSeeding in
            if wasSeeding && !isSeeding {
                WatchSyncService.sync(books: books)
                updateEngagementNudges()
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
            PostUpgradeExportPromptView(books: books, chatMessages: chatMessages)
        }
        .sheet(isPresented: $showingWhatsNew, onDismiss: {
            lastSeenChangelogBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? lastSeenChangelogBuild
            presentFlowOnLaunchIfNeeded()
        }) {
            WhatsNewSheet(sinceBuild: lastSeenChangelogBuild)
        }
        .fullScreenCover(isPresented: $showingFlowOnLaunch) {
            FlowView()
        }
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
        notificationManager.updateStreakAtRiskReminder(
            currentStreak: StreakTracker.currentStreak,
            hasShownUpToday: StreakTracker.hasShownUpToday
        )

        let tomorrowMorning = Calendar.current.nextDate(
            after: .now,
            matching: DateComponents(hour: 9, minute: 0),
            matchingPolicy: .nextTime
        ) ?? .now.addingTimeInterval(24 * 60 * 60)
        let allQuestions = books.flatMap(\.chapters).flatMap(\.quizQuestions)
        let dueByMorning = allQuestions
            .filter { !$0.isSuspended && ($0.dueDate.map { $0 <= tomorrowMorning } ?? false) }
            .count
        notificationManager.updateMorningReviewReminder(dueCount: dueByMorning, enabled: reviewNudgeEnabled)

        let dueNow = allQuestions
            .filter { !$0.isSuspended && ($0.dueDate.map { $0 <= Date.now } ?? false) }
            .count
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
    /// this point (`seedingStatus.isSeeding`) and books/chatMessages may not have
    /// finished loading on the very first call.
    private func resolveLaunchSheets() {
        guard !seedingStatus.isSeeding else { return }
        guard !hasOfferedPostUpgradeExport else {
            maybeShowWhatsNewThenFlow()
            return
        }
        guard !books.isEmpty || !chatMessages.isEmpty else {
            hasOfferedPostUpgradeExport = true
            maybeShowWhatsNewThenFlow()
            return
        }
        showingPostUpgradeExportPrompt = true
    }

    /// `maybeShowWhatsNew()` presents at most one sheet; if it didn't (nothing
    /// new to show), this is where Flow gets its turn instead of the two
    /// racing — see `presentFlowOnLaunchIfNeeded`'s doc comment for why Flow
    /// waits here rather than triggering independently.
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
    private func presentFlowOnLaunchIfNeeded() {
        guard books.contains(where: { !$0.highlights.isEmpty }) else { return }
        showingFlowOnLaunch = true
    }

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
    private var seedingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(seedingStatus.message)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cobuxGlassFloating(shape: .capsule)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

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
