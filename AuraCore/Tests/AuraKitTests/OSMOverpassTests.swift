import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite("OSM Overpass")
struct OSMOverpassTests {
    @Test func queryBoundsToRadiusAndKeys() {
        let q = OSMOverpass.query(near: Coordinate(latitude: 40.44, longitude: -79.99), radiusMeters: 1200)
        #expect(q.contains("around:1200,40.44,-79.99"))
        #expect(q.contains("[out:json]"))
        #expect(q.contains("tourism"))
    }

    @Test func decodesNodesWithTags() {
        let json = """
        {"elements":[
          {"type":"node","id":42,"lat":40.44,"lon":-79.99,"tags":{"tourism":"viewpoint","name":"Grandview"}},
          {"type":"node","id":43,"lat":40.45,"lon":-79.98,"tags":{"amenity":"cafe"}},
          {"type":"way","id":99,"tags":{"leisure":"park"}}
        ]}
        """.data(using: .utf8)!
        let els = OSMOverpass.elements(from: json)
        #expect(els.count == 2)   // way dropped (no lat/lon)
        #expect(els[0].id == "osm:node/42")
        #expect(els[0].name == "Grandview")
        #expect(els[0].tags["tourism"] == "viewpoint")
        #expect(els[1].name == nil)
    }

    @Test func malformedDataYieldsEmpty() {
        #expect(OSMOverpass.elements(from: Data("nonsense".utf8)).isEmpty)
    }
}
