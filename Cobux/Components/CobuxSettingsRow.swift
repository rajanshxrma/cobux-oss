import SwiftUI

/// A static label/value display row for `Form`/`List` screens — an SF Symbol
/// in a tinted rounded-square badge, a `.cobuxRowLabel` leading label, and an
/// optional `.cobuxRowValue` trailing value. Replaces the bare
/// `HStack { Text(...); Spacer(); Text(...).foregroundStyle(.secondary) }`
/// that had been copy-pasted independently at every info-row call site
/// (Settings' Books/Highlights/Chapters/Version/Developer/TestFlight-expiry
/// rows) with no shared identity.
///
/// `valueColor` defaults to `.secondary`, matching the convention already
/// used everywhere else in the app for muted trailing text — deliberately
/// NOT `.cobuxMuted` by default, so adopting this component doesn't quietly
/// shift the color of every row that keeps its default. Pass `.cobuxGood`,
/// `.cobuxWarning`, etc. explicitly for rows that carry real semantic
/// meaning (e.g. "Key set" vs "No key").
///
/// NOT for interactive controls — `Picker`/`Stepper`/`Button`/`SecureField`
/// stay as native `Form` rows, which already pick up iOS 26's Liquid Glass
/// restyling automatically on recompile with zero code changes.
struct CobuxSettingsRow: View {
    let icon: String
    var iconTint: Color = .cobuxAccent
    let label: String
    var value: String? = nil
    var valueColor: Color = .secondary
    /// Adds `.contentTransition(.numericText())` to the value `Text` itself
    /// (not the row as a whole — that modifier only does anything meaningful
    /// on `Text`/`Image`). Off by default; opt in for a value that's a live
    /// changing number, e.g. `MoreView`'s streak count, which had this
    /// digit-roll animation before it was an ad-hoc `HStack` — preserved here
    /// rather than silently lost when it moved onto this shared component.
    var valueNumericTransition: Bool = false

    var body: some View {
        HStack(spacing: CobuxSpacing.rowGap) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.15), in: RoundedRectangle(cornerRadius: CobuxRadius.iconBadge, style: .continuous))
            Text(label)
                .font(CobuxTypography.cobuxRowLabel)
            Spacer()
            if let value {
                Text(value)
                    .font(CobuxTypography.cobuxRowValue)
                    .foregroundStyle(valueColor)
                    .contentTransition(valueNumericTransition ? .numericText() : .identity)
            }
        }
    }
}
