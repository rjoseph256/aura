import Testing
import Foundation
@testable import AuraCore

/// Pins which peers get a dot on the group-ride map.
///
/// The map already draws the rider via Mapbox's location puck, so the rider must NOT also
/// get a peer dot — otherwise everyone sees themselves twice, stacked (the annotations set
/// `allowOverlapWithPuck(true)`). This was latent from the day the feature shipped and
/// invisible until the broadcast topic was fixed: no broadcast ever arrived, so no peer had
/// a coordinate and the `coordinate != nil` filter dropped every dot including the self
/// echo. Once positions flowed, the database broadcast the rider's own position back to
/// them and drew a second, pulsing copy that greyed to "no signal" while their puck stayed
/// live. Both map call sites live in the untestable app target, so the rule is pinned here.
struct GroupMapDotsTests {
    private let selfID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let peerID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private func peer(_ id: UUID, at coordinate: Coordinate?) -> RidePeer {
        RidePeer(userID: id, displayName: "Rider", coordinate: coordinate, status: .riding)
    }

    private let here = Coordinate(latitude: 40.44, longitude: -79.99)

    /// The regression: the rider's own entry must never become a dot, even fully populated.
    @Test func excludesSelfSoTheRiderIsNotDrawnTwice() {
        let dots = GroupMapDots.visiblePeers(
            peers: [peer(selfID, at: here), peer(peerID, at: here)], selfUserID: selfID)
        #expect(dots.map(\.userID) == [peerID])
    }

    /// A peer with no fix yet has nowhere to be drawn.
    @Test func excludesPeersWithoutACoordinate() {
        let dots = GroupMapDots.visiblePeers(
            peers: [peer(peerID, at: nil)], selfUserID: selfID)
        #expect(dots.isEmpty)
    }

    /// Ordering is preserved so dot identity stays stable across refreshes.
    @Test func keepsRemainingPeersInOrder() {
        let a = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let b = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000004")!
        let dots = GroupMapDots.visiblePeers(
            peers: [peer(a, at: here), peer(selfID, at: here), peer(b, at: here)],
            selfUserID: selfID)
        #expect(dots.map(\.userID) == [a, b])
    }

    /// A solo ride has no peers at all — the map must stay visually unchanged.
    @Test func isEmptyForASoloRide() {
        #expect(GroupMapDots.visiblePeers(peers: [], selfUserID: selfID).isEmpty)
    }

    /// No group identity (solo map): nothing to exclude, so filter on coordinate alone.
    @Test func withoutASelfIDFiltersOnCoordinateOnly() {
        let dots = GroupMapDots.visiblePeers(
            peers: [peer(peerID, at: here), peer(selfID, at: nil)], selfUserID: nil)
        #expect(dots.map(\.userID) == [peerID])
    }
}
