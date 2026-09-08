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

    @Test func reservedIndicesAreNotReissuedWhileRoomRemains() {
        let id = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        let plain = PeerPalette.assign(userIDs: [id], paletteCount: 8)[id]!
        let probed = PeerPalette.assign(userIDs: [id], paletteCount: 8, reserved: [plain])[id]!
        #expect(probed != plain)
    }

    @Test func aFullPaletteStillAssignsRatherThanDropping() {
        let id = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let result = PeerPalette.assign(userIDs: [id], paletteCount: 4, reserved: [0, 1, 2, 3])
        #expect(result[id] != nil, "over-capacity collides (as today) — it never drops a rider")
    }

    @Test func outOfRangeReservationsCannotStarveTheDeCollisionProbe() {
        let id = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000005")!
        // Only index 0 is genuinely held; 100/101/102 are out of range. If they counted toward
        // the room check, probing would be skipped and this rider would collide on 0.
        let result = PeerPalette.assign(userIDs: [id], paletteCount: 4,
                                        reserved: [0, 100, 101, 102])[id]!
        #expect(result != 0, "a free in-range slot existed and had to be probed for")
        #expect((0..<4).contains(result))
    }
}
