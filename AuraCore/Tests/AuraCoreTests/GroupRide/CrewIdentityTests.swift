import Testing
import Foundation
@testable import AuraCore

struct CrewIdentityTests {
    let selfID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
    let maraID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000000A")!
    let miraID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000000B")!

    @Test func selfContributesNothing() {
        let identity = CrewIdentity.derive(
            peers: [RidePeer(userID: selfID, displayName: "Jamie"),
                    RidePeer(userID: maraID, displayName: "Mara")],
            selfUserID: selfID, nameMap: [:], colors: [maraID: 3])
        #expect(identity.names[selfID] == nil)
        #expect(identity.monograms[selfID] == nil)
        #expect(identity.names[maraID] == "Mara")
    }

    /// Monograms widen over the FULL peers-minus-self set — including a coordinate-less
    /// `.awaiting` member — so the map and the lobby can never disagree on a label
    /// (the map previously widened over only the visible set).
    @Test func monogramsWidenOverTheFullPeerSetNotTheVisibleOne() {
        let identity = CrewIdentity.derive(
            peers: [RidePeer(userID: maraID, displayName: "Mara", coordinate: Coordinate(latitude: 1, longitude: 2)),
                    RidePeer(userID: miraID, displayName: "Mira")],   // no coordinate: awaiting
            selfUserID: selfID, nameMap: [:], colors: [:])
        #expect(identity.monograms[maraID] == "MA")
        #expect(identity.monograms[miraID] == "MI")
    }

    @Test func nameMapOverridesThePeerCarriedName() {
        let identity = CrewIdentity.derive(
            peers: [RidePeer(userID: maraID, displayName: "")],
            selfUserID: selfID, nameMap: [maraID: "Mara Chen"], colors: [:])
        #expect(identity.names[maraID] == "Mara Chen")
    }
}
