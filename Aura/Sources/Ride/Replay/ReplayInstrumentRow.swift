import SwiftUI
import AuraKit

/// The three readouts (spec D5): speed as the hero, distance and time with their totals. One
/// combined VoiceOver element. Wraps to two lines at accessibility sizes.
struct ReplayInstrumentRow: View {
    let readout: ReplayReadout
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 40

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                    hero
                    HStack(spacing: AuraTheme.Spacing.xxl) { distance; time }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
                    hero
                    Spacer(minLength: 0)
                    distance
                    time
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readout.accessibilityLabel)
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
            Text(readout.speedText)
                .font(AuraTheme.Typography.metricBrand(min(heroSize, 56)))
                .monospacedDigit()
                .foregroundStyle(AuraTheme.textPrimary)
            Text(readout.speedUnit)
                .font(AuraTheme.Typography.unit)
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    private var distance: some View { StatPair(value: readout.distanceText, label: readout.distanceUnit.uppercased()) }
    private var time: some View { StatPair(value: readout.timeText, label: "TIME") }
}
