import Contacts
import UIKit

/// Adds a contact named "Journal 📓" pointing at the user's own iMessage address.
///
/// Why this exists: texting yourself in Messages is a real, pinned, blue-bubble
/// conversation, and on Rajan's Mac those messages flow into his journal. The
/// only ugly part is that the chat is headed with his own name. Naming the
/// contact "Journal 📓" makes it read as what it is.
///
/// Deliberately NOT automatic on install. Three reasons, and the first is the
/// one that matters:
///
/// 1. iOS does not expose the user's own phone number to an app. There is no
///    API. So a self-contact cannot be created without the user supplying the
///    address, which is most of the work anyone was hoping to skip.
/// 2. Writing to somebody's address book unprompted, on first launch, is the
///    kind of thing that fails review — and should.
/// 3. The message ingestion is a script on Rajan's Mac, not part of this app.
///    A contact created for someone without that pipeline would look like a
///    feature and do nothing, which is the exact defect class this codebase
///    spent a night removing.
///
/// So the copy here promises only what it does: it creates a contact. It does
/// not claim anything about journaling.
enum CobuxContactService {
    enum Outcome {
        case added
        case alreadyExists
        case permissionDenied
        case failed(String)
    }

    /// "Journal 📓", not "Cobux".
    ///
    /// Fable's argument, which Rajan agreed with: a contact named after the app
    /// that actually texts HIS OWN number is a small identity lie in his address
    /// book, and the first time he notices it, trust in the feature drops. This
    /// chat is his self-chat. The honest name is also the better one.
    private static let contactName = "Journal 📓"

    /// - Parameter address: the user's own phone number or Apple ID — whichever
    ///   they actually use for iMessage.
    static func addContact(address: String) async -> Outcome {
        let store = CNContactStore()
        let granted: Bool
        do {
            granted = try await store.requestAccess(for: .contacts)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard granted else { return .permissionDenied }

        // Don't create a second one if it's already there.
        let predicate = CNContact.predicateForContacts(matchingName: contactName)
        if let existing = try? store.unifiedContacts(
            matching: predicate, keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor]),
           !existing.isEmpty {
            return .alreadyExists
        }

        let contact = CNMutableContact()
        contact.givenName = contactName
        contact.organizationName = "Cobux"
        // The app icon, so the chat header carries it the way a person's photo
        // would. Read from the bundle rather than shipped twice.
        if let icon = UIImage(named: "AppIcon") ?? appIconFromBundle() {
            contact.imageData = icon.jpegData(compressionQuality: 0.9)
        }

        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("No address given.") }
        if trimmed.contains("@") {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelOther,
                                                     value: trimmed as NSString)]
        } else {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberiPhone,
                                                   value: CNPhoneNumber(stringValue: trimmed))]
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            return .added
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `UIImage(named: "AppIcon")` does not resolve on every iOS version, so
    /// fall back to reading the primary icon file straight out of the bundle.
    private static func appIconFromBundle() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }
}
