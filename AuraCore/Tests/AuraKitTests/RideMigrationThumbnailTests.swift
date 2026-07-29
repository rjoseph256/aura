import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Covers `RideMigrationPlan.thumbnailData(forTrack:rideID:decoder:encoder:)`, the V1→V2
/// backfill helper, for the three outcomes that do **not** assert.
///
/// The two loud paths are deliberately absent. Both call `assertionFailure`, which traps in
/// DEBUG, and `swift test` builds DEBUG — a test that drove either would abort the suite rather
/// than fail an expectation. The sibling `statsData` assert is untested for the same reason.
///
/// No `.swiftDataSerialized` trait: this suite builds no container and materializes no schema,
/// so it is outside the ROH-65 entity-cache hazard that gate exists for.
@Suite("V1→V2 thumbnail backfill")
struct RideMigrationThumbnailTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func track(_ count: Int) -> [TrackPoint] {
        (0..<count).map {
            TrackPoint(coordinate: Coordinate(latitude: Double($0) * 0.001,
                                              longitude: Double($0) * 0.001),
                       elevation: nil,
                       timestamp: Date(timeIntervalSince1970: TimeInterval($0)))
        }
    }

    /// The load-bearing guarantee. `trackData`'s default is `Data()` — what CloudKit
    /// materializes for a record that never carried the key — and `JSONDecoder` throws on it.
    /// That is an empty ride, not corruption, so it must return nil **without** asserting.
    /// If this regresses, DEBUG builds trap at container-open on launch.
    @Test func emptyBlobIsAnEmptyRideNotCorruption() {
        #expect(RideMigrationPlan.thumbnailData(
            forTrack: Data(), rideID: UUID(), decoder: decoder, encoder: encoder) == nil)
    }

    /// The happy path: a real track round-trips to a decodable polyline of at least two points.
    @Test func trackWithEnoughPointsProducesADecodableThumbnail() throws {
        let data = try encoder.encode(track(200))
        let thumb = try #require(RideMigrationPlan.thumbnailData(
            forTrack: data, rideID: UUID(), decoder: decoder, encoder: encoder))
        let coords = try decoder.decode([Coordinate].self, from: thumb)
        #expect(coords.count >= 2)
    }

    /// A ride with fewer than two points has no polyline to draw. Silent, like the empty blob.
    /// This is the path `RideMigrationTests.swift:34`'s free-ride row already takes — it encodes
    /// `[TrackPoint]()` as the two bytes `[]`, which is non-empty and decodes to zero points.
    @Test(arguments: [0, 1]) func trackTooShortToDrawIsSilent(count: Int) throws {
        let data = try encoder.encode(track(count))
        #expect(RideMigrationPlan.thumbnailData(
            forTrack: data, rideID: UUID(), decoder: decoder, encoder: encoder) == nil)
    }
}
