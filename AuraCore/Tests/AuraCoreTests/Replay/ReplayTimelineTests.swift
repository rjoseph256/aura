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

struct ReplayTimelineHoldTests {
    typealias Fixtures = ReplayFixtures

    private func twoSegments(gap: TimeInterval) -> ReplayTimeline {
        Fixtures.timeline([Fixtures.straight(seconds: 600),
                           Fixtures.straight(seconds: 600, start: 600 + gap, from: Fixtures.east(3600))])
    }

    @Test func aTenMinutePauseIsOneHoldCappedByTheShare() {
        let t = twoSegments(gap: 600)                        // moving 1200 s → 10 s playback, rate 120
        #expect(t.holds.count == 1)
        let hold = t.holds[0]
        #expect(hold.kind == .paused && hold.seconds == 600)
        // 600 / 120 = 5 → maxHold 4 → share cap 0.25 × 10 = 2.5.
        let width = (hold.range.upperBound - hold.range.lowerBound) * t.playbackDuration
        #expect(abs(width - 2.5) < 1e-9)
        #expect(abs(t.playbackDuration - 12.5) < 1e-9)
    }

    @Test func aThreeSecondGapIsNotAPause() {
        let t = twoSegments(gap: 3)
        #expect(t.holds.isEmpty)
        #expect(abs(t.playbackDuration - 10) < 1e-9)
    }

    // §4.3 the sample inside a hold, and at its exclusive end, for many gap lengths
    @Test func holdRangesAreHalfOpenForEveryGap() {
        for gap in stride(from: 60.0, through: 1200, by: 10) {
            let t = twoSegments(gap: gap)
            let hold = t.holds[0]
            for f in [hold.range.lowerBound, (hold.range.lowerBound + hold.range.upperBound) / 2] {
                let s = t.sample(at: f)
                #expect(s.phase == .hold(.paused, seconds: gap), "gap \(gap) at \(f)")
                #expect(abs(s.coordinate.longitude - Fixtures.east(3600).longitude) < 1e-9)
                #expect(s.speedMetersPerSecond == nil && s.bearing == nil)
                #expect(abs(s.distanceMeters - 3600) < 0.01)
                #expect(abs(s.seconds - 600) < 1e-9)
            }
            let after = t.sample(at: hold.range.upperBound)
            #expect(after.phase == .moving, "gap \(gap): hold's exclusive end is inside it")
        }
    }

    @Test func noFractionOutsideAHoldRangeIsAHold() {
        let t = twoSegments(gap: 600)
        let hold = t.holds[0]
        for k in 0...500 {
            let f = Double(k) / 500
            let isHold: Bool
            if case .hold = t.sample(at: f).phase { isHold = true } else { isHold = false }
            #expect(isHold == hold.range.contains(f), "fraction \(f)")
        }
    }

