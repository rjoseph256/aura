import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlaceMatcher")
struct SavedPlaceMatcherTests {
    private func make(_ name: String, subtitle: String? = nil,
                      kind: SavedPlace.Kind = .favorite,
                      savedAt: TimeInterval = 0, lon: Double = -79.9) -> SavedPlace {
        SavedPlace(name: name, subtitle: subtitle,
                   coordinate: Coordinate(latitude: 40.4, longitude: lon),
                   category: .custom, kind: kind,
                   savedAt: Date(timeIntervalSince1970: savedAt))
    }

    @Test func substringCaseAndDiacriticInsensitive() {
        let list = [make("Café Colado", lon: -79.1)]
        #expect(SavedPlaceMatcher.matches(query: "cafe", in: list).count == 1)
        #expect(SavedPlaceMatcher.matches(query: "COLADO", in: list).count == 1)
        #expect(SavedPlaceMatcher.matches(query: "tavern", in: list).isEmpty)
    }

    @Test func matchesSubtitleToo() {
        let list = [make("Trace", subtitle: "Butler Street", lon: -79.2)]
        #expect(SavedPlaceMatcher.matches(query: "butler", in: list).count == 1)
    }

    @Test func homeKindMatchesHomeQueryPrefixes() {
        let list = [make("1284 Milton St", kind: .home, lon: -79.3)]
        for query in ["h", "ho", "hom", "home"] {
            #expect(SavedPlaceMatcher.matches(query: query, in: list).count == 1,
                    "query \(query) should match Home")
        }
        #expect(SavedPlaceMatcher.matches(query: "homes", in: list).isEmpty)
    }

    @Test func capsAtLimitHomeFirstThenNewest() {
        let list = [
            make("Alpha stop", savedAt: 1, lon: -79.1),
            make("Alpha park", savedAt: 3, lon: -79.2),
            make("Alpha cafe", savedAt: 2, lon: -79.3),
            make("Alpha home base", kind: .home, savedAt: 0, lon: -79.4)
        ]
        let hits = SavedPlaceMatcher.matches(query: "alpha", in: list)
        #expect(hits.count == 3)
        #expect(hits[0].kind == .home)
        #expect(hits[1].name == "Alpha park")
        #expect(hits[2].name == "Alpha cafe")
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(SavedPlaceMatcher.matches(query: "  ", in: [make("A")]).isEmpty)
    }
}
