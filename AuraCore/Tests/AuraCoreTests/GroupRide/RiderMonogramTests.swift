import Testing
import Foundation
@testable import AuraCore

struct RiderMonogramTests {
    @Test func uniqueInitialsStaySingleChar() {
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Mara", b: "Devon"])
        #expect(m[a] == "M"); #expect(m[b] == "D")
    }

    @Test func sharedInitialWidensBothColliders() {
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam Rivera", b: "Sara Lee"])
        #expect(m[a] == "SR")   // first + last-word initial
        #expect(m[b] == "SL")
        #expect(m[a] != m[b])
    }

    @Test func singleWordCollisionUsesFirstTwoLetters() {
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam", b: "Sid"])
        #expect(m[a] == "SA"); #expect(m[b] == "SI")
    }

    @Test func sameFirstTwoLettersWidenUntilDistinct() {   // the literal acceptance case
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam", b: "Sara"])
        #expect(m[a] == "SAM"); #expect(m[b] == "SAR")
        #expect(m[a] != m[b])
    }

    @Test func nonColliderKeepsOneCharWhenOthersCollide() {
        let a = UUID(), b = UUID(), c = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam", b: "Sid", c: "Priya"])
        #expect(m[c] == "P")    // untouched
    }

    @Test func identicalNamesStillResolveToDistinctLabels() {
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam", b: "Sam"])
        #expect(m[a] != m[b])   // guaranteed distinct (index fallback)
    }
}
