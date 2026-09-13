import SwiftUI

/// One line of a voice surface's transcript, kept for the whole session.
/// Shared model behind both `VoiceModeView` and `SpokenQuizView` -- their
/// controllers reset their own per-turn state (`liveTranscript`,
/// `spokenSentences`) every turn, so each view folds finalized text into its
/// own `[VoiceTranscriptEntry]` array view-side, and both arrays render
/// through the same row/scroll mechanics below.
struct VoiceTranscriptEntry: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

/// A single transcript line -- his side right-aligned in a bubble, the
/// other side left-aligned plain text. Extracted byte-for-byte out of
/// `VoiceModeView.transcriptRow` so Spoken Quiz renders question/feedback
/// and his recognized answer with the exact same look Voice Mode already
/// shipped, rather than a hand-rolled third transcript.
struct VoiceTranscriptRow: View {
    let text: String
    let isUser: Bool
    let isLive: Bool
    /// Reduce Motion is a hard gate (CobuxMotion.swift): the row's entrance
    /// degrades to a plain fade -- no rise from the bottom edge.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(isLive ? 0.6 : 0.95))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
            }
            .transition(entrance)
        } else {
            Text(text)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(entrance)
        }
    }

    private var entrance: AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeOut(duration: 0.2))
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom))
                .animation(.spring(response: 0.38, dampingFraction: 0.78)),
            removal: .opacity
        )
    }
}

/// The whole session as one top-anchored, two-sided transcript: finalized
/// entries stack top-down, and the caller's `tail` renders whatever the
/// state machine is doing right now (a live-growing line, a "thinking"
/// label, or nothing) below them, at the same scroll position.
///
/// Two separate scroll triggers, not one, because `VoiceModeView` needs two
/// different feels: a smooth spring-scroll when a new entry lands or the
/// state machine flips (`animatedTrigger`), and an un-animated nudge on
/// every partial-transcript character so the tail stays pinned while he's
/// mid-sentence without visibly animating each keystroke
/// (`immediateTrigger`). Generic over both trigger types so each caller
/// passes its own controller's `state`/`liveTranscript` straight through --
/// no shared enum or String coercion needed.
struct VoiceTranscriptScrollView<Tail: View, AnimatedTrigger: Equatable, ImmediateTrigger: Equatable>: View {
    let entries: [VoiceTranscriptEntry]
    let animatedTrigger: AnimatedTrigger
    let immediateTrigger: ImmediateTrigger
    @ViewBuilder var tail: () -> Tail
    /// Reduce Motion is a hard gate (CobuxMotion.swift): the tail is kept in
    /// view by an instant jump, not an animated scroll.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var tailAnchorID: String { "transcriptTail" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, so a long session's transcript builds only the rows
                // that are actually on screen.
                //
                // This was a plain `VStack`, which builds every row it contains
                // up front and discards none. That is ordinarily just a
                // scrolling cost, but here it compounds: per this view's own
                // note above, `immediateTrigger` fires on every partial
                // transcript character, so the whole accumulated transcript was
                // being rebuilt on roughly every character the recogniser
                // returned while he was still speaking. The rows are
                // identical in every other way -- `LazyVStack` keeps the same
                // alignment and spacing, and the tail anchor below still sits
                // at the end of the same stack, so auto-scroll is unchanged.
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        VoiceTranscriptRow(text: entry.text, isUser: entry.isUser, isLive: false)
                    }

                    tail()

                    // Stable tail anchor -- live rows change identity as
                    // states flip, so auto-scroll targets this instead.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.tailAnchorID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: entries.count) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(Self.tailAnchorID, anchor: .bottom) }
            }
            .onChange(of: animatedTrigger) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(Self.tailAnchorID, anchor: .bottom) }
            }
            .onChange(of: immediateTrigger) { _, _ in
                proxy.scrollTo(Self.tailAnchorID, anchor: .bottom)
            }
        }
    }
}
