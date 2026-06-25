import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct RideSessionCoordinatorTests {
    private func ride(_ t: TimeInterval) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: t),
             endedAt: Date(timeIntervalSince1970: t + 1), track: [], stats: .zero,
             routeId: nil, destinationPlaceId: nil)
    }

    @Test func rideStoreConformsToRideSaving() throws {
        let store = try RideStore.inMemory()
        let saving: any RideSaving = store
        try saving.save(ride(100))
        #expect(try store.allRides().count == 1)
    }
}
