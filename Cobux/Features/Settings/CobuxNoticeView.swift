import SwiftUI

/// "A note on advice" -- the one place Cobux says, in its own voice, what it
/// is and is not.
///
/// Rajan's ask (instruction ledger N20): *"should have some type of thing so
/// that if its suggestions lead to harmful turnouts it's not a legal problem
/// or any responsibility of mine at all … I don't want the chat to be changed
/// or mention this tho but make sure."* So this is a reading page reached
/// from Settings > About, never a banner, never a line in a reply, and no
/// chat copy was touched to add it.
///
/// This is a SURFACE, not a shield. A paragraph in Settings is what a
/// careful app says; what actually limits liability is the attorney consult
/// parked in his pending file (terms of use, jurisdiction, the crisis-line
/// wording a lawyer would want). Until that happens, the honest claim for
/// this page is that the reader has been told plainly, in a place they can
/// find again.
///
/// Voice rules, all his: no wall of legalese, nothing that talks down to the
/// reader, no colon-prefixed headings. Body in `CobuxTypography.passage`,
/// the face reserved for words the app wants read slowly.
struct CobuxNoticeView: View {
    /// Each paragraph stands alone; the page is short enough that a reader
    /// can take it in one sitting, which is the point of keeping it plain.
    private let paragraphs: [String] = [
        "Cobux thinks alongside you. It draws on the books in your library and, when you have allowed it, on your own writing, and it offers what it finds the way a well-read friend might over a long conversation.",
        "It is not a licensed professional. Nothing it says is medical, legal, financial or psychological advice. It has not examined you, your health, your finances or your circumstances, and the authors it quotes wrote for a general reader, not for your particular situation. Cobux carries that limit with it into every reply.",
        "The decisions stay yours, and so do their outcomes. Read what Cobux offers as one more voice in the room, weigh it against what you know, and bring anything that matters to someone qualified to look at it closely.",
        "If you are in crisis or in danger, please contact your local emergency services or a crisis line right away. Cobux is a place to think, and some moments need more than thinking.",
    ]

    var body: some View {
        ScrollView {
            // lint-ok: nonlazy-stack-in-scrollview-advisory -- four fixed paragraphs, not a feed
            VStack(alignment: .leading, spacing: CobuxSpacing.xl) {
                ForEach(paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(CobuxTypography.passage(size: 17))
                        .foregroundStyle(Color.cobuxInk)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Where to raise anything this page leaves open. The
                // developer's name already sits on the About row this page is
                // reached from, so no address is repeated here.
                Text("Questions about this note are welcome through the developer named on the About screen.")
                    .font(CobuxTypography.cobuxCaption)
                    .foregroundStyle(Color.cobuxMuted)
                    .padding(.top, CobuxSpacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CobuxSpacing.screenMargin)
            .padding(.vertical, CobuxSpacing.xl)
        }
        .background(Color.cobuxBackground)
        .navigationTitle("A note on advice")
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview {
    NavigationStack { CobuxNoticeView() }
}
