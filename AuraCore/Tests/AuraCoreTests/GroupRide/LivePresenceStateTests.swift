import Testing
import Foundation
@testable import AuraCore

struct LivePresenceStateTests {
    let now = Date(timeIntervalSince1970: 1000)
    let alex = UUID(); let sam = UUID()

    func seeded() -> LivePresenceState {
        LivePresenceState(roster: [
            RidePeer(userID: alex, displayName: "Alex"),
            RidePeer(userID: sam, displayName: "Sam")
        ], droppedTimeout: 40)
    }

    @Test func rosterSeededPeersStartAwaiting() {
        let state = seeded()
        #expect(state.peers.count == 2)
        #expect(state.peers.allSatisfy { $0.status == .awaiting })
    }
    @Test func applyUpdatesPositionAndCarriesNameForward() {
        var state = seeded()
        state.apply(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: now, motionState: .moving), now: now)
        let peer = state.peers.first { $0.userID == alex }!
        #expect(peer.displayName == "Alex")          // not on the delta; carried forward
        #expect(peer.progressMeters == 100)
        #expect(peer.status == .riding)
    }
    @Test func tickFlipsSilentPeerToDropped() {
        var state = seeded()
        state.apply(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: now, motionState: .moving), now: now)
        state.tick(now: now.addingTimeInterval(120))
        #expect(state.peers.first { $0.userID == alex }!.status == .dropped)
    }
    @Test func removeDropsThePeer() {
        var state = seeded()
        state.remove(userID: sam)
        #expect(state.peers.contains { $0.userID == sam } == false)
    }
    @Test func applyForUnknownUserAddsThemNameless() {
        var state = seeded()
        let ghost = UUID()
        state.apply(LivePositionPayload(userID: ghost,
            coordinate: Coordinate(latitude: 0, longitude: 0),
            progressMeters: 0, recordedAt: now, motionState: .moving), now: now)
        #expect(state.peers.contains { $0.userID == ghost })
    }
    @Test func mergeAddsUnknownMembersAsGiven() {
        var state = LivePresenceState(roster: [], droppedTimeout: 15)
        let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        state.merge(roster: [RidePeer(userID: id, displayName: "Priya", status: .awaiting)])
        #expect(state.peers.map(\.userID) == [id])
        #expect(state.peers[0].status == .awaiting)
    }

    @Test func mergeNeverOverwritesAKnownPeer() {
        let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        var state = LivePresenceState(roster: [], droppedTimeout: 15)
        let fix = Date()
        state.apply(LivePositionPayload(userID: id, coordinate: Coordinate(latitude: 1, longitude: 2),
                                        progressMeters: 100, recordedAt: fix, motionState: .moving), now: fix)
        state.merge(roster: [RidePeer(userID: id, displayName: "Priya", status: .awaiting)])
        #expect(state.peers[0].status == .riding, "a lobby roster poll must not reset a live peer")
        #expect(state.peers[0].coordinate != nil)
    }

    @Test func mergeIsIdempotent() {
        let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
        var state = LivePresenceState(roster: [], droppedTimeout: 15)
        let member = RidePeer(userID: id, displayName: "Priya", status: .awaiting)
        state.merge(roster: [member])
        state.merge(roster: [member])
        #expect(state.peers.count == 1)
    }
}
