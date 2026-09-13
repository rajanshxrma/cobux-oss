import SwiftUI
import SwiftData
import UIKit

/// The tab shell, paging under the finger — Snapchat's model, with iOS 26's
/// real tab bar.
///
/// WHY THIS IS NOT A `TabView`. Rajan asked for this twice: "the bottom five
/// tabs like chat more wisdom libray etc should be swipable the way on
/// snapchat they are u can go from camera to chat by just swiping left rigth
/// the screen and they move to new tab smoothly like contnued make it exactly
/// liek that." That is *interactive paging*: the next screen tracks the finger
/// continuously and settles, not a gesture that fires and snaps.
///
/// SwiftUI cannot do it. The complete set of `TabViewStyle` conformers in
/// iPhoneOS26.5 is `DefaultTabViewStyle`, `PageTabViewStyle`,
/// `VerticalPageTabViewStyle`, `CarouselTabViewStyle`,
/// `SidebarAdaptableTabViewStyle`, `TabBarOnlyTabViewStyle` and
/// `GroupedTabViewStyle` (read out of the SDK's own `.swiftinterface`, not
/// remembered). `.page` is the only one that pages, and it replaces the Liquid
/// Glass tab bar with page dots. There is no style that is both.
///
/// UIKit is. `UITabBarController`'s interactive-transition delegate pair —
/// `tabBarController(_:animationControllerForTransitionFrom:to:)` and
/// `tabBarController(_:interactionControllerForAnimationController:)` — is
/// still `API_AVAILABLE(ios(7.0))` and carries no `API_DEPRECATED` in
/// `UITabBarController.h` on 26.5, on the same class that declares
/// `tabBarMinimizeBehavior` and `bottomAccessory` (both `ios(26.0)`). So the
/// interactive transition and the modern system bar are the same object. Each
/// tab is a `UIHostingController` over the SwiftUI view it always was.
///
/// WHAT THIS DELIBERATELY DOES NOT ANIMATE. The delegate hands back an
/// animation controller *only while a finger is driving one* (`isTransitioning`).
/// A tab-bar tap, a deep link, any programmatic `selectedTab` write — all get
/// `nil`, which is UIKit's instant swap. That is the same rule `ContentView`
/// states in prose and must keep: no animation is bound to `selectedTab`, so
/// opening Chat never animates a composer into place.
///
/// GESTURE SAFETY. See `Coordinator.gestureRecognizerShouldBegin`: the pan is
/// vetoed unless it is decisively horizontal, away from both screen edges, off
/// the tab bar, outside any horizontally-scrollable scroll view or text input
/// under the touch, and at the root of the visible tab's navigation stack.
///
/// WHAT A TAP COSTS, and what this shell does about it (build 59). Rajan:
/// "the menus and moving is so fucking slow ... like on Instagram and
/// Snapchat, their bottom menus are just so fast to move around ... whenever
/// I click it still loads ... it should never be this slow." A tap was never
/// animated here -- the delegate hands it `nil` and UIKit swaps at once -- so
/// the slowness was never the transition. It was the work that ran in the
/// same frame as the swap:
///
///   1. `updateUIViewController` reassigned every host's `rootView` on every
///      `ContentView` body pass, and a tap IS a body pass (`selectedTab`
///      changes). Five SwiftUI trees re-diffed and re-evaluated per tap, four
///      of them off screen; `Page.content` is an `AnyView`, precisely the
///      wrapper that denies SwiftUI the type identity it would use to skip a
///      subtree. Now a root view is forwarded ONCE, and again only when
///      something it cannot see for itself changes -- see
///      `Coordinator.refreshHostsIfNeeded` for the two keys and for why
///      nothing else can go stale.
///   2. The first visit to a tab built it under the thumb. `UITabBarController`
///      loads an unselected child's view on first selection, so the first tap
///      on Library ran `viewDidLoad`, the tab's first `body`, every `@Query`'s
///      first fetch and the first layout between the tap and the pixel. Now
///      the off-screen tabs are built after launch settles, one per pass,
///      nearest neighbour first -- see `Coordinator.scheduleWarmUp`.
///   3. Re-appear work each tab did on its own tap frame (Chat's full
///      transcript reload, Wisdom's keychain read, Library's highlight count)
///      -- fixed in the tabs, recorded in `docs/regressions.yml`.
struct PagingTabView: UIViewControllerRepresentable {

    /// One tab: its bar item, and the SwiftUI view it hosts.
    struct Page {
        let title: String
        let systemImage: String
        let content: AnyView

