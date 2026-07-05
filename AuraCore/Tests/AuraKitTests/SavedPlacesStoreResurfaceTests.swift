import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
@Suite("SavedPlacesStore resurface")
struct SavedPlacesStoreResurfaceTests {
    private func store() throws -> SavedPlacesStore {
        let c = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SavedPlacesStore(container: c, now: { Date(timeIntervalSince1970: 10) })
    }
    private func place(_ name: String) -> Place {
        Place(id: UUID(), name: name, subtitle: nil,
              coordinate: Coordinate(latitude: 40.44, longitude: -79.99), category: .custom)
    }

    @Test func saveWithResurfacePersistsFlag() throws {
        let s = try store()
        _ = s.save(place("Spot"), subtitle: nil, resurface: true)
        #expect(s.places.first?.resurface == true)
    }

    @Test func setResurfaceTogglesOff() throws {
        let s = try store()
        guard case let .saved(saved) = s.save(place("Spot"), subtitle: nil, resurface: true) else {
            Issue.record("not saved"); return
        }
        s.setResurface(id: saved.id, false)
        #expect(s.places.first { $0.id == saved.id }?.resurface == false)
    }

    @Test func updateNameOnlyIfStillProvisional() throws {
        let s = try store()
        guard case let .saved(saved) = s.save(place("Marked spot"), subtitle: nil, resurface: true) else {
            Issue.record("not saved"); return
        }
        // A user rename lands first.
        s.rename(id: saved.id, to: "Best viewpoint")
        // Async geocode backfill tries to set the real name, but must NOT clobber the user edit.
        s.updateName(id: saved.id, to: "Overlook Park", ifCurrentlyNamed: "Marked spot")
        #expect(s.places.first { $0.id == saved.id }?.name == "Best viewpoint")
        // If still provisional, backfill applies.
        guard case let .saved(two) = s.save(place("Marked spot"), subtitle: nil, resurface: true) else {
            Issue.record("not saved"); return
        }
        s.updateName(id: two.id, to: "River Trail", ifCurrentlyNamed: "Marked spot")
        #expect(s.places.first { $0.id == two.id }?.name == "River Trail")
    }
}
