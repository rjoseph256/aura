import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
@Suite("Resurface reading seam", .swiftDataSerialized)
struct ResurfacePlacesReadingTests {
    @Test func returnsOnlyFlaggedPlaces() throws {
        let c = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = SavedPlacesStore(container: c, now: { Date(timeIntervalSince1970: 1) })
        _ = store.save(Place(id: UUID(), name: "Keep", subtitle: nil,
                             coordinate: Coordinate(latitude: 40.0, longitude: -79.0), category: .custom),
                       subtitle: nil, resurface: true)
        _ = store.save(Place(id: UUID(), name: "Plain", subtitle: nil,
                             coordinate: Coordinate(latitude: 41.0, longitude: -79.0), category: .custom),
                       subtitle: nil, resurface: false)
        let reading: any ResurfacePlacesReading = store
        #expect(reading.resurfacePlaces().map(\.name) == ["Keep"])
    }
}
