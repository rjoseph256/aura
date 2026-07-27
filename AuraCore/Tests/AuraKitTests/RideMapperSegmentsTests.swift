import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

/// Spec D2's dual-write, from the mapper's side: V6 writes the segmented blob *and* the flat
/// one, and the read prefers segments while never letting a bad blob take a ride — or the
/// whole History fetch — down with it.
@MainActor
@Suite("RideMapper segments (V6)", .swiftDataSerialized)
struct RideMapperSegmentsTests {
    private func pt(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: nil,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    private func twoSegmentRide(pausedSeconds: TimeInterval = 0) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
             endedAt: Date(timeIntervalSince1970: 610),
             segments: [RideSegment(points: [pt(40.0, 0), pt(40.1, 10)]),
                        RideSegment(points: [pt(41.0, 600), pt(41.1, 610)])],
             stats: nil, pausedSeconds: pausedSeconds,
             routeId: nil, destinationPlaceId: nil)
    }

    // MARK: write

    @Test func recordDualWritesTheSegmentedAndTheFlatBlob() throws {
        let ride = twoSegmentRide()
        let record = try RideMapper.record(from: ride)

        let segmentsData = try #require(record.segmentsData)
        #expect(try JSONDecoder().decode([RideSegment].self, from: segmentsData) == ride.segments)
        // The flat blob stays flat and complete: a V5 device reading the same CloudKit
        // record must still see a track, just without the pause boundary (spec D2/D3).
        #expect(try JSONDecoder().decode([TrackPoint].self, from: record.trackData)
                == ride.flattenedPoints)
    }

    @Test func recordCarriesPausedSecondsIntoItsOwnColumn() throws {
        let record = try RideMapper.record(from: twoSegmentRide(pausedSeconds: 305))
        #expect(record.pausedSeconds == 305)
    }

    // MARK: read

    @Test func readPrefersSegmentsDataOverTheFlatTrack() throws {
        // Deliberately disagreeing blobs: only a read that prefers `segmentsData` can pass.
        let ride = twoSegmentRide()
        let record = try RideMapper.record(from: ride)
        record.trackData = try JSONEncoder().encode([pt(9.9, 0)])

        let back = try RideMapper.ride(from: record)
        #expect(back.segments == ride.segments)
    }

    @Test func readWrapsTheFlatTrackWhenSegmentsDataIsAbsent() throws {
        // Exactly the shape of a row synced down from a V5 device: no segmented blob at all.
        let ride = twoSegmentRide()
        let record = try RideMapper.record(from: ride)
        record.segmentsData = nil

        let back = try RideMapper.ride(from: record)
        #expect(back.segments.count == 1, "a flat track is one segment")
        #expect(back.flattenedPoints == ride.flattenedPoints)
    }

    /// `RideMapper.ride` is called inside a `.map` in `RideStore.allRides()`, so a throw here
    /// is not one bad ride — it is an empty History for every ride the rider has.
    @Test func readFallsBackToTheFlatTrackWhenSegmentsDataIsCorrupt() throws {
        let ride = twoSegmentRide()
        let record = try RideMapper.record(from: ride)
        record.segmentsData = Data("{ this is not a segment array".utf8)

        let back = try RideMapper.ride(from: record)
        #expect(back.segments.count == 1, "degraded to the flat track, not thrown")
        #expect(back.flattenedPoints == ride.flattenedPoints, "and no point is lost")
    }

    @Test func oneCorruptSegmentsBlobDoesNotEmptyTheWholeHistoryFetch() throws {
        let store = try RideStore.inMemory()
        let healthy = twoSegmentRide()
        try store.save(healthy)

        let broken = twoSegmentRide()
        let brokenRecord = try RideMapper.record(from: broken)
        brokenRecord.segmentsData = Data([0x00, 0x01, 0x02])
        store.container.mainContext.insert(brokenRecord)
        try store.container.mainContext.save()

        let all = try store.allRides()
        #expect(all.count == 2, "the corrupt row degrades; it does not take History down")
        #expect(all.first { $0.id == healthy.id }?.segments.count == 2)
        #expect(all.first { $0.id == broken.id }?.segments.count == 1)
    }

    /// The shape a CloudKit record materialized without either key carries: no segmented blob
    /// and an EMPTY flat blob, which `JSONDecoder` throws on. Read as an empty ride, because a
    /// throw here empties History for every ride the rider owns, not just this one.
    @Test func aRecordWithNoBlobsAtAllReadsAsAnEmptyRideRatherThanThrowing() throws {
        let record = try RideMapper.record(from: twoSegmentRide())
        record.segmentsData = nil
        record.trackData = Data()

        let back = try RideMapper.ride(from: record)
        #expect(back.segments.isEmpty, "zero points is zero segments, not one empty one")
    }

    // MARK: summary

    @Test func summaryCarriesPausedSeconds() throws {
        let record = try RideMapper.record(from: twoSegmentRide(pausedSeconds: 42))
        #expect(RideMapper.summary(from: record).pausedSeconds == 42)
    }
}
