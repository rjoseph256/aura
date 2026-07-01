import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlacesLogic")
struct SavedPlacesLogicTests {
    private func coord(_ lat: Double, _ lon: Double) -> Coordinate {
        Coordinate(latitude: lat, longitude: lon)
    }
    private func favorite(_ name: String, lat: Double, lon: Double,
                          savedAt: TimeInterval, kind: SavedPlace.Kind = .favorite) -> SavedPlace {
        SavedPlace(name: name, subtitle: nil, coordinate: coord(lat, lon),
                   category: .custom, kind: kind,
                   savedAt: Date(timeIntervalSince1970: savedAt))
    }
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func addAppendsAsFavorite() {
        let place = Place(name: "Trace", coordinate: coord(40.44, -79.99), category: .brewery)
        guard case let .added(list) = SavedPlacesLogic.add(place, subtitle: "Butler St",
                                                           to: [], now: now) else {
            Issue.record("expected .added"); return
        }
        #expect(list.count == 1)
        #expect(list[0].kind == .favorite)
        #expect(list[0].subtitle == "Butler St")
        #expect(list[0].savedAt == now)
    }

    @Test func addAtSameKeyReplacesAdoptingNewName() {
        let existing = favorite("Old Name", lat: 40.44060, lon: -79.99590, savedAt: 1)
        let place = Place(name: "New Name", coordinate: coord(40.440601, -79.995899),
                          category: .custom)
        guard case let .added(list) = SavedPlacesLogic.add(place, subtitle: "New St",
                                                           to: [existing], now: now) else {
            Issue.record("expected .added"); return
        }
        #expect(list.count == 1)
        #expect(list[0].name == "New Name")        // collapse adopts newest name
        #expect(list[0].subtitle == "New St")
        #expect(list[0].id == existing.id)          // identity is stable
        #expect(list[0].kind == existing.kind)      // kind survives a re-save
    }

    @Test func addRefusesBeyondCap() {
        let full = (0..<SavedPlacesLogic.maxCount).map {
            favorite("P\($0)", lat: 40.0 + Double($0) * 0.001, lon: -79.9, savedAt: Double($0))
        }
        let place = Place(name: "One more", coordinate: coord(41.0, -79.0), category: .custom)
        #expect(SavedPlacesLogic.add(place, subtitle: nil, to: full, now: now) == .full)
    }

    @Test func reSaveAtCapIsNotRefused() {
        // Replacing an existing key must not trip the cap.
        let full = (0..<SavedPlacesLogic.maxCount).map {
            favorite("P\($0)", lat: 40.0 + Double($0) * 0.001, lon: -79.9, savedAt: Double($0))
        }
        let place = Place(name: "P0 renamed", coordinate: coord(40.0, -79.9), category: .custom)
        guard case .added = SavedPlacesLogic.add(place, subtitle: nil, to: full, now: now) else {
            Issue.record("re-save at cap must succeed"); return
        }
    }

    @Test func setHomeDemotesPreviousAndRefreshesItsSavedAt() {
        let oldHome = favorite("Old home", lat: 40.1, lon: -79.1, savedAt: 1, kind: .home)
        let target = favorite("New home", lat: 40.2, lon: -79.2, savedAt: 2)
        let list = SavedPlacesLogic.setHome(id: target.id, in: [oldHome, target], now: now)
        let home = list.first { $0.kind == .home }
        let demoted = list.first { $0.id == oldHome.id }
        #expect(home?.id == target.id)
        #expect(demoted?.kind == .favorite)
        #expect(demoted?.savedAt == now)   // surfaces at top of favorites
    }

    @Test func removeHomeMakesFavorite() {
        let home = favorite("Home", lat: 40.1, lon: -79.1, savedAt: 1, kind: .home)
        let list = SavedPlacesLogic.removeHome(id: home.id, in: [home])
        #expect(list[0].kind == .favorite)
    }

    @Test func renameTrimsAndIgnoresEmpty() {
        let item = favorite("Old", lat: 40.1, lon: -79.1, savedAt: 1)
        #expect(SavedPlacesLogic.rename(id: item.id, to: "  New  ", in: [item])[0].name == "New")
        #expect(SavedPlacesLogic.rename(id: item.id, to: "   ", in: [item])[0].name == "Old")
    }

    @Test func reconciledDropsIDDoublesKeepingNewest() {
        let id = UUID()
        var a = favorite("A", lat: 40.1, lon: -79.1, savedAt: 1); a.id = id
        var b = favorite("A latest", lat: 40.1, lon: -79.1, savedAt: 9); b.id = id
        let list = SavedPlacesLogic.reconciled([a, b])
        #expect(list.count == 1)
        #expect(list[0].name == "A latest")
    }

    @Test func reconciledCollapsesKeyDoublesKeepingNewest() {
        let a = favorite("First", lat: 40.44060, lon: -79.99590, savedAt: 1)
        let b = favorite("Second", lat: 40.440601, lon: -79.995899, savedAt: 9)
        let list = SavedPlacesLogic.reconciled([a, b])
        #expect(list.count == 1)
        #expect(list[0].name == "Second")
    }

    @Test func reconciledKeepsSingleNewestHomeAndSortsHomeFirst() {
        let homeA = favorite("Home A", lat: 40.1, lon: -79.1, savedAt: 5, kind: .home)
        let homeB = favorite("Home B", lat: 40.2, lon: -79.2, savedAt: 9, kind: .home)
        let fav = favorite("Fav", lat: 40.3, lon: -79.3, savedAt: 99)
        let list = SavedPlacesLogic.reconciled([fav, homeA, homeB])
        #expect(list.filter { $0.kind == .home }.count == 1)
        #expect(list[0].kind == .home)
        #expect(list[0].name == "Home B")           // newest savedAt wins Home
        #expect(list[1].name == "Fav")              // favorites by savedAt desc
    }

    @Test func savedMatchingByIDThenKey() {
        let saved = favorite("Cafe", lat: 40.44060, lon: -79.99590, savedAt: 1)
        // Fresh UUID (search mints one) but jittered-same coordinate → key match.
        let searchPick = Place(name: "Cafe", coordinate: coord(40.440601, -79.995899),
                               category: .custom)
        #expect(SavedPlacesLogic.saved(matching: searchPick, in: [saved])?.id == saved.id)
        #expect(SavedPlacesLogic.isSaved(searchPick, in: [saved]))
        let elsewhere = Place(name: "Cafe", coordinate: coord(41.0, -79.0), category: .custom)
        #expect(!SavedPlacesLogic.isSaved(elsewhere, in: [saved]))
    }
}
