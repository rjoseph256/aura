import SwiftUI

struct StatPair: View {
    enum Context { case cockpit, brand }
    let value: String
    let label: String
    var context: Context = .brand
    /// How the value stacks over the label. Cockpit instrument rows read best leading
    /// (the default); centered 3-up grids (e.g. the ride summary) pass `.center`.
    var alignment: HorizontalAlignment = .leading
    /// Label font. Defaults to `.caption2` (cockpit/summary rows); the share card passes a
    /// larger size so labels survive feed-thumbnail scale.
    var labelFont: Font = .caption2
    /// Label color override. Defaults to `nil` (→ `AuraTheme.textSecondary`); the share card
    /// passes its high-contrast secondary because a fixed PNG can't honor Increase Contrast.
    var labelColor: Color?
    /// Line limit for the VALUE text only — never the label, which is always a short, fixed
    /// word and never needs it. `nil` (default) leaves the value unconstrained, matching every
    /// caller before this parameter existed (replay's instrument row is the first to set it, so
    /// a long value like "32:28 / 3:01:56" shrinks instead of wrapping or truncating).
    var valueLineLimit: Int?
    /// Minimum scale factor for the VALUE text only. `1` (default, i.e. no shrinking) matches
    /// every caller before this parameter existed.
    var valueMinimumScaleFactor: CGFloat = 1
    // Brand (system) font has a fixed size → @ScaledMetric drives Dynamic Type.
    @ScaledMetric(relativeTo: .title2) private var brandValueSize: CGFloat = 21
    // Cockpit (Saira) font self-scales via relativeTo: → plain base size (no @ScaledMetric).
    private let cockpitValueSize: CGFloat = 22

    var body: some View {
        VStack(alignment: alignment, spacing: AuraTheme.Spacing.xs) {
            Text(value)
                .font(context == .cockpit
                      ? AuraTheme.Typography.metricCockpit(cockpitValueSize, relativeTo: .title2)
                      : AuraTheme.Typography.metricBrand(brandValueSize))
                .foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(valueLineLimit)
                .minimumScaleFactor(valueMinimumScaleFactor)
            Text(label)
                .font(labelFont)
                .foregroundStyle(labelColor ?? AuraTheme.textSecondary)
        }
    }
}