    // §4.4 stationary runs and lost signal
    @Test func sixtySecondsOfJitterIsOneStoppedHold() {
        var pts = Fixtures.straight(seconds: 300).points
        let stop = pts[300].coordinate
        pts.append(contentsOf: Fixtures.jitter(seconds: 60, at: stop, start: 301))
        pts.append(contentsOf: Fixtures.straight(seconds: 300, start: 361, from: stop).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        #expect(t.holds.count == 1)
        #expect(t.holds[0].kind == .stopped)
        #expect(abs(t.holds[0].seconds - 60) < 1e-9)                   // 59 jitter legs + the leg into the run
        let inside = t.sample(at: (t.holds[0].range.lowerBound + t.holds[0].range.upperBound) / 2)
        #expect(abs(inside.coordinate.longitude - stop.longitude) < 1e-7)
        #expect(inside.seconds > 300 && inside.seconds < 362)          // in-segment holds advance the clock
    }

    @Test func thirtySecondsOfJitterIsNoHold() {
        var pts = Fixtures.straight(seconds: 300).points
        let stop = pts[300].coordinate
        pts.append(contentsOf: Fixtures.jitter(seconds: 30, at: stop, start: 301))
        pts.append(contentsOf: Fixtures.straight(seconds: 300, start: 331, from: stop).points.dropFirst())
        #expect(Fixtures.timeline([RideSegment(points: pts)]).holds.isEmpty)
    }

    @Test func twoRunsSeparatedByAMovingLegAreTwoHolds() {
        var pts = Fixtures.straight(seconds: 100).points
        let a = pts[100].coordinate
        pts.append(contentsOf: Fixtures.jitter(seconds: 50, at: a, start: 101))
        pts.append(contentsOf: Fixtures.straight(seconds: 100, start: 151, from: a).points.dropFirst())
        let b = Fixtures.east(600, from: a)
        pts.append(contentsOf: Fixtures.jitter(seconds: 50, at: b, start: 252))
        pts.append(contentsOf: Fixtures.straight(seconds: 100, start: 302, from: b).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        #expect(t.holds.count == 2)
        #expect(t.holds.allSatisfy { $0.kind == .stopped })
    }

    @Test func aLongLegIsSignalLostWhenItMovesAndStoppedWhenItDoesNot() {
        var far = Fixtures.straight(seconds: 100).points
        far.append(Fixtures.point(Fixtures.east(1400), at: 220))                       // 120 s, 800 m
        far.append(contentsOf: Fixtures.straight(seconds: 100, start: 221, from: Fixtures.east(1400)).points.dropFirst())
        let lost = Fixtures.timeline([RideSegment(points: far)])
        #expect(lost.holds.count == 1 && lost.holds[0].kind == .signalLost)

        var near = Fixtures.straight(seconds: 100).points
        near.append(Fixtures.point(Fixtures.east(610), at: 220))                       // 120 s, 10 m
        near.append(contentsOf: Fixtures.straight(seconds: 100, start: 221, from: Fixtures.east(610)).points.dropFirst())
        let stopped = Fixtures.timeline([RideSegment(points: near)])
        #expect(stopped.holds.count == 1 && stopped.holds[0].kind == .stopped)
    }

    // §4.5 the lost leg's interior is never sampled
    @Test func aLostSignalLegIsAJumpNotAGlide() {
        var pts = Fixtures.straight(seconds: 100).points
        let from = pts[100].coordinate, to = Fixtures.east(1400)
        pts.append(Fixtures.point(to, at: 220))
        pts.append(contentsOf: Fixtures.straight(seconds: 100, start: 221, from: to).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        for k in 0...2000 {
            let lon = t.sample(at: Double(k) / 2000).coordinate.longitude
            let strictlyInside = lon > from.longitude + 1e-9 && lon < to.longitude - 1e-9
            #expect(!strictlyInside, "sampled inside the lost leg at \(k)/2000")
        }
    }

    // A zero-width leg with a real displacement is not folded into a stop.
    @Test func aTeleportWithNoTimeBreaksAStationaryRun() {
        var pts = Fixtures.straight(seconds: 100).points
        let a = pts[100].coordinate
        pts.append(contentsOf: Fixtures.jitter(seconds: 40, at: a, start: 101))
        pts.append(Fixtures.point(Fixtures.east(300, from: a), at: 140))               // same stamp, 300 m away
        pts.append(contentsOf: Fixtures.jitter(seconds: 40, at: Fixtures.east(300, from: a), start: 141))
        pts.append(contentsOf: Fixtures.straight(seconds: 100, start: 181, from: Fixtures.east(300, from: a)).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        #expect(t.holds.isEmpty)                                       // two 40 s runs, neither ≥ 45 s
    }

    // §4.1 the share cap with many pauses
    @Test func twelvePausesAreCappedAtAQuarterOfTheMovingPlayback() {
        var segments: [RideSegment] = []
        var start: TimeInterval = 0
        var from = Fixtures.origin
        for _ in 0..<13 {
            segments.append(Fixtures.straight(seconds: 100, start: start, from: from))
            start += 130
            from = Fixtures.east(700, from: from)
        }
        let t = Fixtures.timeline(segments)
        #expect(t.holds.count == 12)
        let movingPlayback = 1300.0 / 120
        let holdTotal = t.holds.reduce(0.0) { $0 + ($1.range.upperBound - $1.range.lowerBound) } * t.playbackDuration
        #expect(abs(holdTotal - 0.25 * movingPlayback) < 1e-9)
    }
}

struct ReplayTimelineSpeedProfileEventTests {
    typealias Fixtures = ReplayFixtures

    // §4.6 speed
    @Test func quarterCircleReadsTheArcSpeedNotTheChord() {
        let t = Fixtures.timeline([Fixtures.quarterCircle(radius: 100, speed: 6)])
        for k in 5...19 {
            let s = t.sample(at: Double(k) / 20)
            #expect(s.seconds > t.speedWindowSeconds)
            #expect(abs((s.speedMetersPerSecond ?? 0) - 6) < 0.005, "at \(k)/20")
        }
    }

    @Test func speedIsNilAtStartInsideAHoldAndForAZeroSpan() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 600),
                                   Fixtures.straight(seconds: 600, start: 1200, from: Fixtures.east(3600))])
        #expect(t.sample(at: 0).speedMetersPerSecond == nil)
        let mid = (t.holds[0].range.lowerBound + t.holds[0].range.upperBound) / 2
        #expect(t.sample(at: mid).speedMetersPerSecond == nil)
        let same = RideSegment(points: (0...3).map { Fixtures.point(Fixtures.east(Double($0) * 10), at: 0) })
        #expect(Fixtures.timeline([same]).sample(at: 0.5).speedMetersPerSecond == nil)
    }

