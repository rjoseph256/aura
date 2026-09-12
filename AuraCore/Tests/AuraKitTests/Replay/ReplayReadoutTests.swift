import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ReplayReadoutTests {
    private let origin = Coordinate(latitude: 40.44, longitude: -79.99)

    private func sample(speed: Double?, distance: Double, seconds: TimeInterval,
                        elevation: Double? = nil, phase: ReplayPhase = .moving) -> ReplaySample {
        ReplaySample(coordinate: origin, bearing: 90, elevation: elevation, speedMetersPerSecond: speed,
                     distanceMeters: distance, seconds: seconds, phase: phase)
    }

    /// 12.3 mi, 1:02:11 total.
    private var timeline: ReplayTimeline {
        let seconds = 3731
        let meters = 12.3 * 1609.344
        let step = meters / Double(seconds)
        let metersPerDegreeLon = 6_371_000 * Double.pi / 180 * cos(origin.latitude * .pi / 180)
        let pts = (0...seconds).map { i in
            TrackPoint(coordinate: Coordinate(latitude: origin.latitude,
                                              longitude: origin.longitude + Double(i) * step / metersPerDegreeLon),
                       elevation: 100, timestamp: Date(timeIntervalSince1970: Double(i)))
        }
        return ReplayTimeline(segments: [RideSegment(points: pts)])
    }

    @Test func imperialStrings() {
        let r = ReplayReadout(sample: sample(speed: 8.9408, distance: 2.4 * 1609.344, seconds: 848, elevation: 95.1),
                              timeline: timeline, units: .imperial)
        #expect(r.speedText == "20" && r.speedUnit == "mph")
        #expect(r.distanceText == "2.4 / 12.3" && r.distanceUnit == "mi")
        #expect(r.timeText == "14:08 / 1:02:11")
        #expect(r.elevationText == "312 ft")
        #expect(r.holdText == nil)
        #expect(r.accessibilityValue == "2.4 miles, 14 minutes")
        #expect(r.accessibilityLabel == "Speed 20 miles per hour. Distance 2.4 of 12.3 miles. Time 14:08 of 1:02:11.")
    }

    @Test func metricStringsAndNilSpeed() {
        let r = ReplayReadout(sample: sample(speed: nil, distance: 3862.4, seconds: 60), timeline: timeline, units: .metric)
        #expect(r.speedText == "—" && r.speedUnit == "km/h")
        #expect(r.distanceText == "3.9 / 19.8" && r.distanceUnit == "km")
        #expect(r.timeText == "1:00 / 1:02:11")
        #expect(r.elevationText == nil)
        #expect(r.accessibilityLabel.hasPrefix("Speed unavailable."))
    }

    @Test func holdLabels() {
        #expect(ReplayReadout.holdLabel(kind: .stopped, seconds: 600) == "Stopped · 10 min")
        #expect(ReplayReadout.holdLabel(kind: .paused, seconds: 45) == "Paused · 45 s")
        #expect(ReplayReadout.holdLabel(kind: .signalLost, seconds: 180) == "No signal · 3 min")
        #expect(ReplayReadout.holdLabel(kind: .paused, seconds: 3720) == "Paused · 62 min")
        let r = ReplayReadout(sample: sample(speed: nil, distance: 100, seconds: 30, phase: .hold(.stopped, seconds: 600)),
                              timeline: timeline, units: .imperial)
        #expect(r.holdText == "Stopped · 10 min")
        #expect(r.accessibilityLabel.hasPrefix("Stopped · 10 min."))
    }

    @Test func subtitleIsThreeValued() {
        func ride(kind: Ride.Kind, name: String?) -> Ride {
            Ride(kind: kind, startedAt: .distantPast, endedAt: .distantPast, segments: [], stats: nil,
                 destinationName: name, routeId: nil, destinationPlaceId: nil)
        }
        #expect(ReplayReadout.subtitle(for: ride(kind: .navigate, name: "Blue Bottle")) == "Blue Bottle")
        #expect(ReplayReadout.subtitle(for: ride(kind: .navigate, name: "")) == "Navigated")
        #expect(ReplayReadout.subtitle(for: ride(kind: .freeRide, name: nil)) == "Explore")
    }
}

struct ReplayBandContentTests {
    private func segment(seconds: Int, start: TimeInterval, elevation: (Int) -> Double?) -> RideSegment {
        let origin = Coordinate(latitude: 40.44, longitude: -79.99)
        let metersPerDegreeLon = 6_371_000 * Double.pi / 180 * cos(origin.latitude * .pi / 180)
        return RideSegment(points: (0...seconds).map { i in
            TrackPoint(coordinate: Coordinate(latitude: origin.latitude,
                                              longitude: origin.longitude + (start + Double(i)) * 6 / metersPerDegreeLon),
                       elevation: elevation(i), timestamp: Date(timeIntervalSince1970: start + Double(i)))
        })
    }
    private func ride(_ segments: [RideSegment], gain: Double) -> Ride {
        let stats = RideStats(distanceMeters: 3600, movingTimeSeconds: 600, averageSpeedMetersPerSecond: 6,
                              maxSpeedMetersPerSecond: 6, elevationGainMeters: gain)
        return Ride(kind: .freeRide, startedAt: .distantPast, endedAt: .distantPast, segments: segments,
                    stats: stats, destinationName: nil, routeId: nil, destinationPlaceId: nil)
    }

    @Test func climbIsASilhouetteOnThePlaybackAxis() {
        let r = ride([segment(seconds: 600, start: 0) { 300 + Double($0) / 5 }], gain: 120)
        let c = ReplayBandContent(ride: r, timeline: ReplayTimeline(segments: r.segments))
        guard case let .silhouette(samples) = c.kind else { Issue.record("expected silhouette"); return }
        #expect(samples.count == ReplayBandContent.sampleCount)
        #expect(samples[0] < samples[samples.count - 1])
    }

    @Test func flatAndMissingElevationAreARail() {
        let flat = ride([segment(seconds: 600, start: 0) { _ in 300 }], gain: 2)
        #expect(ReplayBandContent(ride: flat, timeline: ReplayTimeline(segments: flat.segments)).kind == .rail)
        let none = ride([segment(seconds: 600, start: 0) { _ in nil }], gain: 0)
        #expect(ReplayBandContent(ride: none, timeline: ReplayTimeline(segments: none.segments)).kind == .rail)
    }

    @Test func holdsAreCarriedFromTheTimeline() {
        let r = ride([segment(seconds: 300, start: 0) { _ in 300 }, segment(seconds: 300, start: 600) { _ in 300 }], gain: 0)
        let c = ReplayBandContent(ride: r, timeline: ReplayTimeline(segments: r.segments))
        #expect(c.holds.count == 1 && c.holds[0].kind == .paused && c.holds[0].seconds == 300)
    }
}
