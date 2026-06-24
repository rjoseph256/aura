import SwiftUI
import WidgetKit
import AuraKit

// Shared building blocks for the in-progress-ride Live Activity. They reuse AuraTheme
// (shared into this target) so the Lock Screen and Dynamic Island read like a slice of
// the ride HUD: near-black surface, aurora gradient identity, cyan/violet/green accents,
// and the same heavy rounded numerals the SpeedRail and TurnCard use.

/// Distance (m) within which the next maneuver is treated as imminent — the turn arrow
/// and distance shift to brand green, echoing the navigate HUD's turn card expanding.
/// Matches `TurnCardPresenter`'s 150 m expand threshold.
let rideActivityImminentMeters: Double = 150

func rideActivityIsImminent(_ turnDistanceMeters: Double?) -> Bool {
    guard let d = turnDistanceMeters else { return false }
    return d <= rideActivityImminentMeters
}

/// Best-effort maneuver glyph from the instruction text. A generic arrow would be safe
/// (the HUD uses one) but a left/right/arrive cue reads far better at a glance; we fall
/// back to a neutral "continue" arrow when the phrasing isn't recognized.
func rideActivityManeuverSymbol(for instruction: String?) -> String {
    guard let s = instruction?.lowercased() else { return "location.north.line.fill" }
    if s.contains("arriv") || s.contains("destination") { return "mappin.and.ellipse" }
    if s.contains("u-turn") || s.contains("uturn") { return "arrow.uturn.left" }
    if s.contains("roundabout") || s.contains("rotary") { return "arrow.trianglehead.clockwise" }
    if s.contains("left") { return "arrow.turn.up.left" }
    if s.contains("right") { return "arrow.turn.up.right" }
    return "arrow.up" // continue / head / straight
}

/// A glanceable stat: a big rounded value over a small muted label. The numeral matches
/// the HUD's `heroNumber`/metric voice.
struct RideStatCell: View {
    let value: String
    let label: String
    var tint: Color = AuraTheme.text
    var size: CGFloat = 19

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.muted)
        }
    }
}

/// Like `RideStatCell` but its value is a self-ticking elapsed clock counting up from
/// `start`. The system renders it on-device, so elapsed time stays live without the app
/// pushing a state update every second.
struct RideTimerStatCell: View {
    let start: Date
    let label: String
    var tint: Color = AuraTheme.cyan
    var size: CGFloat = 19

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(start, style: .timer)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.muted)
        }
    }
}

/// A small SF Symbol on the aurora gradient — the app's mark, miniaturized. Identifies
/// the activity (bicycle for a free ride, a maneuver arrow for navigate). Pass `solid` to
/// override the gradient with a flat color (the navigate arrow goes brand green when a
/// turn is imminent).
struct AuroraGlyph: View {
    let systemName: String
    var solid: Color? = nil
    var size: CGFloat = 34

    private var foreground: AnyShapeStyle {
        solid.map { AnyShapeStyle($0) } ?? AnyShapeStyle(AuraTheme.auroraGradient)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.35))
                .overlay(Circle().strokeBorder(foreground.opacity(0.9), lineWidth: 1.5))
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(foreground)
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
                .foregroundStyle(AuraTheme.muted)
                .labelStyle(.titleAndIcon)
        } else {
            HStack(spacing: 5) {
                Circle().fill(AuraTheme.cyan).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AuraTheme.cyan)
            }
        }
    }
}
