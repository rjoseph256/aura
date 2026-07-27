import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

/// The off-launch half of spec D2's backfill. `RideSegmentBackfiller` fills `segmentsData` on
/// rows that do not have it — rides recorded before V6, and rides that keep arriving from a V5
/// device long after the migration ran, which is why it has to be re-runnable rather than a
/// one-shot migration stage.
///
/// The properties under test are the ones that let it run unattended on a rider's phone: it
/// never rewrites a row that already has segments, it survives rows it cannot read, it is
/// resumable and cancellable, unreadable rows cannot starve the budget, and it cannot throw
/// into its caller.
@MainActor
@Suite("Ride segment backfill", .swiftDataSerialized)
struct RideSegmentBackfillTests {
    /// Every row this suite writes starts here, comfortably outside the settling window, so a
    /// test opts into the unsettled case rather than tripping over it.
    private let longAgo = Date(timeIntervalSince1970: 1_000_000)
    private var settledBefore: Date { longAgo.addingTimeInterval(60) }

    private func pt(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: nil,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    /// Inserts a row in the pre-V6 shape: a flat track and no segmented blob.
    @discardableResult
    private func insertUnbackfilled(_ store: RideStore, id: UUID = UUID(),
                                    startedAt: Date? = nil, trackData: Data) throws -> UUID {
        store.container.mainContext.insert(RideRecord(
            id: id, kindRaw: "freeRide", startedAt: startedAt ?? longAgo,
            endedAt: (startedAt ?? longAgo).addingTimeInterval(1000),
            trackData: trackData, segmentsData: nil, statsData: nil,
            routeId: nil, destinationPlaceId: nil))
        try store.container.mainContext.save()
        return id
    }

    private func rawSegments(in store: RideStore, id: UUID) throws -> Data? {
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        let record = try #require(try store.container.mainContext.fetch(descriptor).first)
        return record.segmentsData
    }

    private func segments(in store: RideStore, id: UUID) throws -> [RideSegment]? {
        guard let data = try rawSegments(in: store, id: id) else { return nil }
        return try JSONDecoder().decode([RideSegment].self, from: data)
    }

    @Test func anUnbackfilledRowGainsOneSegmentCarryingEveryPoint() async throws {
        let store = try RideStore.inMemory()
        let track = [pt(40.0, 0), pt(40.1, 10), pt(40.2, 20)]
        let id = try insertUnbackfilled(store, trackData: try JSONEncoder().encode(track))

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(settledBefore: settledBefore)

        #expect(result == .init(backfilled: 1, unreadable: 0, failedWrites: 0, remaining: 0))
        #expect(try segments(in: store, id: id) == [RideSegment(points: track)])
    }

    /// An empty flat blob is LEFT alone rather than stamped as an empty ride. It already reads
    /// as an empty ride through the mapper, so writing `[]` buys nothing — and it would freeze
    /// the row that way forever, because reads prefer `segmentsData` and nothing re-derives it.
    /// A CloudKit row whose asset has not materialized yet has exactly this shape.
    @Test func anEmptyTrackBlobIsLeftPendingRatherThanStampedEmpty() async throws {
        let store = try RideStore.inMemory()
        let id = try insertUnbackfilled(store, trackData: Data())

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(settledBefore: settledBefore)

        #expect(result.backfilled == 0)
        #expect(result.remaining == 1)
        #expect(try rawSegments(in: store, id: id) == nil)
        // And it still reads as a whole (empty) ride meanwhile.
        #expect(try #require(try store.ride(id: id)).segments.isEmpty)
    }

    /// A ride encoded as zero points is a real fix-less ride, not a missing asset: it gets the
    /// canonical zero-segment encoding.
    @Test func anEncodedEmptyTrackBackfillsToZeroSegments() async throws {
        let store = try RideStore.inMemory()
        let id = try insertUnbackfilled(store, trackData: try JSONEncoder().encode([TrackPoint]()))

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(settledBefore: settledBefore)

        #expect(result.backfilled == 1)
        #expect(try segments(in: store, id: id) == [])
    }

    /// A ride that started inside the settling window may still be being recorded — or paused —
    /// on another device, arriving here in pieces. Backfilling from a piece would pin the ride
    /// to that piece permanently, since reads prefer `segmentsData`.
    @Test func aRecentRideIsLeftForALaterRun() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        let settled = try insertUnbackfilled(store, trackData: track)
        let fresh = try insertUnbackfilled(store, startedAt: settledBefore.addingTimeInterval(60),
                                           trackData: track)

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(settledBefore: settledBefore)

        #expect(result == .init(backfilled: 1, unreadable: 0, failedWrites: 0, remaining: 1))
        #expect(try rawSegments(in: store, id: settled) != nil)
        #expect(try rawSegments(in: store, id: fresh) == nil, "not settled yet")
    }

