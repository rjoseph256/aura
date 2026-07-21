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

    /// A runaway roster is capped, but the leader (furthest along) is always kept.
    @Test func capKeepsLeaderWhenOverBudget() {
        let leader = UUID()
        var peers: [RidePeer] = (0..<9).map {
            RidePeer(userID: UUID(), displayName: "\($0)",
                     coordinate: Coordinate(latitude: 0, longitude: Double($0)),
                     progressMeters: Double($0), status: .riding)
        }
        peers.append(RidePeer(userID: leader, displayName: "L",
                              coordinate: Coordinate(latitude: 1, longitude: 1),
                              progressMeters: 9_999, status: .riding))
        let visible = GroupMapDots.visiblePeers(peers: peers, selfUserID: nil, maxDots: 7)
        #expect(visible.count == 7)
        #expect(visible.contains { $0.userID == leader })
    }

    /// Under budget, the default cap is a no-op and order is unchanged.
    @Test func underBudgetIsUnchangedOrder() {
        let peers = [
            RidePeer(userID: UUID(), displayName: "A",
                     coordinate: Coordinate(latitude: 0, longitude: 0), status: .riding),
            RidePeer(userID: UUID(), displayName: "B",
                     coordinate: Coordinate(latitude: 0, longitude: 1), status: .riding)
        ]
        #expect(GroupMapDots.visiblePeers(peers: peers, selfUserID: nil) == peers)
    }
}
