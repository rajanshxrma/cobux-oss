import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Turns a chat message's markdown source into the two things a pasteboard
/// needs: rendered rich text, and clean plain text.
///
/// Extracted out of `MessageBubbleView` so copying uses the SAME block split
/// the screen uses. A second parser would drift from the first, and the two
/// would disagree in exactly the case nobody tests — which is the
/// whole-document-structure lesson this codebase has already paid for.
///
/// Why both representations: `ChatMessage.content` is markdown source, and
/// what he reads is the rendered result. Copying the source pastes literal
/// `**asterisks**` into someone's messages; copying rendered plain text loses
/// the bold in Notes. Putting both on the pasteboard lets each destination
/// take the one it can use — which is exactly the Claude/ChatGPT behaviour he
/// asked for by name.
enum ChatTranscript {
    struct Block: Equatable {
        let text: String
        let isQuote: Bool
    }

    /// Splits into plain runs and `>`-quote runs. Byte-for-byte the rule
    /// `MessageBubbleView.contentBlocks` uses, including the one that matters:
    /// a bare ">" ENDS a quote rather than extending it, so three candidate
    /// replies stay three separately-copyable cards.
    static func blocks(in content: String) -> [Block] {
        var blocks: [Block] = []
        var textLines: [String] = []
        var quoteLines: [String] = []

        func flushText() {
            guard !textLines.isEmpty else { return }
            blocks.append(Block(text: textLines.joined(separator: "\n"), isQuote: false))
            textLines.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(Block(text: quoteLines.joined(separator: "\n"), isQuote: true))
            quoteLines.removeAll()
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                flushText()
                let body = String(trimmed.drop(while: { $0 == ">" }))
                    .trimmingCharacters(in: .whitespaces)
                if body.isEmpty { flushQuote() } else { quoteLines.append(body) }
            } else {
                flushQuote()
                textLines.append(line)
            }
        }
        flushText()
        flushQuote()
        return blocks
    }

    /// Parsed markdown, remembered by exact source text.
    ///
    /// `AttributedString(markdown:)` runs a full CommonMark parse. A chat
    /// bubble ran one per text block, straight out of `body` -- and `body` for
    /// every visible bubble is re-evaluated on every reveal tick, which is 12.5
    /// times a second for as long as a reply is streaming. So the cost of
    /// showing one reply arrive was every visible message in the thread being
    /// re-parsed, from scratch, twelve times a second, for the whole length of
    /// the answer. The bubbles being re-parsed had not changed by a single
    /// character.
    ///
    /// Keyed by the source text itself rather than by message id: identity is
    /// what actually determines the answer, an id would need plumbing through
    /// two call sites, and a message's text never changes once finalized, so
    /// the two are equivalent for every stable row while the key stays honest
    /// if one ever were edited.
    ///
    /// STREAMING TEXT IS NOT STORED (see `memoise:`). A growing reply presents
    /// a different string on every tick, so caching it would insert hundreds of
    /// dead prefixes and evict exactly the finished messages this exists to
    /// protect. The streaming bubble pays for its own parse, once per tick,
    /// which is unavoidable -- it is the only thing on screen that actually
    /// changed.
    ///
    /// `@MainActor`, and honest about it: every caller is a SwiftUI body.
    /// Bounded and FIFO-evicted, so a long-lived session cannot grow it without
    /// limit.
    @MainActor
    enum InlineMarkdown {
        private static let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        private static let limit = 256
        private static var cache: [String: AttributedString] = [:]
        private static var insertionOrder: [String] = []

        static func parse(_ text: String, memoise: Bool) -> AttributedString {
            if memoise, let hit = cache[text] { return hit }
            let parsed = (try? AttributedString(markdown: text, options: options))
                ?? AttributedString(text)
            guard memoise else { return parsed }
            cache[text] = parsed
            insertionOrder.append(text)
            if insertionOrder.count > limit {
                cache.removeValue(forKey: insertionOrder.removeFirst())
            }
            return parsed
        }
    }

    /// The whole message as one attributed string, blocks joined as paragraphs.
    static func attributed(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = AttributedString()
        for (index, block) in blocks(in: content).enumerated() {
            if index > 0 { out.append(AttributedString("\n\n")) }
            let parsed = (try? AttributedString(markdown: block.text, options: options))
                ?? AttributedString(block.text)
            out.append(parsed)
        }
        return out
    }

    /// The whole message as RTF bytes, with the formatting actually IN them.
    ///
    /// `AttributedString(markdown:)` records emphasis as
    /// `inlinePresentationIntent` attributes -- an *intent*, which SwiftUI
    /// resolves at render time but which RTF serialization does not read at
    /// all. Exporting the intents directly produced an RTF with no \b and no
    /// \i in it: "paste in Notes keeps the bold" was false, and the rich half
    /// of the pasteboard was dead weight. Fable caught it empirically at the
    /// audit gate, before it reached anyone.
    ///
    /// So the intents are resolved into real font traits here, by hand, before
    /// serialization. Platform-conditional because the harness runs this on
    /// macOS -- which is also what lets a test assert the exported bytes
    /// actually contain the bold control word.
    static func rtfData(_ content: String, bodyPointSize: CGFloat = 17) -> Data? {
        #if canImport(UIKit)
        typealias PlatformFont = UIFont
        #elseif canImport(AppKit)
        typealias PlatformFont = NSFont
        #else
        return nil
        #endif

        #if canImport(UIKit) || canImport(AppKit)
        let source = attributed(content)
        let output = NSMutableAttributedString()
        let body = PlatformFont.systemFont(ofSize: bodyPointSize)

        for run in source.runs {
            let text = String(source[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = body
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: bodyPointSize - 1, weight: .regular)
            } else {
                var traits: [Bool] = [intent.contains(.stronglyEmphasized),
                                      intent.contains(.emphasized)]
                #if canImport(UIKit)
                var symbolic: UIFontDescriptor.SymbolicTraits = []
                if traits[0] { symbolic.insert(.traitBold) }
                if traits[1] { symbolic.insert(.traitItalic) }
                if !symbolic.isEmpty,
                   let descriptor = body.fontDescriptor.withSymbolicTraits(symbolic) {
                    font = UIFont(descriptor: descriptor, size: bodyPointSize)
                }
                #else
                if traits[0] {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if traits[1] {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                #endif
                _ = traits
            }
            output.append(NSAttributedString(string: text, attributes: [.font: font]))
        }

        return try? output.data(
            from: NSRange(location: 0, length: output.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #endif
    }

    /// The whole message as plain text, with the markdown machinery consumed
    /// rather than stripped by hand: this is the rendered characters, so
    /// `**bold**` arrives as bold's text and `> ` never appears at all.
    ///
    /// No "via Cobux" watermark, and no appended source list. He copies counsel
    /// to send to a person; an app signature under it makes his words read as
    /// the app's.
    static func plainText(_ content: String) -> String {
        String(attributed(content).characters)
    }
}
