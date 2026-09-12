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
                    distance
                    time
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
                    hero
                    Spacer(minLength: 0)
                    distance
                    // Higher layout priority so distance (not time) is squeezed first when the
                    // row is tight — a 3-hour ride's "0:00 / 3:01:56" is the value most likely to
                    // wrap otherwise.
                    time
                        .layoutPriority(1)
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

    // `.lineLimit(1).minimumScaleFactor(0.7)` so a long value ("0:00 / 3:01:56") shrinks instead
    // of wrapping or truncating; it reaches both Texts inside `StatPair`, but the label is
    // already a short single word so it never needs the floor.
    private var distance: some View {
        StatPair(value: readout.distanceText, label: readout.distanceUnit.uppercased())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
    private var time: some View {
        StatPair(value: readout.timeText, label: "TIME")
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
