import SwiftUI

/// A `Form` section with type-scale-consistent header/footer text, instead of
/// each of Settings/MoreView/etc. reaching for a bare `Text("...")` header
/// (or, in a few places, nothing at all) per call site with no shared
/// identity. Per the 2.2.0 redesign plan, this is the single highest-leverage
/// change for the ~15 stock `Form`/`List` screens actually looking designed —
/// bigger than glass itself, since it's what stops them reading as a default
/// system Form the instant it's applied. `SettingsView` is the exemplar this
/// was proven on; `MoreView` is the second consumer that confirms it
/// generalizes before the remaining screens adopt it in 2.3.0.
struct CobuxFormSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            content()
        } header: {
            Text(title)
                .font(CobuxTypography.cobuxSectionHeader)
        } footer: {
            if let footer {
                Text(footer)
                    .font(CobuxTypography.cobuxCaption)
            }
        }
    }
}
