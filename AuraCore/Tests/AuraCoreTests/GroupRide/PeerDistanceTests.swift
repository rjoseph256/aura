import Testing
import Foundation
import AuraCore

struct PeerDistanceTests {
    private func peer(_ p: Double?, _ s: PeerStatus) -> RidePeer {
        RidePeer(userID: UUID(), displayName: "x", progressMeters: p, status: s)
    }
    @Test func aheadImperial() {
        let l = PeerDistance.label(selfProgress: 0, peer: peer(804.7, .riding), isImperial: true)
        #expect(l == "0.5 mi ahead")
    }
    @Test func behindMetric() {
        let l = PeerDistance.label(selfProgress: 200, peer: peer(80, .riding), isImperial: false)
        #expect(l == "120 m behind")
    }
    @Test func evenWhenClose() {
        let l = PeerDistance.label(selfProgress: 100, peer: peer(105, .riding), isImperial: false)
        #expect(l == "even")
    }
    @Test func awaitingHasNoDistance() {
        #expect(PeerDistance.label(selfProgress: 0, peer: peer(nil, .awaiting), isImperial: false) == nil)
    }
}
