import SwiftUI

/// The ride HUD's persistent control cluster: recenter, an optional mute, and end-ride, all
/// on `HUDControlButton`. Recenter lights when the map is panned off the puck; mute lights
/// when muted; end-ride is pink. Mute is omitted (pass `onToggleMute: nil`) on a free ride,
/// which has no turn-by-turn voice to mute. The caller owns the end-ride confirmation, so
/// this stays a dumb control surface.
struct ControlCluster: View {
    let isFollowing: Bool
    var isMuted: Bool = false
    var onRecenter: () -> Void
    /// When nil, the mute button is omitted.
    var onToggleMute: (() -> Void)?
    var onEndRide: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.md) {
            Button(action: onRecenter) {
                Image(systemName: "location.fill")
            }
            .buttonStyle(.hudControl(active: !isFollowing))
            .accessibilityLabel("Recenter map")
            .accessibilityValue(isFollowing ? "Following" : "Off")

            if let onToggleMute {
                Button(action: onToggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.hudControl(active: isMuted))
                .accessibilityLabel("Mute voice guidance")
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(isMuted ? "On" : "Off")
            }

            Button(action: onEndRide) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.hudControl(role: .destructive))
            .accessibilityLabel("End ride")
        }
    }
}

#Preview {
    HStack(spacing: 40) {
        // Navigate: with mute.
        ControlCluster(isFollowing: true, isMuted: false,
                       onRecenter: {}, onToggleMute: {}, onEndRide: {})
        // Explore: no mute.
        ControlCluster(isFollowing: false, onRecenter: {}, onEndRide: {})
    }
    .padding()
    .background(AuraTheme.background)
}
