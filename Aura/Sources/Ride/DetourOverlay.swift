import SwiftUI
import AuraCore
import AuraKit

/// The slim detour chrome shown over the free-ride HUD while a gem detour is active.
///
/// Mirrors `NavigateHUDView`'s turn-card placement (top-center safe area, `.overlay(alignment:
/// .top)` + 8pt padding, R13) so the two guidance surfaces read as the same system. Three
/// phases: a turn banner + destination chip while `.guiding` (Mapbox turn-by-turn), a compass
/// arrow + straight-line distance while `.headingOnly` (offline fallback, R14), and a lightweight
/// "Routing…" chip while `.routing`. A transient "Arrived — <name>" chip rides on top of all of
/// them, driven by `controller.arrivalBanner`.
///
/// The destination chip's **Stop** control is intentionally `.bordered` (neutral), never
/// `.destructive` — it cancels the detour only, and must never read like the pink End Ride
/// control (R12). Its accessibility label is explicitly "Stop detour" for the same reason.
struct DetourOverlay: View {
    let controller: GuidanceController
    /// Whether the ride is stopped. Calms the turn card, for the reason the navigate HUD calms
    /// its own: the expanded card is a solid mint fill and it would otherwise sit directly above
    /// the mint Resume pill, shouting the turn at a rider who has stopped. This is the only turn
    /// card Explore has, and since the pause silences that leg's turn haptics too, an uncalmed
    /// card would be the one signal left contradicting the paused state.
    ///
    /// Required, not defaulted, for the same reason `RideMapView.isPaused` is: a silently
    /// unwired paused signal compiles clean and ships dead.
    let isPaused: Bool
    var units: DistanceUnits = .imperial
    var reduceMotion: Bool = false
    var onStop: () -> Void

    private var formatter: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            if let arrived = controller.arrivalBanner {
                arrivalChip(arrived)
            } else {
                switch controller.phase {
                case .guiding(let gem):
                    if let vm = controller.guidance {
                        TurnCardView(state: isPaused ? vm.turn.calmed() : vm.turn,
                                     reduceMotion: reduceMotion)
                    }
                    destinationChip(gem, distance: guidingDistanceText)
                case .headingOnly(let gem):
                    headingPointer
                    destinationChip(gem, distance: headingDistanceText)
                case .routing(let gem):
                    routingChip(gem)
                case .inactive:
                    EmptyView()
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: controller.phase)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: controller.arrivalBanner)
    }

    // MARK: - Chips

    private func destinationChip(_ gem: Gem, distance: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.fill")
                .foregroundStyle(AuraTheme.accent)
            Text(gem.name)
                .font(.subheadline)
                .lineLimit(1)
            if !distance.isEmpty {
                Text(distance)
                    .font(.caption)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Stop", action: onStop)
                .font(.subheadline)
                .buttonStyle(.bordered)   // neutral — NOT .destructive; never confused with End Ride
                .accessibilityLabel("Stop detour")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var headingPointer: some View {
        VStack(spacing: 4) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 34))
                .foregroundStyle(AuraTheme.accent)
                .rotationEffect(.degrees(controller.headingArrow?.relativeBearingDegrees ?? 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                           value: controller.headingArrow?.relativeBearingDegrees)
            Text("Offline · approximate direction")
                .font(.caption2)
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func routingChip(_ gem: Gem) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Routing to \(gem.name)…")
                .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func arrivalChip(_ gem: Gem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AuraTheme.accent)
            Text("Arrived — \(gem.name)")
                .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .transition(reduceMotion ? .identity : .opacity)
    }

    // MARK: - Distance text

    private var guidingDistanceText: String {
        guard let meters = controller.guidance?.lastUpdate?.distanceRemainingMeters else { return "" }
        return formatter.maneuverDistance(meters)
    }

    private var headingDistanceText: String {
        guard let meters = controller.headingArrow?.straightLineDistanceMeters else { return "" }
        return formatter.maneuverDistance(meters)
    }
}
