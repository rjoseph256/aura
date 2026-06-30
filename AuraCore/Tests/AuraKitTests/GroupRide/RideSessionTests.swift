import Testing
import Foundation
@testable import AuraKit
import AuraCore

@MainActor
struct RideSessionTests {
    let me = UUID(); let alex = UUID()
    let t0 = Date(timeIntervalSince1970: 1000)

    func makeSession(_ transport: InMemoryRideSessionTransport) -> RideSession {
        RideSession(rideID: UUID(), selfUserID: me, transport: transport,
                    cadence: LiveShareCadence(foregroundInterval: .seconds(2), droppedTimeout: 40))
    }

    // Event handling is tested by calling `ingest(_:)` directly — deterministic, no
    // Task.sleep wait on the stream pump. The stream-to-ingest wiring itself is covered
    // by Task 13's InMemoryRideSessionTransport test.
    @Test func ingestPositionAppliesDelta() async {
        let session = makeSession(InMemoryRideSessionTransport())
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.position(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: t0, motionState: .moving)))
        #expect(session.peers.first { $0.userID == alex }?.progressMeters == 100)
        session.stop()
    }

    @Test func ingestMemberLeftPrunesThePeer() async {
        let session = makeSession(InMemoryRideSessionTransport())
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.memberLeft(alex))
        #expect(session.peers.contains { $0.userID == alex } == false)
        session.stop()
    }

    @Test func ingestConnectedReSeedsFromSnapshot() async {
        let transport = InMemoryRideSessionTransport()
        transport.snapshotResult = [LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 9, longitude: 9),
            progressMeters: 500, recordedAt: t0, motionState: .moving)]
        let session = makeSession(transport)
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.connected)
        #expect(session.peers.first { $0.userID == alex }?.progressMeters == 500)
        session.stop()
    }

    @Test func publishIfDueDrainsOwnPointsOnCadence() async {
        let transport = InMemoryRideSessionTransport()
        let session = makeSession(transport)
        await session.start(roster: [])
        session.locationDidUpdate(coordinate: Coordinate(latitude: 1, longitude: 1),
                                  progressMeters: 10, speed: 5, at: t0)
        // first call publishes (lastPublish starts at .distantPast)
        await session.publishIfDue(now: t0, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)
        // immediately again: not due yet (interval 2s)
        session.locationDidUpdate(coordinate: Coordinate(latitude: 1, longitude: 1),
                                  progressMeters: 11, speed: 5, at: t0.addingTimeInterval(0.5))
        await session.publishIfDue(now: t0.addingTimeInterval(0.5), lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)
        // after the interval: publishes again
        session.locationDidUpdate(coordinate: Coordinate(latitude: 1, longitude: 1),
                                  progressMeters: 12, speed: 5, at: t0.addingTimeInterval(3))
        await session.publishIfDue(now: t0.addingTimeInterval(3), lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 2)
        session.stop()
    }

    @Test func stalenessTickFlipsSilentPeerToDroppedWithNoPayloads() async {
        let session = makeSession(InMemoryRideSessionTransport())
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.position(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: t0, motionState: .moving)))
        session.stalenessTick(now: t0.addingTimeInterval(120))   // advance time only
        #expect(session.peers.first { $0.userID == alex }?.status == .dropped)
        session.stop()
    }
}
