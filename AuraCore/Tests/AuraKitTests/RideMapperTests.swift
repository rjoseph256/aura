import XCTest
import Testing
import AuraCore
@testable import AuraKit

final class RideMapperTests: XCTestCase {
    func test_ride_roundTripsThroughRecord() throws {
        let ride = Ride(
            kind: .navigate,
            startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 2000),
            track: [TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0), elevation: 250,
                               timestamp: Date(timeIntervalSince1970: 1000))],
            stats: RideStats(distanceMeters: 1234, movingTimeSeconds: 600,
                             averageSpeedMetersPerSecond: 2.0, maxSpeedMetersPerSecond: 6.0,
                             elevationGainMeters: 42),
            destinationName: "The Church Brew Works",
            routeId: UUID(),
            destinationPlaceId: UUID())
        let record = try RideMapper.record(from: ride)
        let back = try RideMapper.ride(from: record)
        XCTAssertEqual(back, ride)
        XCTAssertEqual(back.destinationName, "The Church Brew Works")
    }

    @MainActor
    func test_recorder_end_carriesDestinationName() {
        let recorder = RideRecorder(kind: .navigate)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        let ride = recorder.end(at: Date(timeIntervalSince1970: 100), destinationName: "Frick Park")
        XCTAssertEqual(ride.destinationName, "Frick Park")
        XCTAssertEqual(ride.kind, .navigate)
    }

    func test_freeRide_withNilStats_roundTrips() throws {
        let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
                        track: [], stats: nil, routeId: nil, destinationPlaceId: nil)
        XCTAssertEqual(try RideMapper.ride(from: RideMapper.record(from: ride)), ride)
    }

    func test_record_populatesDenormalizedColumns() throws {
        let ride = Ride(
            kind: .navigate, startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 100),
            track: [TrackPoint(coordinate: .init(latitude: 1, longitude: 1), elevation: nil,
                               timestamp: Date(timeIntervalSince1970: 0)),
                    TrackPoint(coordinate: .init(latitude: 2, longitude: 2), elevation: nil,
                               timestamp: Date(timeIntervalSince1970: 50))],
            stats: RideStats(distanceMeters: 1234, movingTimeSeconds: 600,
                             averageSpeedMetersPerSecond: 2, maxSpeedMetersPerSecond: 6,
                             elevationGainMeters: 42),
            destinationName: "Frick Park", routeId: nil, destinationPlaceId: nil)
        let record = try RideMapper.record(from: ride)
        XCTAssertEqual(record.distanceMeters, 1234, accuracy: 0.001)
        XCTAssertEqual(record.movingTimeSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(record.elevationGainMeters, 42, accuracy: 0.001)
        XCTAssertNotNil(record.thumbnailData)
    }

    func test_summary_mapsColumnsWithoutTrack() throws {
        let ride = Ride(
            kind: .freeRide, startedAt: Date(timeIntervalSince1970: 10), endedAt: nil,
            track: [], stats: nil, routeId: nil, destinationPlaceId: nil)
        let summary = RideMapper.summary(from: try RideMapper.record(from: ride))
        XCTAssertEqual(summary.id, ride.id)
        XCTAssertEqual(summary.kind, .freeRide)
        XCTAssertFalse(summary.hasStats)
        XCTAssertEqual(summary.distanceMeters, 0, accuracy: 0.001)
        XCTAssertTrue(summary.thumbnailCoordinates.isEmpty)
    }
}

/// Swift Testing companion to `RideMapperTests` above. `multiSegmentRideFlattensThroughTheStoreUntilV6`
/// needs Swift Testing's prefix-free test discovery — XCTest only picks up methods whose
/// selector literally starts with `test`, which would silently drop a test named to match the
/// `RideMapper.record(from:)` doc comment's back-tick reference verbatim. It builds a real
/// `RideStore`, so it takes the same `.swiftDataSerialized` + `@MainActor` shape as
/// `RideStoreSummaryTests`/`GoldenRidePlaybackTests`.
@MainActor
@Suite(.swiftDataSerialized)
struct RideMapperStoreRoundTripTests {
    private func pt(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: nil,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    /// Pins the KNOWN-WRONG-FOR-NOW behavior documented at `RideMapper.record(from:)`:
    /// `record(from:)` flattens `ride.flattenedPoints` into a single `trackData` blob, and
    /// `ride(from:)` decodes that blob back through the single-segment `track:` convenience
    /// initializer — so a multi-segment ride that round-trips through a real `RideStore`
    /// comes back with its pause boundary collapsed to one segment, even though every point
    /// survives, in order. This is INTENDED for Slice A (out of scope per the segmented-rides
    /// spec); a future schema-V6 pass that adds a segmented `segmentsData` blob is expected to
    /// flip this test's first assertion to `segments.count == 2`, not to keep it green as-is.
    @Test func multiSegmentRideFlattensThroughTheStoreUntilV6() throws {
        let segmentA = [pt(40.0, 0), pt(40.1, 10)]
        let segmentB = [pt(41.0, 600), pt(41.1, 610)]
        let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                        endedAt: Date(timeIntervalSince1970: 610),
                        segments: [RideSegment(points: segmentA), RideSegment(points: segmentB)],
                        stats: nil, routeId: nil, destinationPlaceId: nil)
        #expect(ride.segments.count == 2, "sanity: the ride starts as two real segments")

        let store = try RideStore.inMemory()
        try store.save(ride)
        let back = try #require(try store.ride(id: ride.id))

        #expect(back.segments.count == 1, "known-wrong-for-now: the store collapses the pause boundary")
        #expect(back.flattenedPoints == segmentA + segmentB, "but every point survives, in order")
    }
}
