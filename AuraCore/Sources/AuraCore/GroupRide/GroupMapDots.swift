import Foundation

/// Selects which peers get a dot on the group-ride map — the one home for that rule, since
/// both call sites (`NavigateHUDView` and `RideMapView`) are in the untestable app target.
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
    /// optional because the solo map has no group identity to exclude — nil filters on
    /// coordinate alone rather than forcing callers to invent a placeholder id.
    public static func visiblePeers(peers: [RidePeer], selfUserID: UUID?) -> [RidePeer] {
        peers.filter { $0.userID != selfUserID && $0.coordinate != nil }
    }
}
