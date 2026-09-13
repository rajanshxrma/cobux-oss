import SwiftData
import SwiftUI

/// The compose surface shown inside Messages.
///
/// Deliberately minimal: one text field and Save. Everything the full compose
/// screen offers -- photos, health context, the calendar -- belongs to a screen
/// you opened on purpose. This exists for the thought that arrives mid-
/// conversation and would otherwise be lost by the time you switched apps.
///
/// **Why this surface stopped looking like Cobux, measured rather than felt.**
/// It was the only place in the app that had never been through the design
/// system. `swiftlint CobuxMessages` reported four errors against it --
/// `no_raw_system_color` three times, `no_magic_corner_radius` once -- while
/// every other surface reported none. It set its own radii, its own type, and
/// system colours; and because an app extension's `Bundle.main` is the
/// EXTENSION rather than the app, `Color.accentColor` had no `AccentColor` to
/// resolve and fell back to iOS BLUE. The send arrow in the Messages drawer was
/// a different colour from every other accent in Cobux. His verdict, "it's out
/// of the place, it's not beautiful", was reading a real and specific fact.
///
/// The fix is not new decoration. It is the app's own tokens -- `CobuxSpacing`,
/// `CobuxRadius`, `CobuxTypography`, `CobuxColor`, the kicker/pill control
/// grammar -- applied to a surface that had been improvising them, plus the
/// eight colour sets copied into this extension's own catalogue so they
/// actually resolve here.
///
/// Nothing heavy: these are value types over SwiftUI. No model container is
/// touched until `save()`, no embeddings, no fetch on appear -- an extension
/// gets a fraction of an app's memory and this one has one job.
///
/// Since build 58 the expanded pane has a second mode, "Ask Cobux"
/// (`MessagesAskView`), and the text itself lives in `MessagesPaneModel`
/// rather than in `@State` here. Both for the same reason: the controller
/// REASSIGNS this view when Messages changes the pane size, and what he typed
/// in the strip has to be exactly what the expanded pane shows -- a fact, not
/// a property of how SwiftUI happened to diff two roots.
struct MessagesJournalView: View {
    @Bindable var model: MessagesPaneModel
    let onSaved: () -> Void
    /// Whether Messages is showing the short strip or the full pane.
    var isCompact: Bool = false
    /// Asks the controller to expand, for the cases the strip is too small for.
    var onRequestExpand: () -> Void = {}
    /// Puts text into the iMessage composer. The person sends it.
    var onInsertText: (String) -> Void = { _ in }
    /// Opens the containing app at a route.
    var onOpen: (URL) -> Void = { _ in }

