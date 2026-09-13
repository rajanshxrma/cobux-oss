import UIKit
import SwiftUI

/// Draws a Bound Volume as a real PDF — the drawing half of VolumeBinder.
///
/// Runs OFF the main thread: the caller hands in value snapshots (read on the
/// binder's own `@ModelActor`, never the main context) and
/// `UIGraphicsPDFRenderer`, `UIFont`, `NSAttributedString.boundingRect` and
/// `.draw(in:)` are all safe off-main. Binding a volume costs the main
/// thread nothing beyond the tap.
///
/// Always ink on paper: the light palette regardless of app theme — a book
/// page is paper; the dark variants exist for screens.
enum VolumeRenderer {
    static let pageSize = CGSize(width: 396, height: 612)   // 5.5" × 8.5"
    static let sideMargin: CGFloat = 54
    static let topMargin: CGFloat = 64
    static let bottomMargin: CGFloat = 72
    static var contentWidth: CGFloat { pageSize.width - sideMargin * 2 }

    private static func serif(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func hue(_ month: Int) -> UIColor {
        UIColor(Color.cobuxMonthHue(month, dark: false))
    }

    private static let ink = UIColor(white: 0.12, alpha: 1)
    private static let gray = UIColor(white: 0.45, alpha: 1)

    struct Metadata {
        let title: String
        let volumeNumber: Int
        let boundDate: Date
        let passageCount: Int
        let pairedLineCount: Int
    }

    /// Pagination over MEASURED unit heights — the same `boundingRect` the
    /// draw calls use, at the real font and column width, once per passage.
    /// The binder's estimate is the harness's stand-in; the book breaks its
    /// pages on what the text engine actually needs.
    static func paginate(passages: [VolumeBinder.Passage]) -> [VolumeBinder.Page] {
        VolumeBinder.paginate(passages: passages,
                              pageHeight: pageSize.height - topMargin - bottomMargin,
                              height: { measuredHeight(of: $0, width: contentWidth) })
    }

    /// Exactly what `drawPassage` advances by, computed without drawing.
    /// Every constant here has a twin in `drawPassage`; change both.
    static func measuredHeight(of passage: VolumeBinder.Passage, width: CGFloat) -> CGFloat {
        var height: CGFloat = 8 + 6
        height += textHeight(passage.text, font: serif(13), lineHeightMultiple: 1.45, width: width)
        if let paired = passage.pairedLine {
            height += 12 + 1 + 8
            height += textHeight("\u{201C}\(paired)\u{201D}", font: serif(11).italic(),
                                 lineHeightMultiple: 1.4, width: width)
            if let book = passage.pairedBookTitle {
                height += 4 + textHeight(book, font: serif(9), lineHeightMultiple: 1, width: width)
            }
        }
        return height
    }

    /// Renders the whole book. Pure function of its inputs — the pagination
    /// came from `VolumeBinder`, so what the tests proved is what prints.
    static func render(passages: [VolumeBinder.Passage],
                       pages: [VolumeBinder.Page],
                       metadata: Metadata) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            // No author field, ever — the app never asserts his name.
            kCGPDFContextTitle as String: metadata.title,
            kCGPDFContextCreator as String: "Cobux",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let contentWidth = Self.contentWidth

        return renderer.pdfData { ctx in
            // ---- title page
            ctx.beginPage()
            drawCentered("VOLUME \(roman(metadata.volumeNumber))",
                         font: serif(13), color: gray, kern: 2.4, y: 180, ctx: ctx)
            // Measured, never assumed: the default three-month range names
            // two months and a year, and at 30pt that wraps on this page.
            // The ladder steps the face down to keep one line; if even the
            // floor wraps, the rule moves down under the measured bottom
            // instead of striking through the year.
            let titleLayout = VolumeBinder.titleLayout(metadata.title) { title, size in
                textHeight(title, font: serif(size, weight: .semibold), lineHeightMultiple: 1,
                           width: pageSize.width, centered: true)
            }
            drawCentered(metadata.title, font: serif(titleLayout.fontSize, weight: .semibold),
                         color: ink, y: 220, height: titleLayout.height, ctx: ctx)
            let firstMonth = passages.first?.month ?? 1
            hue(firstMonth).setFill()
            // 16pt under the title's measured bottom: 272 for the approved
            // single-line case, lower only when the title genuinely needs it.
            UIBezierPath(rect: CGRect(x: (pageSize.width - 40) / 2, y: 220 + titleLayout.height + 16,
                                      width: 40, height: 1)).fill()
            drawCentered("Bound \(longDate(metadata.boundDate))",
                         font: serif(9), color: gray, y: pageSize.height - 90, ctx: ctx)

            // ---- body
            var pageNumber = 1
            for page in pages {
                ctx.beginPage()
                pageNumber += 1
                var y = topMargin
                for (blockIndex, block) in page.blocks.enumerated() {
                    if blockIndex > 0 { y += 28 }
                    switch block {
                    case let .monthSection(month, year):
                        // The era divider, translated to print. Dates, never counts.
                        let rule = UIBezierPath(rect: CGRect(x: sideMargin, y: 230,
                                                             width: 36, height: 2))
                        hue(month).setFill(); rule.fill()
                        draw(Calendar.current.monthSymbols[max(0, min(11, month - 1))],
                             font: serif(28, weight: .semibold), color: hue(month),
                             at: CGPoint(x: sideMargin, y: 242), width: contentWidth)
                        draw(String(year), font: serif(16), color: gray,
                             at: CGPoint(x: sideMargin, y: 282), width: contentWidth)
                    case let .passage(index):
                        y = drawPassage(passages[index], at: y, width: contentWidth, ctx: ctx)
                    }
                }
                if !page.blocks.contains(where: {
                    if case .monthSection = $0 { return true }; return false
                }) {
                    drawCentered(String(pageNumber), font: serif(9), color: gray,
                                 y: pageSize.height - 40, ctx: ctx)
                }
            }

            // ---- colophon: facts about the artifact, offered. Never graded.
            ctx.beginPage()
            let lines = "\(metadata.passageCount) passages" +
                (metadata.pairedLineCount > 0
                 ? " · \(metadata.pairedLineCount) lines from your library" : "") +
                " · Bound \(longDate(metadata.boundDate)) · Set by Cobux"
            drawCentered(lines, font: serif(9), color: gray,
                         y: pageSize.height / 2, ctx: ctx)
        }
    }

