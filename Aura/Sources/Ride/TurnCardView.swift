import SwiftUI
import AuraKit

/// Animated turn-card pinned at the top of the navigate HUD.
///
/// Two visual states keyed by `state.isExpanded`:
/// - **Collapsed** (calm): compact dark card, small arrow + distance + street name.
/// - **Expanded** (imminent): grows, shifts to brand-green fill, black text, glow.
///
/// Motion is driven by a single `.smooth(duration: 0.38)` animation so the whole
/// card morphs together — no overshoot, calm and decisive. `reduceMotion` gates
/// every heavy transform so the card crossfades only.
struct TurnCardView: View {
    let state: TurnCardState
    var reduceMotion: Bool = false

    // MARK: Layout constants

    private let arrowCollapsed: CGFloat = 24
    private let arrowExpanded:  CGFloat = 34

    private let distCollapsed:  CGFloat = 22
    private let distExpanded:   CGFloat = 36

    // MARK: Body

    var body: some View {
        HStack(spacing: state.isExpanded ? 14 : 10) {
            // Maneuver arrow
            Image(systemName: "arrow.turn.up.right")
                .font(.system(
                    size: state.isExpanded ? arrowExpanded : arrowCollapsed,
                    weight: .bold
                ))
                .foregroundStyle(state.isExpanded ? Color.black : AuraTheme.text)
                // Scale instead of animating .font size (font size doesn't interpolate).
                .scaleEffect(reduceMotion ? 1 : (state.isExpanded ? 1.0 : 0.72))
                .animation(
                    reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
                    value: state.isExpanded
                )

            VStack(alignment: .leading, spacing: state.isExpanded ? 4 : 2) {
                // Distance countdown — rolls digit-by-digit.
                Text(state.distanceText)
                    .font(.system(
                        size: state.isExpanded ? distExpanded : distCollapsed,
                        weight: .heavy,
                        design: .rounded
                    ))
                    .foregroundStyle(state.isExpanded ? Color.black : AuraTheme.text)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        state.isExpanded ? Color.black.opacity(0.75) : AuraTheme.text.opacity(0.9)
                    )
                    .contentTransition(.opacity)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, state.isExpanded ? 20 : 14)
        .padding(.vertical,   state.isExpanded ? 18 : 12)
        // Background shifts from near-opaque dark → brand green.
        .background(
            state.isExpanded ? AuraTheme.route : AuraTheme.surface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        // Hairline border visible in collapsed state only.
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    state.isExpanded ? Color.clear : Color.white.opacity(0.08),
                    lineWidth: 0.5
                )
        )
        // Static glow in expanded state only — NOT a repeating pulse.
        .shadow(
            color: reduceMotion ? .clear : (state.isExpanded
                   ? AuraTheme.route.opacity(0.55)
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
