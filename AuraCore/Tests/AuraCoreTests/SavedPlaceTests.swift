import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlace")
struct SavedPlaceTests {
    private let coordinate = Coordinate(latitude: 40.4406, longitude: -79.9959)

    @Test func initFromPlaceCarriesFields() {
        let place = Place(name: "Trace Brewing", coordinate: coordinate, category: .brewery)
        let saved = SavedPlace(place: place, subtitle: "4312 Main St, Pittsburgh",
                               kind: .favorite, savedAt: Date(timeIntervalSince1970: 100))
        #expect(saved.id == place.id)
        #expect(saved.name == "Trace Brewing")
        #expect(saved.subtitle == "4312 Main St, Pittsburgh")
        #expect(saved.coordinate == coordinate)
        #expect(saved.category == .brewery)
        #expect(saved.kind == .favorite)
    }

    @Test func placeConversionSetsIsSavedAndKeepsID() {
        let saved = SavedPlace(id: UUID(), name: "Home base", subtitle: nil,
                               coordinate: coordinate, category: .address,
                               kind: .home, savedAt: .init(timeIntervalSince1970: 0))
        let place = saved.place
        #expect(place.id == saved.id)
        #expect(place.isSaved)
        #expect(place.name == "Home base")
        #expect(place.subtitle == nil)
    }

    @Test func placeDecodesLegacyJSONWithoutSubtitle() throws {
        // Recents persisted before this change have no `subtitle` key.
        let jsonString = """
        {"id":"\(UUID().uuidString)","name":"Point State Park",
         "coordinate":{"latitude":40.4418,"longitude":-80.0134},
         "category":"trailhead","isSaved":false}
        """
        let json = Data(jsonString.utf8)
        let place = try JSONDecoder().decode(Place.self, from: json)
        #expect(place.subtitle == nil)
    }

    @Test func savedPlaceRoundTripsThroughJSON() throws {
        let saved = SavedPlace(id: UUID(), name: "Cafe", subtitle: "Butler St",
                               coordinate: coordinate, category: .custom,
                               kind: .favorite, savedAt: Date(timeIntervalSince1970: 42))
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(SavedPlace.self, from: data)
        #expect(back == saved)
    }
}
