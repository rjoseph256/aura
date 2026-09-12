import SwiftUI
import AuraKit

/// The three readouts (spec D5): speed as the hero, distance and time with their totals. One
/// combined VoiceOver element. Stacks all three vertically at accessibility sizes **(v2.3)**.
struct ReplayInstrumentRow: View {
    let readout: ReplayReadout
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 40

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Speed (hero), then distance so-far/total, then time so-far/total — each its
                // own row, leading-aligned — rather than distance+time sharing a second row,
                // which truncated the time value ("0:00 / 7:…") at AX3.
                VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                    hero
                    distance(minimumScaleFactor: 0.7)
                    time(minimumScaleFactor: 0.7)
                }
            } else {
                // Distance and time split the remaining width evenly (not `.layoutPriority`,
                // which let time take its full width and squeezed distance into truncating —
                // "6.7 / 3…" — once time grew to "32:28 / 3:01:56"). Each column's own
                // `minimumScaleFactor` absorbs its longest value within its half instead.
                HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
                    hero
                    Spacer(minLength: 0)
                    distance(minimumScaleFactor: 0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    time(minimumScaleFactor: 0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    // `valueLineLimit`/`valueMinimumScaleFactor` reach only `StatPair`'s value text, never its
    // unit label ("MI"/"TIME"), which is a short fixed word and must stay unscaled. The default
    // and accessibility branches pass different floors (see call sites above).
    private func distance(minimumScaleFactor: CGFloat) -> some View {
        StatPair(
            value: readout.distanceText, label: readout.distanceUnit.uppercased(),
            valueLineLimit: 1, valueMinimumScaleFactor: minimumScaleFactor)
    }
    private func time(minimumScaleFactor: CGFloat) -> some View {
        StatPair(value: readout.timeText, label: "TIME",
                 valueLineLimit: 1, valueMinimumScaleFactor: minimumScaleFactor)
    }
}
