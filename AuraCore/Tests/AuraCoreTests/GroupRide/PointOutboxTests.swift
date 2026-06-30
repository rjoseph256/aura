import Testing
import Foundation
@testable import AuraCore

struct PointOutboxTests {
    func point(_ p: Double) -> LivePositionPayload {
        LivePositionPayload(userID: UUID(), coordinate: Coordinate(latitude: 0, longitude: 0),
                            progressMeters: p, recordedAt: Date(timeIntervalSince1970: p),
                            motionState: .moving)
    }
    @Test func addThenDrainReturnsAllOldestFirstAndClears() {
        var box = PointOutbox()
        box.add(point(1)); box.add(point(2))
        let drained = box.drain()
        #expect(drained.map(\.progressMeters) == [1, 2])
        #expect(box.isEmpty)
    }
    @Test func capacityEvictsOldest() {
        var box = PointOutbox(capacity: 2)
        box.add(point(1)); box.add(point(2)); box.add(point(3))
        #expect(box.drain().map(\.progressMeters) == [2, 3])
    }
}