    private static func drawPassage(_ passage: VolumeBinder.Passage, at y: CGFloat,
                                    width: CGFloat, ctx: UIGraphicsPDFRendererContext) -> CGFloat {
        var y = y
        // An import whose date collapsed onto its import date is named as
        // such -- the same word Ebb's kicker uses -- because this is the one
        // artifact that leaves the device, and a day-precise date the app is
        // not sure of is a claim about his life it cannot support.
        let kicker = ((passage.dateIsCertain ? "" : "Imported ") + kickerDate(passage.date)).uppercased()
        draw(kicker, font: serif(8, weight: .semibold), color: hue(passage.month),
             at: CGPoint(x: sideMargin, y: y), width: width, kern: 0.7)
        y += 8 + 6
        y = drawWrapped(passage.text, font: serif(13), color: ink,
                        lineHeightMultiple: 1.45, at: y, width: width)
        if let paired = passage.pairedLine {
            y += 12
            hue(passage.month).withAlphaComponent(0.3).setFill()
            UIBezierPath(rect: CGRect(x: sideMargin, y: y, width: 40, height: 1)).fill()
            y += 1 + 8
            y = drawWrapped("\u{201C}\(paired)\u{201D}",
                            font: serif(11).italic(), color: gray,
                            lineHeightMultiple: 1.4, at: y, width: width)
            if let book = passage.pairedBookTitle {
                y += 4
                y = drawWrapped(book, font: serif(9), color: gray,
                                lineHeightMultiple: 1, at: y, width: width)
            }
        }
        return y
    }

    // ------------------------------------------------------------ helpers

    private static func attributes(font: UIFont, color: UIColor,
                                   kern: CGFloat = 0, lineHeightMultiple: CGFloat = 1,
                                   centered: Bool = false) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        if centered { style.alignment = .center }
        return [.font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style]
    }

    /// The one measurement: `boundingRect` with the same attributes the draw
    /// uses, rounded up to whole points the way the draw rects are.
    private static func textHeight(_ text: String, font: UIFont, lineHeightMultiple: CGFloat,
                                   width: CGFloat, centered: Bool = false) -> CGFloat {
        let attributed = NSAttributedString(
            string: text,
            attributes: attributes(font: font, color: ink, lineHeightMultiple: lineHeightMultiple,
                                   centered: centered))
        let bound = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], context: nil)
        return ceil(bound.height)
    }

    private static func draw(_ text: String, font: UIFont, color: UIColor,
                             at point: CGPoint, width: CGFloat, kern: CGFloat = 0) {
        NSAttributedString(string: text, attributes: attributes(font: font, color: color, kern: kern))
            .draw(in: CGRect(x: point.x, y: point.y, width: width, height: 400))
    }

    @discardableResult
    private static func drawWrapped(_ text: String, font: UIFont, color: UIColor,
                                    lineHeightMultiple: CGFloat, at y: CGFloat,
                                    width: CGFloat) -> CGFloat {
        let height = textHeight(text, font: font, lineHeightMultiple: lineHeightMultiple, width: width)
        NSAttributedString(
            string: text,
            attributes: attributes(font: font, color: color, lineHeightMultiple: lineHeightMultiple))
            .draw(in: CGRect(x: sideMargin, y: y, width: width, height: height))
        return y + height
    }

    private static func drawCentered(_ text: String, font: UIFont, color: UIColor,
                                     kern: CGFloat = 0, y: CGFloat, height: CGFloat = 60,
                                     ctx: UIGraphicsPDFRendererContext) {
        NSAttributedString(string: text,
                           attributes: attributes(font: font, color: color, kern: kern, centered: true))
            .draw(in: CGRect(x: 0, y: y, width: pageSize.width, height: height))
    }

    // Both of these draw into a PDF, not into a view. `render` runs OFF the
    // main thread by design (see this type's doc comment: that is the whole
    // reason binding a volume costs the main thread nothing beyond the tap),
    // and it runs once per bound volume -- there is no body here to re-evaluate
    // and no frame to miss. Next to the per-passage `NSAttributedString`
    // layout and `.draw(in:)` these sit beside, a formatter is not the cost.
    //
    // Hoisting them is what would be wrong: a shared `DateFormatter` reached
    // from a background renderer is precisely the case `ChatView`'s hoisted
    // pair documents itself as NOT being ("every caller is on the main actor").
    private static func kickerDate(_ date: Date) -> String {
        // lint-ok: formatter-constructed-per-render -- PDF export, off the main thread by design, once per passage of one bound volume
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func longDate(_ date: Date) -> String {
        // lint-ok: formatter-constructed-per-render -- PDF export, off the main thread by design, twice per bound volume (title page and colophon)
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                                      (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                      (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = max(1, n), out = ""
        for (value, glyph) in table {
            while n >= value { out += glyph; n -= value }
        }
        return out
    }
}

private extension UIFont {
    func italic() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitItalic)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
