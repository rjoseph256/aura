import Testing
import Foundation
@testable import AuraCore

struct RiderColorLatchTests {
    let a = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000B")!
    let c = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000C")!

    /// The exact case PeerPaletteTests misses: membership changes, existing hues hold.
    @Test func aRidersHueNeverChangesWhenMembershipChanges() {
        var latch = RiderColorLatch(paletteCount: 8)
        latch.latch(peerIDs: [a, b])
        let hueA = latch.colorIndex(for: a)
        latch.latch(peerIDs: [a, b, c])       // c joins
        #expect(latch.colorIndex(for: a) == hueA)
        latch.latch(peerIDs: [a, c])          // b absent from an update — NOT a release
        #expect(latch.colorIndex(for: a) == hueA)
        #expect(latch.colorIndex(for: b) != nil, "silence is not departure (D3.3)")
    }

    @Test func newcomersDeCollideAgainstIssuedHues() {
        var latch = RiderColorLatch(paletteCount: 8)
        latch.latch(peerIDs: [a])
        latch.latch(peerIDs: [a, b, c])
        let issued = [a, b, c].compactMap { latch.colorIndex(for: $0) }
        #expect(Set(issued).count == 3, "three riders, three distinct hues")
    }

    /// Both ids hash to the SAME raw slot (5 of 8), which is the case `reserved:` exists for:
    /// without it the newcomer is handed the hue the first rider already holds.
    @Test func aNewcomerWhoseHashCollidesGetsADifferentHue() {
        let first = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000101")!
        let second = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000109")!
        var latch = RiderColorLatch(paletteCount: 8)
        latch.latch(peerIDs: [first])
        let hueFirst = latch.colorIndex(for: first)
        latch.latch(peerIDs: [first, second])
        #expect(latch.colorIndex(for: first) == hueFirst, "the first rider is untouched")
        #expect(latch.colorIndex(for: second) != hueFirst, "the collider was de-collided, not overwritten")
    }

    @Test func releaseFreesTheHueForALaterJoiner() {
        var latch = RiderColorLatch(paletteCount: 2)
        latch.latch(peerIDs: [a, b])          // palette full
        let hueA = latch.colorIndex(for: a)
        latch.release(a)
        #expect(latch.colorIndex(for: a) == nil, "release actually drops the assignment")
        latch.latch(peerIDs: [b, c])
        #expect(latch.colorIndex(for: b) != latch.colorIndex(for: c), "the released slot is reusable")
        #expect(latch.colorIndex(for: c) == hueA, "and it is specifically the freed slot that is reused")
    }

    @Test func lookupMissReturnsNil() {
        let latch = RiderColorLatch(paletteCount: 8)
        #expect(latch.colorIndex(for: a) == nil)
    }

    /// Past `paletteCount` there is nothing left to hand out: the 9th rider repeats an existing
    /// hue, and that repeat latches permanently like any other assignment. Pinned so it reads as
    /// intended degradation rather than an accident.
    @Test func aNinthRiderRepeatsAHueRatherThanGoingUncoloured() {
        let riders = [
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E01")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E02")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E03")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E04")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E05")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E06")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E07")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E08")!,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000E09")!
        ]
        var latch = RiderColorLatch(paletteCount: 8)
        for count in 1...riders.count {          // riders arrive one at a time, as in a live session
            latch.latch(peerIDs: Array(riders.prefix(count)))
        }
        let issued = riders.compactMap { latch.colorIndex(for: $0) }
        #expect(issued.count == 9, "every rider is coloured — none is dropped")
        #expect(Set(issued).count == 8, "the palette is exhausted, so exactly one hue repeats")
    }
}
