import Testing
import Foundation
@testable import AuraCore

struct PeerPaletteTests {
    @Test func indicesAreInRange() {
        let ids = (0..<5).map { _ in UUID() }
        let m = PeerPalette.assign(userIDs: ids, paletteCount: 6)
        #expect(m.count == 5)
        #expect(m.values.allSatisfy { (0..<6).contains($0) })
    }

    @Test func assignmentIsStablePerUser() {
        let ids = (0..<4).map { _ in UUID() }
        let a = PeerPalette.assign(userIDs: ids, paletteCount: 6)
        let b = PeerPalette.assign(userIDs: ids.shuffled(), paletteCount: 6)
        for id in ids { #expect(a[id] == b[id]) } // order-independent, id-stable
    }

    @Test func noCollisionsWhenCountAllows() {
        let ids = (0..<6).map { _ in UUID() }
        let m = PeerPalette.assign(userIDs: ids, paletteCount: 8)
        #expect(Set(m.values).count == ids.count) // all distinct
    }

    @Test func moreUsersThanColoursWrapsGracefully() {
        let ids = (0..<10).map { _ in UUID() }
        let m = PeerPalette.assign(userIDs: ids, paletteCount: 6)
        #expect(m.count == 10)
        #expect(m.values.allSatisfy { (0..<6).contains($0) })
    }
}
