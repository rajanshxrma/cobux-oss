import SwiftUI
import UIKit

/// Cobux chat inside Messages -- the expanded pane's second mode.
///
/// His design, verbatim: "could we have the whole Cobux chat in here in the
/// iMessages … having more room … the whole thing opens and then Cobux chat
/// could load and you could respond and then the user could slide it down and
/// send the text because that's what we created in Cobux and we wanted it to
/// be text friendly". So: a transcript, a composer, a streaming reply, and on
/// every reply the one control that is the point of the surface -- "Send to
/// conversation" -- which puts the words into the iMessage composer and stops.
/// The person hits send. Nothing here ever sends a message on their behalf,
/// and nothing here reads the conversation the pane is sitting in.
///
/// What it deliberately is NOT (see docs/imessage-journaling.md §3): the
/// app's grounded chat. No library retrieval runs in this process -- that is a
/// ~72 MB working set on a jetsam budget Apple does not publish -- so the
/// reply comes from Cobux's voice and the books it carries, not from a ranked
/// slice of his highlights. "Open in Cobux" is the door to the full thing, and
/// because every finished turn is written into the app's general thread, the
/// door opens onto THIS conversation continuing, not a blank one.
///
/// Design system only: the extension has no other palette. The single filled
/// pill on the surface is "Send to conversation" on the LATEST reply; older
/// replies keep the same actions as quiet chips, so saturation appears once.
struct MessagesAskView: View {
    @Bindable var model: MessagesPaneModel
    /// Puts text into the iMessage composer (`MSConversation.insertText`).
    let onInsertText: (String) -> Void
    /// Opens the containing app at a route.
    let onOpen: (URL) -> Void

    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CobuxSpacing.md) {
            transcript
            if let notice = model.notice {
                noticeLine(notice)
                    .transition(.opacity)
            }
            composer
            footer
        }
        // The controller bumps this after Messages finishes the expand
        // transition (see `MessagesViewController.didTransition`). `.onAppear`
        // alone was the "sometimes" -- it can fire mid-animation, before the
        // pane can host a keyboard.
        .onChange(of: model.focusRequest) { _, _ in
            if model.mode == .ask { composerFocused = true }
        }
        .onAppear {
            if model.turns.isEmpty { composerFocused = true }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CobuxSpacing.md) {
                    if model.turns.isEmpty {
                        emptyState
                    }
                    ForEach(model.turns) { turn in
                        turnRow(turn)
                            .id(turn.id)
                    }
                }
                .padding(.vertical, CobuxSpacing.xs)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Follow the reply as it streams. Keyed on the LAST turn's text
            // length so a new user line and every chunk both scroll.
            .onChange(of: model.turns.last?.rawText.count) { _, _ in
                guard let last = model.turns.last else { return }
                withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Says what this is before the first question, in one breath: what it
    /// gives back, and the one privacy fact that makes the surface worth
    /// trusting. Caption weight so it reads as a footnote, not a headline.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
            Text("Ask Cobux")
                .cobuxKicker(tint: Color.cobuxAccent)
            Text("Describe what you're navigating and Cobux drafts something you can drop straight into this conversation. Nothing in the conversation is read.")
                .font(CobuxTypography.cobuxCaption)
                .foregroundStyle(Color.cobuxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CobuxSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cobuxCard()
    }

    @ViewBuilder
    private func turnRow(_ turn: MessagesChatTurn) -> some View {
        switch turn.role {
        case .user:
            userBubble(turn)
        case .cobux:
            replyCard(turn)
        }
    }

    /// The user's own words, right-aligned in an accent wash -- ink on a
    /// 15% tint, never white on a fill, so it reads at any text size in
    /// both themes.
    private func userBubble(_ turn: MessagesChatTurn) -> some View {
        HStack {
            Spacer(minLength: CobuxSpacing.xxl)
            Text(turn.rawText)
                .font(CobuxTypography.cobuxBody)
                .foregroundStyle(Color.cobuxInk)
                .padding(.horizontal, CobuxSpacing.chipH)
                .padding(.vertical, CobuxSpacing.sm)
                .background(Color.cobuxAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: CobuxRadius.bubble))
        }
    }

    private func replyCard(_ turn: MessagesChatTurn) -> some View {
        let isLatest = model.turns.last?.id == turn.id
        return VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
            if let errorLine = turn.errorLine {
                Text(errorLine)
                    .font(CobuxTypography.cobuxCaption)
                    .foregroundStyle(Color.cobuxDanger)
                    .fixedSize(horizontal: false, vertical: true)
                if isLatest, !model.isReplying, errorLine != "Stopped." {
                    Button {
                        model.retry(turn.id)
                    } label: {
                        Text("Try again")
                            .foregroundStyle(Color.cobuxAccent)
                            .cobuxQuietChip(tint: Color.cobuxAccent)
                    }
                    .buttonStyle(.plain)
                }
            } else if turn.isStreaming, turn.displayText.isEmpty {
                // The user's line is already on screen; this is the only
                // moment the pane has nothing of Cobux's to show yet.
                HStack(spacing: CobuxSpacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.cobuxAccent)
                    Text("Cobux is thinking")
                        .font(CobuxTypography.cobuxCaption)
                        .foregroundStyle(Color.cobuxMuted)
                }
            } else {
                replyText(turn)
                if !turn.isStreaming {
                    replyActions(turn, isLatest: isLatest)
                }
            }
        }
        .padding(CobuxSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cobuxCard()
    }

    /// The reply, paragraph by paragraph. A `"> "` line is a message the
    /// model drafted for him -- the repartee convention in `PromptTemplates`
    /// -- and is set apart the way the app sets a quote block apart (serif,
    /// hairline on the left) AND made a button, because the whole reason it
    /// is on its own line is so he can lift it out on its own.
    private func replyText(_ turn: MessagesChatTurn) -> some View {
        VStack(alignment: .leading, spacing: CobuxSpacing.sm) {
            ForEach(Array(turn.displayText.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, rawLine in
                let line = String(rawLine)
                if line.hasPrefix("> ") {
                    draftLine(String(line.dropFirst(2)), streaming: turn.isStreaming)
                } else {
                    Text(line)
                        .font(CobuxTypography.cobuxBody)
                        .foregroundStyle(Color.cobuxInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func draftLine(_ text: String, streaming: Bool) -> some View {
        Button {
            model.notice = nil
            onInsertText(text)
        } label: {
            HStack(alignment: .top, spacing: CobuxSpacing.sm) {
                RoundedRectangle(cornerRadius: CobuxRadius.structural)
                    .fill(Color.cobuxAccent)
                    .frame(width: 2)
                Text(text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(Color.cobuxInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !streaming {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.cobuxAccent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(streaming)
        .accessibilityLabel(text)
        .accessibilityHint("Puts this line in your message")
    }

    /// The two controls every finished reply carries, plus the one the
    /// reply exists for. The filled pill is reserved for the latest reply;
    /// an older reply's "Send to conversation" is a chip, so a transcript of
    /// five replies has one saturated control, not five.
    private func replyActions(_ turn: MessagesChatTurn, isLatest: Bool) -> some View {
        HStack(spacing: CobuxSpacing.sm) {
            Button {
                model.notice = nil
                onInsertText(turn.sendableText)
            } label: {
                if isLatest {
                    Label("Send to conversation", systemImage: "arrow.down.to.line")
                        .cobuxPrimaryPill(tint: Color.cobuxAccent)
                } else {
                    Label("Send to conversation", systemImage: "arrow.down.to.line")
                        .foregroundStyle(Color.cobuxAccent)
                        .cobuxQuietChip(tint: Color.cobuxAccent)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Puts the reply in your message. You send it.")

            Button {
                UIPasteboard.general.string = turn.sendableText
                withAnimation(.snappy) { model.notice = .copied }
            } label: {
                Text("Copy")
                    .foregroundStyle(Color.cobuxAccent)
                    .cobuxQuietChip(tint: Color.cobuxAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, CobuxSpacing.xs)
    }

    // MARK: - Notice

    @ViewBuilder
    private func noticeLine(_ notice: MessagesPaneModel.Notice) -> some View {
        switch notice {
        case .missingKey:
            // One calm line. Not an error card: nothing broke, a thing is not
            // set up, and the link is the fix.
            HStack(spacing: CobuxSpacing.sm) {
                Text("Add your API key in Cobux Settings")
                    .font(CobuxTypography.cobuxCaption)
                    .foregroundStyle(Color.cobuxMuted)
                Spacer(minLength: 0)
                Button {
                    onOpen(CobuxDeepLink.settingsURL())
                } label: {
                    Text("Open in Cobux")
                        .foregroundStyle(Color.cobuxAccent)
                        .cobuxQuietChip(tint: Color.cobuxAccent)
                }
                .buttonStyle(.plain)
            }
        case .insertFailed:
            Text("Couldn't add that to your message. Copy it instead.")
                .font(CobuxTypography.cobuxCaption)
                .foregroundStyle(Color.cobuxDanger)
        case .copied:
            Label("Copied", systemImage: "checkmark.circle.fill")
                .font(CobuxTypography.cobuxCaption)
                .foregroundStyle(Color.cobuxGood)
        }
    }

    // MARK: - Composer

    /// Same capsule as the journal strip's field, so the two modes read as
    /// one surface. Grows to four lines; a question longer than that is a
    /// journal entry.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: CobuxSpacing.sm) {
            TextField("Ask Cobux…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(CobuxTypography.cobuxBody)
                .foregroundStyle(Color.cobuxInk)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { if model.canSend { model.send() } }
                .padding(.horizontal, CobuxSpacing.chipH)
                .padding(.vertical, CobuxSpacing.chipV)
                .background(Color.cobuxSurface, in: RoundedRectangle(cornerRadius: CobuxRadius.bubble))
                .overlay(RoundedRectangle(cornerRadius: CobuxRadius.bubble).stroke(Color.cobuxLine, lineWidth: 1))

            Button {
                if model.isReplying {
                    model.stop()
                } else if model.canSend {
                    model.send()
                }
            } label: {
                Image(systemName: model.isReplying ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.cobuxAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend && !model.isReplying)
            .accessibilityLabel(model.isReplying ? "Stop" : "Ask")
        }
    }

    // MARK: - Footer

    /// The quiet door to the full app, and the same privacy line the journal
    /// strip carries -- the one fact that makes this surface worth opening
    /// instead of switching apps.
    private var footer: some View {
        HStack(spacing: CobuxSpacing.sm) {
            Button {
                onOpen(CobuxDeepLink.chatURL())
            } label: {
                Label("Open in Cobux", systemImage: "arrow.up.forward.app")
                    .font(CobuxTypography.cobuxCaption)
                    .foregroundStyle(Color.cobuxAccent)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Continues this conversation in the app, with your library")
            Spacer(minLength: 0)
            Text("Nothing in this conversation is read.")
                .font(CobuxTypography.cobuxCaption)
                .foregroundStyle(Color.cobuxMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
