import Testing
import Foundation
import AuraCore

struct GroupRosterViewDataTests {
    let me = UUID(), sara = UUID(), jordan = UUID()
    private func peer(_ id: UUID, _ p: Double?, _ s: PeerStatus, _ name: String = "") -> RidePeer {
        RidePeer(userID: id, displayName: name, progressMeters: p, status: s)
    }
    @Test func ordersLeaderFirstAndPinsSelf() {
        let rows = GroupRosterViewData.rows(
            peers: [peer(me, 100, .riding), peer(sara, 300, .riding), peer(jordan, 50, .stopped)],
            nameMap: [sara: "Sara", jordan: "Jordan"], selfUserID: me, selfProgress: 100, isImperial: false)
        #expect(rows.map(\.id) == [sara, me, jordan])       // 300, 100(self), 50
        #expect(rows.first { $0.isSelf }?.id == me)
    }
    @Test func nameMapOverridesBlank_elseRider() {
        let rows = GroupRosterViewData.rows(
            peers: [peer(sara, 10, .riding)], nameMap: [:], selfUserID: me, selfProgress: 0, isImperial: false)
        #expect(rows.first { $0.id == sara }?.name == "Rider")   // no name yet
    }
    @Test func droppedShowsNoSignal() {
        let rows = GroupRosterViewData.rows(
            peers: [peer(jordan, 10, .dropped)], nameMap: [jordan: "Jordan"], selfUserID: me, selfProgress: 0, isImperial: false)
        #expect(rows.first { $0.id == jordan }?.distanceLabel == "no signal")
    }
    @Test func synthesizesSelfWhenAbsent() {
        let rows = GroupRosterViewData.rows(
            peers: [], nameMap: [:], selfUserID: me, selfProgress: 0, isImperial: false)
        #expect(rows.map(\.id) == [me])
    }
    @Test func middleNameTierNoMapEntryButDisplayName() {
        let liv = UUID()
        let rows = GroupRosterViewData.rows(
            peers: [peer(liv, 10, .riding, "Liv")],
            nameMap: [:],  // no entry for liv
            selfUserID: me, selfProgress: 0, isImperial: false)
        #expect(rows.first { $0.id == liv }?.name == "Liv")
    }
    @Test func tiebreakDeterminismByUserID() {
        let uuid1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let uuid2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let rows = GroupRosterViewData.rows(
            peers: [
                peer(uuid2, 100, .riding),  // same progress
                peer(uuid1, 100, .riding)   // same progress
            ],
            nameMap: [:], selfUserID: me, selfProgress: 0, isImperial: false)
        // uuid1 < uuid2 lexicographically, so uuid1 should appear first
        #expect(rows.map(\.id) == [uuid1, uuid2, me])
    }
    @Test func theSelfRowShowsTheRealNameWhenTheRosterResolvesIt() {
        let selfID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
        let rows = GroupRosterViewData.rows(peers: [], nameMap: [selfID: "Jamie Rivera"],
                                            selfUserID: selfID, selfProgress: 0, isImperial: true)
        #expect(rows[0].name == "Jamie Rivera")
        #expect(rows[0].isSelf)
        #expect(rows[0].nameResolved)
    }

    @Test func anUnresolvedSelfNameFallsBackToYouWithNoMarker() {
        let selfID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!
        let rows = GroupRosterViewData.rows(peers: [], nameMap: [:],
                                            selfUserID: selfID, selfProgress: 0, isImperial: true)
        #expect(rows[0].name == "You")
        #expect(!rows[0].nameResolved, "the view suppresses the marker so it can't read You YOU")
    }
}
