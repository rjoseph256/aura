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
/// resumable, and it cannot throw into the caller.
@MainActor
@Suite("Ride segment backfill", .swiftDataSerialized)
struct RideSegmentBackfillTests {
    private func pt(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: nil,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    /// Inserts a row in the pre-V6 shape: a flat track and no segmented blob.
    @discardableResult
    private func insertUnbackfilled(_ store: RideStore, id: UUID = UUID(),
                                    trackData: Data) throws -> UUID {
        store.container.mainContext.insert(RideRecord(
            id: id, kindRaw: "freeRide", startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 2000),
            trackData: trackData, segmentsData: nil, statsData: nil,
            routeId: nil, destinationPlaceId: nil))
        try store.container.mainContext.save()
        return id
    }

    private func segments(in store: RideStore, id: UUID) throws -> [RideSegment]? {
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        let record = try #require(try store.container.mainContext.fetch(descriptor).first)
        guard let data = record.segmentsData else { return nil }
        return try JSONDecoder().decode([RideSegment].self, from: data)
    }

    @Test func anUnbackfilledRowGainsOneSegmentCarryingEveryPoint() async throws {
        let store = try RideStore.inMemory()
        let track = [pt(40.0, 0), pt(40.1, 10), pt(40.2, 20)]
        let id = try insertUnbackfilled(store, trackData: try JSONEncoder().encode(track))

        let result = await RideSegmentBackfiller(modelContainer: store.container).backfill()

        #expect(result == .init(backfilled: 1, skipped: 0, remaining: 0))
        #expect(try segments(in: store, id: id) == [RideSegment(points: track)])
    }

    /// `Ride`'s canonical rule: no points is ZERO segments. `Data()` is what CloudKit
    /// materializes for a record that never carried the key, and an encoded `[]` is what a
    /// fix-less ride wrote — both are empty rides, neither is corrupt.
    @Test func emptyTracksBackfillToZeroSegments() async throws {
        let store = try RideStore.inMemory()
        let encodedEmpty = try insertUnbackfilled(store, trackData: try JSONEncoder().encode([TrackPoint]()))
        let noBlob = try insertUnbackfilled(store, trackData: Data())

        let result = await RideSegmentBackfiller(modelContainer: store.container).backfill()

        #expect(result.backfilled == 2)
        #expect(result.skipped == 0)
        #expect(try segments(in: store, id: encodedEmpty) == [])
        #expect(try segments(in: store, id: noBlob) == [])
    }

    /// Unreadable rows are counted and stepped over. This is the shape that broke the
    /// offset-paged design reviewed out of revision 1: bad rows never leave the pending set,
    /// so they have to interleave with good ones across several batches without the sweep
    /// losing its place. Hence 24 rows, every third one corrupt, and a batch size of 4.
    @Test func undecodableRowsAreSkippedWithoutStrandingTheRest() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        var goodIds: [UUID] = []
        var badIds: [UUID] = []
        for index in 0..<24 {
            let id = UUID()
            if index % 3 == 0 {
                try insertUnbackfilled(store, id: id, trackData: Data("not json \(index)".utf8))
                badIds.append(id)
            } else {
                try insertUnbackfilled(store, id: id, trackData: track)
                goodIds.append(id)
            }
        }

        let result = await RideSegmentBackfiller(modelContainer: store.container)
            .backfill(batchSize: 4)

        #expect(result == .init(backfilled: 16, skipped: 8, remaining: 0))
        for id in goodIds {
            #expect(try segments(in: store, id: id)?.count == 1, "good row \(id) was stranded")
        }
        for id in badIds {
            #expect(try segments(in: store, id: id) == nil, "a bad row stays nil, never garbage")
        }
    }

    /// The sweep must never touch a row that already has segments — clobbering a real
    /// multi-segment ride with a flattened one would destroy exactly what V6 exists to keep.
    @Test func aRowThatAlreadyHasSegmentsIsLeftAlone() async throws {
        let store = try RideStore.inMemory()
        let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                        endedAt: Date(timeIntervalSince1970: 610),
                        segments: [RideSegment(points: [pt(40.0, 0), pt(40.1, 10)]),
                                   RideSegment(points: [pt(41.0, 600)])],
                        stats: nil, routeId: nil, destinationPlaceId: nil)
        try store.save(ride)

        let result = await RideSegmentBackfiller(modelContainer: store.container).backfill()

        #expect(result == .init(backfilled: 0, skipped: 0, remaining: 0))
        #expect(try segments(in: store, id: ride.id)?.count == 2)
    }

    @Test func aSecondRunFindsNothingToDo() async throws {
        let store = try RideStore.inMemory()
        try insertUnbackfilled(store, trackData: try JSONEncoder().encode([pt(40.0, 0)]))
        let backfiller = RideSegmentBackfiller(modelContainer: store.container)

        #expect(await backfiller.backfill().backfilled == 1)
        #expect(await backfiller.backfill() == .init(backfilled: 0, skipped: 0, remaining: 0))
    }

    /// A budgeted run leaves the rest pending and the next run finishes the job. This is what
    /// makes a kill mid-sweep cost only the current batch: a row is pending precisely while
    /// its `segmentsData` is nil, so there is no progress state to lose.
    @Test func aBudgetedRunIsResumable() async throws {
        let store = try RideStore.inMemory()
        let track = try JSONEncoder().encode([pt(40.0, 0), pt(40.1, 10)])
        for _ in 0..<10 { try insertUnbackfilled(store, trackData: track) }
        let backfiller = RideSegmentBackfiller(modelContainer: store.container)

        let first = await backfiller.backfill(batchSize: 2, maxRows: 4)
        #expect(first == .init(backfilled: 4, skipped: 0, remaining: 6))

        let second = await backfiller.backfill(batchSize: 2)
        #expect(second == .init(backfilled: 6, skipped: 0, remaining: 0))
    }

    /// End to end: a backfilled row reads back through the production path as real segments,
    /// from a store opened fresh on the same container (which is what the next launch does).
    @Test func backfilledRowsReadAsSegmentsThroughTheStore() async throws {
        let store = try RideStore.inMemory()
        let track = [pt(40.0, 0), pt(40.1, 10)]
        let id = try insertUnbackfilled(store, trackData: try JSONEncoder().encode(track))

        await RideSegmentBackfiller(modelContainer: store.container).backfill()

        let reopened = RideStore(container: store.container)
        let ride = try #require(try reopened.ride(id: id))
        #expect(ride.segments == [RideSegment(points: track)])
    }
}
