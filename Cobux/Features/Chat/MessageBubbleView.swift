import SwiftUI

struct MessageBubbleView: View {
    let content: String
    let isUser: Bool
    let timestamp: Date
    let referencedBooks: [String]
    var isError: Bool = false
    var isStreaming: Bool = false

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
                            .foregroundStyle(.red)
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
                .background(isUser ? AnyShapeStyle(LinearGradient(colors: [Color.cobuxAccent, Color.cobuxAccent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(.ultraThinMaterial))
                .clipShape(ChatBubbleShape(direction: isUser ? .right : .left))
                .overlay(
                    ChatBubbleShape(direction: isUser ? .right : .left)
                        .stroke(isError ? .red.opacity(0.4) : (isUser ? .clear : .secondary.opacity(0.15)), lineWidth: 1)
                )

                if !isUser { Spacer() }
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
    }

    @ViewBuilder
    private func quoteBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(isUser ? Color.white.opacity(0.55) : Color.cobuxAccent.opacity(0.55))
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
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
