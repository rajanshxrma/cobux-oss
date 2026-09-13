import AppIntents
import SwiftUI
import UniformTypeIdentifiers

/// The journal's first-open face — a preview of what it BECOMES, not a blank
/// apology.
///
/// Rajan's order, near-verbatim: "when they open the journal section for the
/// first time they are displayed of what their journal section could look
/// like when they have a lot of journal writing... this will motivate them
/// into writing... also display features in that carousel." And the hard
/// constraint he asked about honestly: iOS gives NO app silent read access to
/// Apple Notes or other writing apps — there is no such API, by Apple's
/// design. So "some writing definitely syncs" becomes import-by-action made
/// unmissable: a one-tap file/folder import surfaced here as a first-class
/// choice, not buried in Settings.
///
/// The carousel is faux entries — clearly sample, never mistaken for his — so
/// the empty room shows its furnished self. Each card doubles as a feature
/// tour: on-this-day, the resonance echo, keeps, the correspondence.
struct JournalFirstRunView: View {
    var onNewEntry: () -> Void
    var onImportFile: () -> Void
    var onImportAppleJournal: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The SAME key `SettingsView` binds, from the service that owns it -- not a
    /// second key with a similar name. Two toggles for one behaviour, disagreeing
    /// about their default, is the defect this codebase has already written up
    /// twice (see `SettingsView`'s note on `useRealNamesInLifeExamples`).
    /// Default `false`, exactly as there: nothing here turns anything on.
    /// Same key AND the same `store:` as `SettingsView` -- the store is as much
    /// part of a setting's identity as its key, and omitting it here is what
    /// made the whole feature inert (see that declaration's note).
    @AppStorage(AmbientContextService.enabledKey, store: CobuxSchema.groupDefaults)
    private var ambientContextEnabled: Bool = true // default ON since 58 -- see AmbientContext.cached()
    /// Set only when iOS has actually refused. Renders one honest line and
    /// nothing else -- no retry button, no second ask. Settings is the way back
    /// in, which is where a permission a user declined belongs.
    @State private var ambientDenied = false

    private struct Sample: Identifiable {
        let id = UUID()
        let kicker: String
        let body: String
        let month: Int
    }

    private let samples: [Sample] = [
        .init(kicker: "ON THIS DAY · A YEAR AGO",
              body: "I keep coming back to the idea that the work is the reward. Not the finish — the doing.",
              month: 3),
        .init(kicker: "YOUR WORDS × YOUR BOOKS",
              body: "The bridge at night, everything quiet. Beside it, from Meditations: \u{201C}Confine yourself to the present.\u{201D}",
              month: 6),
        .init(kicker: "YOU KEPT THIS",
              body: "Whatever you decide, decide it as the person you want to become — not the one you're afraid you are.",
              month: 9),
        .init(kicker: "YOU ANSWERED YOURSELF · TWO YEARS ON",
              body: "I was so sure back then. I'm gentler with him now. He didn't know yet, and that's alright.",
              month: 11),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Your journal")
                        .font(CobuxTypography.display(colorScheme, size: 28, weight: .bold))
                    Text("The book you're writing. Here's what it becomes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    // `.top`, not the default centre. A no-op while every card is
                    // the same 190pt tall, which is every card at every ordinary
                    // text size -- and the thing that keeps the row honest when a
                    // capability card has to grow past that at an accessibility
                    // size, instead of the sample cards floating mid-row.
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(samples) { sample in
                            sampleCard(sample)
                        }
                        // The carousel stops being only a mood board here.
                        //
                        // Rajan's principle, stated as a general rule and not
                        // about one feature: "user shuold be shown the features
                        // cobux offers and put them in fornt of users eyes
                        // against them manually finding them out wherever and
                        // feel they missed out for even a tiny bit of time."
                        //
                        // Both of these facts already existed on this screen --
                        // one in Settings four taps away, one in the tertiary
                        // caption2 paragraph at the bottom that nobody reads.
                        // Same shape as the sample cards, deliberately: the
                        // capabilities are part of what the journal becomes,
                        // not a settings panel bolted to the side of it.
                        // Ordered by what each one ASKS of him, least first.
                        // Durability asks nothing and answers the biggest
                        // unspoken worry, so it leads; weather and place is an
                        // offer with a permission behind it; the last two are
                        // other doors. Four capability cards after four sample
                        // cards is eight, which is more swiping than he already
                        // called a lot -- see the note on `contactCard` for the
                        // one I would drop first if he wants it shorter.
                        durabilityCard
                        ambientCard
                        waysInCard
                        contactCard
                    }
                    .padding(.horizontal, CobuxSpacing.screenMargin)
                }
                .scrollTargetBehavior(.viewAligned)