        init(title: String, systemImage: String, content: AnyView) {
            self.title = title
            self.systemImage = systemImage
            self.content = content
        }
    }

    /// Two-way, and deliberately the caller's *derived* binding rather than raw
    /// state — `ContentView.tabSelection` carries side effects (re-tapping the
    /// active tab pops it to root; leaving More resets `morePath`) that every
    /// route into this shell has to keep running.
    @Binding var selection: Int
    let pages: [Page]
    /// A second, independent veto on paging, computed by the caller from state
    /// UIKit cannot see. The `UINavigationController` walk in the coordinator is
    /// the primary one; this is the belt to its braces.
    let pagingEnabled: Bool

    // Forwarded into every hosting controller. A `UIHostingController` built by
    // hand does not inherit the SwiftUI environment, and these two are the only
    // values in this app that a hosting controller cannot derive for itself:
    // everything else read anywhere in Cobux (`\.colorScheme`, `\.dismiss`,
    // `\.accessibilityReduceMotion`, `\.openURL`, `\.dynamicTypeSize`) comes
    // from the trait collection or the presentation, live, with no staleness to
    // manage. There are no custom `EnvironmentKey`s and no `environmentObject`s
    // in the app, so this list is the whole of it.
    //
    // Declared as `@Environment` here on purpose: that is what makes SwiftUI
    // re-run `updateUIViewController` when either changes, so what is forwarded
    // can never go stale.
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Reduce Motion is a hard gate (`CobuxMotion`'s standing rule): when it is
    /// on the tab changes instantly instead of tracking the finger.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        let coordinator = context.coordinator
        coordinator.parent = self

        let hosts = pages.map { page -> UIHostingController<AnyView> in
            let host = UIHostingController(rootView: wrapped(page.content))
            host.tabBarItem = UITabBarItem(title: page.title,
                                           image: UIImage(systemName: page.systemImage),
                                           selectedImage: nil)
            return host
        }
        coordinator.hosts = hosts
        coordinator.noteHostsForwarded()
        controller.viewControllers = hosts
        controller.delegate = coordinator
        controller.selectedIndex = clamped(selection)
        // Once. `Color.cobuxAccent` is an asset colour, so the `UIColor` made
        // from it is dynamic and follows the theme on its own; setting it
        // again on every pass was a `tintColorDidChange` walk of five view
        // trees for a value that never moves.
        controller.view.tintColor = UIColor(Color.cobuxAccent)

        coordinator.attach(to: controller)
        coordinator.scheduleWarmUp()
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        // First, always: every callback below reads `parent` for the live
        // binding and the live `pagingEnabled`.
        coordinator.parent = self

        // NOT `hosts[i].rootView = wrapped(page.content)` for every page on
        // every pass any more. That line ran on every `ContentView` body
        // evaluation -- every tab tap, every push, every deep-link flag -- and
        // re-diffed all five trees each time (docs/deferred.md recorded it
        // when the shell shipped in 54). The coordinator now reassigns only
        // when one of the two things a root view cannot see for itself has
        // changed, and defers even that until no finger is on the screen.
        coordinator.refreshHostsIfNeeded()

        // A scene phase change clears any transition still marked in flight.
        //
        // The other way `isTransitioning` could stick is an animator that is
        // created but whose completion never runs, and the realistic instance
        // is backgrounding mid-settle -- swipe a tab, swipe up to home inside
        // 300ms. `UIViewPropertyAnimator` completions across a background
        // cycle are not dependable. `scenePhase` is already an `@Environment`
        // here, so this function re-runs on every phase change and the state
        // self-heals on the next foreground instead of leaving a dead shell.
        if scenePhase != .active {
            coordinator.clearStuckTransition()
        }

        // Never fight a finger. A drag owns `selectedIndex` for as long as it
        // is in flight; the coordinator reconciles the binding when it settles.
        guard !coordinator.isTransitioning else { return }
        let target = clamped(selection)
        if controller.selectedIndex != target {
            controller.selectedIndex = target
        }
    }

