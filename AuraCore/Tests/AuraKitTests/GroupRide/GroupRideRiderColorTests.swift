import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideRiderColorTests {
    let peerA = UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000A")!
    let peerB = UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000B")!

    func makeLiveSession() async -> GroupRideSession {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        let session = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                       displayNameProvider: { "Jamie" })
        await session.create(route: nil)
        await session.beginLiveSession()
        return session
    }

    func position(_ id: UUID) -> TransportEvent {
        .position(LivePositionPayload(userID: id, coordinate: Coordinate(latitude: 1, longitude: 2),
                                      progressMeters: 0, recordedAt: Date(), motionState: .moving))
    }

    @Test func peersGetLatchedHuesAndSelfGetsNone() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        #expect(session.crewIdentity.colors[peerA] != nil)
        #expect(session.crewIdentity.colors[session.selfUserID!] == nil, "white = me: self holds no hue")
    }

    @Test func aHueSurvivesMembershipChange() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        let hue = session.crewIdentity.colors[peerA]
        await session.ingest(position(peerB))
        #expect(session.crewIdentity.colors[peerA] == hue)
    }

    @Test func memberLeftReleasesTheHue() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        await session.ingest(.memberLeft(peerA))
        #expect(session.crewIdentity.colors[peerA] == nil)
    }

    @Test func identityCoversEveryNonSelfPeerInTheSnapshot() async {
        let session = await makeLiveSession()
        await session.ingest(position(peerA))
        await session.ingest(position(peerB))
        for peer in session.peers where peer.userID != session.selfUserID {
            #expect(session.crewIdentity.colors[peer.userID] != nil,
                    "one writer: no peer can appear without a latched hue")
        }
    }

    /// `beginLiveSession` seeds `peers` from the roster, so it must populate identity in the same
    /// step — otherwise a member already in the lobby renders with no name, hue or monogram until
    /// the first tick heals it. Reverting that one call site to a bare `peers =` left every other
    /// test green, because they all ingest immediately afterwards.
    @Test func beginLiveSessionPopulatesIdentityBeforeAnyTickOrIngest() async {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        let session = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                       displayNameProvider: { "Jamie" })
        await session.create(route: nil)

        let guest = InMemoryGroupRideBackend(sharing: backend)
        try? await guest.signIn(idToken: "g", nonce: "n", displayName: "Mara")
        _ = try? await guest.joinRide(code: session.joinCode!)

        await session.beginLiveSession()

        let others = session.peers.filter { $0.userID != session.selfUserID }
        #expect(!others.isEmpty, "the fixture must really seed a second member, or the loop below pins nothing")
        for peer in others {
            #expect(session.crewIdentity.names[peer.userID] != nil)
            #expect(session.crewIdentity.colors[peer.userID] != nil)
        }
    }
}
