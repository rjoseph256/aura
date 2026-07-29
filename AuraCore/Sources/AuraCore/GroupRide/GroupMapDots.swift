import Foundation

/// Selects which peers get a dot on the group-ride map — the one home for that rule, since its
/// only call site (`NavigateHUDView`) is in the untestable app target. `RideMapView` was a
/// second call site until ROH-105 removed its dead peer path.
///
/// The rider is already drawn by Mapbox's location puck, so their own entry must be
/// excluded: the annotations set `allowOverlapWithPuck(true)`, so a self dot stacks a
/// second, pulsing marker directly on the puck — and it greys to "no signal" the moment
/// position publishing pauses, leaving a dead-looking copy of the rider beside their live
/// puck. `peers` legitimately contains the rider (the roster seeds every member, and the
/// database broadcasts each position back to its own sender), so the filter belongs here
/// rather than upstream.
public enum GroupMapDots {
    /// Peers that should be drawn: everyone except the rider, that has a fix to draw at.
    /// Order is preserved so dot identity stays stable across refreshes. `selfUserID` is
    /// optional because `NavigateHUDView`'s solo path has no group identity to exclude — nil
    /// filters on coordinate alone rather than forcing callers to invent a placeholder id.
    public static func visiblePeers(peers: [RidePeer], selfUserID: UUID?,
                                    maxDots: Int = 7) -> [RidePeer] {
        let visible = peers.filter { $0.userID != selfUserID && $0.coordinate != nil }
        guard visible.count > maxDots else { return visible }
        // Runaway roster (> 8): keep the leader (furthest along) + fill the rest in existing order.
        let leaderID = visible.max { ($0.progressMeters ?? -.infinity) < ($1.progressMeters ?? -.infinity) }?.userID
        var kept = visible.filter { $0.userID == leaderID }
        for peer in visible where peer.userID != leaderID {
            if kept.count == maxDots { break }
            kept.append(peer)
        }
        return kept
    }
}
