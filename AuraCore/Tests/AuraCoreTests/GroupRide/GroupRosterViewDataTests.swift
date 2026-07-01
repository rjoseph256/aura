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
}
