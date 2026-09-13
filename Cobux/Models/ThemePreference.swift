import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    /// The red-black look on any device, whatever its own setting.
    ///
    /// The 3.0 identity repainted only the dark palette, and the default here
    /// is `.system`, so a phone kept in light mode never saw it (ledger row
    /// "The red-black theme as a fourth Appearance choice"; decided as P9,
    /// 12 Sep). This is exactly the dark scheme -- `colorScheme` returns
    /// `.dark`, and every room already wears the crimson wash in dark
    /// (`CobuxGround`) -- named so a light-mode phone can choose it. It does
    /// not repaint light mode's own palette: a light red-black is a different
    /// design, and he can ask for it after seeing this one.
    case crimson

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match Device"
        case .light: return "Light"
        case .dark: return "Dark"
        case .crimson: return "Crimson"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .crimson: return .dark
        }
    }
}
