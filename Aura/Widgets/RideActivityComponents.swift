import SwiftUI
import WidgetKit
import AuraKit

// Shared building blocks for the in-progress-ride Live Activity. They reuse AuraTheme
// (shared into this target) so the Lock Screen and Dynamic Island read like a slice of
// the migrated cockpit: near-black surface, solid mint identity mark, mint accents, and
// the same Saira Condensed cockpit numerals the cockpit InstrumentChassis and StatPair use.

/// Distance (m) within which the next maneuver is treated as imminent — the turn arrow
/// and distance hold the mint accent (the active cue), echoing the navigate HUD's turn
/// card expanding.
/// Matches `TurnCardPresenter`'s 150 m expand threshold.
let rideActivityImminentMeters: Double = 150

func rideActivityIsImminent(_ turnDistanceMeters: Double?) -> Bool {
    guard let d = turnDistanceMeters else { return false }
    return d <= rideActivityImminentMeters
}

/// A glanceable stat: a big cockpit numeral over a small muted label. The numeral uses
/// the Saira Condensed cockpit face, matching the cockpit's `StatPair(.cockpit)` voice.
struct RideStatCell: View {
    let value: String
    let label: String
    var tint: Color = AuraTheme.textPrimary
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(AuraTheme.Typography.metricCockpit(size, relativeTo: .title3))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }
}

/// Like `RideStatCell` but its value is a self-ticking elapsed clock counting up from
/// `start`. The system renders it on-device, so elapsed time stays live without the app
/// pushing a state update every second. Mint tint marks it as the live, trustworthy value.
struct RideTimerStatCell: View {
    let start: Date
    let label: String
    var tint: Color = AuraTheme.accent
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(start, style: .timer)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }
}

/// A small SF Symbol in a mint-keyed disc — the app's mark, miniaturized. Identifies the
/// activity (bicycle for a free ride, a maneuver arrow for navigate). When `imminent`, the
/// disc inverts to a solid mint fill with an ink-on-mint glyph — the same cue the cockpit's
/// turn card uses when a maneuver is close.
struct AuraGlyph: View {
    let systemName: String
    var imminent: Bool = false
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            if imminent {
                Circle().fill(AuraTheme.accent)
            } else {
                Circle()
                    .fill(AuraTheme.surface)
                    .overlay(Circle().strokeBorder(AuraTheme.accent.opacity(0.9), lineWidth: 1.5))
            }
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(imminent ? AuraTheme.onAccent : AuraTheme.accent)
        }
        .frame(width: size, height: size)
    }
}

/// Tiny live/updating indicator shown in the Lock Screen header. Goes muted when the
/// activity's content is stale (app suspended / killed mid-ride).
struct RideStatusPill: View {
    let isStale: Bool

    var body: some View {
        if isStale {
            Label("Updating", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
                .labelStyle(.titleAndIcon)
        } else {
            HStack(spacing: 5) {
                Circle().fill(AuraTheme.accent).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AuraTheme.accent)
            }
        }
    }
}
