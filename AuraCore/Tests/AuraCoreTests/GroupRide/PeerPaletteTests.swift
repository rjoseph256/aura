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
        // Many generated sets so the de-collision probe is reliably exercised (a random 6-into-8
        // set has raw hash collisions ~90% of the time; 200 sets makes "probe deleted" fail almost
        // surely, instead of the ~8% of single runs that would pass a broken impl).
        for _ in 0..<200 {
            let ids = (0..<6).map { _ in UUID() }
            let m = PeerPalette.assign(userIDs: ids, paletteCount: 8)
            #expect(Set(m.values).count == ids.count) // always distinct when count allows
        }
    }

    @Test func moreUsersThanColoursWrapsGracefully() {
        let ids = (0..<10).map { _ in UUID() }
        let m = PeerPalette.assign(userIDs: ids, paletteCount: 6)
        #expect(m.count == 10)
        #expect(m.values.allSatisfy { (0..<6).contains($0) })
    }
}