    @Test func windowIsTwelveSecondsAtRate120AndFiveAtRate30() {
        #expect(abs(Fixtures.timeline([Fixtures.straight(seconds: 2400)]).speedWindowSeconds - 12) < 1e-9)
        #expect(abs(Fixtures.timeline([Fixtures.straight(seconds: 300)]).speedWindowSeconds - 5) < 1e-9)
        // Speed drops 6 → 3 m/s at 20 s. At 34 s the 12 s trailing window is all post-change:
        // reads 3. A 6 s window would too, but a centered ±12 s window would blend.
        var pts = Fixtures.straight(seconds: 20, speed: 6).points
        let c = pts[20].coordinate
        pts.append(contentsOf: Fixtures.straight(seconds: 2400, speed: 3, start: 20, from: c).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        #expect(abs((t.sample(at: 34 / t.totalSeconds).speedMetersPerSecond ?? 0) - 3) < 0.05)
        // At 26 s the window [14, 26] straddles the change: 36 + 18 = 54 m over 12 s = 4.5.
        #expect(abs((t.sample(at: 26 / t.totalSeconds).speedMetersPerSecond ?? 0) - 4.5) < 0.05)
    }

    /// D5.1: never reaches back across a hold. Barrier-irrelevant fixture: the lost leg's own
    /// time gap makes the unclamped search skip it anyway — see the mutation-proven test below.
    @Test func speedAfterALostLegIgnoresTheGap() {
        var pts = Fixtures.straight(seconds: 200).points
        let to = Fixtures.east(2100)
        pts.append(Fixtures.point(to, at: 320))                                        // 120 s, 900 m
        pts.append(contentsOf: Fixtures.straight(seconds: 200, start: 321, from: to).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        var f = t.holds[0].range.upperBound   // first non-nil read: one real leg past the hold —
        while t.sample(at: f).speedMetersPerSecond == nil, f < 1 { f += 1e-6 }   // 3 m/s, that leg's own
        let justAfter = t.sample(at: f)                                         // speed, not the ride's 6
        #expect(justAfter.seconds > 320 && justAfter.seconds < 326)
        #expect(abs((justAfter.speedMetersPerSecond ?? -1) - 3) < 0.1)
        let later = t.sample(at: (t.holds[0].range.upperBound + 1) / 2)
        #expect(abs((later.speedMetersPerSecond ?? 0) - 6) < 0.05)
    }
    /// Mutation-proven: a stop's barrier sits inside dense real timestamps, so an unclamped
    /// search reaches into its near-zero jitter — the lost leg above cannot show this.
    @Test func speedAfterAStopNeverReachesIntoIt() {
        var pts = Fixtures.straight(seconds: 300).points
        let stop = pts[300].coordinate
        pts.append(contentsOf: Fixtures.jitter(seconds: 60, at: stop, start: 301))
        pts.append(contentsOf: Fixtures.straight(seconds: 300, start: 361, from: stop).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        let hold = t.holds[0]; #expect(hold.kind == .stopped)
        let holdClockEnd = t.sample(at: hold.range.upperBound).seconds
        var f = hold.range.upperBound   // search to 2-3 s past the hold's clock end
        while t.sample(at: f).seconds - holdClockEnd < 2, f < 1 { f += 1e-6 }
        let s = t.sample(at: f)
        #expect(s.seconds - holdClockEnd >= 2 && s.seconds - holdClockEnd < 3)
        // Barrier: ~2.9 m/s (growing toward 6). No barrier: ~1.0-1.25 m/s (jitter reached). 2 m/s separates them (measured).
        #expect((s.speedMetersPerSecond ?? 0) > 2)
    }

    // §4.9 profile
    @Test func profileRepeatsThroughAHoldAndCarriesAcrossNil() {
        let a = Fixtures.straight(seconds: 600, elevation: { i in i == 300 ? nil : 300 + Double(i) / 10 })
        let b = Fixtures.straight(seconds: 600, start: 1200, from: Fixtures.east(3600), elevation: { _ in 100 })
        let t = Fixtures.timeline([a, b])
        let profile = t.profile(sampleCount: 240)
        #expect(profile?.count == 240)
        let hold = t.holds[0]
        let inHold = profile!.enumerated().filter { hold.range.contains(Double($0.offset) / 239) }
        #expect(!inHold.isEmpty)
        #expect(inHold.allSatisfy { abs($0.element - 360) < 1e-9 })
        // The nil at i == 300 lands inside leg 299→300 / 300→301; the samples there carry 329.9…330.1.
        let aroundNil = profile!.enumerated().filter { (0.245...0.255).contains(Double($0.offset) / 239 * (t.playbackDuration / 10)) }
        #expect(aroundNil.allSatisfy { $0.element > 329 && $0.element < 331 })
    }

    @Test func profileIsNilWithoutElevationAndFillsLeadingNils() {
        let none = Fixtures.timeline([Fixtures.straight(seconds: 100, elevation: { _ in nil })])
        #expect(none.profile(sampleCount: 10) == nil)
        let late = Fixtures.timeline([Fixtures.straight(seconds: 100, elevation: { i in i < 50 ? nil : 420 })])
        #expect(late.profile(sampleCount: 10) == Array(repeating: 420, count: 10))
    }

    // §4.10 events
    @Test func eventsCoverEndsHoldsAndWholeUnits() {
        let t = Fixtures.timeline([Fixtures.straight(seconds: 300, speed: 6),
                                   Fixtures.straight(seconds: 300, start: 900, from: Fixtures.east(1800))])
        let e = t.events
        #expect(e.first == 0 && e.last == 1)
        #expect(e == e.sorted())
        #expect(zip(e, e.dropFirst()).allSatisfy { $1 - $0 > 1e-9 })
        for hold in t.holds {
            #expect(e.contains { abs($0 - hold.range.lowerBound) < 1e-12 })
            #expect(e.contains { abs($0 - hold.range.upperBound) < 1e-12 })
        }
        let marks = e.filter { f in
            let d = t.sample(at: f).distanceMeters
            return [1000.0, 2000, 3000, 1609.344, 3218.688].contains { abs($0 - d) < 0.01 }
        }
        #expect(marks.count == 5)
    }

    @Test func unitMarksInsideALostLegLandOnTheHoldStart() {
        var pts = Fixtures.straight(seconds: 200).points                               // 1200 m
        let to = Fixtures.east(2100)
        pts.append(Fixtures.point(to, at: 320))                                        // 900 m lost leg
        pts.append(contentsOf: Fixtures.straight(seconds: 200, start: 321, from: to).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        let hold = t.holds[0]
        // 1609.344 and 2000 fall inside the lost leg → both events are the hold's start.
        #expect(t.events.filter { abs($0 - hold.range.lowerBound) < 1e-12 }.count == 1)   // deduplicated
        #expect(t.events.contains { abs($0 - hold.range.upperBound) < 1e-12 })
        #expect(t.events.contains { abs(t.sample(at: $0).distanceMeters - 3000) < 0.01 })
    }
}

struct ReplayTimelineScaleTests {
    // §4.12 the working size: 10,800 points, four holds, two segments
    @Test func threeHourRideBuildsAndHoldsTheInvariants() {
        let ride = SyntheticRide.threeHour(startingAt: ReplayFixtures.t0)
        #expect(ride.segments.count == 2)
        #expect(ride.flattenedPoints.count == 10_800)
        let t = ReplayTimeline(segments: ride.segments)
        #expect(t.isReplayable)
        #expect(t.playbackDuration <= 45 * 1.25 + 1e-9)
        #expect(t.holds.map(\.kind) == [.stopped, .paused, .signalLost, .stopped])
        #expect(t.holds[1].seconds == 601)                                 // 5399 → 6000
        let stats = RideStatsCalculator.stats(segments: ride.segments)
        #expect(abs(t.sample(at: 1).distanceMeters - stats.distanceMeters) < 1e-6)
        for hold in t.holds {
            #expect(t.sample(at: hold.range.lowerBound).phase == .hold(hold.kind, seconds: hold.seconds))
            #expect(t.sample(at: hold.range.upperBound).phase == .moving)
        }
        var d = -1.0
        for k in 0...1000 {
            let s = t.sample(at: Double(k) / 1000)
            #expect(s.distanceMeters >= d - 1e-9); d = s.distanceMeters
            #expect(s.coordinate.latitude.isFinite && s.coordinate.longitude.isFinite)
        }
        #expect(t.profile(sampleCount: 240)?.count == 240)
        #expect(t.events.count > 40)                                      // ~65 km → 64 km + 40 mi marks + holds
    }
}
