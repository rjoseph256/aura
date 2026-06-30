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
}
