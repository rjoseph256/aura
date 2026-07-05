import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlace resurface")
struct SavedPlacesResurfaceTests {
    private func place(_ id: UUID, _ lat: Double, resurface: Bool, _ saved: TimeInterval) -> SavedPlace {
        SavedPlace(id: id, name: "P", subtitle: nil,
                   coordinate: Coordinate(latitude: lat, longitude: -79.99),
                   category: .custom, kind: .favorite, savedAt: Date(timeIntervalSince1970: saved),
                   resurface: resurface)
    }

    @Test func defaultsFalse() {
        let p = SavedPlace(name: "P", subtitle: nil,
                           coordinate: Coordinate(latitude: 1, longitude: 2),
                           category: .custom, kind: .favorite, savedAt: .init(timeIntervalSince1970: 0))
        #expect(p.resurface == false)
    }

    @Test func setResurfaceTogglesById() {
        let id = UUID()
        let list = [place(id, 40.0, resurface: false, 1)]
        let on = SavedPlacesLogic.setResurface(id: id, true, in: list)
        #expect(on.first?.resurface == true)
        let off = SavedPlacesLogic.setResurface(id: id, false, in: on)
        #expect(off.first?.resurface == false)
    }

    @Test func reconcileKeepsResurfaceIfEitherDuplicateFlagged() {
        let id = UUID()
        // Same id, the NEWER save has resurface=false, but an older flagged one must not silently demote it.
        let list = [place(id, 40.0, resurface: true, 1), place(id, 40.0, resurface: false, 2)]
        let out = SavedPlacesLogic.reconciled(list)
        #expect(out.count == 1)
        #expect(out.first?.resurface == true)
    }
}
