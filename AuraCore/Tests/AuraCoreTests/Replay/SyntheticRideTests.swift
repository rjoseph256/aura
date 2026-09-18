#if DEBUG
import Foundation
import Testing
@testable import AuraCore

/// The DEBUG seeds only earn their keep if they land in the regime they are named for.
@Suite struct SyntheticRideTests {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func unfinishedRideIsUnfinished() {
        let ride = SyntheticRide.unfinished(startingAt: start)
        #expect(ride.isUnfinished)
        // ROH-107: the marker is the checkpoint, never a nil end. The row keeps its elapsed time.
        #expect(ride.checkpointedAt != nil)
        #expect(ride.endedAt != nil)
    }

    @Test func unfinishedRideHasARealTrack() {
        let ride = SyntheticRide.unfinished(startingAt: start)
        #expect((ride.stats?.distanceMeters ?? 0) > 1_000)
    }

    @Test func unfinishedRideCannotCollideWithTheLongRide() {
        #expect(SyntheticRide.unfinished(startingAt: start).id != SyntheticRide.threeHourID)
    }
}
#endif
