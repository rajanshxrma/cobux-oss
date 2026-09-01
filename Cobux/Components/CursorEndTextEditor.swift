import SwiftUI
import UIKit

/// A plain multi-line text editor that focuses itself and places the cursor
/// at the very end of whatever text it starts with, the moment it appears.
///
/// SwiftUI's own `TextEditor(text:selection:)` does exactly this, but
/// `TextSelection` isn't available until iOS 18 -- Cobux's deployment target
/// is iOS 17 (`project.yml`), so `JournalEntryComposeView` needs a real
/// `UITextView` wrapper instead. Deliberately minimal: this only ever needs
/// to do the one thing it's named for (focus + cursor at end on creation),
/// not general arbitrary cursor placement.
struct CursorEndTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// Defaults to the stock body style, unchanged from before this
    /// parameter existed -- `JournalEntryComposeView` passes a serif design
    /// matching `CobuxTypography.display()`'s own light-mode face, so the
    /// entry reads in the same editorial type while writing it as it does
    /// afterward in `JournalEntryDetailView`. UIKit has no direct bridge
    /// from a SwiftUI `Font`, so this takes a `UIFont` rather than
    /// duplicating `CobuxTypography`'s scheme-switching logic here.
    var font: UIFont = .preferredFont(forTextStyle: .body)

    func makeUIView(context: Context) -> UITextView {
        let textView = CaretTrackingTextView()
        textView.font = font
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.text = text
        textView.delegate = context.coordinator
        // Notes-like feel: the text view IS the page. It owns all scrolling
        // (it must never be nested inside another scroll view -- that nesting
        // is exactly what made journal typing near the bottom judder), it
        // bounces even when short, and dragging down over it tucks the
        // keyboard away interactively, the same gesture Notes has.
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        // Editorial margins for a full-bleed page. `lineFragmentPadding` is
        // 5pt on each side already; this brings the text ~20pt off the edges,
        // matching the compose screen's other content.
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 15, bottom: 14, right: 15)
        attemptFocus(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // A `UIViewRepresentable`'s coordinator is created once and reused
        // across every `updateUIView` call -- without this, its `parent`
        // stays the SPECIFIC struct snapshot captured back in
        // `makeCoordinator()`'s one call, for the view's entire lifetime.
        // That happens to keep working today only because the binding here
        // is backed by plain `@State` in the immediate parent; refreshing it
        // explicitly is the correct, general fix regardless.
        context.coordinator.parent = self
        uiView.font = font

        // Only pushed when the SwiftUI-side `text` changed for a reason
        // OTHER than this view's own typing (e.g. the binding was reset
        // externally) -- otherwise this would fight the user's own cursor
        // position on every keystroke, since typing already round-trips
        // through `textViewDidChange` below.
        if uiView.text != text {
            // Preserve the caret. Assigning `.text` resets `selectedRange` to
            // the end of the document, so any external push -- which
            // `updateUIView` can fire for reasons that have nothing to do with
            // typing (a re-render while the sheet animates, a parent state
            // change) -- would silently yank the cursor away from wherever the
            // user actually was. Clamped, since the new text can be shorter.
            let caret = uiView.selectedRange
            uiView.text = text
            let limit = (text as NSString).length
            uiView.selectedRange = NSRange(
                location: min(caret.location, limit),
                length: min(caret.length, max(0, limit - min(caret.location, limit)))
            )
        }

        // `updateUIView` fires repeatedly as SwiftUI's own lifecycle
        // progresses (e.g. while a sheet is still animating in) -- a genuine,
        // event-driven retry point, unlike a single blind
        // `DispatchQueue.main.async` in `makeUIView` alone, which could fire
        // before the view is actually attached to a window and then never
        // try again. `hasFocused` makes this a one-time success, not a fight
        // for focus on every re-render once it's already worked (or once the
        // user has intentionally tapped elsewhere).
        attemptFocus(uiView, coordinator: context.coordinator)
    }

    private func attemptFocus(_ textView: UITextView, coordinator: Coordinator) {
        guard !coordinator.hasFocused else { return }
        DispatchQueue.main.async {
            guard !coordinator.hasFocused, textView.window != nil else { return }
            guard textView.becomeFirstResponder() else { return }
            coordinator.hasFocused = true
            let end = textView.endOfDocument
            textView.selectedTextRange = textView.textRange(from: end, to: end)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CursorEndTextEditor
        var hasFocused = false
        init(_ parent: CursorEndTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            // Keep the line you're typing on visible. This used to scroll on
            // EVERY keystroke from an async hop; each call forced a layout
            // pass that raced other scrolling machinery, which read as the
            // reported shake ("when it gets to the bottom of textbox it
            // shakes and is weird with the iPhone keyboard open").
            //
            // Checking first means the common case -- typing on a line that is
            // already on screen -- does no scrolling and no extra layout at
            // all, so there is nothing for keyboard avoidance to fight.
            CursorEndTextEditor.scrollCaretIntoViewIfNeeded(textView)
        }
    }

    /// Scrolls only when the caret has actually left the visible box --
    /// shared by the per-keystroke path above and the height-change path in
    /// `CaretTrackingTextView` below.
    static func scrollCaretIntoViewIfNeeded(_ textView: UITextView) {
        guard let selectedRange = textView.selectedTextRange else { return }
        let caretRect = textView.caretRect(for: selectedRange.end)
        guard !caretRect.isNull, caretRect.origin.y.isFinite, caretRect.height.isFinite else { return }
        let visible = textView.bounds.inset(by: textView.adjustedContentInset)
            .offsetBy(dx: textView.contentOffset.x, dy: textView.contentOffset.y)
        guard !visible.contains(caretRect) else { return }
        textView.scrollRangeToVisible(textView.selectedRange)
    }
}

/// Keeps the line being written visible when the editor's HEIGHT changes --
/// which is what happens the moment the keyboard slides up and SwiftUI's
/// keyboard avoidance shrinks this view's frame. Without this, a caret that
/// was near the bottom of the screen ends up hidden under the keyboard until
/// the next keystroke ("sometimes the keyboard hides it"). Guarded to height
/// changes only: normal scrolling moves `bounds.origin`, not the height, so
/// this never runs mid-scroll and cannot reintroduce a correction loop.
private final class CaretTrackingTextView: UITextView {
    private var lastBoundsHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height != lastBoundsHeight else { return }
        lastBoundsHeight = bounds.height
        guard isFirstResponder else { return }
        CursorEndTextEditor.scrollCaretIntoViewIfNeeded(self)
    }
}
