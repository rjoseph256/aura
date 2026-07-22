import SwiftUI
import AuraCore
import AuraKit

/// The ride HUD's persistent control cluster: an optional +/- zoom pill, recenter, an optional
/// mark-this-spot, an optional mute, and end-ride. The circular buttons use `HUDControlButton`;
/// the zoom pill (ROH-57) is `MapZoomControl` on the same `.ride` metrics. Recenter lights when the map is
/// panned off the puck; mute lights when muted; end-ride is pink. Mute is omitted (pass
/// `onToggleMute: nil`) on a free ride, which has no turn-by-turn voice to mute. Mark-spot is a
/// free-ride feature: hidden entirely on Navigate (`showMarkSpot: false`), and on a free ride it
/// renders disabled until the first GPS fix (`onMarkSpot: nil`) rather than shifting the layout.
/// The caller owns the end-ride confirmation, so this stays a dumb control surface.
///
/// Every button uses `.ride` metrics (ROH-75): the drawn circle stays at 44 pt to keep the
/// controls light over the map, but the tap region grows to 56 pt so a moving, one-handed rider
/// can hit them without precision. All buttons share one uniform, padding-compensated gap (see
/// `body`) so the cluster reads as a single cohesive stack. End isn't set apart by spacing — it's
/// distinguished by its pink fill and a confirm-on-tap, which a lone separating gap only made look
/// orphaned (device feedback, ROH-75).
struct ControlCluster: View {
    let isFollowing: Bool
    var isMuted: Bool = false
    var onRecenter: () -> Void
    /// Whether this mode has a mark-this-spot control at all. Free rides do (`true`, the
    /// default); Navigate does not (`false`) — mark-spot is an Explore feature, so Navigate showed
    /// a permanently-disabled button that only cost height. Dropping it there also keeps the
    /// zoom-pill-taller cluster clear of the turn card on a short screen (ROH-57).
    var showMarkSpot: Bool = true
    /// When `showMarkSpot` is true and this is nil, the mark button renders disabled (dimmed,
    /// non-tappable) rather than hidden, so the free-ride cluster doesn't shift as GPS acquires.
    var onMarkSpot: (() -> Void)?
    /// When nil, the mute button is omitted.
    var onToggleMute: (() -> Void)?
    /// The +/- zoom pill (ROH-57). When either is nil the pill is omitted, so a caller without a
    /// zoomable map keeps the old cluster exactly. Both HUDs supply them; the pill leads the
    /// stack so the End button keeps its bottom-anchored position and muscle memory.
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onEndRide: () -> Void
    /// Disables the End (stop) button while a waited-on group end/leave is pending, so repeated
    /// taps do nothing. Defaulted so the solo/Explore call sites are unaffected.
    var isEndDisabled: Bool = false

    var body: some View {
        // Each `.ride` button's tap frame is wider than its drawn circle by `pad` of invisible
        // padding, and VStack spacing sits between the *frames* — so subtract `pad` back out to
        // get the intended visible gap between circles. One uniform gap across the whole stack:
        // End is evened in with the rest rather than orphaned below a big gap. It stays distinct
        // by its pink fill, and its tap opens a confirmation, so it needs no separating gap.
        let pad = CGFloat(HUDControlMetrics.ride.resolvedHitTarget - HUDControlMetrics.ride.size)
        let buttonSpacing = max(0, AuraTheme.Spacing.md - pad)
        return VStack(spacing: buttonSpacing) {
            if let onZoomIn, let onZoomOut {
                // The pill draws to its frame edge (no invisible overhang), unlike the circular
                // buttons which carry `pad/2` of it on every touching edge. So add `pad/2` back
                // under the pill, or its visible gap to Recenter would read `pad/2` tighter than
                // the uniform circle-to-circle gap.
                MapZoomControl(metrics: .ride, onZoomIn: onZoomIn, onZoomOut: onZoomOut)
                    .padding(.bottom, pad / 2)
            }

            Button(action: onRecenter) {
                Image(systemName: "location.fill")
            }
            .buttonStyle(.hudControl(active: !isFollowing, metrics: .ride))
            .accessibilityLabel("Recenter map")
            .accessibilityValue(isFollowing ? "Following" : "Off")

            if showMarkSpot {
                Button {
                    onMarkSpot?()
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .buttonStyle(.hudControl(metrics: .ride))
                .disabled(onMarkSpot == nil)
                .opacity(onMarkSpot == nil ? 0.4 : 1)
                .accessibilityLabel("Mark this spot")
            }

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

            Button(action: onEndRide) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.hudControl(role: .destructive, metrics: .ride))
            .disabled(isEndDisabled)
            .accessibilityLabel("End ride")
            .accessibilityIdentifier(RideTestID.hudEnd)
        }
    }
}

#Preview {
    HStack(spacing: 40) {
        // Navigate: zoom pill + mute, no mark-spot (Navigate has no such feature).
        ControlCluster(isFollowing: true, isMuted: false,
                       onRecenter: {}, showMarkSpot: false, onToggleMute: {},
                       onZoomIn: {}, onZoomOut: {}, onEndRide: {})
        // Explore: zoom pill, no mute, mark-spot present but still disabled (no fix yet).
        ControlCluster(isFollowing: false, onRecenter: {}, onMarkSpot: nil, onToggleMute: nil,
                       onZoomIn: {}, onZoomOut: {}, onEndRide: {})
    }
    .padding()
    .background(AuraTheme.background)
}
