import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// `NSExtensionPrincipalClass` for the Share Extension — extracts whatever plain text was
/// shared (a Kindle/Books/Safari text selection), then hands off to `ShareQuoteView` for the
/// actual save. A plain `UIViewController` hosting SwiftUI, not `SLComposeServiceViewController`
/// — Apple's default compose UI doesn't have a book picker, and this needs one.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedText { [weak self] text in
            DispatchQueue.main.async {
                self?.presentShareQuoteView(initialText: text ?? "")
            }
        }
    }

    private func presentShareQuoteView(initialText: String) {
        let quoteView = ShareQuoteView(
            initialText: initialText,
            onComplete: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let hosting = UIHostingController(rootView: quoteView)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        let error = NSError(domain: "com.rajansharma.Cobux.ShareExtension", code: 0)
        extensionContext?.cancelRequest(withError: error)
    }

    /// Share extensions receive one or more `NSExtensionItem`s, each carrying `NSItemProvider`
    /// attachments — the exact shape depends on the source app. Text selections from Kindle/
    /// Books/Safari register as `public.plain-text`; falls back to a shared URL's absolute
    /// string if no plain text is present, so the extension still produces something usable
    /// rather than an empty quote field.
    private func extractSharedText(completion: @escaping (String?) -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments, !attachments.isEmpty else {
            completion(nil)
            return
        }

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { result, _ in
                completion((result as? String))
            }
            return
        }

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { result, _ in
                completion((result as? URL)?.absoluteString)
            }
            return
        }

        completion(nil)
    }
}
