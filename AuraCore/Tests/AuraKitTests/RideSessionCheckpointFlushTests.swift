import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Records what was saved, which neither `FlakyRideSaving` nor `ThrowingRideSaving` does —
/// they count. These tests assert on the `Ride`'s fields, so they need the object.
@MainActor
final class RecordingRideSaving: RideSaving {
    private(set) var saved: [Ride] = []
    /// Every ride handed to `save`, including the ones that then threw. `saved` alone cannot
    /// answer "what did we try to persist on the failing call", which is the question when a
    /// display-only field is restored on a published ride.
    private(set) var attempted: [Ride] = []
    private(set) var discarded: [UUID] = []
    var failNextSave = false

    func save(_ ride: Ride) throws {
        attempted.append(ride)
        if failNextSave { failNextSave = false; throw CocoaError(.fileWriteUnknown) }
        saved.append(ride)
    }
    func discard(id: UUID) throws { discarded.append(id) }
}

/// The pause-boundary flush (spec D7) and the lifecycle of the row it writes. Nothing else in
/// the app persists mid-ride, so these tests own the rules for when that row appears, when it
/// is updated, and when it is removed.
@MainActor
@Suite(.swiftDataSerialized)
struct RideSessionCheckpointFlushTests {
    private func point(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80),
                   elevation: 250, timestamp: Date(timeIntervalSince1970: t))
    }

    private func makeCoordinator() -> RideSessionCoordinator {
        RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                               screen: SpyScreenWake(), activity: SpyRideActivity())
    }

    /// A ride with two fixes — comfortably past the discard floor, so the pause writes a real
    /// checkpoint — left paused.
    private func pausedRideWithACheckpoint(saving: any RideSaving) async throws
        -> RideSessionCoordinator {
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: saving, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        return c
    }

    /// Nothing persists mid-ride today, and a pause deliberately creates the conditions for a
    /// jetsam kill: backgrounded, no interaction, screen wake released, for tens of minutes.
    @Test func pauseFlushesTheClosedSegmentsToTheStore() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        let flushed = try store.allRides()
        #expect(flushed.count == 1)
        #expect(flushed.first?.flattenedPoints.count == 2)
        c.cancel()
    }

    @Test func finishingAfterAPauseUpdatesTheCheckpointInsteadOfDuplicatingIt() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        c.resume()
        location.emit(point(40.42, 20))
        #expect(await waitUntil { c.segments.flatMap(\.points).count == 3 })
        c.finish()
        let rides = try store.allRides()
        #expect(rides.count == 1)
        #expect(rides.first?.endedAt != nil)
        #expect(rides.first?.flattenedPoints.count == 3)
    }

    /// Throwing the ride away takes its checkpoint with it, or an abandoned ride is left
    /// behind in History as a ghost.
    ///
    /// **Seam test, not a reachable production state.** `flushCheckpoint` writes only above the
    /// 25 m discard floor (`RideSessionCoordinator.swift:206`) and `RideHUDView.backTapped`
    /// discards only below it, so a checkpoint and a discard cannot coexist in the app.
    /// `finish()` is the only path that clears the marker in production. This pins the seam so a
    /// future UI that *can* reach both still deletes the row.
    @Test func discardingAPausedRideRemovesTheCheckpoint() async throws {
        let store = try RideStore.inMemory()
        let c = try await pausedRideWithACheckpoint(saving: store)
        #expect(try store.allRides().count == 1)
        c.discard()
        #expect(try store.allRides().isEmpty)
    }

    /// `cancel()` runs from `onDisappear`, which this codebase documents as unreliable on the
    /// retained nav root. A teardown the rider did not ask for must not destroy the one
    /// persisted copy of their ride — that is the exact loss the checkpoint exists to prevent.
    @Test func cancelKeepsTheCheckpointForRecovery() async throws {
        let store = try RideStore.inMemory()
        let c = try await pausedRideWithACheckpoint(saving: store)
        c.cancel()
        #expect(try store.allRides().count == 1)
    }

    /// `pendingCheckpoint` tracks whether a row is out there, not whether the last write
    /// succeeded. Forgetting the id after a failed second flush would leave the first row
    /// undeletable, and a discarded ride would stay in History forever.
    @Test func aFailedSecondFlushStillLeavesTheFirstCheckpointDeletable() async throws {
        let saving = FlakyRideSaving(failingSaveNumbers: [2])
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: saving, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        c.resume()
        location.emit(point(40.42, 20))
        #expect(await waitUntil { c.segments.flatMap(\.points).count == 3 })
        c.pause()                       // this flush throws
        #expect(saving.saveCount == 2)
        c.discard()
        #expect(saving.discarded.count == 1, "the surviving first checkpoint is still cleaned up")
    }

    /// `onDisappear` calls `cancel()` after every finish, including the normal End. That must
    /// not delete the ride that was just saved.
    @Test func cancelAfterFinishKeepsTheSavedRide() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        c.finish()
        c.cancel()
        #expect(try store.allRides().count == 1)
    }

    @Test func aFlushFailureDoesNotBreakTheRide() async throws {
        let saving = ThrowingRideSaving()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: saving, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        c.pause()
        #expect(saving.saveCount == 1, "the flush was attempted")
        #expect(c.isRecording)
        #expect(c.saveFailed == false, "a checkpoint is best-effort; only the real save reports")
        c.discard()
        #expect(saving.discardCount == 0, "nothing was written, so there is nothing to discard")
    }

    /// A ride the app itself would discard silently is not worth a row in History. Flushing one
    /// would leave a mis-tap behind if the app were killed during the pause — and a rider who
    /// pauses before the first fix has literally nothing to recover.
    @Test func pausingAMisTapRideWritesNoCheckpoint() async throws {
        let store = try RideStore.inMemory()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: store, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        #expect(await waitUntil { c.segments.first?.points.count == 1 })
        #expect(RideBackOutGate.canDiscard(distanceMeters: c.stats.distanceMeters),
                "premise: one fix is under the discard floor")
        c.pause()
        #expect(try store.allRides().isEmpty)
        c.cancel()
    }

    /// The marker is set at the pause and cleared at End. `endedAt` keeps its Pass 2 stamp
    /// throughout, so an unfinished row still carries a real duration.
    @Test func aCheckpointIsMarkedAndFinishingClearsIt() async throws {
        let saving = RecordingRideSaving()
        let c = try await pausedRideWithACheckpoint(saving: saving)
        let checkpoint = try #require(saving.saved.last)
        #expect(checkpoint.checkpointedAt != nil)
        #expect(checkpoint.endedAt != nil, "Pass 2's stamp stays; the marker is a separate field")

        c.finish()
        let finished = try #require(saving.saved.last)
        #expect(finished.checkpointedAt == nil)
        #expect(finished.endedAt != nil)
    }

    /// `finish()` cleared the checkpoint handle before the save, so a throw stranded the row with
    /// nothing able to remove it — and the rider saw "couldn't save this ride" beside a History
    /// row marked as never ended.
    @Test func aFailedFinishKeepsTheDeletionHandle() async throws {
        let saving = RecordingRideSaving()
        let c = try await pausedRideWithACheckpoint(saving: saving)
        saving.failNextSave = true

        c.finish()

        #expect(c.saveFailed)
        #expect(c.pendingCheckpoint != nil, "the row is still out there and must stay removable")
    }

    /// The other half of that failure: the summary screen has to describe the row that reached
    /// History, which is the pause checkpoint — truncated at the flush. `recorder.end()`
    /// hardcodes `checkpointedAt: nil`, so without this restoration the sheet's badge, its
    /// trophy suppression, its count-up skip and its "what was recorded is in History" wording
    /// are all unreachable, and the rider reads "it won't appear in History" over a ride that is
    /// sitting in History marked "No end recorded".
    ///
    /// **No app-target unit bundle exists**, so this is where that treatment is pinned; the view
    /// reads `Ride.isUnfinished`, which is what this ride now satisfies.
    @Test func aFailedFinishPublishesTheSurvivingCheckpointsMarker() async throws {
        let saving = RecordingRideSaving()
        let c = try await pausedRideWithACheckpoint(saving: saving)
        let flushed = try #require(saving.saved.last?.checkpointedAt)
        saving.failNextSave = true

        c.finish()

        let published = try #require(c.finishedRide)
        #expect(published.checkpointedAt == flushed,
                "the marker on the row that is actually in the store, not a fresh stamp")
        #expect(published.isUnfinished, "so the sheet badges it and suppresses the celebration")
        #expect(published.endedAt != nil, "still a real duration; only the marker was restored")
        // The whole point of doing this on a copy: a restored display value must never be a
        // value we persist.
        #expect(saving.attempted.last?.checkpointedAt == nil,
                "what finish() handed to save() is the finished ride, unmarked")
    }

    /// A successful End is untouched by that restoration: `finish()` clears the handle, and the
    /// published ride is the finished one. A regression here would badge every ride that was ever
    /// paused.
    @Test func aSuccessfulFinishPublishesNoMarker() async throws {
        let saving = RecordingRideSaving()
        let c = try await pausedRideWithACheckpoint(saving: saving)
        #expect(saving.saved.last?.checkpointedAt != nil, "premise: a checkpoint was written")

        c.finish()

        let published = try #require(c.finishedRide)
        #expect(published.checkpointedAt == nil)
        #expect(!published.isUnfinished)
        #expect(c.saveFailed == false)
        #expect(c.pendingCheckpoint == nil)
    }

    /// A failed finish with no checkpoint behind it — the rider never paused, or paused under the
    /// discard floor — really did lose the ride, and must keep the blunter wording. Restoring a
    /// marker here would tell them to look in History for something that is not there.
    @Test func aFailedFinishWithNoCheckpointPublishesNoMarker() async throws {
        let saving = RecordingRideSaving()
        let location = ManualLocationProvider()
        let c = makeCoordinator()
        c.start(location: location, saving: saving, units: .metric, authorization: .authorized)
        location.emit(point(40.40, 0))
        location.emit(point(40.41, 10))
        #expect(await waitUntil { c.stats.distanceMeters > 0 })
        #expect(c.pendingCheckpoint == nil, "premise: no pause, so no checkpoint row")
        saving.failNextSave = true

        c.finish()

        #expect(c.saveFailed)
        #expect(try #require(c.finishedRide).checkpointedAt == nil)
        #expect(!(try #require(c.finishedRide).isUnfinished))
    }

    /// `recorder.rideID` survives `end()` — it is reset only in `start(at:)` — so a passthrough
    /// that forgets the recording check hands the glance surfaces an id for a ride that finished,
    /// permanently filtering it out of Home and the widget.
    ///
    /// It also has to be the *right* id. `activeRideID != nil` alone is satisfied by a
    /// regression returning `UUID()`, which would make the exclusion half of ROH-107 a silent
    /// no-op on Home, the widget and the weekly ring with the whole suite still green — so this
    /// pins it against the checkpoint handle and against the id of the row in the store, which
    /// is the id `WidgetSnapshot.make`'s filter actually compares.
    @Test func activeRideIDIsTheRecordedRideAndIsNilOnceItEnds() async throws {
        let saving = RecordingRideSaving()
        // Reuse the suite's existing start-a-ride helper; do not hand-roll the start(...) call.
        let c = try await pausedRideWithACheckpoint(saving: saving)
        let active = try #require(c.activeRideID, "a paused ride is still active")
        #expect(active == c.pendingCheckpoint?.rideID)
        #expect(active == saving.saved.last?.id, "the id of the row the glance surfaces filter on")

        c.finish()
        #expect(c.activeRideID == nil, "rideID survives end(); the isRecording check is what saves us")
        #expect(saving.saved.last?.id == active, "and End updated that same row")
    }
}
