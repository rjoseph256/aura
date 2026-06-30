import Testing
import Foundation
@testable import AuraCore

struct SpeedSmootherTests {
    @Test func firstSampleSeedsDirectly() {
        var s = SpeedSmoother()
        #expect(s.add(10, at: Date(timeIntervalSince1970: 0)) == 10)
        #expect(s.value == 10)
    }

    @Test func convergesTowardStepInput() {
        var s = SpeedSmoother(timeConstant: 2.5)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = s.add(0, at: t0)
        // Feed a 10 m/s step at 1 s intervals; after ~3 time-constants it is close to 10.
        var v = 0.0
        for i in 1...10 { v = s.add(10, at: Date(timeIntervalSince1970: Double(i))) }
        #expect(v > 9.5)
        // And it is responsive: one 1 s step already moves a meaningful fraction.
        var s2 = SpeedSmoother(timeConstant: 2.5)
        _ = s2.add(0, at: t0)
        let after1s = s2.add(10, at: Date(timeIntervalSince1970: 1))
        #expect(after1s > 2.5 && after1s < 6)   // alpha = 1 - e^(-1/2.5) ≈ 0.33
    }

    @Test func nonPositiveDtReplacesWithoutNaN() {
        var s = SpeedSmoother()
        _ = s.add(5, at: Date(timeIntervalSince1970: 10))
        let v = s.add(8, at: Date(timeIntervalSince1970: 10)) // dt == 0
        #expect(v == 8)
        #expect(!v.isNaN)
    }

    @Test func negativeSampleIgnored() {
        var s = SpeedSmoother()
        _ = s.add(7, at: Date(timeIntervalSince1970: 0))
        let v = s.add(-1, at: Date(timeIntervalSince1970: 1))
        #expect(v == 7)
    }

    @Test func resetZeroes() {
        var s = SpeedSmoother()
        _ = s.add(9, at: Date(timeIntervalSince1970: 0))
        s.reset()
        #expect(s.value == 0)
        // After reset the next sample seeds again.
        #expect(s.add(4, at: Date(timeIntervalSince1970: 1)) == 4)
    }
}
