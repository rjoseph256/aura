import SwiftUI
import AuraCore
import AuraKit

/// The prominent bottom cockpit instrument panel: a hero SPEED readout beside the
/// distance still to go and the arrival ETA, sized to about a quarter of the screen so
/// the numbers stay glanceable at riding speed. Speed is the visual hero; to-go and
/// arrival are strong secondary instruments. Driven by the live current speed and the
/// pure `CruisingState`, so it previews without any guidance engine.
struct InstrumentPanel: View {
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    let trip: CruisingState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            if let street = trip.streetName {
                Text(street)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true) // folded into the trip element's composed read
            }

            // Speed hero + trip stats sit together as one centered cluster with a fixed
            // gap, so the panel's slack falls to the outer margins instead of opening a
            // void down the middle.
            HStack(alignment: .center, spacing: AuraTheme.Spacing.xxl) {
                speedInstrument
                // to-go and ETA stack beside the hero.
                VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                    tripInstrument(value: trip.distanceRemaining ?? "–", label: "TO GO")
                        // One composed VoiceOver read for the whole trip (street + to-go +
                        // ETA), so the pair reads once, not as two mechanical stops.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(trip.accessibilityLabel)
                    tripInstrument(value: trip.eta ?? "–", label: "ARRIVE")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, AuraTheme.Spacing.xl)
        .padding(.top, AuraTheme.Spacing.lg)
        .padding(.bottom, AuraTheme.Spacing.xl) // clear the home indicator
        .background(panelBackground)
        // A cockpit glance target: let it enlarge meaningfully but cap the accessibility
        // tail so the hero speed can't swamp the whole panel.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // Hero speed: the panel's dominant element. Realistic cycling speeds are 1–2 digits,
    // so the value can run very large without risk of overflow; `minimumScaleFactor`
    // guards the edge case. Read as a single VoiceOver element.
    private var speedInstrument: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.sm) {
            Text(fmt.speedValue(currentSpeedMetersPerSecond))
                .font(AuraTheme.Typography.speedHero(150, relativeTo: .largeTitle))
                .foregroundStyle(AuraTheme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(fmt.speedUnit.uppercased())
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(AuraTheme.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue(SpeedRailVoice.speedValue(currentSpeedMetersPerSecond, units: units))
    }

    // A secondary instrument: a cockpit number over a small caption label.
    private func tripInstrument(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AuraTheme.Typography.metricCockpit(34, relativeTo: .title2))
                .foregroundStyle(AuraTheme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // Opaque surface with rounded top corners + a hairline, bleeding to the bottom edge.
    // Legibility beats atmosphere in the cockpit, so the panel stays solid rather than
    // translucent even when the map is bright behind it.
    private var panelBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: AuraTheme.Radius.xl,
            topTrailingRadius: AuraTheme.Radius.xl,
            style: .continuous)
        return shape
            .fill(AuraTheme.surface)
            .overlay(shape.stroke(AuraTheme.hairline(contrast), lineWidth: 1))
            .ignoresSafeArea(edges: .bottom)
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        InstrumentPanel(
            currentSpeedMetersPerSecond: 8.1, // ~18 mph
            units: .imperial,
            trip: .init(streetName: "Stedman Street", distanceRemaining: "7.2 mi",
                        eta: "11:32 PM",
                        accessibilityLabel: "On Stedman Street, 7.2 miles to go, arriving 11:32 PM"))
            .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
    }
}
