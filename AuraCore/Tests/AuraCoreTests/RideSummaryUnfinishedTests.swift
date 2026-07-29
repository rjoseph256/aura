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
}
