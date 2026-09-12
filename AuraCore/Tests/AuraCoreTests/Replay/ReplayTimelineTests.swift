import Testing
import Foundation
@testable import AuraCore

struct ReplayTimelineConstructionTests {
    typealias Fixtures = ReplayFixtures

    // §4.1 duration rule
    @Test func underTheFloorClampsToMinPlayback() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 300)])   // 300 s / 120 = 2.5 s → floor
        #expect(abs(t.playbackDuration - 10) < 1e-9)
        #expect(abs(t.rate - 30) < 1e-9)
    }

    @Test func atRateIsExactlyRate() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 2400)])  // 20 min / 120 = 10 s exactly
        #expect(abs(t.playbackDuration - 20) < 1e-9)
        #expect(abs(t.rate - 120) < 1e-9)
    }

    @Test func overTheCapClampsToMaxPlayback() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 7200)])  // 2 h / 120 = 60 s → cap 45
        #expect(abs(t.playbackDuration - 45) < 1e-9)
        #expect(abs(t.rate - 160) < 1e-9)
    }

    @Test func emptyAndSinglePointInteriorSegmentsAddNoHold() {
        let a = Fixtures.straight(seconds: 600)
        let lone = RideSegment(points: [Fixtures.point(Fixtures.origin, at: 700)])
        let b = Fixtures.straight(seconds: 600, start: 800, from: Fixtures.east(4000))
        let with = Fixtures.timeline([a, RideSegment(points: []), lone, b])
        let without = Fixtures.timeline([a, b])
        #expect(with.holds.count == 1)
        #expect(with.holds == without.holds)
        #expect(abs(with.playbackDuration - without.playbackDuration) < 1e-9)
    }

    // §4.2 normalization
    @Test func identicalTimestampsBuildAndAreNotReplayable() {
        let pts = (0...5).map { Fixtures.point(Fixtures.east(Double($0) * 50), at: 0) }
        let t = Fixtures.timeline([RideSegment(points: pts)])
        #expect(t.totalSeconds == 0)
        #expect(t.isReplayable == false)
        #expect(t.playbackDuration.isFinite)
        for k in 0...20 {
            let s = t.sample(at: Double(k) / 20)
            #expect(s.coordinate.latitude.isFinite && s.coordinate.longitude.isFinite)
            #expect(s.distanceMeters.isFinite && s.seconds.isFinite)
        }
    }

    @Test func backwardsStampIsZeroWidthAndLengthensTheNextLeg() {
        var pts = Fixtures.straight(seconds: 200).points
        pts[100] = Fixtures.point(pts[100].coordinate, at: 98)       // stamped 1 s BEFORE its predecessor
        let t = Fixtures.timeline([RideSegment(points: pts)])
        // Leg 99→100 normalizes to 0 s (keeps its 6 m); leg 100→101 is 101 − 98 = 3 s at 2 m/s.
        #expect(abs(t.totalSeconds - 201) < 1e-9)
        #expect(t.holds.isEmpty)
        #expect(t.rate > 0)
        var lastDistance = -1.0, lastSeconds = -1.0
        for k in 0...200 {
            let s = t.sample(at: Double(k) / 200)
            #expect(s.distanceMeters >= lastDistance - 1e-9)
            #expect(s.seconds >= lastSeconds - 1e-9)
            lastDistance = s.distanceMeters; lastSeconds = s.seconds
        }
        #expect(abs(t.totalDistanceMeters - 1200) < 0.01)              // the zero-width leg kept its distance
    }

    // §4.11 replayable
    @Test func replayableNeedsSixtySecondsAndTwoHundredMeters() {
        #expect(Fixtures.timeline([Fixtures.straight(seconds: 59, speed: 6)]).isReplayable == false)
        #expect(Fixtures.timeline([Fixtures.straight(seconds: 120, speed: 1)]).isReplayable == false)
        #expect(Fixtures.timeline([Fixtures.straight(seconds: 60, speed: 4)]).isReplayable == true)
        #expect(Fixtures.timeline([]).isReplayable == false)
        #expect(Fixtures.timeline([RideSegment(points: [Fixtures.point(Fixtures.origin, at: 0)])]).isReplayable == false)
    }

    @Test func totalsAreTheSegmentSums() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 100),
                                   Fixtures.straight(seconds: 50, start: 400, from: Fixtures.east(2000))])
        #expect(abs(t.totalSeconds - 150) < 1e-9)
        #expect(abs(t.totalDistanceMeters - 900) < 0.01)
        #expect(t.drawableLines.count == 2)
        #expect(t.drawableLines[0].count == 101 && t.drawableLines[1].count == 51)
    }

    @Test func emptyTimelineIsTotal() {
        let t = Fixtures.timeline([])
        #expect(t.drawableLines.isEmpty && t.holds.isEmpty && t.events == [0, 1])
        #expect(t.sample(at: 0.5).phase == .ended)
        #expect(t.profile(sampleCount: 10) == nil)
    }
}

struct ReplayTimelineSamplingTests {
    typealias Fixtures = ReplayFixtures

