import SwiftUI

/// The ride HUD's persistent control cluster: recenter, an optional mark-this-spot, an
/// optional mute, and end-ride, all on `HUDControlButton`. Recenter lights when the map is
/// panned off the puck; mute lights when muted; end-ride is pink. Mute is omitted (pass
/// `onToggleMute: nil`) on a free ride, which has no turn-by-turn voice to mute. Mark-spot is
/// omitted/disabled (pass `onMarkSpot: nil`) until the rider's first GPS fix. The recenter +
/// mark-spot (+ mute) group sits `AuraTheme.Spacing.xxxl` (32 pt, comfortably over the ≥16 pt
/// floor) away from the destructive End Ride button, so a fat-finger reaching for End can't
/// land on mark-spot instead. The caller owns the end-ride confirmation, so this stays a dumb
/// control surface.
struct ControlCluster: View {
    let isFollowing: Bool
    var isMuted: Bool = false
    var onRecenter: () -> Void
    /// When nil, the mark-this-spot button is disabled (dimmed, non-tappable) rather than hidden,
    /// so the cluster's layout doesn't shift as GPS acquires.
    var onMarkSpot: (() -> Void)? = nil
    /// When nil, the mute button is omitted.
    var onToggleMute: (() -> Void)?
    var onEndRide: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xxxl) {
            VStack(spacing: AuraTheme.Spacing.md) {
                Button(action: onRecenter) {
                    Image(systemName: "location.fill")
                }
                .buttonStyle(.hudControl(active: !isFollowing))
                .accessibilityLabel("Recenter map")
                .accessibilityValue(isFollowing ? "Following" : "Off")

                Button {
                    onMarkSpot?()
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .buttonStyle(.hudControl)
                .disabled(onMarkSpot == nil)
                .opacity(onMarkSpot == nil ? 0.4 : 1)
                .accessibilityLabel("Mark this spot")

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
        // Navigate: with mute, mark-spot ready.
        ControlCluster(isFollowing: true, isMuted: false,
                       onRecenter: {}, onMarkSpot: {}, onToggleMute: {}, onEndRide: {})
        // Explore: no mute, mark-spot still disabled (no fix yet).
        ControlCluster(isFollowing: false, onRecenter: {}, onEndRide: {})
    }
    .padding()
    .background(AuraTheme.background)
}
