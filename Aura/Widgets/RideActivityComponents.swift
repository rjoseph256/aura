import SwiftUI
import WidgetKit
import AuraKit
import AuraCore

// Shared building blocks for the in-progress-ride Live Activity. They reuse AuraTheme
// (shared into this target) so the Lock Screen and Dynamic Island read like a slice of
// the migrated cockpit: near-black surface, solid mint identity mark, mint accents, and
// the same Saira Condensed cockpit numerals the cockpit InstrumentChassis and StatPair use.

/// Distance (m) within which the next maneuver is treated as imminent — the turn arrow
/// and distance hold the mint accent (the active cue), echoing the navigate HUD's turn
/// card expanding.
/// Matches `TurnCardPresenter`'s 150 m expand threshold.
let rideActivityImminentMeters: Double = 150

/// Paused suppresses it: pausing within 150 m of a turn — at the junction, at the light, at the
/// shop just before it — would otherwise leave the app's single most urgent cue, a solid mint
/// fill, burning on a ride that is recording nothing.
func rideActivityIsImminent(_ turnDistanceMeters: Double?, isPaused: Bool) -> Bool {
    guard !isPaused, let d = turnDistanceMeters else { return false }
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

/// The date to hand `Text(_, style: .timer)`: the active-time anchor while running, the stop's
/// own instant while paused.
func rideActivityClockAnchor(_ clock: RideActiveClock) -> Date {
    switch clock {
    case .running(let anchor): anchor
    case .paused(let since, _): since
    }
}

/// The label under the clock. A paused clock is not reporting elapsed ride time and must not keep
/// claiming to — the expanded Dynamic Island has no status pill, so this label is that
/// presentation's only paused signal.
func rideActivityClockLabel(_ clock: RideActiveClock, running: String) -> String {
    clock.isPaused ? PauseControlCopy.stateChipLabel : running
}

/// The clock cell. Running, it is a self-ticking active-time clock the system renders on-device,
/// so elapsed stays live without the app pushing every second. Paused, it counts *up* from the
/// instant of the stop — still OS-rendered, so it keeps moving even when the app is suspended or
/// dead, and answers the one question a stopped rider has: how long have I been stopped.
///
/// Mint marks the live running value; paused drops to secondary, because a paused clock is not
/// reporting the ride.
struct RideTimerStatCell: View {
    let clock: RideActiveClock
    let label: String
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rideActivityClockAnchor(clock), style: .timer)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(clock.isPaused ? AuraTheme.textSecondary : AuraTheme.accent)
                .lineLimit(1)
            Text(rideActivityClockLabel(clock, running: label))
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

/// The Lock Screen's state word. Paused and stale **compose** rather than one masking the other:
/// a jetsam kill during a pause is likely by construction, nothing ends the orphan until ROH-124
/// ships, and a killed ride wearing a confident PAUSED is how a rider reads "still paused, good",
/// rides home, and records none of it (spec D6).
struct RideStatusPill: View {
    let isPaused: Bool
    let isStale: Bool

    var body: some View {
        switch (isPaused, isStale) {
        case (true, true):
            pill("\(PauseControlCopy.stateChipLabel) · NOT UPDATING")
        case (true, false):
            pill(PauseControlCopy.stateChipLabel)
        case (false, true):
            Label("Updating", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
                .labelStyle(.titleAndIcon)
        case (false, false):
            HStack(spacing: 5) {
                Circle().fill(AuraTheme.accent).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AuraTheme.accent)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(AuraTheme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// `pause.fill` outranks both the maneuver arrow and the bicycle: what the rider needs from a
/// glance at a paused activity is that it is paused.
///
/// Use this overload at every site that wraps the result in `AuraGlyph` — the Lock Screen header,
/// the Lock Screen navigate turn glyph, and the Dynamic Island's expanded-leading region.
/// `AuraGlyph` already draws a filled disc with its own stroked circular border and insets the
/// symbol inside it, so swapping the symbol itself to a `.circle` outline draws a second ring on
/// top of that enclosure — a donut, not "same state, weakened". These sites also always sit
/// beside `RideStatusPill`, which already reads `PAUSED · NOT UPDATING` when stale, so the glyph
/// doesn't need to carry that distinction too — doing so is both redundant and where the donut
/// looks worst. There is deliberately no `stale` parameter here: paused is `pause.fill`
/// regardless, so a call site literally cannot pass the wrong thing.
func rideActivityGlyph(nav: Bool, paused: Bool, turnGlyph: String?) -> String {
    if paused { return "pause.fill" }
    return nav ? (turnGlyph ?? "arrow.turn.up.right") : "bicycle"
}

/// The bare-glyph counterpart for the Dynamic Island's `compactLeading` and `minimal`
/// presentations, which render a raw `Image(systemName:)` with no `AuraGlyph` enclosure and no
/// `RideStatusPill` beside them — the glyph is their *only* channel, so it is the only place
/// staleness may still degrade the glyph itself. It degrades within the same symbol family rather
/// than switching to a warning glyph: `pause.circle`'s hollow outline reads as the *same* paused
/// state losing its footing, not as a different (error) state, which a triangle-exclamation glyph
/// would imply. Solid `pause.fill` is confident, live-and-paused; the outline is that same idea
/// going quiet.
func rideActivityBareGlyph(nav: Bool, paused: Bool, stale: Bool, turnGlyph: String?) -> String {
    if paused { return stale ? "pause.circle" : "pause.fill" }
    return nav ? (turnGlyph ?? "arrow.turn.up.right") : "bicycle"
}
