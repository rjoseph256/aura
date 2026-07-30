import SwiftUI
import AuraCore
import AuraKit

/// The shared cockpit instrument chassis: a hero SPEED readout beside a caller-supplied
/// column of secondary instruments, on the opaque quarter-screen panel. Navigate fills the
/// column with to-go + ETA; Explore fills it with distance + time + climb. The chassis owns
/// the optional top line (navigate's street name) and applies ONE composed VoiceOver label
/// across the secondary column, so it reads as a single utterance (the top line's own Text
/// is hidden and folded into that label). Speed stays its own composed element.
struct InstrumentChassis<Column: View>: View {
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    /// Optional context line above the instruments (navigate: current street; Explore: nil).
    let topLine: String?
    /// The composed VoiceOver read for the whole secondary cluster (includes the top line).
    let columnAccessibilityLabel: String
    /// While paused, the readouts drop to secondary weight so a frozen clock looks deliberately
    /// frozen rather than broken.
    ///
    /// `AuraTheme.textSecondary`, never an opacity multiplier on `textPrimary`:
    /// `AuraPaletteContrastTests` guards the token against the panel, and it cannot see through
    /// a composition. This must also stay pure styling — adding a `Text` here would break the
    /// one-composed-VoiceOver-element invariant documented above.
    let isPaused: Bool
    @ViewBuilder let column: Column

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }
    private var readoutColor: Color { isPaused ? AuraTheme.textSecondary : AuraTheme.textPrimary }

    var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            if let topLine {
                Text(topLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true) // folded into the column's composed read
            }

            // Speed hero + secondary column sit together as one centered cluster with a
            // fixed gap, so the panel's slack falls to the outer margins.
            HStack(alignment: .center, spacing: AuraTheme.Spacing.xxl) {
                speedInstrument
                column
                    // One composed VoiceOver read for the whole secondary cluster, so the
                    // instruments read once, not as several mechanical stops.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(columnAccessibilityLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, AuraTheme.Spacing.xl)
        .padding(.top, AuraTheme.Spacing.lg)
        .padding(.bottom, AuraTheme.Spacing.xl) // clear the home indicator
        .background(panelBackground)
        // A cockpit glance target: let it enlarge but cap the accessibility tail so the hero
        // speed can't swamp the whole panel.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // Hero speed: the panel's dominant element. Realistic cycling speeds are 1–2 digits, so
    // the value can run large without overflow; `minimumScaleFactor` guards the edge case.
    private var speedInstrument: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.sm) {
            Text(fmt.speedValue(currentSpeedMetersPerSecond))
                .font(AuraTheme.Typography.speedHero(150, relativeTo: .largeTitle))
                .foregroundStyle(readoutColor)
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

    // Opaque surface with rounded top corners + a hairline, bleeding to the bottom edge.
    // Legibility beats atmosphere in the cockpit, so the panel stays solid.
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

/// One secondary cockpit instrument: a large Saira value over a small caption label. Shared
/// by the navigate (to-go / ETA) and Explore (distance / time / climb) panel columns.
struct CockpitInstrument: View {
    let value: String
    let label: String
    let isPaused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AuraTheme.Typography.metricCockpit(34, relativeTo: .title2))
                .foregroundStyle(isPaused ? AuraTheme.textSecondary : AuraTheme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
