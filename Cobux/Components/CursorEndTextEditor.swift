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
            // NO caret correction here -- and that absence is the fifth fix,
            // the one that finally follows the house's own solved-problems
            // rule. UIKit already scrolls the caret into view while typing
            // when the insets are honest (CaretTrackingTextView owns them).
            // Our hand-rolled checker reserved a one-line "breathing band" at
            // the bottom, which made the LAST line permanently count as
            // off-screen once the view was scrolled to its end -- so it fired
            // scrollRangeToVisible on every keystroke against UIKit's own
            // positioning, and the two disagreed by exactly one band, forever.
            // That disagreement was the up-and-down, reported four times,
            // always "at the bottom, above the keyboard edge". The system
            // solution existed all along; this line now simply lets it run.
        }
    }

    /// Scrolls only when the caret has actually left the visible box --
    /// shared by the per-keystroke path above and the height-change path in
    /// `CaretTrackingTextView` below.
    static func scrollCaretIntoViewIfNeeded(_ textView: UITextView) {
        guard let selectedRange = textView.selectedTextRange else { return }
        let caretRect = textView.caretRect(for: selectedRange.end)
        guard !caretRect.isNull, caretRect.origin.y.isFinite, caretRect.height.isFinite else { return }
        let visible = visibleContentRect(bounds: textView.bounds,
                                         inset: textView.adjustedContentInset,
                                         lineHeight: caretRect.height)
        guard !visible.contains(caretRect) else { return }
        // The guards above verify the caret has actually left the visible
        // box before scrolling; the common typing case returns early and
        // never fights keyboard avoidance.
        // lint-ok: keystroke-scroll -- guarded, caret verified offscreen
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// The on-screen region, in the same coordinate space `caretRect(for:)`
    /// returns. Pure arithmetic so it can be reasoned about (and tested)
    /// without instantiating a text view.
    ///
    /// On any scroll view -- `UITextView` included -- `bounds.origin` IS
    /// `contentOffset`, so insetting the bounds already yields a rect in
    /// content coordinates. The previous version *additionally* offset by
    /// `contentOffset`, double-counting the scroll position: the moment the
    /// entry grew long enough to scroll at all, the computed rect sat a whole
    /// offset too far down the document, the visibly on-screen caret always
    /// tested as outside it, and `scrollRangeToVisible` fired on EVERY
    /// keystroke. That is the shake Rajan reported three times -- and it was
    /// specifically "when it gets to the bottom of textbox", because that is
    /// exactly when `contentOffset.y` stops being zero.
    static func visibleContentRect(bounds: CGRect,
                                   inset: UIEdgeInsets,
                                   lineHeight: CGFloat) -> CGRect {
        // No breathing band. The band meant the last line could NEVER be
        // "visible" at max scroll -- the exact oscillator behind four judder
        // reports. UIKit's own caret geometry has no such band; agreeing
        // with the system is the fix.
        _ = lineHeight
        return bounds.inset(by: inset)
    }
}

/// Owns the keyboard, so that exactly one thing does.
///
/// This is the fourth attempt at the judder Rajan has now reported four times
/// -- "when i get to bottom still it weirds out up and down when my keyboard
/// upper edge touches my writing" -- and the previous three all failed the same
/// way: they tuned WHO corrects the scroll position, when the real problem is
/// HOW MANY things were correcting it.
///
/// Fix one removed the nested scroll view (a `Form` wrapping a `UITextView`),
/// which was necessary and real. Fix two stopped double-counting
/// `contentOffset`. Fix three coalesced the corrections. All three left the
/// underlying structure intact: SwiftUI's keyboard avoidance ANIMATES this
/// view's frame smaller over ~0.25s, `layoutSubviews` runs once per animation
/// frame, and a scroll correction made against a frame that is still moving is
/// a correction that has to be made again on the next frame. That is the
/// up-and-down, and it is not tunable -- it is what the structure does.
///
/// Notes never judders because its text view's frame does NOT change when the
/// keyboard appears. The view keeps its full height, the keyboard simply
/// covers the bottom of it, and the text view accounts for that with
/// `contentInset.bottom`. Nothing re-lays-out, nothing animates a frame,
/// nothing scrolls in response to a scroll. UIKit's own built-in
/// caret-into-view then works, because it is the only thing running.
///
/// So: `JournalEntryComposeView` tells SwiftUI to stop resizing this view
/// (`.ignoresSafeArea(.keyboard)`), and this class takes responsibility for
/// the keyboard itself. Both halves are required -- the inset alone would
/// double-compensate against a frame that still shrinks, which is a worse
/// version of the same bug.
private final class CaretTrackingTextView: UITextView {
    private var observers: [NSObjectProtocol] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
                self?.applyKeyboardInset(note)
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func applyKeyboardInset(_ note: Notification) {
        guard let window else { return }
        let info = note.userInfo
        let endFrame = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let overlap: CGFloat
        if note.name == UIResponder.keyboardWillHideNotification || endFrame == nil {
            overlap = 0
        } else {
            // Both rects in window space before comparing. The notification's
            // frame is in screen coordinates, which is only the same thing as
            // window coordinates in the common case -- not in Split View, not
            // in Stage Manager.
            let keyboard = window.convert(endFrame!, from: nil)
            let mine = convert(bounds, to: window)
            overlap = max(0, mine.maxY - keyboard.minY)
        }
        // `adjustedContentInset` already adds `safeAreaInsets`, so adding the
        // raw overlap here would count the home indicator twice and leave a
        // permanent gap under the last line.
        let bottom = max(0, overlap - safeAreaInsets.bottom)
        guard abs(contentInset.bottom - bottom) > 0.5 else { return }

        let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curveRaw = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.contentInset.bottom = bottom
            self.verticalScrollIndicatorInsets.bottom = bottom
        } completion: { _ in
            // One correction, after everything has settled -- not one per
            // animation frame. By this point the inset is final, so the answer
            // this computes stays true.
            guard self.isFirstResponder else { return }
            CursorEndTextEditor.scrollCaretIntoViewIfNeeded(self)
        }
    }
}
