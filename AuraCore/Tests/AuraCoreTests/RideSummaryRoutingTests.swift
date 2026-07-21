import Testing
import Foundation
import AuraCore

struct RideSummaryRoutingTests {
    private func ride(_ id: UUID = UUID()) -> Ride {
        Ride(id: id, kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
             endedAt: Date(timeIntervalSince1970: 60), track: [], stats: nil,
             routeId: nil, destinationPlaceId: nil)
    }

    @Test func collapsedIsAlwaysExactlyTheSummaryEntry() {
        let result = RideSummaryRouting.collapsed(ride: ride(), saveFailed: false)
        #expect(result.count == 1)          // collapse, NOT a top-swap that keeps prior entries
        if case .rideSummary = result[0] {} else { Issue.record("expected .rideSummary at [0]") }
    }

    @Test func collapsedCarriesRideAndSaveFailed() {
        let id = UUID()
        let result = RideSummaryRouting.collapsed(ride: ride(id), saveFailed: true)
        guard case let .rideSummary(payload) = result.first else {
            Issue.record("expected .rideSummary"); return
        }
        #expect(payload.ride.id == id)
        #expect(payload.saveFailed == true)
    }
}
