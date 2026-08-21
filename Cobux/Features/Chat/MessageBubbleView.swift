import SwiftUI
import SwiftData
import UIKit

struct MessageBubbleView: View {
    let content: String
    let isUser: Bool
    let timestamp: Date
    let referencedBooks: [String]
    var isError: Bool = false
    var isStreaming: Bool = false
    /// The book this thread is scoped to, per `Book.coverColorHex` -- falls back to the
    /// app-wide accent for the general thread. Threading a book's own living color into
    /// its chat thread was promised in Phase 2 ("the dynamic accent for that book's
    /// detail, chat thread, quiz session, and mastery ring") but only ever reached
    /// Library/BookDetail.
    var accentColor: Color = .cobuxAccent
    /// Set by `ChatView` once `SearchService.relevantFigure` (an independent,
    /// ADDITIVE lookup that runs AFTER a reply has already streamed back and
    /// been finalized) resolves a figure for this reply — nil most of the
    /// time. Default nil so this bubble compiles/renders unchanged at any
    /// call site that doesn't pass it.
    var referencedFigureID: UUID? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var resolvedFigure: Figure?
    @State private var figureImage: UIImage?

    private struct ContentBlock: Identifiable {
        let id: Int
        let text: String
        let isQuote: Bool
    }

    /// Splits `content` into plain-text and block-quote (`>`-prefixed) runs so
    /// quotes can render with a Notes-style accent bar instead of a literal
    /// "> " prefix, which `.inlineOnlyPreservingWhitespace` markdown parsing
    /// leaves untouched.
    private var contentBlocks: [ContentBlock] {
        var blocks: [ContentBlock] = []
        var textLines: [String] = []
        var quoteLines: [String] = []
        var nextID = 0

        func flushText() {
            guard !textLines.isEmpty else { return }
            blocks.append(ContentBlock(id: nextID, text: textLines.joined(separator: "\n"), isQuote: false))
            nextID += 1
            textLines.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(ContentBlock(id: nextID, text: quoteLines.joined(separator: "\n"), isQuote: true))
            nextID += 1
            quoteLines.removeAll()
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                flushText()
                quoteLines.append(String(trimmed.drop(while: { $0 == ">" })).trimmingCharacters(in: .whitespaces))
            } else {
                flushQuote()
                textLines.append(line)
            }
        }
        flushText()
        flushQuote()
        return blocks
    }

    private func inlineAttributed(_ text: String, color: Color) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // Set color on the AttributedString itself rather than relying solely on
        // a `.foregroundStyle` view modifier — markdown-parsed runs can carry
        // their own color attributes that a modifier won't reliably override.
        attributed.foregroundColor = color
        return attributed
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            HStack {
                if isUser { Spacer() }

                VStack(alignment: .leading, spacing: 6) {
                    if isError {
                        Label(content, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.cobuxDanger)
                            .font(.subheadline)
                    } else if isStreaming && content.isEmpty {
                        TypingIndicatorView()
                    } else {
                        ForEach(contentBlocks) { block in
                            if block.isQuote {
                                quoteBlock(block.text)
                            } else if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(inlineAttributed(block.text, color: isUser ? .white : .primary))
                                    .lineSpacing(2)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !referencedBooks.isEmpty && !isUser {
                        FlowLayout(spacing: 6) {
                            ForEach(referencedBooks, id: \.self) { title in
                                bookChip(title)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isUser ? AnyShapeStyle(accentColor) : AnyShapeStyle(Color.cobuxSurface))
                .clipShape(ChatBubbleShape(direction: isUser ? .right : .left))
                .overlay(
                    ChatBubbleShape(direction: isUser ? .right : .left)
                        .stroke(isError ? Color.cobuxDanger.opacity(0.4) : (isUser ? .clear : .secondary.opacity(0.15)), lineWidth: 1)
                )

                if !isUser { Spacer() }
            }

            // Additive, post-reply figure attachment (see `SearchService.relevantFigure`
            // and `ChatView.completeReveal`) — rendered below the bubble itself, never
            // blocking the message text, which is why resolution happens in `.task`
            // rather than synchronously in `body`. Keyed off `figureImage` (whether it
            // actually resolved), not `referencedFigureID` (whether one was assigned) --
            // an id that's still loading, or that never resolves to a real image, would
            // otherwise still insert this HStack as a present sibling, adding stray
            // vertical spacing for nothing.
            if !isUser, figureImage != nil {
                HStack {
                    figureCard
                    Spacer()
                }
            }

            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: isUser ? .bottomTrailing : .bottomLeading)
                .combined(with: .opacity)
                .animation(.spring(response: 0.38, dampingFraction: 0.78)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        ))
        .task(id: referencedFigureID) {
            await loadFigure()
        }
    }

    /// A single-row-by-`id` fetch, mirroring the exact safe pattern in
    /// `BookCard.loadHighlightCount()` — cheap, not a full table scan — run
    /// from `.task` so it never blocks this bubble's text from rendering.
    @MainActor
    private func loadFigure() async {
        guard let referencedFigureID else {
            resolvedFigure = nil
            figureImage = nil
            return
        }
        let targetFigureID = referencedFigureID
        var descriptor = FetchDescriptor<Figure>(
            predicate: #Predicate<Figure> { $0.id == targetFigureID }
        )
        descriptor.fetchLimit = 1
        guard let figure = try? modelContext.fetch(descriptor).first else { return }
        resolvedFigure = figure
        figureImage = await FigureImageLoader.image(for: figure)
    }

    @ViewBuilder
    private var figureCard: some View {
        if let figureImage {
            VStack(alignment: .leading, spacing: CobuxSpacing.xs) {
                Image(uiImage: figureImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))

                if let resolvedFigure, !resolvedFigure.caption.isEmpty {
                    Text(resolvedFigure.caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(CobuxSpacing.sm)
            .cobuxCard()
        }
    }

    @ViewBuilder
    private func quoteBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(isUser ? Color.white.opacity(0.55) : accentColor.opacity(0.55))
                .frame(width: 3)
            Text(inlineAttributed(text, color: isUser ? .white.opacity(0.85) : .primary.opacity(0.75)))
                .italic()
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func bookChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .lineLimit(1)
            .foregroundStyle(.secondary.opacity(0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.pill, style: .continuous))
    }
}

/// A simple left-to-right, top-to-bottom wrapping layout for chip-style
/// content whose count/width isn't known ahead of time.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
