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