    private func clamped(_ index: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(index, 0), pages.count - 1)
    }

    /// The environment bridge. `.modelContainer` rather than a bare
    /// `.environment(\.modelContext,)` because `@Query` — used throughout the
    /// tabs — wants the container registered, not just a context handed over.
    /// The context here *is* `container.mainContext`, so this is the same
    /// object the tabs read today, not a second one.
    private func wrapped(_ content: AnyView) -> AnyView {
        AnyView(
            content
                .tint(Color.cobuxAccent)
                .environment(\.scenePhase, scenePhase)
                .modelContainer(modelContext.container)
        )
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PagingTabView
        var hosts: [UIHostingController<AnyView>] = []
        private weak var controller: UITabBarController?
        private weak var pan: UIPanGestureRecognizer?

        /// Non-nil only while a finger is driving a tab transition.
        private var interactor: UIPercentDrivenInteractiveTransition?
        /// Cancelled and replaced on every transition. Whatever else happens,
        /// this fires and releases the lock.
        private var watchdog: DispatchWorkItem?
        /// Set when UIKit actually asks for an animator, so `begin` can tell
        /// "a transition started" from "nothing happened".
        private var vendedAnimator = false
        /// True from the moment a drag commits to a tab change until the
        /// transition's completion handler runs. While it is true, `selectedIndex`
        /// belongs to the gesture and `updateUIViewController` keeps its hands off.
        private(set) var isTransitioning = false
        private var transitionFrom = 0
        private var transitionTo = 0
        /// Which way the incoming screen enters — taken from the finger, not from
        /// the index delta, so it stays right in right-to-left layouts.
        private var incomingFromRight = true
        /// Set once per gesture when the drag cannot page (no tab that way, or
        /// Reduce Motion is deferring the decision to `.ended`).
        private var panBlocked = false
        /// Under Reduce Motion nothing tracks; the direction is remembered here
        /// and applied as an instant change when the finger lifts.
        private var deferredDirection: Int?

        init(_ parent: PagingTabView) {
            self.parent = parent
        }

        // MARK: Root-view forwarding

        /// What the hosts' root views were last built from. A root view is
        /// reassigned only when one of these changes -- never merely because
        /// `ContentView`'s body ran.
        ///
        /// WHY NOTHING ELSE CAN GO STALE. Every value `ContentView` puts into a
        /// `Page` is either a `Binding` to its own `@State` (`$libraryPath`,
        /// `$pendingDeepLinkBookID`, ...) or a reference (`ClaudeService`,
        /// `NotificationManager`). A `Binding` made from `@State` reads and
        /// writes the State's storage box, not the struct copy it was made
        /// from -- the same fact that lets a `Button { count += 1 }` closure
        /// work from a stale `self` -- so a root view built on pass 1 still
        /// sees and drives the live value on pass 500. The Flow button's
        /// `showingFlowOnLaunch = true` is a `@State` write for the same
        /// reason. `ContentView` states this contract where the pages are
        /// built. What CAN go stale is the environment this shell forwards by
        /// hand in `wrapped(_:)` -- `scenePhase` -- and the set of pages
        /// itself, so those are the two keys.
        ///
        /// Deliberately NOT keyed on the selected index, although the plan in
        /// docs/deferred.md floated that. Refreshing the incoming tab on every
        /// selection would put one full body pass of that tab back into the
        /// tap frame -- and for Chat, the tab he taps most, that is the heaviest
        /// body in the app. The tab is not stale (above), so there is nothing
        /// for that pass to correct.
        private var forwardedScenePhase: ScenePhase?
        private var forwardedPageTitles: [String] = []
        /// Set when a refresh fell due while a finger was driving a transition.
        /// Reassigning five root views mid-drag is a layout pass under the
        /// finger, so it waits for `transitionEnded` -- the explicit refresh
        /// at the end of a transition that docs/deferred.md asked for, here
        /// with a real job: a scene-phase change that landed mid-settle.
        private var needsHostRefresh = false

        /// Records what `makeUIViewController` just forwarded, so the first
        /// `updateUIViewController` does not immediately forward it again.
        func noteHostsForwarded() {
            forwardedScenePhase = parent.scenePhase
            forwardedPageTitles = parent.pages.map(\.title)
        }

        /// Forwards the pages' root views if, and only if, what they were last
        /// built from has changed. Called from every `updateUIViewController`;
        /// a no-op on the ordinary pass, which is the whole point.
        func refreshHostsIfNeeded() {
            let titles = parent.pages.map(\.title)
            guard forwardedScenePhase != parent.scenePhase || forwardedPageTitles != titles else { return }
            if isTransitioning {
                needsHostRefresh = true
                return
            }
            refreshHosts()
        }

        /// Reassigns every host's root view from the live pages. The one place
        /// `rootView` is written after `makeUIViewController`.
        private func refreshHosts() {
            needsHostRefresh = false
            forwardedScenePhase = parent.scenePhase
            forwardedPageTitles = parent.pages.map(\.title)
            for (index, page) in parent.pages.enumerated() where index < hosts.count {
                hosts[index].rootView = parent.wrapped(page.content)
            }
        }

        // MARK: Warm-up

        /// The off-screen tabs, built before he gets to them.
        private var warmUpTask: Task<Void, Never>?

        /// `UITabBarController` loads an unselected child's view the first time
        /// it is selected -- so before this, the first tap on Library ran the
        /// hosting controller's `viewDidLoad`, the tab's first `body`, every
        /// `@Query`'s first fetch and the first layout pass in the same frame
        /// as the swap. "whenever I click it still loads" is that frame.
        ///
        /// This gives each off-screen host a real frame and lays it out once,
        /// off-window, after launch has settled: the hierarchy exists, the
        /// queries have answered, the layout is cached, and the first real
        /// selection is a swap of a finished view -- Instagram's and Snapchat's
        /// model, where the neighbouring screens are already built. Ordered
        /// nearest neighbour first (one swipe away), one host per pass with a
        /// gap between, so the tab on screen never waits behind two of them.
        ///
        /// SAFETY. Never while `SeedingStatus.shared.isSeeding`: building a
        /// tree against a store the seed merge is mutating is the Build-5
        /// crash class, and Library's grid is the surface that hit it. Never
        /// under a finger (`isTransitioning`) and never in the background.
        /// No model object leaves the main actor -- this is the same main-actor
        /// layout pass the tab would get on selection, only earlier. Whether
        /// SwiftUI treats an off-window layout as an appearance (and so runs
        /// the tabs' `.task`s here) cannot be settled from this Mac; every
        /// root-level `.task`/`.onAppear` in the five tabs is guarded on the
        /// seed flag and reads only counts or its own actor-isolated probe, so
        /// it is safe either way -- and if they do not run here, the redacted
        /// first states the tabs already draw fill in on first selection,
        /// exactly as they do today.
        ///
        /// Safe-area insets are zero off-window, so the first on-window layout
        /// re-runs with the real ones. That is a layout pass over a built tree,
        /// not the build; the build is what this moves.
        func scheduleWarmUp() {
            warmUpTask?.cancel()
            warmUpTask = Task { @MainActor [weak self] in
                // The launch tab's first frame and `ContentView`'s launch
                // `.task` chain go first.
                try? await Task.sleep(for: .milliseconds(900))
                while SeedingStatus.shared.isSeeding {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard let self, let controller = self.controller else { return }
                let anchor = controller.selectedIndex
                let order = self.hosts.indices.sorted { abs($0 - anchor) < abs($1 - anchor) }
                for index in order {
                    guard !Task.isCancelled else { return }
                    while self.isTransitioning || self.parent.scenePhase != .active {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                    }
                    // Read again at the moment of use, not trusted from above.
                    guard !SeedingStatus.shared.isSeeding else { return }
                    let host = self.hosts[index]
                    // He may have got there first; a loaded view is a warm view.
                    guard index != controller.selectedIndex, !host.isViewLoaded else { continue }
                    host.view.frame = controller.view.bounds
                    host.view.layoutIfNeeded()
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }

        // MARK: Gesture

        func attach(to controller: UITabBarController) {
            self.controller = controller
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            // `cancelsTouchesInView` stays at its default `true`: touches reach
            // buttons and rows normally right up until this recognizer actually
            // wins, and are cancelled the moment it does. Setting it false would
            // let a control under the finger fire on release after a page.
            controller.view.addGestureRecognizer(pan)
            self.pan = pan
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let controller, let root = controller.view else { return }
            let width = root.bounds.width
            guard width > 0 else { return }
            let translation = pan.translation(in: root).x

            switch pan.state {
            case .began:
                panBlocked = false
                deferredDirection = nil
                let fingerMovingLeft = pan.velocity(in: root).x < 0
                let step = parent.layoutDirection == .rightToLeft
                    ? (fingerMovingLeft ? -1 : 1)
                    : (fingerMovingLeft ? 1 : -1)
                guard let target = neighbour(of: controller.selectedIndex, step: step) else {
                    panBlocked = true
                    return
                }
                guard !parent.reduceMotion else {
                    // "Instant rather than tracked" — decided when the finger
                    // lifts, so a twitch is still recoverable.
                    deferredDirection = step
                    return
                }
                // Zeroed here so progress starts at exactly 0 at the instant the
                // transition starts. Without this the recognizer's own ~10pt
                // activation distance would show up as a jump on the first frame.
                pan.setTranslation(.zero, in: root)
                begin(from: controller.selectedIndex, to: target, fingerMovingLeft: fingerMovingLeft)

            case .changed:
                guard !panBlocked, let interactor else { return }
                interactor.update(progress(for: translation, width: width))

            case .ended, .cancelled, .failed:
                defer {
                    panBlocked = false
                    deferredDirection = nil
                }
                if let interactor {
                    self.interactor = nil
                    let settled = progress(for: translation, width: width)
                    let velocity = pan.velocity(in: root).x
                    let flickedOnward = abs(velocity) > 450
                        && (incomingFromRight ? velocity < 0 : velocity > 0)
                    if pan.state == .ended, settled > 0.32 || flickedOnward {
                        interactor.finish()
                    } else {
                        interactor.cancel()
                    }
                } else if pan.state == .ended, let step = deferredDirection {
                    // Reduce Motion: no animation controller is ever produced for
                    // this, so `selectedIndex` swaps the screen outright.
                    let settled = abs(translation) / width
                    guard settled > 0.32 || abs(pan.velocity(in: root).x) > 450,
                          let target = neighbour(of: controller.selectedIndex, step: step) else { return }
                    controller.selectedIndex = target
                    commit(target)
                }

            default:
                break
            }
        }

        /// Signed against the committed direction and clamped at 0, so dragging
        /// back past the start holds the transition at its origin instead of
        /// running it forward again the other way.
        private func progress(for translation: CGFloat, width: CGFloat) -> CGFloat {
            let towardTarget = incomingFromRight ? -translation : translation
            return min(max(towardTarget / width, 0), 1)
        }

        private func neighbour(of index: Int, step: Int) -> Int? {
            let target = index + step
            return (target >= 0 && target < hosts.count) ? target : nil
        }

        private func begin(from: Int, to: Int, fingerMovingLeft: Bool) {
            guard let controller, !isTransitioning else { return }
            transitionFrom = from
            transitionTo = to
            incomingFromRight = fingerMovingLeft
            isTransitioning = true
            let interactor = UIPercentDrivenInteractiveTransition()
            // The scrubbed animator is linear so the screen tracks the finger
            // 1:1; the ease belongs to the settle after the finger lifts.
            interactor.completionCurve = .easeOut
            self.interactor = interactor
            // This is what actually starts the transition. Programmatic
            // `selectedIndex` does not call the delegate's selection callbacks,
            // so there is no feedback loop back into the binding here.
            vendedAnimator = false
            controller.selectedIndex = to

            // ROLL BACK if nothing started.
            //
            // `isTransitioning` is set above and cleared in exactly one place:
            // the animator's completion. So it clears if and only if UIKit
            // asked for an animator. Should that write above ever produce no
            // transition, the flag would stay true forever -- and since this
            // build added `guard !isTransitioning` to both
            // `gestureRecognizerShouldBegin` and `shouldSelect`, a stuck flag
            // now refuses every swipe AND every tab tap AND every programmatic
            // change, which is the whole shell dead until the app is force
            // quit. Those guards are right, but they turned an unlikely stuck
            // flag from "some swipes get eaten" into a lockout, so the flag
            // must not be able to stick.
            //
            // This does not depend on knowing whether UIKit consults
            // `shouldSelect` for a programmatic write -- the header asserts it
            // does not, and the evidence supports that, but an assertion is a
            // poor thing to hang the shell on. Either way: no animator, no
            // transition, so put the flag back.
            // `self.interactor`, explicitly: the local `let interactor` above
            // shadows the property here, so the unqualified name is the
            // constant and does not compile.
            if !vendedAnimator {
                isTransitioning = false
                self.interactor = nil
                return
            }

            // THE WATCHDOG. An animator exists, so the rollback above does not
            // apply and the flag now depends entirely on that animator's
            // completion running. `UIViewPropertyAnimator` does not guarantee
            // that -- an interrupted settle or a background cycle mid-flight
            // can swallow it -- and one swallowed completion used to mean the
            // tab bar never worked again.
            //
            // The transition is 0.3s. If nothing has reported back in four
            // times that, the transition is not happening and the lock is
            // released regardless. Cheap, unconditional, and it makes the
            // stuck state impossible rather than merely unlikely.
            let token = DispatchWorkItem { [weak self] in
                guard let self, self.isTransitioning else { return }
                self.interactor?.cancel()
                self.clearStuckTransition()
            }
            watchdog?.cancel()
            watchdog = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: token)
        }

        /// Drops a transition the animator never finished reporting on.
        ///
        /// Deliberately does NOT touch `selectedIndex`: whatever UIKit left on
        /// screen is what the user is looking at, and the binding is reconciled
        /// by the next `updateUIViewController` pass. This only releases the
        /// lock.
        func clearStuckTransition() {
            watchdog?.cancel()
            watchdog = nil
            guard isTransitioning else { return }
            isTransitioning = false
            interactor = nil
            vendedAnimator = false
            // A refresh that fell due during the transition this just
            // abandoned lands now, not on some later pass.
            if needsHostRefresh { refreshHosts() }
        }

        /// Runs once per transition, whichever way it ended.
        private func transitionEnded(finished: Bool) {
            watchdog?.cancel()
            watchdog = nil
            isTransitioning = false
            interactor = nil
            // The explicit end-of-transition refresh. It has work to do only
            // when the forwarded environment changed while the finger was
            // down (backgrounded mid-settle); a cancelled swipe on its own
            // leaves nothing stale -- see `forwardedScenePhase`.
            if needsHostRefresh { refreshHosts() }
            guard let controller else { return }
            let landed = finished ? transitionTo : transitionFrom
            // UIKit restores `selectedViewController` itself when a transition
            // completes as cancelled. This reconciles the one case where it did
            // not — and because `isTransitioning` is already false, the delegate
            // hands back no animator for it, so it is an instant correction
            // rather than a second slide.
            if controller.selectedIndex != landed {
                controller.selectedIndex = landed
            }
            commit(landed)
        }

        /// The only place a swipe writes SwiftUI state — once, after the screen
        /// has already moved. Nothing is written mid-drag, so a drag causes no
        /// `ContentView` body evaluation at all until it settles.
        private func commit(_ index: Int) {
            guard parent.selection != index else { return }
            parent.selection = index
        }

        // MARK: UITabBarControllerDelegate

        func tabBarController(_ tabBarController: UITabBarController,
                              shouldSelect viewController: UIViewController) -> Bool {
            // A TAP IS NEVER REFUSED. This used to be
            // `guard !isTransitioning else { return false }`, to stop a tap
            // landing mid-settle and being overwritten by the drag's own
            // completion. That trade was wrong by an enormous margin and
            // Rajan hit it on the first build that carried it: he opened the
            // app, swiped, and then could not tap Chat or More at all -- the
            // whole tab bar dead, with no way out but force-quitting.
            //
            // The mechanism: `isTransitioning` clears only when the animator's
            // completion runs, and a `UIViewPropertyAnimator` completion is
            // not guaranteed to run (interrupted settle, a background cycle
            // mid-transition). One missed completion and every tab tap was
            // refused forever. The bug it was preventing -- arriving on the
            // wrong tab for a moment -- is a nuisance; this was a brick.
            //
            // So the tap wins, and it also REPAIRS the stuck state on its way
            // through: whatever transition is still marked in flight is
            // abandoned here, which is both what makes the tap land correctly
            // and what makes a stuck flag self-heal on the very next thing the
            // user does, rather than waiting for a scene-phase change.
            if isTransitioning {
                interactor?.cancel()
                clearStuckTransition()
            }
            // Re-tapping the active tab. Handled here as well as in `didSelect`
            // because popping that tab to root is behaviour `ContentView` owns
            // (`tabSelection`'s setter) and this is the callback UIKit is
            // documented to make for every tap, re-selection included. Both
            // paths do the same idempotent thing.
            if let index = tabBarController.viewControllers?.firstIndex(of: viewController),
               index == tabBarController.selectedIndex {
                parent.selection = index
            }
            return true
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              didSelect viewController: UIViewController) {
            guard let index = tabBarController.viewControllers?.firstIndex(of: viewController) else { return }
            // Straight through the caller's binding, side effects and all.
            parent.selection = index
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              animationControllerForTransitionFrom fromVC: UIViewController,
                              to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            // ONLY while a finger is driving. Taps, deep links and every
            // programmatic write get nil — UIKit's instant swap — which is what
            // keeps "no animation bound to `selectedTab`" true.
            guard isTransitioning else { return nil }
            // Records that a transition really is under way, so `begin` can
            // roll the flag back when one never starts.
            vendedAnimator = true
            return TabSlideAnimator(incomingFromRight: incomingFromRight) { [weak self] finished in
                self?.transitionEnded(finished: finished)
            }
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              interactionControllerFor animationController: UIViewControllerAnimatedTransitioning)
        -> UIViewControllerInteractiveTransitioning? {
            interactor
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let controller,
                  let root = controller.view,
                  hosts.count > 1 else { return false }
            // The caller's own veto (a detail pushed through a path it owns).
            guard parent.pagingEnabled else { return false }

            // 0. Not while one is already settling. `isTransitioning` stays
            //    true until the animator's completion, up to 0.3s after the
            //    finger lifts, and without this a second flick started inside
            //    that window did NOTHING AT ALL: the recogniser began, `begin`
            //    bailed on its own `!isTransitioning` guard without setting
            //    `panBlocked` or making an interactor, and `.changed` and
            //    `.ended` then both found nothing to drive. No motion, no tab
            //    change, not even a snap back. Rapid consecutive flicks are
            //    the normal way to use the thing this was modelled on, so the
            //    swipe had to be refused here rather than silently swallowed
            //    three callbacks later.
            //
            //    REFUSED FOR THIS GESTURE ONLY, never permanently. The tap
            //    path repairs a stuck flag outright; this one cannot, because
            //    a swipe genuinely should not start while another is honestly
            //    still settling. The watchdog in `begin` is what guarantees
            //    the flag cannot outlive the transition, so a refusal here is
            //    always bounded.
            guard !isTransitioning else { return false }

            // 1. Decisively horizontal. A diagonal drag belongs to whatever is
            //    scrolling vertically underneath.
            let velocity = pan.velocity(in: root)
            guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }

            // 2. Both screen edges stay the system's. The left edge is the
            //    interactive back gesture (the right edge is, in RTL), and this
            //    holds even if the navigation-depth check below ever stops
            //    finding a stack to measure.
            let translation = pan.translation(in: root).x
            let startX = pan.location(in: root).x - translation
            let edge: CGFloat = 20
            guard startX > edge, startX < root.bounds.width - edge else { return false }

            // 3. Not on the tab bar itself — it has its own gestures on iOS 26.
            if !controller.tabBar.isHidden,
               controller.tabBar.frame.insetBy(dx: 0, dy: -8).contains(pan.location(in: root)) {
                return false
            }

            // 4. Not out of a pushed detail screen. This is a deliberate choice,
            //    not an omission: at depth the horizontal axis is already spoken
            //    for by the interactive back gesture, and "back" would become
            //    ambiguous if the same drag could also land in another tab.
            //    Snapchat's swipe surface is likewise its flat top level.
            if navigationDepth(in: controller.selectedViewController) > 1 { return false }

            // 5. Not over anything that owns horizontal drags itself.
            if touchIsOverHorizontalOwner(at: pan.location(in: root), in: root) { return false }

            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Explicitly exclusive. By the time this pan begins it has already
            // established that nothing else under the touch wants the horizontal
            // axis, so whatever else is tracking should be cancelled rather than
            // run alongside — two things reading one drag is how a pager ends up
            // scrolling a list sideways while it pages.
            false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            // Screen-edge pans always win: system back/forward, and anything
            // else the OS puts on an edge.
            if other is UIScreenEdgePanGestureRecognizer { return true }
            if let nav = Self.firstNavigationController(in: controller?.selectedViewController),
               let pop = nav.interactivePopGestureRecognizer, other === pop {
                return true
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // THE reason the swipe did nothing on his phone through 54-57.
            //
            // This pan lives on the tab controller's root view. Under it,
            // every tab is a vertical `List`/`ScrollView`, and a `UIScrollView`'s
            // own pan recognises on ANY drag past its threshold -- sideways
            // included, even when its content has no horizontal axis. Two
            // exclusive recognisers (`shouldRecognizeSimultaneouslyWith` is
            // false, on purpose) race, the deeper one wins, and ours is reset
            // before `gestureRecognizerShouldBegin` ever gets to say the drag
            // was decisively horizontal. `touchIsOverHorizontalOwner` already
            // decided a vertical scroll view has "no horizontal axis to defend
            // and the page should run over it" -- this is the half that makes
            // UIKit agree. So: a vertical-only scroll view's pan waits for ours
            // to FAIL first. Ours fails inside `gestureRecognizerShouldBegin`
            // the moment a drag reads as vertical, so a list scrolls after a
            // handful of points of travel, same as it did; a sideways drag,
            // which used to be eaten, now pages.
            //
            // Scoped to scroll views without a horizontal axis. Anything that
            // owns horizontal drags (a `ScrollView(.horizontal)`, the calendar
            // strip, a text view) keeps winning outright, exactly as before.
            guard let scroll = other.view as? UIScrollView,
                  other === scroll.panGestureRecognizer,
                  scroll.isScrollEnabled,
                  scroll.contentSize.width <= scroll.bounds.width + 1,
                  !scroll.alwaysBounceHorizontal else { return false }
            return true
        }

        // MARK: Hierarchy inspection

        /// Deepest `UINavigationController` stack under a tab. SwiftUI's
        /// `NavigationStack` is backed by one, so this reads the real pushed
        /// depth whether the push came through a path `ContentView` holds, a
        /// `navigationDestination(item:)` inside the tab (Quiz has two), or a
        /// plain `NavigationLink` (Chat's stack has no path at all). If a future
        /// SwiftUI stops using `UINavigationController` this returns 1 and the
        /// caller's `pagingEnabled` is what still covers the path-driven tabs.
        private func navigationDepth(in viewController: UIViewController?) -> Int {
            guard let viewController else { return 0 }
            var depth = 1
            if let nav = viewController as? UINavigationController {
                depth = max(depth, nav.viewControllers.count)
            }
            for child in viewController.children {
                depth = max(depth, navigationDepth(in: child))
            }
            return depth
        }

        private static func firstNavigationController(in viewController: UIViewController?) -> UINavigationController? {
            guard let viewController else { return nil }
            if let nav = viewController as? UINavigationController { return nav }
            for child in viewController.children {
                if let found = firstNavigationController(in: child) { return found }
            }
            return nil
        }

        /// Walks up from the deepest view under the touch. Catches, by
        /// construction rather than by listing screens: the journal calendar's
        /// month strip and every other `ScrollView(.horizontal)` (Wisdom's theme
        /// rails, Chat's suggestion chips, the quiz scope builder), and text
        /// entry, where a horizontal drag means the caret or a selection.
        ///
        /// A vertical `List`/`ScrollView` is *not* caught — its content is no
        /// wider than its bounds, so it has no horizontal axis to defend and the
        /// page should run over it.
        private func touchIsOverHorizontalOwner(at point: CGPoint, in root: UIView) -> Bool {
            var view = root.hitTest(point, with: nil)
            while let current = view, current !== root {
                if current is UITextView || current is UITextField { return true }
                if let scroll = current as? UIScrollView,
                   scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 || scroll.alwaysBounceHorizontal {
                    return true
                }
                view = current.superview
            }
            return false
        }
    }
}

// MARK: - The slide

/// Both screens translate with the finger, one screen width apart, no parallax
/// and no scaling — the whole illusion is that the two tabs are adjacent, which
/// a second moving plane would break.
///
/// Built as an interruptible `UIViewPropertyAnimator` so
/// `UIPercentDrivenInteractiveTransition` scrubs `fractionComplete` directly,
/// and given a LINEAR curve on purpose: an eased curve would run the content
/// ahead of the finger at the midpoint. The ease lives on the interactor's
/// `completionCurve`, which is the part that plays after the finger lifts.
///
/// `CGAffineTransform`, not frame changes: no layout pass per frame, on a shell
/// that has five view trees alive inside it.
private final class TabSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let incomingFromRight: Bool
    private let onEnd: (Bool) -> Void
    private var animator: UIViewPropertyAnimator?

    init(incomingFromRight: Bool, onEnd: @escaping (Bool) -> Void) {
        self.incomingFromRight = incomingFromRight
        self.onEnd = onEnd
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        (interruptibleAnimator(using: transitionContext) as? UIViewPropertyAnimator)?.startAnimation()
    }

    func interruptibleAnimator(using transitionContext: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
        if let animator { return animator }

        let container = transitionContext.containerView
        guard let toController = transitionContext.viewController(forKey: .to),
              let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            // Nothing to move. Finish honestly rather than leaving the tab bar
            // controller waiting on a transition that never completes.
            let empty = UIViewPropertyAnimator(duration: 0, curve: .linear) {}
            empty.addCompletion { [weak self] _ in
                let finished = !transitionContext.transitionWasCancelled
                transitionContext.completeTransition(finished)
                self?.animator = nil
                self?.onEnd(finished)
            }
            self.animator = empty
            return empty
        }

        let offset = incomingFromRight ? container.bounds.width : -container.bounds.width
        toView.frame = transitionContext.finalFrame(for: toController)
        toView.transform = CGAffineTransform(translationX: offset, y: 0)
        container.addSubview(toView)

        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: transitionContext),
                                              curve: .linear) {
            toView.transform = .identity
            fromView.transform = CGAffineTransform(translationX: -offset, y: 0)
        }
        animator.addCompletion { [weak self] _ in
            let finished = !transitionContext.transitionWasCancelled
            fromView.transform = .identity
            toView.transform = .identity
            if !finished { toView.removeFromSuperview() }
            transitionContext.completeTransition(finished)
            self?.animator = nil
            self?.onEnd(finished)
        }
        self.animator = animator
        return animator
    }
}
