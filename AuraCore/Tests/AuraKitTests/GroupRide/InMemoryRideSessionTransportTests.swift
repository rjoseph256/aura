import Testing
import Foundation
@testable import AuraKit
import AuraCore

@MainActor
struct InMemoryRideSessionTransportTests {
    @Test func emittedEventsReachTheSubscriptionStream() async {
        let transport = InMemoryRideSessionTransport()
        let sub = transport.liveSubscription(rideID: UUID())
        let collected = Task {
            var seen: [TransportEvent] = []
            for await event in sub.events { seen.append(event); if seen.count == 2 { break } }
            return seen
        }
        transport.emit(.connected)
        transport.emit(.memberLeft(UUID()))
        let seen = await collected.value
        #expect(seen.count == 2)
    }
    @Test func publishIsRecordedAndSnapshotIsCanned() async throws {
        let transport = InMemoryRideSessionTransport()
        let rid = UUID()
        let p = LivePositionPayload(userID: UUID(), coordinate: Coordinate(latitude: 0, longitude: 0),
                                    progressMeters: 1, recordedAt: Date(), motionState: .moving)
        transport.snapshotResult = [p]
        try await transport.publish(rideID: rid, points: [p])
        let snap = try await transport.snapshot(rideID: rid)
        #expect(transport.publishedBatches.count == 1)
        #expect(snap.count == 1)
    }
}
