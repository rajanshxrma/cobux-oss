import SwiftUI
import ContactsUI

/// The system contact picker, wrapped for SwiftUI — the "picker first"
/// posture of `docs/people-in-the-journal.md` §4.
///
/// `CNContactPickerViewController` needs NO permission and no usage string:
/// iOS draws its own picker out of process and the app receives exactly one
/// `CNContact`, the one he tapped, and nothing else. So the address book is
/// never read by the app, `NSContactsUsageDescription` keeps its promise
/// ("never reads your address book"), and Settings → Privacy → Contacts shows
/// Cobux exactly as before.
///
/// What is kept: the contact's `identifier` (on the `JournalPerson` row, his
/// decision, survives restore) and a downscaled copy of the photo in
/// `PeopleThumbnailStore` (regenerable, excluded from backup). Nothing is
/// ever written back — no `CNSaveRequest` anywhere in People.
struct PersonContactPicker: UIViewControllerRepresentable {
    /// The one contact he chose, with a small JPEG of its photo when it has
    /// one. Delivered on the main actor after the picker dismisses itself.
    struct Pick {
        let identifier: String
        let photo: Data?
    }

    let onPick: (Pick) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // A tap on a contact returns the contact; no property drill-down. The
        // page needs a person, not a phone number.
        picker.displayedPropertyKeys = [CNContactGivenNameKey, CNContactFamilyNameKey]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let parent: PersonContactPicker

        init(parent: PersonContactPicker) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            // The thumbnail is already small; the full image is the fallback
            // for a contact that has one but no cached thumbnail. Either way
            // `PeopleThumbnailStore` bounds it before writing.
            let photo: Data? = {
                if contact.isKeyAvailable(CNContactThumbnailImageDataKey),
                   let data = contact.thumbnailImageData { return data }
                if contact.isKeyAvailable(CNContactImageDataKey),
                   let data = contact.imageData { return data }
                return nil
            }()
            parent.onPick(Pick(identifier: contact.identifier, photo: photo))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}
