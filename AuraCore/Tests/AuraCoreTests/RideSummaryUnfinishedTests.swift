import Testing
import Foundation
@testable import AuraCore

@Suite("RideSummary.isUnfinished")
struct RideSummaryUnfinishedTests {
    private func summary(endedAt: Date?, checkpointedAt: Date?) -> RideSummary {
        RideSummary(id: UUID(), kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                    endedAt: endedAt, hasStats: true, distanceMeters: 1_000,
                    movingTimeSeconds: 300, pausedSeconds: 0, checkpointedAt: checkpointedAt,
                    elevationGainMeters: 10, destinationName: nil, thumbnailCoordinates: [])
    }

    @Test func aFinishedRideIsNotUnfinished() {
        #expect(!summary(endedAt: Date(timeIntervalSince1970: 100), checkpointedAt: nil).isUnfinished)
    }

    @Test func aCheckpointIsUnfinished() {
        #expect(summary(endedAt: Date(timeIntervalSince1970: 100),
                        checkpointedAt: Date(timeIntervalSince1970: 100)).isUnfinished)
    }

    /// Commits c356419 / ac5582c (PR #90) shipped a `checkpoint(at:)` that wrote a nil
    /// `endedAt`. No App Store build carried it, but a dev build used during Pass 2 device
    /// verification could have written such rows, and they mirror to CloudKit. They carry no
    /// `checkpointedAt` and would otherwise render as finished.
    @Test func aPassTwoDevBuildRowIsUnfinished() {
        #expect(summary(endedAt: nil, checkpointedAt: nil).isUnfinished)
    }

    /// `Ride` carries the same predicate — the summary sheet and the share card read it off the
    /// ride in hand rather than the projection. Two model-layer copies; this pins them equal on
    /// every case above, which is the only thing stopping them drifting.
    @Test func rideAgreesWithItsSummaryProjection() {
        func ride(endedAt: Date?, checkpointedAt: Date?) -> Ride {
            Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0), endedAt: endedAt,
                 track: [], stats: nil, checkpointedAt: checkpointedAt,
                 routeId: nil, destinationPlaceId: nil)
        }
        let stamp = Date(timeIntervalSince1970: 100)
        for (endedAt, checkpointedAt) in [(stamp, nil), (stamp, stamp), (nil, nil), (nil, stamp)]
            as [(Date?, Date?)] {
            #expect(ride(endedAt: endedAt, checkpointedAt: checkpointedAt).isUnfinished
                    == summary(endedAt: endedAt, checkpointedAt: checkpointedAt).isUnfinished)
        }
    }
}