                Text("These are examples — yours fill in as you write and bring your past writing in.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 10) {
                    Button(action: onNewEntry) {
                        Label("Write your first entry", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                            .cobuxPrimaryPill(tint: Color.cobuxAccent)
                    }
                    .buttonStyle(.plain)

                    Button(action: onImportFile) {
                        // Names what the picker behind it can actually take,
                        // and nothing else. It used to say "Notes, a file, a
                        // folder": the file and the folder are both real
                        // (`PersonalWritingImportService.supportedContentTypes`
                        // includes `.folder`, and a folder is walked inside its
                        // security scope), but Notes is not -- that only ever
                        // arrives through Share → Cobux, which the footnote
                        // below says outright.
                        Label("Bring in past writing (a file or a folder)", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Color.cobuxAccent)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    Button(action: onImportAppleJournal) {
                        Text("Import from the Apple Journal app")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, CobuxSpacing.screenMargin)

                // The honest note -- his own no-false-promises principle.
                //
                // The second half is the answer to "the new users should know
                // about this feature that this exists so there should be
                // somewhere in the app". Every way into the journal that ISN'T
                // this screen used to be announced only by the Messages tip in
                // `JournalListView`, which renders once entries already exist
                // -- invisible to exactly the person who needs it.
                //
                // Three ways are named because three are real for anyone: the
                // bundled Messages extension, the `JournalEntryIntent` Siri
                // phrase, and the journal widget (whose whole surface is a
                // new-entry deep link).
                //
                // The "Journal 📓" self-contact used to be excluded outright,
                // and the reason was right but the conclusion was too wide. What
                // is Rajan-only is the AUTOMATIC part: `CobuxContactService`'s
                // own doc comment (:19-21) says the message ingestion is a
                // script on his Mac, not part of this app. The contact itself
                // works for anyone -- it names a chat with yourself -- and the
                // Messages extension that saves a line out of that chat is
                // bundled and real for everyone. So it is named now, as the
                // manual thing it is, on `contactCard`: not as a path that
                // journals by itself, which it is not, but as a chat you can
                // name and then keep lines from by hand. Both halves have to
                // stay on that card; the promise is false without the second.
                //
                // The three ways in that used to end this paragraph now have
                // their own card in the carousel above, where they are actually
                // looked at. Printing them twice on one screen would be noise,
                // so what is left here is the part no card carries: the honest
                // limit, and the import path that belongs beside the import
                // button directly above it.
                Text("Cobux can't read your Notes app on its own — Apple doesn't allow that. But bringing your writing in takes one tap: in Notes or any writing app, Share → Cobux. Or pick a text, Markdown, RTF or HTML file here — or a folder of them.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Capability cards

    /// Weather and place, explained BEFORE anything is asked of the system.
    ///
    /// This settles a ruling Rajan had been holding (deferred P4: "default on,
    /// or offer once in the composer?"). His answer, and his reason, verbatim:
    /// "waitehre and palce ain journal shoudl be on by deaflut or the user
    /// should go thru the carouseld explaing the ffeatures first of such and
    /// asking them to toggle it in then it will ask for perimssio. such way the
    /// user is not afraid why cobux needs lcaotion serives wetc"
    ///
    /// So the order is fixed and it is the whole feature: **explain, let them
    /// turn it on, and only then ask iOS.** A location sheet that arrives with
    /// no explanation does not read as a permission request, it reads as an app
    /// that wants something -- and a journal is the last app that can afford to
    /// be wondered about. Nothing here runs on appear, on skip, or on finishing:
    /// `requestAuthorization()` is reachable from exactly one place, the
    /// `.onChange` below, and only on the false -> true edge.
    ///
    /// A user who never touches this card ends with the setting off and has
    /// never seen a system prompt. That is the standing rule, not a nicety.
    private var ambientCard: some View {
        capabilityCard(kicker: "WEATHER AND PLACE") {
            Text("So an entry brings the day back with it — the weather, and the city you were in.")
                .font(CobuxTypography.passage(size: 17))
                .lineSpacing(5)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Toggle("Add to my entries", isOn: $ambientContextEnabled)
                .font(.subheadline)
                .tint(Color.cobuxAccent)
                // Identical to the Settings toggle's handler, on purpose: one
                // behaviour, two doors, and a door that asked differently would
                // be a second implementation of a permission rule.
                .onChange(of: ambientContextEnabled) { _, enabled in
                    guard enabled else { ambientDenied = false; return }
                    AmbientContextService.shared.requestAuthorization()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        // A toggle must never sit there claiming a permission
                        // that was declined. It goes back off, says so once, and
                        // never asks again.
                        if AmbientContextService.shared.authorizationDenied {
                            ambientContextEnabled = false
                            ambientDenied = true
                        } else {
                            AmbientContextService.shared.refreshIfNeeded()
                        }
                    }
                }
            if ambientDenied {
                Text("Location is off for Cobux. You can turn it back on in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The ways into the journal that are real for EVERY user.
    ///
    /// Deliberately not the "Journal 📓" contact. `CobuxContactService` creates
    /// a contact pointing at the user's own iMessage address and says so in its
    /// own doc comment (:19-21): "The message ingestion is a script on Rajan's
    /// Mac, not part of this app. A contact created for someone without that
    /// pipeline would look like a feature and do nothing." Putting it in a
    /// first-run carousel would be that defect with a spotlight on it, on the
    /// one screen whose whole job is not over-promising, so it stays in Settings
    /// where its copy promises only that it adds a contact.
    ///
    /// These three ship in the app itself and work on anyone's phone: the
    /// bundled Messages extension (`CobuxMessages/`), the App Intent behind the
    /// Siri phrase (`Cobux/Intents/JournalEntryIntent.swift`), and the journal
    /// widget, whose whole surface is a `cobux://journal/new` deep link.
    ///
    /// No action and no toggle, and that is honest rather than lazy: iOS owns
    /// all three switches. An app cannot install its own widget, enable its own
    /// Messages extension, or register a Siri phrase the user has to accept.
    /// Naming them IS the feature here -- they were already real and already
    /// invisible.
    private var waysInCard: some View {
        capabilityCard(kicker: "OTHER WAYS IN") {
            // Their own stack at 6pt: three items of one list, closer to each
            // other than to the kicker above or the line below. Each string is
            // short enough to hold ONE line at this face inside the card's
            // 228pt of content, which is what stops three list items becoming
            // six.
            VStack(alignment: .leading, spacing: 6) {
                wayIn("plus.message", "In Messages, tap + → Cobux")
                wayIn("mic", "Ask Siri: \u{201C}journal in Cobux\u{201D}")
                wayIn("square.grid.2x2", "The journal widget")
            }
            Spacer(minLength: 0)
            Text("The first two write straight into this journal. The widget opens it here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The card that finally says the journal is safe -- and offers Apple Notes
    /// as a second copy without claiming Cobux can write to it.
    ///
    /// Two facts, and the order is the point.
    ///
    /// FIRST: this has been true since automatic backup shipped and NO screen in
    /// the app has ever said it. `AutoBackupService.maxSnapshots` is 3, rotating,
    /// written atomically to his own iCloud container, and `AutoRestoreService`
    /// pulls them back on reinstall. A safety net nobody knows about is not a
    /// safety net -- it is a feature he would only discover by losing something,
    /// which is the one moment it is too late to reassure anyone.
    ///
    /// SECOND: he asked for entries to sync into an Apple Notes folder, and iOS
    /// ships no API to write into Notes -- there is no Notes module, and
    /// `INCreateNoteIntent` is a protocol an app implements to BE asked by Siri,
    /// not one it can call. So the split is: Cobux produces the words
    /// (`JournalArchiveIntent`, `JournalPlainTextArchive`) and Apple's own
    /// Create Note action does the writing, inside a shortcut the user accepts
    /// once. "via Shortcuts:" is not a stylistic choice -- it is the clause that
    /// keeps the sentence true, and the colon is what makes the button below it
    /// read as the rest of the sentence rather than as decoration. If that
    /// wording ever has to go, the Apple Notes half goes with it; the backup
    /// half stands alone and is the more important one anyway.
    ///
    /// `ShortcutsLink` comes from the `_AppIntents_SwiftUI` cross-import overlay
    /// (iOS 16+), which is why this file now imports AppIntents beside SwiftUI.
    private var durabilityCard: some View {
        capabilityCard(kicker: "ALREADY BACKED UP") {
            Text("Your journal already backs itself up to your iCloud.")
                .font(CobuxTypography.passage(size: 15))
                .lineSpacing(4)
                .foregroundStyle(.primary)
            Text("Three copies, restored if you reinstall. You can also send it to Apple Notes yourself, with a shortcut:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
        }
    }

    /// The self-chat, named -- and its manual half named just as plainly.
    ///
    /// His ask: "i hope theres a coarulsel as well for add journla to ocntacts
    /// so the user dont find this manually in settings on their looking."
    ///
    /// It gets its own card rather than a fourth line on `waysInCard` for one
    /// reason: the other three are complete in a single line, and this one is
    /// not. `CobuxContactService` creates a contact and NOTHING else -- its own
    /// doc comment says so, and says why: "The message ingestion is a script on
    /// Rajan's Mac, not part of this app. A contact created for someone without
    /// that pipeline would look like a feature and do nothing." The honest
    /// version therefore has two halves, and the second half is the one that
    /// keeps the first from being a lie. A card with room for both is the only
    /// shape this can ship in; if the second sentence ever has to go, the card
    /// goes with it.
    ///
    /// It is also the weakest of the four capability cards, and the one to cut
    /// first if eight is too many: it points at a Settings row, needs him to
    /// supply his own iMessage address, and its payoff over `waysInCard` is the
    /// NAME of the chat -- the manual save it describes is the same + that card
    /// already teaches. It stays because he asked for it by name.
    private var contactCard: some View {
        capabilityCard(kicker: "A CHAT WITH YOURSELF") {
            Text("Settings → Add Journal to Contacts names your own message thread \u{201C}Journal 📓\u{201D}.")
                .font(CobuxTypography.passage(size: 15))
                .lineSpacing(4)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text("It only names the chat. To keep a line from it, tap + in Messages and choose Cobux.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func wayIn(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The sample card's shape with different contents. Same width, same height,
    /// same padding, same background wash and hairline, same kicker grammar --
    /// so a capability card reads as another page of the same carousel rather
    /// than as a settings row that wandered in.
    ///
    /// The wash is the accent rather than a month hue: a month hue is the time
    /// dimension (`JournalSourceFamily` records the same distinction), and these
    /// two cards belong to no month.
    private func capabilityCard<Content: View>(
        kicker: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kicker)
                .font(.caption2.weight(.semibold))
                .kerning(0.7)
                .foregroundStyle(Color.cobuxAccent)
            content()
        }
        // `cardPadding` IS 16 -- the same number `sampleCard` writes as a
        // literal, through the token, so the two cards cannot drift apart.
        .padding(CobuxSpacing.cardPadding)
        // The sample cards' exact width, and their height as a FLOOR rather than
        // a cap. A sample card is four lines of fixed prose, so 190 always holds
        // it; these two carry a control and a list, which at an accessibility
        // text size need more room than 190 -- and a hard height would have spilled
        // that text outside the tinted rectangle it belongs in. At every ordinary
        // size the floor is the height, so the carousel is visibly unchanged.
        .frame(width: 260, alignment: .topLeading)
        .frame(minHeight: 190, alignment: .topLeading)
        .background(Color.cobuxAccent.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous)
                .strokeBorder(Color.cobuxAccent.opacity(0.18), lineWidth: 0.5)
        )
        // Deliberately NOT combined into one accessibility element the way a
        // sample card is: the toggle inside has to stay reachable, and none of
        // this is an example that needs disclaiming.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func sampleCard(_ sample: Sample) -> some View {
        let hue = Color.cobuxMonthHue(sample.month, dark: colorScheme == .dark)
        return VStack(alignment: .leading, spacing: 10) {
            Text(sample.kicker)
                .font(.caption2.weight(.semibold))
                .kerning(0.7)
                .foregroundStyle(hue)
            Text(sample.body)
                .font(CobuxTypography.passage(size: 17))
                .lineSpacing(5)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 260, height: 190, alignment: .topLeading)
        .background(hue.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CobuxRadius.card, style: .continuous)
                .strokeBorder(hue.opacity(0.18), lineWidth: 0.5)
        )
        // Faux, and it says so under VoiceOver too -- never mistaken for his.
        .accessibilityLabel("Example journal card: \(sample.kicker). \(sample.body)")
    }
}
