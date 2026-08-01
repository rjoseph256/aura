import SwiftUI
import WidgetKit
import ActivityKit
import AuraKit
import AuraCore

/// The Lock Screen presentation of the in-progress-ride Live Activity — the primary
/// surface (every device shows it; Dynamic Island is supplementary). Two layouts:
///
/// - **Free ride:** identity header, then a row of glanceable stats — elapsed, distance,
///   speed.
/// - **Navigate:** the next turn as the hero (distance + instruction, mint when imminent),
///   then a quiet row of elapsed + distance.
///
/// Near-black surface; mint accents and high-contrast cockpit numerals stay legible over
/// the Lock Screen's variable backdrop.
struct RideLockScreenView: View {
    let context: ActivityViewContext<RideActivityAttributes>

    private var attributes: RideActivityAttributes { context.attributes }
    private var state: RideActivityAttributes.ContentState { context.state }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: attributes.units) }
    /// Moving stats (distance / speed) freeze when the app can't push; dim them so the
    /// still-live elapsed timer stays the trustworthy value.
    private var statOpacity: Double { context.isStale ? 0.4 : 1 }

    var body: some View {
        Group {
            switch attributes.mode {
            case .freeRide: freeRide
            case .navigate: navigate
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .containerBackground(for: .widget) { background }
    }

    // MARK: Free ride

    private var freeRide: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "Explore", glyph: rideActivityGlyph(nav: false, paused: state.isPaused,
                                                               turnGlyph: nil),
                   imminent: false)

            HStack(alignment: .top, spacing: 12) {
                RideTimerStatCell(clock: state.activeClock(startedAt: attributes.startedAt),
                                  label: "TIME")
                    .frame(maxWidth: .infinity, alignment: .leading)
                RideStatCell(value: fmt.distanceValue(state.distanceMeters),
                             label: fmt.distanceUnit.uppercased())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(statOpacity)
                RideStatCell(value: fmt.speedValue(state.speedMetersPerSecond),
                             label: fmt.speedUnit.uppercased())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(statOpacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(freeRideAccessibilityLabel)
    }

    // MARK: Navigate

    private var navigate: some View {
        let imminent = rideActivityIsImminent(state.turnDistanceMeters, isPaused: state.isPaused)
        let turnTint = imminent ? AuraTheme.accent : AuraTheme.textPrimary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AuraGlyph(systemName: rideActivityGlyph(nav: true, paused: state.isPaused,
                                                        turnGlyph: state.turnGlyphSystemName),
                          imminent: imminent, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(turnDistanceText)
                        .font(AuraTheme.Typography.metricCockpit(30, relativeTo: .title))
                        .foregroundStyle(turnTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(instructionText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuraTheme.textPrimary.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                RideStatusPill(isPaused: state.isPaused, isStale: context.isStale)
            }

            HStack(alignment: .top, spacing: 12) {
                RideTimerStatCell(clock: state.activeClock(startedAt: attributes.startedAt),
                                  label: "TIME")
                    .frame(maxWidth: .infinity, alignment: .leading)
                RideStatCell(value: fmt.distanceValue(state.distanceMeters),
                             label: fmt.distanceUnit.uppercased())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(statOpacity)
                if let destination = attributes.destinationName {
                    destinationCell(destination)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(navigateAccessibilityLabel)
    }

    private func destinationCell(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("DESTINATION")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    // MARK: Shared

    private func header(title: String, glyph: String, imminent: Bool) -> some View {
        HStack(spacing: 10) {
            AuraGlyph(systemName: glyph, imminent: imminent, size: 30)
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
            Spacer(minLength: 8)
            RideStatusPill(isPaused: state.isPaused, isStale: context.isStale)
        }
    }

    private var background: some View {
        AuraTheme.background
    }

    private var turnDistanceText: String {
        guard let d = state.turnDistanceMeters else { return "–" }
        return fmt.maneuverDistance(d)
    }

    private var instructionText: String {
        state.turnInstruction ?? "Navigating…"
    }

    /// Folds `context.isStale` in alongside `isPaused` so VoiceOver distinguishes all four
    /// states `RideStatusPill` can show. `.accessibilityElement(children: .combine)` followed by
    /// `.accessibilityLabel` REPLACES the merged children's text rather than adding to it, so the
    /// pill's own "NOT UPDATING" is never spoken unless it is folded in here — otherwise a rider
    /// on a jetsam-killed, paused ride hears only "Explore paused," with no hint that nothing is
    /// updating (spec D6).
    private var freeRideAccessibilityLabel: String {
        switch (state.isPaused, context.isStale) {
        case (true, true): return "Explore paused, not updating"
        case (true, false): return "Explore paused"
        case (false, true): return "Explore in progress, not updating"
        case (false, false): return "Explore in progress"
        }
    }

    /// See `freeRideAccessibilityLabel` — same composition rule, applied to the navigate layout.
    private var navigateAccessibilityLabel: String {
        let next = "Next: \(instructionText), \(turnDistanceText)"
        switch (state.isPaused, context.isStale) {
        case (true, true): return "Navigating, paused, not updating. \(next)"
        case (true, false): return "Navigating, paused. \(next)"
        case (false, true): return "Navigating, not updating. \(next)"
        case (false, false): return "Navigating. \(next)"
        }
    }
}
