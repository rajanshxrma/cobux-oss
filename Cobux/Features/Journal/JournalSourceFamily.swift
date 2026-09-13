import SwiftUI

/// What a journal entry's provenance is called, and what colour it wears.
///
/// The store keeps eight distinct source strings — "Apple Journal", "Notes(writing)",
/// "Notes(personal)", "Notes(daily-journal)", "Journal", "iMessage",
/// "Handwritten", "Study". Those are plumbing. Rajan's own
/// mental model, in his words, is three things: "if it's from iMessage, if it's
/// from Apple Journal, Apple Notes". So the display collapses to families, and
/// the raw strings stay untouched in the data.
///
/// Colour is provenance, deliberately NOT the month hue. The month hue is the
/// time dimension — it moves as you scroll back through the year. Source is a
/// fixed property of an entry. Mixing them would muddle both.
enum JournalSourceFamily {
    case appleJournal, notes, messages, handwritten, study, native

    init(source: String) {
        switch source {
        case "Apple Journal": self = .appleJournal
        case "iMessage": self = .messages
        case "Handwritten": self = .handwritten
        case "Study": self = .study
        // Everything written in Cobux itself. The ABSENCE of a pill is what
        // "written here" looks like — it needs no explanation.
        case "journal": self = .native
        // Journal, Notes(writing) and both Notes folders are all Apple Notes.
        default: self = .notes
        }
    }

    /// Lowercase on purpose: the last pass removed a shouting uppercase caption
    /// from the top of every card, and reintroducing one at the bottom would
    /// undo it. The pill reads as an object, not an announcement.
    var label: String? {
        switch self {
        case .appleJournal: "apple journal"
        case .notes: "notes"
        case .messages: "messages"
        case .handwritten: "handwritten"
        case .study: "the study"
        case .native: nil
        }
    }

    var tint: Color {
        switch self {
        case .appleJournal: Color(hex: "#7C5CBF")   // the Journal app's purple
        case .notes: Color(hex: "#B8860B")          // Notes yellow, darkened to read as ink
        case .messages: Color(hex: "#2E8B57")       // iMessage green
        case .handwritten: Color(hex: "#4A6FA5")    // slate
        case .study: Color(hex: "#8B3A4A")
        case .native: .clear
        }
    }
}

/// The pill itself. Fill at low opacity with the text in the same hue at full
/// strength — quiet enough to sit under his writing, distinct enough to tell
/// three sources apart at a glance.
struct JournalSourcePill: View {
    let family: JournalSourceFamily
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let label = family.label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(family.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(family.tint.opacity(colorScheme == .dark ? 0.16 : 0.12), in: Capsule())
                .accessibilityLabel("from \(label)")
        }
    }
}