    @Test func fractionZeroIsTheFirstPointMovingWithNoSpeed() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 600)])
        let s = t.sample(at: 0)
        #expect(s.coordinate == Fixtures.origin)
        #expect(s.distanceMeters == 0 && s.seconds == 0)
        #expect(s.phase == .moving)
        #expect(s.speedMetersPerSecond == nil)
    }

    @Test func midpointOfAStraightRideIsHalfway() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 600, speed: 6)])
        let s = t.sample(at: 0.5)
        #expect(abs(s.seconds - 300) < 1e-6)
        #expect(abs(s.distanceMeters - 1800) < 0.01)
        #expect(abs(s.coordinate.longitude - Fixtures.east(1800).longitude) < 1e-7)
        #expect(s.phase == .moving)
    }

    // §4.7 totals agree with RideStats
    @Test func fractionOneIsEndedWithTheStatsTotals() {
        let a = Fixtures.straight(seconds: 600)
        let stopAt = Fixtures.east(3600)
        var b = Fixtures.straight(seconds: 200, start: 900, from: stopAt).points
        b.append(contentsOf: Fixtures.jitter(seconds: 90, at: Fixtures.east(1200, from: stopAt), start: 1101))
        let segments = [a, RideSegment(points: b), Fixtures.straight(seconds: 100, start: 1400, from: Fixtures.east(6000))]
        let t = Fixtures.timeline(segments)
        let stats = RideStatsCalculator.stats(segments: segments)
        let end = t.sample(at: 1)
        #expect(end.phase == .ended)
        #expect(abs(end.distanceMeters - stats.distanceMeters) < 1e-6)
        #expect(abs(end.seconds - t.totalSeconds) < 1e-9)
        #expect(abs(t.totalSeconds - 990) < 1e-9)                    // 600 + (200 + 90) + 100
        #expect(end.coordinate == segments[2].points[100].coordinate)
    }

    @Test func distanceAndSecondsAreMonotonicAcrossAPause() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 300),
                                   Fixtures.straight(seconds: 300, start: 900, from: Fixtures.east(1800))])
        var d = -1.0, s = -1.0
        for k in 0...400 {
            let sample = t.sample(at: Double(k) / 400)
            #expect(sample.distanceMeters >= d - 1e-9); #expect(sample.seconds >= s - 1e-9)
            d = sample.distanceMeters; s = sample.seconds
        }
    }

    // §4.5 never a chord across a pause gap: the second segment starts 1 km NORTH, so any
    // interpolation across the gap has a latitude strictly between the two.
    @Test func aPauseGapIsNeverChorded() {
        let a = Fixtures.straight(seconds: 300)
        let bStart = Fixtures.north(1000, from: Fixtures.east(1800))
        let b = Fixtures.straight(seconds: 300, start: 900, from: bStart)
        let t = Fixtures.timeline([a, b])
        for k in 0...2000 {
            let lat = t.sample(at: Double(k) / 2000).coordinate.latitude
            let inside = lat > Fixtures.origin.latitude + 1e-9 && lat < bStart.latitude - 1e-9
            #expect(!inside, "chord sampled at \(k)/2000")
        }
    }

    // §4.8 bearing
    @Test func bearingIsTheCourseAndHoldsAcrossCoincidentPoints() {
        var pts = Fixtures.straight(seconds: 100).points
        pts[50] = Fixtures.point(pts[49].coordinate, at: 50)          // coincident with its predecessor
        let t = Fixtures.timeline([RideSegment(points: pts)])
        #expect(abs((t.sample(at: 0.3).bearing ?? 0) - 90) < 0.5)
        #expect(abs((t.sample(at: 0.495).bearing ?? 0) - 90) < 0.5)
    }

    @Test func bearingIsNilBeforeTheFirstNonCoincidentLeg() {
        var pts = Fixtures.jitter(seconds: 10, at: Fixtures.origin, start: 0)
        pts.append(contentsOf: Fixtures.straight(seconds: 100, start: 10, from: Fixtures.origin).points)
        let t = Fixtures.timeline([RideSegment(points: pts)])
        #expect(t.sample(at: 0.001).bearing == nil)
        #expect(t.sample(at: 0.9).bearing != nil)
    }

    /// D9: the rendered course is over the window, so a zig-zag track reads its net heading,
    /// not a 60°/120° staircase at 120 changes per second.
    @Test func bearingIsSmoothOverTheWindow() {
        let t = Fixtures.timeline([Fixtures.zigzag(seconds: 300)])
        for k in 10...99 {
            let b = t.sample(at: Double(k) / 100).bearing ?? 0
            #expect(abs(b - 90) < 12, "bearing \(b) at \(k)/100")
        }
    }

    @Test func elevationInterpolatesAndBridgesANil() {
        let seg = Fixtures.straight(seconds: 100, elevation: { i in i == 50 ? nil : Double(300 + i) })
        let t = Fixtures.timeline([seg])
        #expect(abs((t.sample(at: 0.25).elevation ?? 0) - 325) < 0.01)
        #expect(t.sample(at: 0.495).elevation == 349)                // inside leg 49→50, end nil
    }

    @Test func endedSampleHasNoBearingOrSpeed() {
        let end = Fixtures.timeline([Fixtures.straight(seconds: 600)]).sample(at: 1)
        #expect(end.bearing == nil && end.speedMetersPerSecond == nil)
    }
}
