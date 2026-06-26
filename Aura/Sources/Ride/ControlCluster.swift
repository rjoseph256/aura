import SwiftUI

/// The navigate HUD's persistent control cluster: recenter, mute, and end-ride, all on
/// `HUDControlButton`. Recenter lights when the map has been panned off the puck; mute
/// lights when muted; end-ride is pink. The caller owns the end-ride confirmation, so
/// this view stays a dumb control surface.
struct ControlCluster: View {
    let isFollowing: Bool
    let isMuted: Bool
    var onRecenter: () -> Void
    var onToggleMute: () -> Void
    var onEndRide: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.md) {
            Button(action: onRecenter) {
                Image(systemName: "location.fill")
            }
            .buttonStyle(.hudControl(active: !isFollowing))
            .accessibilityLabel("Recenter map")
            .accessibilityValue(isFollowing ? "Following" : "Off")

            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.hudControl(active: isMuted))
            .accessibilityLabel("Mute voice guidance")
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isMuted ? "On" : "Off")

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
        ControlCluster(isFollowing: true, isMuted: false,
                       onRecenter: {}, onToggleMute: {}, onEndRide: {})
        ControlCluster(isFollowing: false, isMuted: true,
                       onRecenter: {}, onToggleMute: {}, onEndRide: {})
    }
    .padding()
    .background(AuraTheme.background)
}
