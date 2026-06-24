import XCTest
import AuraCore
@testable import AuraKit

@MainActor
final class RideStoreTests: XCTestCase {
    private func ride(_ t: TimeInterval) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: t), endedAt: Date(timeIntervalSince1970: t + 100),
             track: [], stats: .zero, routeId: nil, destinationPlaceId: nil)
    }

    func test_savesAndFetchesNewestFirst() throws {
        let store = try RideStore.inMemory()
        try store.save(ride(100))
        try store.save(ride(300))
        try store.save(ride(200))
        let all = try store.allRides()
        XCTAssertEqual(all.map(\.startedAt.timeIntervalSince1970), [300, 200, 100])
    }

    func test_delete() throws {
        let store = try RideStore.inMemory()
        let r = ride(100)
        try store.save(r)
        try store.delete(id: r.id)
        XCTAssertTrue(try store.allRides().isEmpty)
    }
}
