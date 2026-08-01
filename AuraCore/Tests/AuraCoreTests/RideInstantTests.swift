import Foundation
import Testing
@testable import AuraCore

@Suite struct RideInstantTests {
    @Test func nowAdvancesMonotonicallyAndCarriesAWallDate() {
        let a = RideInstant.now
        let b = RideInstant.now
        #expect(b.monotonicSeconds >= a.monotonicSeconds)
        // Sanity that the wall half is a real Date and not a stub.
        #expect(abs(a.date.timeIntervalSinceNow) < 86_400)
    }

    /// The origin is process-wide and taken at first use, so a production reading is a small
    /// number. The AuraKitTests shim uses `timeIntervalSinceReferenceDate` (~8e8), and mixing the
    /// two conventions inside one recorder is the failure the `RideClocking` seam exists to
    /// prevent — durations in the tens of millions of seconds, under assertions that still pass.
    @Test func nowIsMeasuredFromAProcessLifetimeOrigin() {
        #expect(RideInstant.now.monotonicSeconds < 86_400)
    }

    @Test func systemRideClockReturnsNow() {
        let before = RideInstant.now
        #expect(SystemRideClock().now().monotonicSeconds >= before.monotonicSeconds)
    }

    @Test func partsAreCarriedVerbatim() {
        let d = Date(timeIntervalSinceReferenceDate: 1_000)
        let i = RideInstant(date: d, monotonicSeconds: 42)
        #expect(i.date == d)
        #expect(i.monotonicSeconds == 42)
    }
}
