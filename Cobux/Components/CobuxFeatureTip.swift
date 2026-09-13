import SwiftUI

/// A permanent, rotating feature hint — the app's single walkthrough
/// primitive.
///
/// Rajan's order: "make sure the user is shown the abilities of the app... a
/// walkthrough at sections where necessary, or tips, or carousels, so the
/// user is prompted to use the features. If a user doesn't know the
/// potential they might not be urged to use the app."
///
/// The design: NO modal, NO coach-mark overlay. Each tip is a quiet inline
/// card, in the feature's own hue.
///
/// **THE SLOT IS NOT CANCELABLE.** This reverses the previous doctrine ("shown
/// ONCE per id and dismissed forever"), on his instruction: *"the tips on top
/// of journal whatver those are plus the from your archive shit sohuld not be
/// crossable it should remain there forever. shit always shuffling or sum
/// mayeb idk but not cancelable. this will also help us maintain the dialog
/// and ui consitencys"*. The reason is the last clause. A card that can vanish
/// means the screen has two different shapes, and he reported the journal
/// head's spacing as inconsistent in the same session. A permanent slot is a
/// fixed layout.
///
/// **What stops a permanent slot from becoming a nag** -- which is the entire
/// reason the old doctrine existed -- is that the slot's existence is constant
/// while its CONTENT is not:
///
/// 1. `markUsed()` still retires a tip permanently, and every existing call
///    site is untouched. A feature he actually uses is never explained to him
///    again. That, not the ×, was always the real answer to nagging.
/// 2. What shows ROTATES by day among the tips still unused, so the slot is
///    never the same sentence two days running.
/// 3. When nothing is left to teach, the slot renders nothing and the screen
///    keeps the rest of its head (on the journal, that is the archive card,
///    whose content is inherently different every time).
///
/// Rotation happens on a DAY boundary and is latched for the life of the view
/// (`CobuxFeatureTipHost`), never re-rolled per body evaluation -- a card that
/// changes while he is reading it is worse than one that never changes. Same
/// trap `RemindersView.preview` was just fixed for.
///
/// ONE TIP PER SCREEN PER VISIT still holds: a screen hands
/// `cobuxTip(firstOf:)` its eligible tips and exactly one shows.
///
/// Every case below is PLACED. The registry shipped 5/7 dead once -- tips
/// registered, titled, `markUsed()` wired, and rendered nowhere -- so the
/// rule is now: a case may not be added here without a `cobuxTip` placement
/// in the same commit. Where each one lives:
/// - `.flow`        FlowView, floating under the wordmark on the first open
/// - `.ebb`         JournalListView, above the calendar (first journal visit)
/// - `.messages`    JournalListView, same slot, the visit after Ebb
/// - `.writeBack`   JournalListView, same slot, after Messages
/// - `.keeps`       JournalListView, same slot, while nothing is kept yet
/// - `.boundVolumes` MoreView, above Saved, once the journal has enough to bind
/// - `.chatImages`  ChatView's empty state
/// - `.situations`  ChatView's empty state, after chatImages, while none exist
/// - `.captureQuote` LibraryView, above the grid, while nothing is unsorted
/// - `.bookMenu`    LibraryView, same slot, the visit after captureQuote
enum CobuxTip: String, CaseIterable {
    case ebb
    case flow
    case keeps
    case writeBack
    case boundVolumes
    case chatImages
    case situations
    /// The Share Extension. Registered because its only explanation in the
    /// whole app -- `UnsortedHighlightsView`'s empty state -- sits behind a
    /// door that opens only once `unsortedCount > 0`, so the one screen that
    /// says "quotes you capture via Share land here" can be reached solely by
    /// someone who already knew. A feature whose instructions require having
    /// used it is the exact thing his principle rules out.
    case captureQuote
    /// A book's own context menu: chat about it, quiz on it, hide it from
    /// Flow, mark it finished. Four capabilities behind a hold with no
    /// affordance -- the menu's own comment calls itself "an accelerator,
    /// never a home", which is only true if anyone knows it is there.
    case bookMenu
    /// The iMessage extension. Predates the registry as its own card with
    /// its own flag (`JournalWaysToWriteTip`); folded in so the journal has
    /// ONE queue and one latch instead of two mechanisms that could stack.
    case messages

