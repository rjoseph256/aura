import SwiftUI
import AuraCore
import AuraKit

/// The cockpit's pause/resume row: one control whose label tracks the state, plus a PAUSED chip
/// carrying a live count of the current stop.
///
/// **Resume is the wider control, and that is the whole point.** Pause is pressed deliberately
/// while stopping and needs no more than a comfortable target. Resume is pressed while clipping
/// in, gloved and one-handed (spec D9, ROH-75). Sizing it the other way round would also put the
/// largest tap target on the ride screen along the bottom edge, where a rain film and a
/// supporting thumb both land, for an action taken on a minority of rides.
///
/// The row is a constant 56 pt in both states, so nothing below it moves when the rider taps.
/// 56 pt is `HUDControlMetrics.ride.resolvedHitTarget`, the target ROH-75 settled on.
///
/// Mint, never amber: amber already carries peer-stopped and weak or lost GPS, so a rider paused
/// under a railway bridge would otherwise see two amber elements meaning different things.
struct PauseControl: View {
    let isPaused: Bool
    /// Duration of the stop in progress. Ignored while recording.
    let pausedSeconds: TimeInterval
    /// Pause or resume, returning the ride's paused state **after** the attempt.
    ///
    /// It returns rather than being a plain `Void` closure because the coordinator's `pause()`
    /// and `resume()` are guarded no-ops when no ride is recording — before `start()` lands,
    /// while the permission sheet is up, in the frame after `finish()`. Announcing the intent
    /// would tell a VoiceOver rider "Ride paused" with nothing paused; announcing the result
    /// cannot.
    let onToggle: () -> Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var rowHeight: CGFloat { CGFloat(HUDControlMetrics.ride.resolvedHitTarget) }

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            if isPaused {
                stateChip
            } else {
                Spacer(minLength: 0)
            }
            control
        }
        .frame(height: rowHeight)
        // Gated like every other ride-HUD animation (TurnCardView, DetourOverlay,
        // ControlCluster, both HUDs). This one earns the gate more than most: the state flip
        // grows the button across the full screen width and slides the chip in beside it, so
        // Reduce Motion gets the two states with no travel between them.
        .animation(reduceMotion ? nil : .snappy, value: isPaused)
    }

    private var stateChip: some View {
        HStack(spacing: AuraTheme.Spacing.xs) {
            Text(PauseControlCopy.stateChipLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(AuraTheme.textPrimary)
            Text(PauseControlCopy.clock(pausedSeconds))
                .font(AuraTheme.Typography.metricCockpit(17, relativeTo: .subheadline))
                .foregroundStyle(AuraTheme.textPrimary)
                .contentTransition(.numericText())
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, AuraTheme.Spacing.md)
        .frame(height: rowHeight)
        .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PauseControlCopy.chipAccessibilityLabel(pausedSeconds: pausedSeconds))
        .accessibilityIdentifier(RideTestID.hudPausedBanner)
    }

    private var control: some View {
        // The announcement lives here, not in the two HUDs. This view is in the app target and
        // can import UIKit freely, and putting it here is what makes spec P7's "written once"
        // literally true rather than "written once per HUD" (which is twice).
        Button {
            let nowPaused = onToggle()
            // Silence, not a wrong announcement, when the toggle was a guarded no-op: the state
            // did not move, so there is nothing to report.
            guard nowPaused != isPaused else { return }
            AccessibilityAnnouncer.announce(PauseControlCopy.announcement(isPaused: nowPaused))
        } label: {
            HStack(spacing: AuraTheme.Spacing.sm) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                Text(PauseControlCopy.buttonLabel(isPaused: isPaused))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(isPaused ? AuraTheme.onAccent : AuraTheme.textPrimary)
            // Paused fills the rest of the row; recording stays compact so the accidental-tap
            // surface along the bottom edge is small.
            .frame(maxWidth: isPaused ? .infinity : nil)
            .frame(height: rowHeight)
            .padding(.horizontal, isPaused ? AuraTheme.Spacing.lg : AuraTheme.Spacing.xl)
            .background {
                if isPaused {
                    Capsule().fill(AuraTheme.accent)
                } else {
                    Capsule()
                        .fill(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast))
                        .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(PauseControlCopy.accessibilityLabel(isPaused: isPaused))
        .accessibilityIdentifier(RideTestID.hudPause)
    }
}

#Preview("Both states") {
    VStack(spacing: 24) {
        PauseControl(isPaused: false, pausedSeconds: 0, onToggle: { true })
        PauseControl(isPaused: true, pausedSeconds: 252, onToggle: { false })
    }
    .padding()
    .background(AuraTheme.background)
}
