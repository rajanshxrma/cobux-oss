import SwiftUI
import UIKit

/// Presents the system share sheet.
///
/// Exists because the WIDGET cannot. A WidgetKit extension hosts only
/// `Button(intent:)`, `Link` and `.widgetURL`, and has no window to present
/// into — a `ShareLink` placed inside one renders perfectly and does nothing
/// when tapped, which is exactly how the widget's share button shipped broken
/// from the commit that introduced it. The widget now links to
/// `cobux://share/<bookID>/<highlightID>`, the app opens, and this does the
/// part only the app can do.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
