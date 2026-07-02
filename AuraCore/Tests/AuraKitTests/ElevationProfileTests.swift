import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ElevationProfileTests {
    private func pt(_ e: Double?) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 0),
                   elevation: e, timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test func realClimbIsProfile() {
        let k = ElevationProfile.classify(track: [pt(10), pt(40)], gainMeters: 30)
        #expect(k == .profile([10, 40]))
    }

    @Test func belowFloorIsFlat() {
        let k = ElevationProfile.classify(track: [pt(10), pt(13)], gainMeters: 3)
        #expect(k == .flat)
    }

    @Test func gainFloorIsInclusive() {
        let k = ElevationProfile.classify(track: [pt(10), pt(20)], gainMeters: 10)
        #expect(k == .profile([10, 20]))
    }

    @Test func fewerThanTwoSamplesIsUnavailable() {
        // No elevation samples at all (pre-elevation ride), even with a stats gain.
        #expect(ElevationProfile.classify(track: [pt(nil), pt(nil)], gainMeters: 50) == .unavailable)
        // Exactly one non-nil sample.
        #expect(ElevationProfile.classify(track: [pt(10), pt(nil)], gainMeters: 50) == .unavailable)
        // Empty track.
        #expect(ElevationProfile.classify(track: [], gainMeters: 50) == .unavailable)
    }

    @Test func netDownhillIsFlatNotProfile() {
        // Big peak-to-trough range but tiny cumulative climb -> flat (regression guard:
        // no "plunging silhouette + 3 ft climbed" contradiction).
        let k = ElevationProfile.classify(track: [pt(500), pt(505), pt(460)], gainMeters: 5)
        #expect(k == .flat)
    }

    @Test func rollingRideIsProfile() {
        // Small range but real cumulative climb -> profile (no "Mostly flat · 180 ft").
        let k = ElevationProfile.classify(track: [pt(100), pt(103), pt(100), pt(103)], gainMeters: 30)
        #expect(k == .profile([100, 103, 100, 103]))
    }
}
