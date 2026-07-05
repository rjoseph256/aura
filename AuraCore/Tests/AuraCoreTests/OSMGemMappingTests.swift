import Testing
import Foundation
@testable import AuraCore

@Suite("OSM gem mapping")
struct OSMGemMappingTests {
    private let c = Coordinate(latitude: 40.44, longitude: -79.99)

    @Test func mapsKnownTagsToCategories() {
        #expect(OSMGemMapping.category(for: ["tourism": "viewpoint"]) == .viewpoint)
        #expect(OSMGemMapping.category(for: ["amenity": "drinking_water"]) == .water)
        #expect(OSMGemMapping.category(for: ["natural": "spring"]) == .water)
        #expect(OSMGemMapping.category(for: ["leisure": "park"]) == .park)
        #expect(OSMGemMapping.category(for: ["amenity": "cafe"]) == .cafe)
        #expect(OSMGemMapping.category(for: ["tourism": "artwork"]) == .mural)
        #expect(OSMGemMapping.category(for: ["historic": "monument"]) == .historic)
        #expect(OSMGemMapping.category(for: ["tourism": "attraction"]) == .landmark)
    }

    @Test func unmappedTagsReturnNil() {
        #expect(OSMGemMapping.category(for: ["shop": "supermarket"]) == nil)
        #expect(OSMGemMapping.category(for: [:]) == nil)
        #expect(OSMGemMapping.gem(id: "osm:node/1", name: "Foo", coordinate: c, tags: ["shop": "supermarket"]) == nil)
    }

    @Test func liveGemNeverExceedsTierCard() {
        // viewpoint defaults to .cardHaptic (T3) but live must cap at .card (T2).
        let g = OSMGemMapping.gem(id: "osm:node/2", name: "Grandview", coordinate: c, tags: ["tourism": "viewpoint"])
        #expect(g?.tier == .card)
        #expect(g?.source == .live)
        #expect(g?.photoAsset == nil)
    }

    @Test func namelessGemFallsBackToCategoryNoun() {
        let g = OSMGemMapping.gem(id: "osm:node/3", name: nil, coordinate: c, tags: ["amenity": "cafe"])
        #expect(g?.name == "Café")
    }
}