    /// Unreadable rows are counted and stepped over. This is the shape that broke the
    /// offset-paged design reviewed out of the first plan revision: bad rows never leave the
    /// pending set, so they have to interleave with good ones without the sweep losing its
    /// place. Hence 24 rows with every third one corrupt.
    @Test func unreadableRowsAreCountedWithoutStrandingTheRest() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        var goodIds: [UUID] = []
        var badIds: [UUID] = []
        for index in 0..<24 {
            let id = UUID()
            if index.isMultiple(of: 3) {
                try insertUnbackfilled(store, id: id, trackData: Data("not json \(index)".utf8))
                badIds.append(id)
            } else {
                try insertUnbackfilled(store, id: id, trackData: track)
                goodIds.append(id)
            }
        }

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(settledBefore: settledBefore)

        #expect(result == .init(backfilled: 16, unreadable: 8, failedWrites: 0, remaining: 8))
        for id in goodIds {
            #expect(try rawSegments(in: store, id: id) != nil, "good row \(id) was stranded")
        }
        for id in badIds {
            #expect(try rawSegments(in: store, id: id) == nil, "a bad row stays nil, never garbage")
        }
    }

    /// Unreadable rows must not spend the budget, or a few corrupt rows at the front of the
    /// history would consume every run and the good rows behind them would never be reached.
    @Test func unreadableRowsDoNotSpendTheBudget() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        for _ in 0..<3 { try insertUnbackfilled(store, trackData: Data("garbage".utf8)) }
        var goodIds: [UUID] = []
        for _ in 0..<3 { goodIds.append(try insertUnbackfilled(store, trackData: track)) }

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(maxRows: 3, settledBefore: settledBefore)

        #expect(result.backfilled == 3, "the budget buys three FILLED rows, not three examined")
        for id in goodIds {
            #expect(try rawSegments(in: store, id: id) != nil)
        }
    }

    /// The sweep must never touch a row that already has segments — clobbering a real
    /// multi-segment ride with a flattened one would destroy exactly what V6 exists to keep.
    /// A pending row rides along so the test cannot pass against a sweep that does nothing.
    @Test func aRowThatAlreadyHasSegmentsIsLeftByteForByteAlone() async throws {
        let store = try RideStore.inMemory()
        let ride = Ride(kind: .freeRide, startedAt: longAgo,
                        endedAt: longAgo.addingTimeInterval(610),
                        segments: [RideSegment(points: [pt(40.0, 0), pt(40.1, 10)]),
                                   RideSegment(points: [pt(41.0, 600)])],
                        stats: nil, routeId: nil, destinationPlaceId: nil)
        try store.save(ride)
        let before = try #require(try rawSegments(in: store, id: ride.id))
        let pending = try insertUnbackfilled(store,
                                             trackData: try JSONEncoder().encode([pt(42.0, 0)]))

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(settledBefore: settledBefore)

        #expect(result.backfilled == 1, "only the pending row")
        #expect(try rawSegments(in: store, id: ride.id) == before, "existing blob untouched")
        #expect(try segments(in: store, id: ride.id)?.count == 2)
        #expect(try rawSegments(in: store, id: pending) != nil)
    }

    @Test func aSecondRunFindsNothingToDo() async throws {
        let store = try RideStore.inMemory()
        try insertUnbackfilled(store, trackData: try JSONEncoder().encode([pt(40.0, 0)]))
        let backfiller = RideSegmentBackfiller(modelContainer: store.container)

        #expect(await backfiller.backfill(settledBefore: settledBefore).backfilled == 1)
        #expect(await backfiller.backfill(settledBefore: settledBefore) == .init())
    }

    /// A budgeted run leaves the rest pending and the next run finishes the job. This is what
    /// makes a kill mid-sweep cost only the row in flight: a row is pending precisely while its
    /// `segmentsData` is nil, so there is no progress state to lose.
    @Test func aBudgetedRunIsResumable() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        for _ in 0..<10 { try insertUnbackfilled(store, trackData: track) }
        let backfiller = RideSegmentBackfiller(modelContainer: store.container)

        let first = await backfiller.backfill(maxRows: 4, settledBefore: settledBefore)
        #expect(first == .init(backfilled: 4, unreadable: 0, failedWrites: 0, remaining: 6))

        let second = await backfiller.backfill(settledBefore: settledBefore)
        #expect(second == .init(backfilled: 6, unreadable: 0, failedWrites: 0, remaining: 0))
    }

    /// Cancellation is how a starting ride takes the device back (`AuraApp` cancels the sweep
    /// on `isRideActive`). A cancelled run stops rather than grinding through the history under
    /// the rider's ride, and whatever it already wrote stays written — it saves per row, so a
    /// cancelled run is a shorter run, not a lost one.
    ///
    /// The sleep makes this deterministic without racing: `Task.sleep` returns immediately on a
    /// task that is already cancelled and wakes immediately on one cancelled while suspended, so
    /// either ordering reaches `backfill` with cancellation already set. Without it, `cancel()`
    /// races the first rows and the test would pass against a sweep that ignores cancellation.
    ///
    /// **Do not spin here.** This was `while !Task.isCancelled { await Task.yield() }`, which
    /// aborted CI intermittently inside libswift_Concurrency's task allocator ("freed pointer was
    /// not the last allocation") — a hot yield loop in a detached task being cancelled underneath
    /// it. It reproduced only on the macOS 15 runner, never locally on macOS 26, and it killed the
    /// whole test process, so the failure surfaced in whatever unrelated suite was printing.
    /// Isolated by bisecting on CI: 5/5 green with this test disabled, 4/4 green with the other
    /// concurrency test re-enabled, against a ~2/3 baseline failure rate.
    @Test func cancellationStopsTheSweep() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        for _ in 0..<40 { try insertUnbackfilled(store, trackData: track) }
        let backfiller = RideSegmentBackfiller(modelContainer: store.container)
        let settled = settledBefore

        // PROBE 4a: detached task calling the actor, but NOT cancelled. Isolates whether the
        // abort needs cancellation or merely the detached -> @ModelActor hop.
        let task = Task.detached {
            return await backfiller.backfill(settledBefore: settled)
        }
        let result = await task.value

        #expect(result.backfilled == 40, "probe: uncancelled, so it should do all the work")
        #expect(result.remaining == 0)
        let stillPending = try store.container.mainContext.fetchCount(
            FetchDescriptor<RideRecord>(predicate: #Predicate { $0.segmentsData == nil }))
        #expect(stillPending == result.remaining, "the reported remainder matches the store")
    }

    /// Two sweeps racing on the same store — a scene reconnect, or a launch-time sweep still
    /// running when another starts. The nil re-check immediately before the write is what keeps
    /// this from double-filling and double-exporting; without it the two runs report more
    /// backfills than there are rows.
    @Test func concurrentSweepsFillEachRowExactlyOnce() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        for _ in 0..<30 { try insertUnbackfilled(store, trackData: track) }
        let backfiller = RideSegmentBackfiller(modelContainer: store.container)
        let settled = settledBefore

        async let first = backfiller.backfill(settledBefore: settled)
        async let second = backfiller.backfill(settledBefore: settled)
        let results = await [first, second]

        #expect(results.reduce(0) { $0 + $1.backfilled } == 30,
                "each row is filled once across both runs, never twice")
        #expect(results.allSatisfy { $0.remaining == 0 })
    }

    /// End to end on a REAL on-disk store with an externalized track — the shape the sweep only
    /// ever meets in production, and the one the in-memory cases above cannot exercise
    /// (`AuraApp` skips ephemeral stores entirely).
    @Test func backfillsAnExternalizedTrackOnDiskAndReadsBackAsSegments() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try ModelContainer(
            for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: dir.appendingPathComponent("rides.store")))
        let store = RideStore(container: container)

        // 3000 points is ~300 KB of JSON — over CoreData's externalization threshold, so both
        // blobs live in the _EXTERNAL_DATA sidecar rather than inline in the row.
        let track = (0..<3000).map { pt(40.0 + Double($0) * 0.00001, TimeInterval($0)) }
        let id = try insertUnbackfilled(store, trackData: try JSONEncoder().encode(track))

        let result = await RideSegmentBackfiller(modelContainer: container)
            .backfill(settledBefore: settledBefore)

        #expect(result.backfilled == 1)
        #expect(try rawSegments(in: store, id: id) != nil, "the blob was really written")
        let ride = try #require(try RideStore(container: container).ride(id: id))
        #expect(ride.segments == [RideSegment(points: track)])
    }
}