    /// Whether this card stays until its feature is used, with no way to
    /// close it.
    ///
    /// TRUE only for the journal's cards. That is exactly the scope of his
    /// instruction -- *"the tips on top of journal whatver those are plus the
    /// from your archive shit sohuld not be crossable it should remain there
    /// forever"* -- and removing the close control from the COMPONENT instead
    /// took it off Library, Chat, Flow and More as well, screens he never
    /// mentioned. He found it on Library and said what he wanted there: *"such
    /// app tips shuold either keep shiffling or a cross icon for these fo rthe
    /// user to close or autmatically hide"*.
    ///
    /// So the rule is per card, in one place, rather than per call site: the
    /// journal's slot is permanent because he asked for a fixed layout there,
    /// and everywhere else a card can be closed.
    var isPermanent: Bool {
        switch self {
        case .ebb, .messages, .writeBack, .keeps: true
        default: false
        }
    }

    private var storageKey: String { "cobux.tip.seen.\(rawValue)" }
    /// The Messages card's pre-registry flag, honoured so nobody who already
    /// dismissed it sees it a second time.
    private static let legacyMessagesKey = "cobux.journal.dismissedMessagesTip"

    var seen: Bool {
        get {
            UserDefaults.standard.bool(forKey: storageKey)
                || (self == .messages && UserDefaults.standard.bool(forKey: Self.legacyMessagesKey))
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    /// Call the moment the feature is actually used, so its hint never appears
    /// (or vanishes if already showing). Discovery beats instruction.
    func markUsed() { seen = true }

    var title: String {
        switch self {
        case .ebb: "Meet Ebb"
        case .flow: "This is Flow"
        case .keeps: "Keep a passage"
        case .writeBack: "Write back to yourself"
        case .boundVolumes: "Bind a volume"
        case .chatImages: "Chat can see images"
        case .situations: "Situations"
        case .messages: "Also in Messages"
        case .captureQuote: "Save a line from anywhere"
        case .bookMenu: "Hold a book"
        }
    }

    var body: String {
        switch self {
        // The hold is named because "Never show this again" is the only way to
        // stop Ebb returning to a passage, and a containment control nobody
        // can find is a containment control that does not exist.
        case .ebb: "Ebb walks you backward through your own writing — a card at a time, ending in a door. Hold any card to answer it, or to never see that passage again. Tap EBB up top whenever you want to wander back."
        // Names the two gestures that have no affordance at all. The Like
        // button was removed on his own instruction ("i dont like the like to
        // down at bottom in the first place") and the context menu is a hold
        // with nothing on the card face to suggest it -- so this tip is the
        // ONLY place either one is ever announced. His standing principle:
        // *"user shuold be shown the features cobux offers and put them in
        // fornt of users eyes against them manually finding them out."*
        case .flow: "Flow deals your library one highlight at a time. Swipe on, double-tap a card to like it, hold it for more, or take any line straight into a conversation."
        case .keeps: "Long-press a passage and keep it. Cobux brings it back after a week, then a month, then longer — never graded, just returned."
        case .writeBack: "Wherever your past writing meets you, you can answer it. Your reply joins the entry it answers, and your journal becomes a correspondence with yourself."
        case .boundVolumes: "Pick a stretch of months and Cobux sets your own passages into a real book — a private PDF in the reading face. Find it under Saved → Volumes."
        case .chatImages: "Tap the + in a chat to attach a photo. Cobux can look at it and answer about what it sees."
        case .situations: "Give an ongoing thing with someone its own chat thread, so the context stays together instead of scattering across messages."
        case .messages: "Cobux lives in iMessage too. In any conversation, tap the + and choose Cobux to save a line to your journal without leaving the chat. Turn it on once: Messages → + → More."
        // Names the apps a reader is most likely to be holding a line in.
        // Promises only what the extension does: the quote arrives, unfiled,
        // and filing it is a later choice -- never "it will be sorted for you".
        case .captureQuote: "Reading somewhere else? Select the line, tap Share, and choose Cobux — from Kindle, Books, Safari, anywhere. It arrives here unfiled, and you put it with its book whenever you like."
        case .bookMenu: "Press and hold any book on this shelf. Chat about that book, quiz yourself on it, hide it from Flow, or mark it finished — without opening it."
        }
    }

    /// The feature's hue, so the tip reads as part of its world.
    var tint: Color {
        switch self {
        case .ebb: Color.cobuxEbb
        case .flow, .keeps, .writeBack, .boundVolumes, .messages: Color.cobuxAccent
        case .captureQuote, .bookMenu: Color.cobuxAccent
        case .chatImages: Color.cobuxAccent
        case .situations: Color.cobuxSituation
        }
    }
}

struct CobuxFeatureTip: View {
    let tip: CobuxTip
    /// Called when the user closes the card. Absent for a permanent one.
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if tip.isPermanent {
            card
        } else {
            ZStack(alignment: .topTrailing) {
                card
                // Dismiss is a SIBLING, never nested in another tappable --
                // the documented dead-tap trap. The 44pt frame is both the
                // minimum target and what puts the glyph's centre outside the
                // corner arc (`CobuxRadius`'s rule).
                Button { onDismiss?() } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss tip")
            }
        }
    }

    private var card: some View {
        // The card is the whole view.
        //
        // The 24pt trailing inset on the title stays: it was there to clear the
        // dismiss glyph, and it now reads as a hanging indent that keeps a long
        // title off the card's right corner. Removing it would be a restyle,
        // which this change is explicitly not.
        VStack(alignment: .leading, spacing: 8) {
            Text(tip.title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.7)
                .foregroundStyle(tip.tint)
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(tip.body)
                .font(CobuxTypography.display(colorScheme, size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CobuxSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tip.tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
    }
}

extension View {
    /// Shows `tip` once, at the top of this view, until seen or the feature is
    /// used. One line to add a walkthrough hint to any surface.
    func cobuxTip(_ tip: CobuxTip) -> some View {
        modifier(CobuxTipModifier(tips: [tip]))
    }

    /// Shows the FIRST unseen tip of `tips` (priority order), once per visit
    /// -- the one-tip-per-screen rule. Pass only the tips that are eligible
    /// right now; a tip that drops out of the list mid-visit hides.
    func cobuxTip(firstOf tips: [CobuxTip]) -> some View {
        modifier(CobuxTipModifier(tips: tips))
    }
}

/// The tip on its own, for a surface that cannot stack a card above its
/// content -- Flow's full-screen feed floats this under its wordmark. Renders
/// nothing when there is nothing to show, so it costs no layout.
struct CobuxFeatureTipHost: View {
    let tips: [CobuxTip]
    /// Space below the card, applied ONLY when a card actually renders.
    ///
    /// It lives here rather than on the caller's view for one reason, and it is
    /// the trap `JournalHighlightCard` already documents: padding the slot
    /// instead of the card opens a permanent hole on every screen that has
    /// nothing to show. Default 0, so every existing call site is unchanged.
    var bottomGap: CGFloat = 0
    /// Latched on first creation: the tip this visit shows, if any.
    ///
    /// `State`'s initial value is read once per view identity, which is what
    /// makes the rotation below a rotation rather than a shuffle. The pick is
    /// a function of the day, so it is stable for as long as he is looking at
    /// it and different the next day -- never re-rolled per body evaluation,
    /// the `randomElement()`-in-`body` trap.
    @State private var settled: CobuxTip?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(firstOf tips: [CobuxTip], bottomGap: CGFloat = 0) {
        self.tips = tips
        self.bottomGap = bottomGap
        _settled = State(initialValue: Self.pick(from: tips))
    }

    /// Rotates by day through the tips still worth showing.
    ///
    /// Only tips whose feature has NOT been used are eligible, so the rotation
    /// shrinks as he learns the app and empties when there is nothing left to
    /// teach -- which is what keeps a permanent slot from becoming a permanent
    /// nag. Keyed on days-since-epoch rather than a stored cursor: no new
    /// persistence, and two screens showing the same pool stay in step instead
    /// of drifting apart.
    static func pick(from tips: [CobuxTip]) -> CobuxTip? {
        let eligible = tips.filter { !$0.seen }
        guard !eligible.isEmpty else { return nil }
        let day = Int(Date.now.timeIntervalSince1970 / 86_400)
        // `%` of a non-negative day count against a non-empty array.
        return eligible[abs(day) % eligible.count]
    }

    var body: some View {
        // `!tip.seen` is re-read every render: `markUsed()` from anywhere on
        // the screen (the EBB button, a saved photo) retires the card on the
        // next body without the caller having to poke a counter. For a
        // permanent card that is the only way it leaves; a closable one can
        // also be dismissed, which marks it seen through the same flag so the
        // two exits cannot disagree.
        if let tip = settled, !tip.seen, tips.contains(tip) {
            CobuxFeatureTip(tip: tip, onDismiss: tip.isPermanent ? nil : {
                withAnimation(reduceMotion ? nil : CobuxMotion.snap) {
                    tip.markUsed()
                    // Re-pick immediately so a screen with more than one card
                    // still has something to say, and lands on nothing only
                    // when there is genuinely nothing left -- which is the
                    // "keep shuffling" half of what he asked for.
                    settled = Self.pick(from: tips)
                }
            })
            .padding(.bottom, bottomGap)
        }
    }
}

private struct CobuxTipModifier: ViewModifier {
    let tips: [CobuxTip]

    func body(content: Content) -> some View {
        VStack(spacing: 12) {
            CobuxFeatureTipHost(firstOf: tips)
                .padding(.horizontal, CobuxSpacing.screenMargin)
            content
        }
    }
}
