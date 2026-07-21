import SwiftUI
import AuraCore

/// The ride HUD's persistent control cluster: recenter, an optional mark-this-spot, an
/// optional mute, and end-ride, all on `HUDControlButton`. Recenter lights when the map is
/// panned off the puck; mute lights when muted; end-ride is pink. Mute is omitted (pass
/// `onToggleMute: nil`) on a free ride, which has no turn-by-turn voice to mute. Mark-spot is
/// omitted/disabled (pass `onMarkSpot: nil`) until the rider's first GPS fix. The caller owns
/// the end-ride confirmation, so this stays a dumb control surface.
///
/// Every button uses `.ride` metrics (ROH-75): the drawn circle stays at 44 pt to keep the
/// controls light over the map, but the tap region grows to 56 pt so a moving, one-handed rider
/// can hit them without precision. The recenter + mark-spot (+ mute) group still sits
/// `AuraTheme.Spacing.xxxl` (32 pt) away from the destructive End button — that spacing is
/// applied between the enlarged tap frames, so a 32 pt dead zone always separates the benign
/// controls' tap region from End's, and a fat-finger reaching for one can't land on the other.
struct ControlCluster: View {
    let isFollowing: Bool
    var isMuted: Bool = false
    var onRecenter: () -> Void
    /// When nil, the mark-this-spot button is disabled (dimmed, non-tappable) rather than hidden,
    /// so the cluster's layout doesn't shift as GPS acquires.
    var onMarkSpot: (() -> Void)?
    /// When nil, the mute button is omitted.
    var onToggleMute: (() -> Void)?
    var onEndRide: () -> Void
    /// Disables the End (stop) button while a waited-on group end/leave is pending, so repeated
    /// taps do nothing. Defaulted so the solo/Explore call sites are unaffected.
    var isEndDisabled: Bool = false

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xxxl) {
            VStack(spacing: AuraTheme.Spacing.md) {
                Button(action: onRecenter) {
                    Image(systemName: "location.fill")
                }
                .buttonStyle(.hudControl(active: !isFollowing, metrics: .ride))
                .accessibilityLabel("Recenter map")
                .accessibilityValue(isFollowing ? "Following" : "Off")

                Button {
                    onMarkSpot?()
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .buttonStyle(.hudControl(metrics: .ride))
                .disabled(onMarkSpot == nil)
                .opacity(onMarkSpot == nil ? 0.4 : 1)
                .accessibilityLabel("Mark this spot")

                if let onToggleMute {
                    Button(action: onToggleMute) {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.hudControl(active: isMuted, metrics: .ride))
                    .accessibilityLabel("Mute voice guidance")
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityValue(isMuted ? "On" : "Off")
                }
            }

            Button(action: onEndRide) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.hudControl(role: .destructive, metrics: .ride))
            .disabled(isEndDisabled)
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
        ControlCluster(isFollowing: false, onRecenter: {}, onMarkSpot: nil, onToggleMute: nil, onEndRide: {})
    }
    .padding()
    .background(AuraTheme.background)
}