    @State private var saved = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        if isCompact {
            compactCapture
        } else {
            expanded
        }
    }

    // MARK: - Identity

    /// The 3.0 mark, as type rather than as an image.
    ///
    /// Cobux's app icon IS an opening double quote in violet, so the surface
    /// can wear its own identity without shipping a single pixel into a
    /// memory-constrained extension. An SF Symbol rather than a literal `“`
    /// glyph on purpose: a serif quote character carries an enormous empty
    /// descender, and centring it means hand-plotting an offset against a font
    /// size -- the unstated-relationship-between-two-numbers class of bug the
    /// project's own lint rules exist to ban. The symbol has a real baseline,
    /// scales with Dynamic Type for free, and needs no magic numbers.
    private var mark: some View {
        Image(systemName: "quote.opening")
            .foregroundStyle(Color.cobuxAccent)
            .accessibilityHidden(true)
    }

    // MARK: - Compact

    /// The strip IS the feature.
    ///
    /// Before this, the compact strip was a label you tapped to expand, so
    /// saving a line took: open Messages app drawer, tap Cobux, tap to expand,
    /// type, tap Save. His verdict was fair -- "this is too many steps" -- and
    /// what he actually wanted was the feel of texting: type, send, done.
    ///
    /// This cannot become a true iMessage conversation (a Messages extension
    /// is a pane the user opens; it can never receive what is typed into the
    /// real conversation field, and there is no way for an app to be a
    /// textable contact). But the number of steps between a thought and a
    /// saved line can be one, and that is what this does.
    ///
    /// **Why it looked like a field floating in an empty sheet.** `.compact`
    /// has not meant "a thin strip above the keyboard" for several iOS
    /// versions -- Messages hands the drawer a tall pane, and this view was a
    /// single `HStack` with no `Spacer`, so SwiftUI centred one text field in
    /// several hundred points of nothing. That is precisely the screenshot.
    /// The content now sits at the TOP of whatever height it is given and lets
    /// the remainder fall away below it, so the pane reads as composed rather
    /// than as one control adrift.
    ///
    /// `ViewThatFits` keeps that honest in the other direction: where the pane
    /// really is short, or the user is at an accessibility text size that eats
    /// the height, the kicker and the footnote drop and the field row alone
    /// survives -- the one part that is the feature. Nothing is clamped, so
    /// every text size still renders at its true size.
    private var compactCapture: some View {
        // The `Spacer` is OUTSIDE the `ViewThatFits`, not inside its candidates.
        // `ViewThatFits` chooses on each candidate's IDEAL height, and a
        // `Spacer` has an ideal height of zero -- put one inside every candidate
        // and all three measure the same, so the first is always chosen and the
        // fallbacks never run. Outside, each candidate measures its real content
        // and the spacer does the one job it is here for: pinning that content
        // to the top of whatever height Messages hands over.
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: CobuxSpacing.md) {
                    header
                    fieldRow
                    footnote
                }

                VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
                    fieldRow
                    footnote
                }

                fieldRow
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CobuxSpacing.lg)
        .padding(.vertical, CobuxSpacing.md)
    }

    /// The kicker grammar, the same one Flow and Ebb use to name the mechanism
    /// that put something in front of you. Here it names where the line is
    /// going, which is the one thing the strip never said.
    private var header: some View {
        HStack(spacing: CobuxSpacing.sm) {
            mark
                .font(.subheadline.weight(.semibold))
            Text("To your journal")
                .cobuxKicker(tint: Color.cobuxAccent)
            Spacer(minLength: 0)
            if saved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.cobuxGood)
                    .transition(.opacity)
            } else {
                // `onRequestExpand` has been on this view's signature since the
                // strip was rebuilt and was never once called -- the pane had
                // no way to reach the roomier surface, which is part of why the
                // roomier surface was never seen. A quiet chip, the app's
                // secondary-action grammar, so it stays subordinate to the send
                // button that is the actual point of the strip.
                Button(action: onRequestExpand) {
                    // The chip modifier goes on the LABEL, the way every other
                    // call site in the app applies it. Outside the button it
                    // still draws correctly and the padded capsule is not
                    // tappable -- only the four words inside it are.
                    Text("More room")
                        .foregroundStyle(Color.cobuxAccent)
                        .cobuxQuietChip(tint: Color.cobuxAccent)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the full writing pane")
            }
        }
    }

    /// The pill is a BUTTON in the compact strip, not a text field.
    ///
    /// His report on 57: "whenever I click on this text box where it says
    /// save a line to your Journal sometimes it does not show the keyboard,
    /// only when I click on more room it works fine". That is not a focus
    /// bug to be retried harder: in the `.compact` presentation the extension
    /// occupies the space the keyboard would rise into, and whether Messages
    /// grants a compact field first responder is its call, made differently
    /// from one tap to the next. Apple's own guidance for a Messages app is
    /// to begin text input by requesting the expanded presentation. So the
    /// pill does exactly one thing -- asks for `.expanded` -- and the expanded
    /// editor takes focus once the transition has FINISHED
    /// (`MessagesViewController.didTransition` → `model.focusRequest`), which
    /// is the moment a keyboard can actually appear. Same capsule, same type,
    /// same placeholder; only what a tap does changed.
    ///
    /// Anything already in `model.journalText` (typed in the expanded pane,
    /// then collapsed without saving) shows here and can still be saved from
    /// the strip with the arrow.
    private var fieldRow: some View {
        HStack(spacing: CobuxSpacing.sm) {
            Button {
                model.mode = .journal
                onRequestExpand()
            } label: {
                Text(model.journalText.isEmpty ? "Save a line to your journal…" : model.journalText)
                    .font(CobuxTypography.cobuxBody)
                    .foregroundStyle(model.journalText.isEmpty ? Color.cobuxMuted : Color.cobuxInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CobuxSpacing.chipH)
                    .padding(.vertical, CobuxSpacing.chipV)
                    // A real hairline on a real surface -- the app's card grammar
                    // in capsule form. Was `Color(.secondarySystemBackground)`,
                    // which is iOS's grey, not Cobux's paper.
                    .background(Color.cobuxSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.cobuxLine, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save a line to your journal")
            .accessibilityHint("Opens the writing pane and the keyboard")

            sendButton
        }
    }

    private var sendButton: some View {
        Button {
            if canSave { save() }
        } label: {
            Image(systemName: saved ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                // `.title` rather than a fixed 28pt, so the control grows with
                // the field beside it instead of shrinking away from it at
                // accessibility text sizes.
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(saved ? Color.cobuxGood : Color.cobuxAccent)
                .contentTransition(.symbolEffect(.replace))
                // The 44pt minimum, which this control never had.
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!canSave && !saved)
        .accessibilityLabel("Save to journal")
    }

    /// Genuinely useful rather than decorative: the one fact that makes this
    /// extension worth opening instead of switching apps is that it reads
    /// nothing of the conversation it is sitting in, and the surface had never
    /// said so. Doubles as the error line, so a failure never overlaps the
    /// field the way the old floating overlay did.
    private var footnote: some View {
        Text(failed
             ? "Couldn't save. Open Cobux and try there."
             : "Goes straight to Cobux. Nothing in this conversation is read.")
            .font(CobuxTypography.cobuxCaption)
            .foregroundStyle(failed ? Color.cobuxDanger : Color.cobuxMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var canSave: Bool {
        !model.journalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saved
    }

    private var wordCount: Int {
        model.journalText.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Expanded

    /// The full pane: one header, two modes.
    ///
    /// "Journal" is the compose surface that has been here since 52; "Ask
    /// Cobux" is the chat he asked for twice. Two quiet chips rather than a
    /// segmented control, because a `Picker(.segmented)` paints iOS's own
    /// selection colours and this surface has already been through the fight
    /// about looking like iOS instead of like Cobux. The selected chip wears
    /// the accent; the other wears muted -- the same two-tier grammar as
    /// every other chip in the app.
    ///
    /// The compact strip does not know about modes. It is journal, always:
    /// the fastest possible capture is the reason the extension exists, and a
    /// mode switch in a strip that short would be a fifth step.
    private var expanded: some View {
        VStack(alignment: .leading, spacing: CobuxSpacing.lg) {
            expandedHeader
            modeChips
            switch model.mode {
            case .journal:
                expandedCompose
            case .ask:
                MessagesAskView(model: model, onInsertText: onInsertText, onOpen: onOpen)
            }
        }
        .padding(CobuxSpacing.screenMargin)
        // Expanded is a full sheet the user opened deliberately, so it wears
        // the app's ground. The COMPACT strip deliberately does not -- see
        // `MessagesViewController`, which keeps the hosting background clear so
        // the strip never draws a slab over the conversation behind it.
        .background(Color.cobuxBackground)
    }

    private var expandedHeader: some View {
        HStack(spacing: CobuxSpacing.sm) {
            mark
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Cobux")
                    .font(CobuxTypography.cobuxSectionHeader)
                    .foregroundStyle(Color.cobuxInk)
                Text(Self.today)
                    .font(CobuxTypography.cobuxCaption)
                    .foregroundStyle(Color.cobuxMuted)
            }
            Spacer(minLength: 0)
            if saved, model.mode == .journal {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cobuxGood)
                    .transition(.opacity)
            }
        }
    }

    private var modeChips: some View {
        HStack(spacing: CobuxSpacing.sm) {
            modeChip("Journal", mode: .journal)
            modeChip("Ask Cobux", mode: .ask)
            Spacer(minLength: 0)
        }
    }

    private func modeChip(_ title: String, mode: MessagesPaneModel.Mode) -> some View {
        let selected = model.mode == mode
        return Button {
            guard !selected else { return }
            withAnimation(.snappy) { model.mode = mode }
            // A mode he just chose should be ready to type into.
            model.requestFocus()
        } label: {
            Text(title)
                .foregroundStyle(selected ? Color.cobuxAccent : Color.cobuxMuted)
                .cobuxQuietChip(tint: selected ? Color.cobuxAccent : Color.cobuxMuted)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The roomier surface, for anything longer than a line.
    ///
    /// Set in the book face. `CobuxTypography`'s doctrine is explicit that a
    /// journal passage is not chrome -- "the journal is the book he is
    /// writing" -- and gets a serif in BOTH themes wherever his own words
    /// appear. Ebb's cards, the threshold card and Flow's journal echo all
    /// honour that; the one place he was actually WRITING the words did not.
    /// Built on `.body` rather than `CobuxTypography.passage`'s fixed point
    /// size so it still answers Dynamic Type, which a compose field must.
    private var expandedCompose: some View {
        VStack(alignment: .leading, spacing: CobuxSpacing.lg) {
            TextEditor(text: $model.journalText)
                .font(.system(.body, design: .serif))
                .foregroundStyle(Color.cobuxInk)
                .scrollContentBackground(.hidden)
                .padding(CobuxSpacing.md)
                .frame(minHeight: 140)
                .cobuxCard()
                .focused($focused)

            HStack(spacing: CobuxSpacing.sm) {
                if failed {
                    Text("Couldn't save. Open Cobux and try there.")
                        .font(CobuxTypography.cobuxCaption)
                        .foregroundStyle(Color.cobuxDanger)
                } else {
                    // A live count rather than a static caption: the one piece
                    // of information a compose surface can give you for free,
                    // and the reason this pane is worth expanding into.
                    Text(wordCount == 1 ? "1 word" : "\(wordCount) words")
                        .font(CobuxTypography.cobuxCaption)
                        .foregroundStyle(Color.cobuxMuted)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)

            // The one filled pill this surface is allowed, in the app's own
            // control grammar. `.borderedProminent` was drawing iOS's blue
            // capsule -- the same missing-AccentColor fallback as the arrow.
            Button {
                save()
            } label: {
                Text("Save to Cobux")
                    .frame(maxWidth: .infinity)
                    .cobuxPrimaryPill(tint: Color.cobuxAccent)
                    .opacity(canSave ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        // Both, deliberately. `.onAppear` covers the pane launched straight
        // into `.expanded`; `focusRequest` covers the transition FROM compact,
        // where the controller bumps it in `didTransition(to:)` -- after the
        // animation, when the editor can actually take the keyboard. The
        // "sometimes" he reported was focus asked for at the wrong moment.
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { _, _ in
            if model.mode == .journal { focused = true }
        }
    }

    /// Built once. A `DateFormatter` constructed inside a computed property
    /// called from `body` resolves the locale's calendar and symbols on every
    /// body evaluation -- the same fix `RemindersView` already carries.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    private static var today: String { dayFormatter.string(from: .now) }

    // MARK: - Save

    private func save() {
        let body = model.journalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        // Same App-Group container the app, widgets and Share Extension use, so
        // the entry is a first-class journal entry rather than a parallel store
        // that would need reconciling later.
        guard let container = CobuxSchema.makeAppGroupContainer() else {
            failed = true
            return
        }
        let context = ModelContext(container)
        // Same rule as the app composer -- this used to stamp a bare time.
        let stamped = JournalSessionStamp.text(at: .now, previousSessionDate: nil,
                                                  ambient: AmbientContext.cached()) + "\n" + body
        // `"iMessage"`, not `"journal"`. This is the one string that decides
        // whether the entry wears a source pill at all: `JournalSourceFamily`
        // has mapped `"iMessage"` to `.messages` -- label "messages", iMessage
        // green -- since the pills shipped, but nothing ever wrote that string,
        // so an entry texted in was stamped `"journal"` and resolved to
        // `.native`, whose label is deliberately nil. His ask: "there's also a
        // tag if it's from iMessage, if it's from Apple Journal, Apple Notes --
        // I want those to be in bubbles as well." He would have written from
        // Messages and looked for the bubble, and it could never have appeared.
        //
        // `.native` (no pill) is reserved for what is composed inside the app,
        // where provenance is never in question. A Messages entry has real
        // provenance worth naming, which also means it now answers the
        // Journal tab's "Imported" filter (`JournalListView`: anything that
        // did not originate in the composer) -- correctly, since it did not.
        context.insert(PersonalWritingEntry(
            source: "iMessage",
            title: "",
            text: stamped,
            modifiedDate: .now
        ))
        do {
            try context.save()
            // The extension is a separate process: without this the app, widgets
            // and watch keep serving a store they think is unchanged.
            CrossProcessSync.markDirty()
            withAnimation(.snappy) { saved = true }
            // Get out of the way. 0.35s is long enough to register the
            // checkmark and short enough that it reads as automatic -- the
            // previous 0.7s felt like the sheet was not closing at all.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onSaved()
                // Reset AFTER collapsing, so the next open is a blank sheet.
                // Without this the state persisted: reopening showed "Saved"
                // over the last entry with the button disabled, which reads as
                // a broken extension rather than a finished one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    model.journalText = ""
                    saved = false
                    failed = false
                }
            }
        } catch {
            failed = true
        }
    }
}
