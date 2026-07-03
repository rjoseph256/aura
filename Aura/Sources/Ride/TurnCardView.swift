import SwiftUI
import AuraKit

/// Animated turn-card pinned at the top of the navigate HUD.
///
/// Two visual states keyed by `state.isExpanded`:
/// - **Collapsed** (calm): compact dark card, small arrow + distance + street name.
/// - **Expanded** (imminent): grows, shifts to solid mint fill, ink-on-mint text, glow.
///
/// Motion is driven by a single `.smooth(duration: 0.38)` animation so the whole
/// card morphs together — no overshoot, calm and decisive. `reduceMotion` gates
/// every heavy transform so the card crossfades only.
struct TurnCardView: View {
    let state: TurnCardState
    var reduceMotion: Bool = false

    // MARK: Layout constants

    // Arrow sizes stay @ScaledMetric (SF Symbol point size). Distance numerals use the
    // Saira cockpit face, which self-scales via `relativeTo:` — so those are plain base sizes.
    @ScaledMetric(relativeTo: .title2)     private var arrowCollapsed: CGFloat = 24
    @ScaledMetric(relativeTo: .largeTitle) private var arrowExpanded: CGFloat = 34

    private let distCollapsed: CGFloat = 22
    private let distExpanded: CGFloat = 36

    // MARK: Body

    var body: some View {
        HStack(spacing: state.isExpanded ? AuraTheme.Spacing.md : AuraTheme.Spacing.sm) {
            // Maneuver arrow — the real directional glyph for the upcoming turn (generic
            // arrow when the engine supplies no structured maneuver).
            Image(systemName: ManeuverIcon.symbol(for: state.maneuver))
                .font(.system(
                    size: state.isExpanded ? arrowExpanded : arrowCollapsed,
                    weight: .bold
                ))
                .foregroundStyle(state.isExpanded ? AuraTheme.onAccent : AuraTheme.accent)
                // Scale instead of animating .font size (font size doesn't interpolate).
                .scaleEffect(reduceMotion ? 1 : (state.isExpanded ? 1.0 : 0.72))
                .animation(
                    reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
                    value: state.isExpanded
                )

            VStack(alignment: .leading, spacing: state.isExpanded ? AuraTheme.Spacing.xs : 2) {
                // Distance countdown — Saira cockpit numerals, mint; rolls digit-by-digit.
                Text(state.distanceText)
                    .font(AuraTheme.Typography.metricCockpit(
                        state.isExpanded ? distExpanded : distCollapsed,
                        relativeTo: state.isExpanded ? .largeTitle : .title2
                    ))
                    .foregroundStyle(state.isExpanded ? AuraTheme.onAccent : AuraTheme.accent)
                    .contentTransition(.numericText())
                    .scaleEffect(
                        reduceMotion ? 1 : (state.isExpanded ? 1.0 : 0.72),
                        anchor: .leading
                    )
                    .animation(
                        reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
                        value: state.isExpanded
                    )

                // Street / instruction text — fades on change.
                Text(state.primaryText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        state.isExpanded ? AuraTheme.onAccent.opacity(0.75) : AuraTheme.textPrimary.opacity(0.9)
                    )
                    .contentTransition(.opacity)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .padding(.horizontal, state.isExpanded ? AuraTheme.Spacing.xl : AuraTheme.Spacing.lg)
        .padding(.vertical, state.isExpanded ? AuraTheme.Spacing.lg : AuraTheme.Spacing.md)
        // Background shifts from near-opaque dark → mint.
        .background(
            state.isExpanded ? AuraTheme.accent : AuraTheme.surface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous)
        )
        // Hairline border visible in collapsed state only.
        .overlay(
            RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous)
                .strokeBorder(
                    state.isExpanded ? Color.clear : AuraTheme.border,
                    lineWidth: 0.5
                )
        )
        // Static glow in expanded state only — NOT a repeating pulse.
        .shadow(
            color: reduceMotion ? .clear : (state.isExpanded
                   ? AuraTheme.accent.opacity(0.55)
                   : .clear),
            radius: 18
        )
        // Master animation: drives color, shape, shadow together.
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
            value: state.isExpanded
        )
        // Horizontal inset from screen edges; safe area inset handled by caller.
        .padding(.horizontal, 12)
    }
}
