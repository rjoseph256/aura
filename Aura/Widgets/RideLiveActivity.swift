import SwiftUI
import WidgetKit
import ActivityKit
import AuraKit

/// The in-progress-ride Live Activity: Lock Screen layout plus all four Dynamic Island
/// presentations (compact leading/trailing, minimal, expanded). The Lock Screen lives in
/// `RideLockScreenView`; this type owns the configuration and the Dynamic Island.
///
/// Free ride leads with the elapsed clock; navigate leads with the next maneuver, which
/// inverts to a solid mint fill when imminent — the same cue the HUD's turn card uses.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(context: context)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            dynamicIsland(context)
        }
    }

    // MARK: Dynamic Island

    private func dynamicIsland(_ context: ActivityViewContext<RideActivityAttributes>) -> DynamicIsland {
        let nav = context.attributes.mode == .navigate
        let imminent = rideActivityIsImminent(context.state.turnDistanceMeters)
        let accent = AuraTheme.accent

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                expandedLeading(context, nav: nav, imminent: imminent)
            }
            DynamicIslandExpandedRegion(.trailing) {
                expandedTrailing(context, nav: nav, imminent: imminent)
            }
            DynamicIslandExpandedRegion(.bottom) {
                expandedBottom(context, nav: nav)
            }
        } compactLeading: {
            Image(systemName: nav ? rideActivityManeuverSymbol(for: context.state.turnInstruction) : "bicycle")
                .foregroundStyle(accent)
        } compactTrailing: {
            if nav {
                Text(turnDistanceText(context))
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            } else {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(AuraTheme.accent)
                    .frame(maxWidth: 56)
            }
        } minimal: {
            Image(systemName: nav ? rideActivityManeuverSymbol(for: context.state.turnInstruction) : "bicycle")
                .foregroundStyle(accent)
        }
        .keylineTint(accent)
    }

    // MARK: Expanded regions

    private func expandedLeading(_ context: ActivityViewContext<RideActivityAttributes>,
                                 nav: Bool, imminent: Bool) -> some View {
        HStack(spacing: 8) {
            AuraGlyph(systemName: nav ? rideActivityManeuverSymbol(for: context.state.turnInstruction) : "bicycle",
                      imminent: nav && imminent, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aura")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AuraTheme.accent)
                Text(nav ? "Next turn" : "Explore")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
    }

    private func expandedTrailing(_ context: ActivityViewContext<RideActivityAttributes>,
                                  nav: Bool, imminent: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if nav {
                Text(turnDistanceText(context))
                    .font(AuraTheme.Typography.metricCockpit(30, relativeTo: .title))
                    .foregroundStyle(imminent ? AuraTheme.accent : AuraTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text("TO TURN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AuraTheme.textSecondary)
            } else {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AuraTheme.accent)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                Text("ELAPSED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func expandedBottom(_ context: ActivityViewContext<RideActivityAttributes>,
                                nav: Bool) -> some View {
        let fmt = RideStatsFormatter(units: context.attributes.units)
        let state = context.state
        let statOpacity = context.isStale ? 0.4 : 1

        if nav {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.turnInstruction ?? "Navigating…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .lineLimit(1)
                HStack(alignment: .top, spacing: 16) {
                    RideTimerStatCell(start: context.attributes.startedAt, label: "TIME")
                    RideStatCell(value: fmt.distanceValue(state.distanceMeters),
                                 label: fmt.distanceUnit.uppercased())
                        .opacity(statOpacity)
                    if let destination = context.attributes.destinationName {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(destination)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(AuraTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("TO")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AuraTheme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 2)
        } else {
            HStack(alignment: .top, spacing: 16) {
                RideStatCell(value: fmt.distanceValue(state.distanceMeters),
                             label: fmt.distanceUnit.uppercased())
                    .opacity(statOpacity)
                RideStatCell(value: fmt.speedValue(state.speedMetersPerSecond),
                             label: fmt.speedUnit.uppercased())
                    .opacity(statOpacity)
                RideStatCell(value: fmt.elevationValue(state.elevationGainMeters),
                             label: "\(fmt.elevationUnit.uppercased()) ↑")
                    .opacity(statOpacity)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private func turnDistanceText(_ context: ActivityViewContext<RideActivityAttributes>) -> String {
        guard let d = context.state.turnDistanceMeters else { return "–" }
        return RideStatsFormatter(units: context.attributes.units).maneuverDistance(d)
    }
}
