import Messages
import SwiftUI
import UIKit

/// Cobux inside the Messages app drawer.
///
/// Reads NOTHING of any conversation — a Messages app extension is handed its
/// own blank surface, which is exactly why this is the version that carries no
/// privacy cost. It writes to the same App Group store the app and Share
/// Extension already write, so an entry made here appears in Journal like any
/// other and rides the existing iCloud export.
///
/// The presentation style matters to the design, not just the layout. In
/// `.compact` — the drawer pane — this is a composed surface with the mark, the
/// field and the send button, because that is the whole point: a thought
/// arrives mid-conversation and should cost one tap, not five. The pane used to
/// be an inert label you tapped to expand, which is what made him say "this is
/// too many steps". `.expanded` keeps the roomier surface for anything longer
/// than a line.
///
/// **`.compact` is not a thin strip.** It has not been one for several iOS
/// versions — Messages gives the drawer a tall pane, and `MessagesJournalView`
/// used to draw a single centred `HStack` into it, which is the field floating
/// in an empty sheet he photographed. That is fixed in the view, which now
/// anchors its content to the top; this file's job is only to tell it which of
/// the two surfaces it is.
///
/// Since build 58 the expanded surface also hosts "Ask Cobux"
/// (`MessagesAskView`), and this controller is where the two things only it
/// can do live: put text into the iMessage composer (`activeConversation?
/// .insertText`) -- never send it; the person does that -- and open the
/// containing app. It also owns the pane's state (`MessagesPaneModel`), so
/// reassigning the root view below never loses what he typed.
final class MessagesViewController: MSMessagesAppViewController {
    private var host: UIHostingController<MessagesJournalView>?
    /// Constructed once, does nothing until asked: no keychain, no network,
    /// no store touched here (see its doc comment).
    private let model = MessagesPaneModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let controller = UIHostingController(rootView: makeRoot(compact: wantsCompactLayout))
        // The pane is Messages' ground, not ours; an opaque hosting background
        // would draw a slab over the conversation. The EXPANDED surface paints
        // its own Cobux ground inside the view, which is the right place for it
        // — that one is a full sheet the user opened on purpose.
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        host = controller
    }

    /// Resync on the way in as well as on transition.
    ///
    /// `viewDidLoad` reads `presentationStyle` once, at a moment Messages has
    /// not necessarily finished deciding it, and `willTransition(to:)` only
    /// fires when the style CHANGES. An extension launched straight into the
    /// expanded style therefore had no callback at all and rendered whatever
    /// `viewDidLoad` happened to read. One idempotent reassignment here closes
    /// that gap; SwiftUI diffs an identical root view to nothing.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host?.rootView = makeRoot(compact: wantsCompactLayout)
    }

    /// Only `.expanded` gets the roomier surface.
    ///
    /// Written as "not expanded" rather than "== .compact" deliberately:
    /// `MSMessagesAppPresentationStyle` also has `.transcript`, a bubble-sized
    /// view inside the conversation itself, and giving that one a full-sheet
    /// layout with its own opaque background would be far worse than giving it
    /// the compact one. The compact surface already adapts to whatever height
    /// it is handed.
    private var wantsCompactLayout: Bool {
        presentationStyle != .expanded
    }

    private func makeRoot(compact: Bool) -> MessagesJournalView {
        MessagesJournalView(
            model: model,
            onSaved: { [weak self] in
                // `.compact` IS the close: a Messages extension is a pane
                // inside Messages, not a sheet it owns, so there is no dismiss
                // API. Collapsing is as closed as it gets. The view resets
                // itself right afterwards so the next open starts blank —
                // without that, reopening showed a stuck "Saved" over the last
                // entry with the button disabled.
                self?.view.endEditing(true)
                self?.requestPresentationStyle(.compact)
            },
            isCompact: compact,
            onRequestExpand: { [weak self] in
                self?.requestPresentationStyle(.expanded)
            },
            onInsertText: { [weak self] text in
                self?.insertIntoConversation(text)
            },
            onOpen: { [weak self] url in
                self?.extensionContext?.open(url)
            }
        )
    }

    /// The whole point of Ask Cobux: the reply lands in the iMessage
    /// composer and STOPS there. His design -- "the user could slide it down
    /// and send the text" -- and the rule this file has carried since 52:
    /// never send a message on the user's behalf. `insertText` is the API
    /// that does exactly that and nothing more; an `MSMessage` is never built.
    ///
    /// On success the pane collapses, because the composer he is about to
    /// send from sits BEHIND the expanded pane. Collapsing is the "slide it
    /// down" -- done for him, so the words and the send button are on screen
    /// together the moment the tap lands.
    private func insertIntoConversation(_ text: String) {
        guard let conversation = activeConversation else {
            model.notice = .insertFailed
            return
        }
        conversation.insertText(text) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil else {
                    self.model.notice = .insertFailed
                    return
                }
                self.view.endEditing(true)
                self.requestPresentationStyle(.compact)
            }
        }
    }

    /// Rebuild the root when Messages changes the pane size, so the compact
    /// pane and the expanded pane are genuinely different surfaces rather than
    /// one layout squeezed into both.
    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        host?.rootView = makeRoot(compact: presentationStyle != .expanded)
    }

    /// Focus AFTER the transition, not during it.
    ///
    /// The fix for "sometimes it does not show the keyboard". The expanded
    /// editor's `.onAppear` runs when the root above is reassigned, which is
    /// `willTransition` -- the pane is still animating and cannot host a
    /// keyboard yet, so whether the focus request survived was a race. This
    /// is the callback Messages fires once the pane IS expanded; the model's
    /// `focusRequest` tells whichever mode is showing to take focus now.
    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        if presentationStyle == .expanded {
            model.requestFocus()
        }
    }
}
