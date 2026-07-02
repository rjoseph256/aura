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
            Text(label)
                .font(labelFont)
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }
}
