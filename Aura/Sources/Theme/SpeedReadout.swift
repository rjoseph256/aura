import SwiftUI

struct SpeedReadout: View {
    let value: String
    let unit: String
    private let size: CGFloat = 62

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.sm) {
            Text(value)
                .font(AuraTheme.Typography.speedHero(size, relativeTo: .largeTitle))
                .foregroundStyle(AuraTheme.textPrimary)
            Text(unit)
                .font(AuraTheme.Typography.unit)
                .foregroundStyle(AuraTheme.accent)
        }
    }
}
