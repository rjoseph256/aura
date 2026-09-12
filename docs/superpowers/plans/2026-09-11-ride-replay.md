# Ride Replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scrub a finished ride back on the summary map: a rider marker runs the recorded track while speed, distance, time, and elevation track a scrubber, with every stop the rider remembers visible as a hold.

**Architecture:** A pure `ReplayTimeline` in AuraCore normalizes a ride's segments into a playback axis of moving legs and holds, and samples any fraction of it without allocation. AuraKit holds the playback state machine (`ReplayPlayback`), the readout strings (`ReplayReadout`), and the band content (`ReplayBandContent`), all tested. The app target is a dumb projection: a `MapViewAnnotation` inside a `TimelineView`, a scrub band, an instrument row, and a one-line entry on the summary.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, SwiftUI (iOS 17 deployment target), MapboxMaps 11.28.0 SwiftUI `Map`, XcodeGen-generated project, SwiftLint `--strict`.

**Spec:** `docs/superpowers/specs/2026-09-11-ride-replay-design.md` (v2). Decisions are cited as D1…D11; invariants as §4.N.

## Global Constraints

- Swift language mode 6; every public pure type is `Sendable` and `Equatable`. `@Observable` classes are `@MainActor`.
- The app target has no unit-test bundle. Every rule lives in AuraCore or AuraKit with a Swift Testing suite; SwiftUI files contain layout only.
- Never read `ride.flattenedPoints` or map `ride.segments` inside a SwiftUI `body`. Build once, hold in `@State`.
- No write to observable state inside a view body. Writes happen in event handlers and `.onChange`.
- SwiftLint `--strict`: line length ≤ 140, file length ≤ 500 warning, no `ultraThinMaterial` outside Theme (use `.mapChip`), no async closure default arguments.
- Mapbox `Map` modifiers (`.gestureOptions`, `.ornamentOptions`, `.mapStyle`) go on the `Map` before any generic SwiftUI modifier.
- Package tests: run from `AuraCore/` with `swift test --no-parallel --filter <Suite>`. One `swift test` at a time on this machine. Lint from the repo root: `swiftlint lint --strict --quiet`.
- App builds are run by the orchestrator via the `apple-platform-build-tools:builder` agent, not by implementers. The project is regenerated with `cd Aura && xcodegen generate`; new files under `Aura/Sources` need no project edit.
- Config values (D2/D3/D5/D7), verbatim: rate 120; minPlayback 10 s; maxPlayback 45 s; minHold 1.5 s; maxHold 4 s; maxHoldShare 0.25; signalGapSeconds 30 s; holdDistanceMeters 50 m; stoppedSpeed 0.5 m/s; minStopSeconds 45 s; minPauseSeconds 5 s; speedWindowFloor 5 s; speedWindowPlayback 0.1 s; coincidentMeters 0.5 m; minReplayableSeconds 60 s; minReplayableMeters 200 m.
- Copy, verbatim: "Replay", "Replay this ride", "Stopped · 10 min", "Paused · 45 s", "No signal · 3 min", "Play replay", "Pause replay", "Ride scrubber", "Recenter map", "—".
- Files the branch must not touch: `NavigateHUDView.swift`, `RideMapView.swift`, `RideSummaryView+ShareUpgrade.swift`, every file under `Aura/Sources/GroupRide/`, `AppRoute.swift`, `SimulatedRideSupport`, `HistoryView.swift`. `RideSummaryView.swift` changes by exactly one line.
- Commit after every task with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer.

---

## File map

| File | Responsibility |
|---|---|
| `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift` | Build the playback axis from segments; `sample`, `holds`, `events`, `profile`. |
| `AuraCore/Sources/AuraCore/Replay/ReplaySample.swift` | `ReplaySample`, `ReplayPhase`, `ReplayHold`. |
| `AuraCore/Sources/AuraCore/Replay/SyntheticRide.swift` | Deterministic synthetic rides (the 3-hour one) for tests and the DEBUG seed. |
| `AuraCore/Tests/AuraCoreTests/Replay/ReplayFixtures.swift` | Small segment builders for the timeline suites. |
| `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` | §4.1–4.12. |
| `AuraCore/Sources/AuraKit/Replay/ReplayPlayback.swift` | Anchor-based playback state; D11. |
| `AuraCore/Sources/AuraKit/Replay/ReplayReadout.swift` | Every displayed string; D5, D7 subtitle. |
| `AuraCore/Sources/AuraKit/Replay/ReplayBandContent.swift` | Silhouette or rail decision, built once; D6. |
| `AuraCore/Tests/AuraKitTests/Replay/ReplayPlaybackTests.swift` | §4.13. |
| `AuraCore/Tests/AuraKitTests/Replay/ReplayReadoutTests.swift` | §4.14 and band content. |
| `Aura/Sources/Theme/AuraTheme.swift` | `RouteStroke` constants (append). |
| `Aura/Sources/Ride/StaticRouteMap.swift` | Read `RouteStroke` (two literals replaced). |
| `Aura/Sources/Ride/Replay/ReplayMap.swift` | `TimelineView` → `Map` → source, layer, marker annotation; recenter; hold capsule. D8. |
| `Aura/Sources/Ride/Replay/ReplayMarkerView.swift` | Puck image + rotation. |
| `Aura/Sources/Ride/Replay/ReplayScrubBand.swift` | Silhouette/rail, strips, captions, thumb, drag, a11y. D6. |
| `Aura/Sources/Ride/Replay/ReplayInstrumentRow.swift` | Three readouts. D5. |
| `Aura/Sources/Ride/Replay/RideReplayView.swift` | The cover: top bar, map, controls. D7. |
| `Aura/Sources/Ride/Replay/RideReplayEntry.swift` | The modifier and pill. D1. |
| `Aura/Sources/Ride/RideSummaryView.swift` | One line. |
| `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` | Three identifiers. |
| `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift` | `-auraSeedLongRide` flag. |
| `Aura/Sources/AuraApp.swift` | DEBUG seed after store creation. |

---

### Task 1: `ReplayTimeline` — construction, normalization, duration, replayability

**Files:**
- Create: `AuraCore/Sources/AuraCore/Replay/ReplaySample.swift`
- Create: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift`
- Create: `AuraCore/Tests/AuraCoreTests/Replay/ReplayFixtures.swift`
- Create: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift`

**Interfaces:**
- Consumes: `RideSegment`, `TrackPoint`, `Coordinate`, `Geo.distance`, `PeerBearing.heading` (all AuraCore).
- Produces: `ReplayTimeline(segments:config:)`, `.config`, `.isReplayable`, `.playbackDuration`, `.rate`, `.totalDistanceMeters`, `.totalSeconds`, `.holds`, `.events`, `.sample(at:)`, `.profile(sampleCount:)`; `ReplaySample`, `ReplayPhase`, `ReplayHold`. This task writes the whole implementation; Tasks 2–4 add the suites that pin sampling, holds, and speed/profile/events and fix whatever they catch.

- [ ] **Step 1: Create the value types**

`AuraCore/Sources/AuraCore/Replay/ReplaySample.swift`:

```swift
import Foundation

/// One stop on the playback axis: a pause gap between segments, a stationary run inside a
/// segment, or a leg the GPS lost. All three render the same way (spec D3).
public struct ReplayHold: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case paused, stopped, signalLost }
    public var kind: Kind
    /// Ride seconds the hold stands for: the gap between fixes, or the run's summed time.
    public var seconds: TimeInterval
    /// Half-open on the playback axis, in fractions of `playbackDuration`. The sample at
    /// `lowerBound` is the hold; the sample at `upperBound` is moving.
    public var range: Range<Double>

    public init(kind: Kind, seconds: TimeInterval, range: Range<Double>) {
        self.kind = kind; self.seconds = seconds; self.range = range
    }
}

public enum ReplayPhase: Sendable, Equatable {
    case moving
    case hold(ReplayHold.Kind, seconds: TimeInterval)
    case ended
}

/// Everything the map, the band, and the instrument row need for one moment of the ride.
public struct ReplaySample: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Course of the current leg (spec D9). nil in a hold, at the end, and before the first
    /// non-coincident leg; the marker draws the disc then.
    public var bearing: Double?
    public var elevation: Double?
    /// Trailing mean over the speed window (spec D5.1). nil → "—".
    public var speedMetersPerSecond: Double?
    public var distanceMeters: Double
    /// Ride seconds elapsed within segments: pause gaps excluded, in-segment stops included.
    public var seconds: TimeInterval
    public var phase: ReplayPhase

    public init(coordinate: Coordinate, bearing: Double?, elevation: Double?,
                speedMetersPerSecond: Double?, distanceMeters: Double, seconds: TimeInterval,
                phase: ReplayPhase) {
        self.coordinate = coordinate; self.bearing = bearing; self.elevation = elevation
        self.speedMetersPerSecond = speedMetersPerSecond; self.distanceMeters = distanceMeters
        self.seconds = seconds; self.phase = phase
    }
}
```

- [ ] **Step 2: Write the failing construction tests**

`AuraCore/Tests/AuraCoreTests/Replay/ReplayFixtures.swift`:

```swift
import Foundation
@testable import AuraCore

/// Segment builders for the replay suites. Everything is one point per second unless a
/// builder says otherwise, so "seconds" and "points − 1" are the same number.
enum ReplayFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let origin = Coordinate(latitude: 40.44, longitude: -79.99)

    /// A coordinate `meters` east of `from` on a flat-earth approximation good to ~1e-6.
    static func east(_ meters: Double, from: Coordinate = origin) -> Coordinate {
        let metersPerDegreeLon = 111_320 * cos(from.latitude * .pi / 180)
        return Coordinate(latitude: from.latitude, longitude: from.longitude + meters / metersPerDegreeLon)
    }

    static func point(_ c: Coordinate, at offset: TimeInterval, elevation: Double? = 300) -> TrackPoint {
        TrackPoint(coordinate: c, elevation: elevation, timestamp: t0.addingTimeInterval(offset))
    }

    /// Straight east at `speed` m/s for `seconds` seconds, first point at `start`.
    static func straight(seconds: Int, speed: Double = 6, start: TimeInterval = 0,
                         from: Coordinate = origin, elevation: (Int) -> Double? = { _ in 300 }) -> RideSegment {
        RideSegment(points: (0...seconds).map { i in
            point(east(Double(i) * speed, from: from), at: start + Double(i), elevation: elevation(i))
        })
    }

    /// `seconds` of GPS jitter around `at`: ±0.2 m, well under the 0.5 m/s stopped threshold.
    static func jitter(seconds: Int, at: Coordinate, start: TimeInterval) -> [TrackPoint] {
        (0..<seconds).map { i in
            point(east(0.2 * sin(Double(i)), from: at), at: start + Double(i))
        }
    }

    /// A quarter circle of radius `radius` m at `speed` m/s, one point per second. The arc
    /// length is what a leg-sum speed reads; a chord implementation reads less.
    static func quarterCircle(radius: Double = 500, speed: Double = 6, start: TimeInterval = 0) -> RideSegment {
        let seconds = Int((.pi / 2 * radius / speed).rounded(.down))
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320 * cos(origin.latitude * .pi / 180)
        return RideSegment(points: (0...seconds).map { i in
            let theta = Double(i) * speed / radius
            let c = Coordinate(latitude: origin.latitude + radius * sin(theta) / metersPerDegreeLat,
                               longitude: origin.longitude + radius * cos(theta) / metersPerDegreeLon)
            return point(c, at: start + Double(i))
        })
    }

    static func timeline(_ segments: [RideSegment], config: ReplayTimeline.Config = .init()) -> ReplayTimeline {
        ReplayTimeline(segments: segments, config: config)
    }
}
```

`AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

struct ReplayTimelineConstructionTests {
    typealias F = ReplayFixtures

    // §4.1 duration rule
    @Test func underTheFloorClampsToMinPlayback() {
        let t = F.timeline([F.straight(seconds: 300)])          // 300 s / 120 = 2.5 s → floor
        #expect(t.playbackDuration == 10)
        #expect(abs(t.rate - 30) < 1e-9)                         // 300 / 10
    }

    @Test func atRateIsExactlyRate() {
        let t = F.timeline([F.straight(seconds: 2400)])         // 20 min / 120 = 10 s exactly
        #expect(abs(t.playbackDuration - 20) < 1e-9)
        #expect(abs(t.rate - 120) < 1e-9)
    }

    @Test func overTheCapClampsToMaxPlayback() {
        let t = F.timeline([F.straight(seconds: 7200)])         // 2 h / 120 = 60 s → cap 45
        #expect(t.playbackDuration == 45)
        #expect(abs(t.rate - 160) < 1e-9)
    }

    @Test func emptyAndSinglePointInteriorSegmentsAddNoHold() {
        let a = F.straight(seconds: 600)
        let lone = RideSegment(points: [F.point(F.origin, at: 700)])
        let b = F.straight(seconds: 600, start: 800, from: F.east(4000))
        let with = F.timeline([a, RideSegment(points: []), lone, b])
        let without = F.timeline([a, b])
        #expect(with.holds.count == 1)
        #expect(with.holds == without.holds)
        #expect(with.playbackDuration == without.playbackDuration)
    }

    // §4.2 normalization
    @Test func identicalTimestampsBuildAndAreNotReplayable() {
        let pts = (0...5).map { F.point(F.east(Double($0) * 50), at: 0) }
        let t = F.timeline([RideSegment(points: pts)])
        #expect(t.totalSeconds == 0)
        #expect(t.isReplayable == false)
        #expect(t.playbackDuration.isFinite)
        for k in 0...20 {
            let s = t.sample(at: Double(k) / 20)
            #expect(s.coordinate.latitude.isFinite && s.coordinate.longitude.isFinite)
            #expect(s.distanceMeters.isFinite && s.seconds.isFinite)
        }
    }

    @Test func backwardsStampIsZeroWidthAndNeverNegative() {
        var pts = F.straight(seconds: 200).points
        pts[100] = F.point(pts[100].coordinate, at: 60)        // clock stepped back 40 s
        let t = F.timeline([RideSegment(points: pts)])
        #expect(t.rate >= 0)
        var lastDistance = -1.0, lastSeconds = -1.0
        for k in 0...200 {
            let s = t.sample(at: Double(k) / 200)
            #expect(s.distanceMeters >= lastDistance - 1e-9)
            #expect(s.seconds >= lastSeconds - 1e-9)
            lastDistance = s.distanceMeters; lastSeconds = s.seconds
        }
        // Legs 99→100 and 100→101 both normalize to dt 0, so the moving span lost 2 s.
        #expect(abs(t.totalSeconds - 198) < 1e-9)
    }

    // §4.11 replayable
    @Test func replayableNeedsSixtySecondsAndTwoHundredMeters() {
        #expect(F.timeline([F.straight(seconds: 59, speed: 6)]).isReplayable == false)   // 354 m, 59 s
        #expect(F.timeline([F.straight(seconds: 120, speed: 1)]).isReplayable == false)  // 120 m
        #expect(F.timeline([F.straight(seconds: 60, speed: 4)]).isReplayable == true)    // 240 m, 60 s
        #expect(F.timeline([]).isReplayable == false)
        #expect(F.timeline([RideSegment(points: [F.point(F.origin, at: 0)])]).isReplayable == false)
    }

    @Test func totalsAreTheSegmentSums() {
        let t = F.timeline([F.straight(seconds: 100), F.straight(seconds: 50, start: 400, from: F.east(2000))])
        #expect(abs(t.totalSeconds - 150) < 1e-9)
        #expect(abs(t.totalDistanceMeters - 900) < 0.5)   // 600 + 300, haversine vs flat
    }
}
```

- [ ] **Step 3: Run the suite to verify it fails to compile**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineConstructionTests`
Expected: compile error, `ReplayTimeline` not found.

- [ ] **Step 4: Write the implementation**

`AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift`:

```swift
import Foundation

/// A finished ride laid out on a playback axis: moving legs at a constant compression of ride
/// time, and holds — pause gaps, stationary runs, lost-signal legs — at a fixed width each
/// (spec D2, D3). Built once; `sample(at:)` is a binary search and allocates nothing.
///
/// Time is normalized in `init`: a leg's `dt` is `max(0, next − prev)`, so a backwards or
/// repeated stamp is a zero-width leg that keeps its distance and occupies no time. Nothing
/// downstream has to guard `dt > 0` again.
public struct ReplayTimeline: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        public var rate: Double = 120
        public var minPlayback: TimeInterval = 10
        public var maxPlayback: TimeInterval = 45
        public var minHold: TimeInterval = 1.5
        public var maxHold: TimeInterval = 4
        public var maxHoldShare: Double = 0.25
        public var signalGapSeconds: TimeInterval = 30
        public var holdDistanceMeters: Double = 50
        public var stoppedSpeed: Double = 0.5
        public var minStopSeconds: TimeInterval = 45
        public var minPauseSeconds: TimeInterval = 5
        public var speedWindowFloor: TimeInterval = 5
        public var speedWindowPlayback: TimeInterval = 0.1
        public var coincidentMeters: Double = 0.5
        public var minReplayableSeconds: TimeInterval = 60
        public var minReplayableMeters: Double = 200
        public init() {}
    }

    struct Leg: Sendable, Equatable {
        var segment: Int
        var startIndex: Int
        var start: Coordinate
        var end: Coordinate
        var startElevation: Double?
        var endElevation: Double?
        var distance: Double
        var dt: TimeInterval
        var bearing: Double?
    }

    struct Hold: Sendable, Equatable {
        var kind: ReplayHold.Kind
        var seconds: TimeInterval
        var anchor: Coordinate
        var anchorElevation: Double?
        /// In-segment holds advance the ride clock across their width; a pause gap does not.
        var advancesClock: Bool
        /// Distance folded into the hold (jitter, or the lost-signal leg). Counted after it.
        var distance: Double
    }

    enum Item: Sendable, Equatable {
        case leg(Leg)
        case hold(Hold)
        /// A zero-width leg: distance only, no time, never a span.
        case skip(distance: Double)
    }

    struct Span: Sendable, Equatable {
        enum Content: Sendable, Equatable { case leg(Leg), hold(Hold) }
        var content: Content
        var playStart: TimeInterval
        var width: TimeInterval
        var distanceAtStart: Double
        var secondsAtStart: TimeInterval
    }

    /// Per drawable segment: global cumulative seconds and distance at each point, for the
    /// speed window (spec D5.1).
    struct SegmentIndex: Sendable, Equatable {
        var times: [TimeInterval]
        var distances: [Double]
    }

    public let config: Config
    public let playbackDuration: TimeInterval
    public let rate: Double
    public let totalDistanceMeters: Double
    public let totalSeconds: TimeInterval
    public let isReplayable: Bool
    public let holds: [ReplayHold]
    public let events: [Double]

    let spans: [Span]
    let segmentIndices: [SegmentIndex]
    let last: (coordinate: Coordinate, elevation: Double?)?
    let first: (coordinate: Coordinate, elevation: Double?)?

    // MARK: - Build

    public init(segments: [RideSegment], config: Config = .init()) {
        self.config = config
        let drawable = segments.filter { $0.points.count > 1 }
        var builder = Builder(config: config)
        for (index, segment) in drawable.enumerated() { builder.add(segment, index: index) }
        let items = builder.items
        segmentIndices = builder.segmentIndices
        totalDistanceMeters = builder.cumulativeDistance
        totalSeconds = builder.cumulativeSeconds
        first = drawable.first.map { ($0.points[0].coordinate, $0.points[0].elevation) }
        last = drawable.last.map { seg in
            let p = seg.points[seg.points.count - 1]
            return (p.coordinate, p.elevation)
        }

        // D2: constant compression of the moving span.
        var movingSpan: TimeInterval = 0
        for case let .leg(leg) in items { movingSpan += leg.dt }
        let movingPlayback = min(max(movingSpan / config.rate, config.minPlayback), config.maxPlayback)
        let rate = movingSpan / movingPlayback
        self.rate = rate

        // D3: hold widths, capped as a share of the moving playback.
        var holdWidths: [TimeInterval] = []
        for case let .hold(hold) in items {
            let raw = rate > 0 ? hold.seconds / rate : config.maxHold
            holdWidths.append(min(max(raw, config.minHold), config.maxHold))
        }
        let holdTotal = holdWidths.reduce(0, +)
        let holdCap = config.maxHoldShare * movingPlayback
        if holdTotal > holdCap, holdTotal > 0 {
            let scale = holdCap / holdTotal
            holdWidths = holdWidths.map { $0 * scale }
        }

        // Lay the spans out. Zero-width legs (or all legs, when movingSpan is 0) fold into the
        // running totals and produce no span.
        var spans: [Span] = []
        var play: TimeInterval = 0
        var distance = 0.0
        var seconds: TimeInterval = 0
        var holdCursor = 0
        for item in items {
            switch item {
            case let .skip(d):
                distance += d
            case let .leg(leg):
                let width = movingSpan > 0 ? leg.dt * movingPlayback / movingSpan : 0
                if width > 0 {
                    spans.append(Span(content: .leg(leg), playStart: play, width: width,
                                      distanceAtStart: distance, secondsAtStart: seconds))
                    play += width
                }
                distance += leg.distance
                seconds += leg.dt
            case let .hold(hold):
                let width = holdWidths[holdCursor]
                holdCursor += 1
                spans.append(Span(content: .hold(hold), playStart: play, width: width,
                                  distanceAtStart: distance, secondsAtStart: seconds))
                play += width
                distance += hold.distance
                if hold.advancesClock { seconds += hold.seconds }
            }
        }
        let duration = spans.isEmpty ? movingPlayback : play
        playbackDuration = duration
        self.spans = spans

        holds = spans.compactMap { span in
            guard case let .hold(hold) = span.content else { return nil }
            return ReplayHold(kind: hold.kind, seconds: hold.seconds,
                              range: (span.playStart / duration)..<((span.playStart + span.width) / duration))
        }
        isReplayable = !drawable.isEmpty
            && movingSpan >= config.minReplayableSeconds
            && totalDistanceMeters >= config.minReplayableMeters
        events = Self.events(spans: spans, holds: holds, duration: duration)
    }

    /// Walks segments once, classifying legs (spec D2) and emitting items in ride order.
    private struct Builder {
        let config: Config
        var items: [Item] = []
        var segmentIndices: [SegmentIndex] = []
        var cumulativeDistance = 0.0
        var cumulativeSeconds: TimeInterval = 0
        private var previousLast: TrackPoint?
        /// Legs of the stationary run being accumulated; flushed at a moving leg or the end.
        private var run: [Leg] = []
        private var lastBearing: Double?

        init(config: Config) { self.config = config }

        mutating func add(_ segment: RideSegment, index: Int) {
            let points = segment.points
            if let prev = previousLast {
                let gap = max(0, points[0].timestamp.timeIntervalSince(prev.timestamp))
                if gap >= config.minPauseSeconds {
                    items.append(.hold(Hold(kind: .paused, seconds: gap, anchor: prev.coordinate,
                                            anchorElevation: prev.elevation, advancesClock: false,
                                            distance: 0)))
                }
            }
            lastBearing = nil
            var times = [cumulativeSeconds]
            var distances = [cumulativeDistance]
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                let dt = max(0, b.timestamp.timeIntervalSince(a.timestamp))
                let d = Geo.distance(a.coordinate, b.coordinate)
                cumulativeDistance += d
                cumulativeSeconds += dt
                times.append(cumulativeSeconds)
                distances.append(cumulativeDistance)
                if d >= config.coincidentMeters { lastBearing = PeerBearing.heading(from: a.coordinate, to: b.coordinate) }
                let leg = Leg(segment: index, startIndex: i - 1, start: a.coordinate, end: b.coordinate,
                              startElevation: a.elevation, endElevation: b.elevation,
                              distance: d, dt: dt, bearing: lastBearing)
                if dt >= config.signalGapSeconds {
                    flushRun()
                    let kind: ReplayHold.Kind = d < config.holdDistanceMeters ? .stopped : .signalLost
                    items.append(.hold(Hold(kind: kind, seconds: dt, anchor: a.coordinate,
                                            anchorElevation: a.elevation, advancesClock: true, distance: d)))
                } else if dt == 0 {
                    if run.isEmpty { items.append(.skip(distance: d)) } else { run.append(leg) }
                } else if d / dt < config.stoppedSpeed {
                    run.append(leg)
                } else {
                    flushRun()
                    items.append(.leg(leg))
                }
            }
            flushRun()
            segmentIndices.append(SegmentIndex(times: times, distances: distances))
            previousLast = points[points.count - 1]
        }

        private mutating func flushRun() {
            guard let head = run.first else { return }
            let seconds = run.reduce(0) { $0 + $1.dt }
            if seconds >= config.minStopSeconds {
                items.append(.hold(Hold(kind: .stopped, seconds: seconds, anchor: head.start,
                                        anchorElevation: head.startElevation, advancesClock: true,
                                        distance: run.reduce(0) { $0 + $1.distance })))
            } else {
                for leg in run { items.append(leg.dt > 0 ? .leg(leg) : .skip(distance: leg.distance)) }
            }
            run.removeAll(keepingCapacity: true)
        }
    }

    private static func events(spans: [Span], holds: [ReplayHold], duration: TimeInterval) -> [Double] {
        var out: [Double] = [0, 1]
        for hold in holds { out.append(hold.range.lowerBound); out.append(hold.range.upperBound) }
        let units: [Double] = [1000, 1609.344]
        for span in spans {
            guard case let .leg(leg) = span.content, leg.distance > 0 else { continue }
            let from = span.distanceAtStart, to = from + leg.distance
            for unit in units {
                var k = (from / unit).rounded(.down) + 1
                while k * unit <= to {
                    let fraction = (span.playStart + (k * unit - from) / leg.distance * span.width) / duration
                    out.append(fraction)
                    k += 1
                }
            }
        }
        out.sort()
        var deduped: [Double] = []
        for f in out where deduped.last.map({ f - $0 > 1e-9 }) ?? true { deduped.append(f) }
        return deduped
    }

    // MARK: - Sample

    /// Total: any fraction, clamped to 0…1. With no drawable segment the sample is the
    /// origin at `.ended`; the entry point never presents such a timeline (`isReplayable`).
    public func sample(at fraction: Double) -> ReplaySample {
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        guard let first else {
            return ReplaySample(coordinate: Coordinate(latitude: 0, longitude: 0), bearing: nil,
                                elevation: nil, speedMetersPerSecond: nil, distanceMeters: 0,
                                seconds: 0, phase: .ended)
        }
        let p = f * playbackDuration
        if f >= 1 || spans.isEmpty {
            if f < 1 {
                return ReplaySample(coordinate: first.coordinate, bearing: nil, elevation: first.elevation,
                                    speedMetersPerSecond: nil, distanceMeters: 0, seconds: 0, phase: .moving)
            }
            let end = last ?? first
            return ReplaySample(coordinate: end.coordinate, bearing: nil, elevation: end.elevation,
                                speedMetersPerSecond: nil, distanceMeters: totalDistanceMeters,
                                seconds: totalSeconds, phase: .ended)
        }
        let span = spans[spanIndex(at: p)]
        let t = min(max((p - span.playStart) / span.width, 0), 1)
        switch span.content {
        case let .leg(leg):
            let coordinate = Coordinate(
                latitude: leg.start.latitude + (leg.end.latitude - leg.start.latitude) * t,
                longitude: leg.start.longitude + (leg.end.longitude - leg.start.longitude) * t)
            let elevation: Double?
            switch (leg.startElevation, leg.endElevation) {
            case let (a?, b?): elevation = a + (b - a) * t
            case let (a?, nil): elevation = a
            case let (nil, b?): elevation = b
            case (nil, nil): elevation = nil
            }
            let seconds = span.secondsAtStart + leg.dt * t
            return ReplaySample(coordinate: coordinate, bearing: leg.bearing, elevation: elevation,
                                speedMetersPerSecond: windowedSpeed(segment: leg.segment, at: seconds),
                                distanceMeters: span.distanceAtStart + leg.distance * t,
                                seconds: seconds, phase: .moving)
        case let .hold(hold):
            return ReplaySample(coordinate: hold.anchor, bearing: nil, elevation: hold.anchorElevation,
                                speedMetersPerSecond: nil, distanceMeters: span.distanceAtStart,
                                seconds: hold.advancesClock ? span.secondsAtStart + hold.seconds * t
                                                            : span.secondsAtStart,
                                phase: .hold(hold.kind, seconds: hold.seconds))
        }
    }

    /// Last span whose `playStart` ≤ `p`. Spans start at 0 and are contiguous, so this is the
    /// span containing `p` for every `p` below `playbackDuration`.
    private func spanIndex(at p: TimeInterval) -> Int {
        var lo = 0, hi = spans.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if spans[mid].playStart <= p { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Spec D5.1: sum of leg distances between the points bracketing `[T − w, T]` within the
    /// segment, over their time span. nil with fewer than two points or a zero span.
    private func windowedSpeed(segment: Int, at seconds: TimeInterval) -> Double? {
        let index = segmentIndices[segment]
        let w = max(config.speedWindowFloor, rate * config.speedWindowPlayback)
        let j = Self.lastIndex(in: index.times, atOrBefore: seconds)
        let i = Self.firstIndex(in: index.times, atOrAfter: seconds - w)
        guard j > i else { return nil }
        let span = index.times[j] - index.times[i]
        guard span > 0 else { return nil }
        return (index.distances[j] - index.distances[i]) / span
    }

    private static func lastIndex(in times: [TimeInterval], atOrBefore t: TimeInterval) -> Int {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func firstIndex(in times: [TimeInterval], atOrAfter t: TimeInterval) -> Int {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] >= t { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    // MARK: - Profile

    /// Elevation at `sampleCount` uniform playback fractions (spec D6): the anchor's value
    /// through a hold, the last known value across points without one, the first known value
    /// before any. nil when no point has elevation.
    public func profile(sampleCount: Int) -> [Double]? {
        guard sampleCount >= 2 else { return nil }
        var raw: [Double?] = []
        raw.reserveCapacity(sampleCount)
        for k in 0..<sampleCount { raw.append(sample(at: Double(k) / Double(sampleCount - 1)).elevation) }
        guard let firstKnown = raw.compactMap({ $0 }).first else { return nil }
        var out: [Double] = []
        out.reserveCapacity(sampleCount)
        var carry = firstKnown
        for value in raw {
            if let value { carry = value }
            out.append(carry)
        }
        return out
    }
}
```

- [ ] **Step 5: Run the construction suite until it passes**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineConstructionTests`
Expected: all 8 tests pass. If `overTheCapClampsToMaxPlayback` reports a rate other than 160, check that `movingSpan` counts only `.leg` items.

- [ ] **Step 6: Lint and commit**

Run from the repo root: `swiftlint lint --strict --quiet` — expected: no output.

```bash
git add AuraCore/Sources/AuraCore/Replay AuraCore/Tests/AuraCoreTests/Replay
git commit -m "feat(roh-239): ReplayTimeline builds a normalized playback axis

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Sampling on moving legs, totals, bearing, never-a-chord

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift` (only if a test fails)
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append a suite)

**Interfaces:**
- Consumes: Task 1's `ReplayTimeline`, `ReplayFixtures`, `RideStatsCalculator.stats(segments:)`.
- Produces: pinned behavior for §4.5 (partial), §4.7, §4.8.

- [ ] **Step 1: Append the sampling suite**

Append to `ReplayTimelineTests.swift`:

```swift
struct ReplayTimelineSamplingTests {
    typealias F = ReplayFixtures

    @Test func fractionZeroIsTheFirstPointMovingWithNoSpeed() {
        let t = F.timeline([F.straight(seconds: 600)])
        let s = t.sample(at: 0)
        #expect(s.coordinate == F.origin)
        #expect(s.distanceMeters == 0 && s.seconds == 0)
        #expect(s.phase == .moving)
        #expect(s.speedMetersPerSecond == nil)
    }

    @Test func midpointOfAStraightRideIsHalfway() {
        let t = F.timeline([F.straight(seconds: 600, speed: 6)])
        let s = t.sample(at: 0.5)
        #expect(abs(s.seconds - 300) < 1e-6)
        #expect(abs(s.distanceMeters - 1800) < 0.5)
        #expect(abs(s.coordinate.longitude - F.east(1800).longitude) < 1e-7)
        #expect(s.phase == .moving)
    }

    // §4.7 totals agree with RideStats
    @Test func fractionOneIsEndedWithTheStatsTotals() {
        let a = F.straight(seconds: 600)
        let stopAt = F.east(3600)
        var b = F.straight(seconds: 200, start: 900, from: stopAt).points
        b.append(contentsOf: F.jitter(seconds: 90, at: F.east(1200, from: stopAt), start: 1101))
        let segments = [a, RideSegment(points: b), F.straight(seconds: 100, start: 1400, from: F.east(6000))]
        let t = F.timeline(segments)
        let stats = RideStatsCalculator.stats(segments: segments)
        let end = t.sample(at: 1)
        #expect(end.phase == .ended)
        #expect(abs(end.distanceMeters - stats.distanceMeters) < 1e-6)
        #expect(abs(end.seconds - t.totalSeconds) < 1e-9)
        #expect(end.coordinate == segments[2].points.last!.coordinate)
    }

    @Test func distanceAndSecondsAreMonotonicAcrossAPause() {
        let t = F.timeline([F.straight(seconds: 300), F.straight(seconds: 300, start: 900, from: F.east(1800))])
        var d = -1.0, s = -1.0
        for k in 0...400 {
            let sample = t.sample(at: Double(k) / 400)
            #expect(sample.distanceMeters >= d - 1e-9); #expect(sample.seconds >= s - 1e-9)
            d = sample.distanceMeters; s = sample.seconds
        }
    }

    // §4.8 bearing
    @Test func bearingIsTheLegCourseAndHoldsAcrossCoincidentPoints() {
        var pts = F.straight(seconds: 100).points
        pts[50] = F.point(pts[49].coordinate, at: 50)          // coincident with its predecessor
        let t = F.timeline([RideSegment(points: pts)])
        let mid = t.sample(at: 0.3)
        #expect(mid.bearing != nil)
        #expect(abs((mid.bearing ?? 0) - 90) < 0.5)               // due east
        // The coincident leg (49→50) is stationary-speed 0 and under 45 s, so it plays as a leg
        // holding the last bearing.
        let atCoincident = t.sample(at: 49.5 / 100)
        #expect(abs((atCoincident.bearing ?? 0) - 90) < 0.5)
    }

    @Test func bearingIsNilBeforeTheFirstNonCoincidentLeg() {
        var pts = F.jitter(seconds: 10, at: F.origin, start: 0)
        pts.append(contentsOf: F.straight(seconds: 100, start: 10, from: F.origin).points)
        let t = F.timeline([RideSegment(points: pts)])
        // First 10 s are jitter (< 0.5 m/s, under minStopSeconds) → played as legs with nil bearing.
        #expect(t.sample(at: 0.01).bearing == nil)
        #expect(t.sample(at: 0.9).bearing != nil)
    }

    @Test func elevationInterpolatesAndBridgesANil() {
        let seg = F.straight(seconds: 100, elevation: { i in i == 50 ? nil : Double(300 + i) })
        let t = F.timeline([seg])
        #expect(abs((t.sample(at: 0.25).elevation ?? 0) - 325) < 0.01)
        let bridged = t.sample(at: 0.495)                  // inside leg 49→50, end elevation nil
        #expect(bridged.elevation == 349)
    }

    @Test func endedSampleHasNoBearingOrSpeed() {
        let t = F.timeline([F.straight(seconds: 600)])
        let end = t.sample(at: 1)
        #expect(end.bearing == nil && end.speedMetersPerSecond == nil)
    }
}
```

- [ ] **Step 2: Run it**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineSamplingTests`
Expected: all pass. A failure in `bearingIsTheLegCourseAndHoldsAcrossCoincidentPoints` means `lastBearing` is being reset per leg instead of per segment; a failure in `fractionOneIsEndedWithTheStatsTotals` means jitter distance is not being folded into the hold's `distance`.

- [ ] **Step 3: Commit**

```bash
git add AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift
git commit -m "test(roh-239): ReplayTimeline sampling, totals, and bearing are pinned

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Holds — pause gaps, stationary runs, lost signal, widths, and the share cap

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift` (only if a test fails)
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append a suite)

**Interfaces:**
- Consumes: Task 1's `ReplayTimeline`, `ReplayHold`, `ReplayPhase`.
- Produces: pinned §4.1 (holds), §4.3, §4.4, §4.5.

- [ ] **Step 1: Append the holds suite**

```swift
struct ReplayTimelineHoldTests {
    typealias F = ReplayFixtures

    private func twoSegments(gap: TimeInterval) -> ReplayTimeline {
        F.timeline([F.straight(seconds: 600), F.straight(seconds: 600, start: 600 + gap, from: F.east(3600))])
    }

    @Test func aTenMinutePauseIsOneHoldOfMaxHoldWidth() {
        let t = twoSegments(gap: 600)                       // moving 1200 s → 10 s playback, rate 120
        #expect(t.holds.count == 1)
        let hold = t.holds[0]
        #expect(hold.kind == .paused && hold.seconds == 600)
        // 600 / 120 = 5 s → capped at maxHold 4; share cap 2.5 s of 10 s → scaled to 2.5.
        let width = (hold.range.upperBound - hold.range.lowerBound) * t.playbackDuration
        #expect(abs(width - 2.5) < 1e-9)
        #expect(abs(t.playbackDuration - 12.5) < 1e-9)
    }

    @Test func aThreeSecondGapIsNotAPause() {
        let t = twoSegments(gap: 3)
        #expect(t.holds.isEmpty)
        #expect(abs(t.playbackDuration - 10) < 1e-9)
    }

    // §4.3 the sample inside a hold
    @Test func sampleInsideAHoldSitsOnTheAnchor() {
        let t = twoSegments(gap: 600)
        let hold = t.holds[0]
        let anchor = F.east(3600)
        for f in [hold.range.lowerBound, (hold.range.lowerBound + hold.range.upperBound) / 2] {
            let s = t.sample(at: f)
            #expect(s.phase == .hold(.paused, seconds: 600))
            #expect(abs(s.coordinate.longitude - anchor.longitude) < 1e-9)
            #expect(s.speedMetersPerSecond == nil && s.bearing == nil)
            #expect(abs(s.distanceMeters - 3600) < 0.5)
            #expect(abs(s.seconds - 600) < 1e-9)              // a pause does not advance the clock
        }
        let after = t.sample(at: hold.range.upperBound)
        #expect(after.phase == .moving)
        #expect(abs(after.coordinate.longitude - anchor.longitude) < 1e-9)   // next segment's first point
    }

    @Test func noFractionOutsideAHoldRangeIsAHold() {
        let t = twoSegments(gap: 600)
        let hold = t.holds[0]
        for k in 0...500 {
            let f = Double(k) / 500
            let isHoldPhase: Bool
            if case .hold = t.sample(at: f).phase { isHoldPhase = true } else { isHoldPhase = false }
            #expect(isHoldPhase == hold.range.contains(f), "fraction \(f)")
        }
    }

    // §4.4 stationary runs and lost signal
    @Test func sixtySecondsOfJitterIsOneStoppedHold() {
        var pts = F.straight(seconds: 300).points
        let stop = pts.last!.coordinate
        pts.append(contentsOf: F.jitter(seconds: 60, at: stop, start: 301))
        pts.append(contentsOf: F.straight(seconds: 300, start: 361, from: stop).points.dropFirst())
        let t = F.timeline([RideSegment(points: pts)])
        #expect(t.holds.count == 1)
        #expect(t.holds[0].kind == .stopped)
        #expect(abs(t.holds[0].seconds - 60) < 1e-9)
        let inside = t.sample(at: (t.holds[0].range.lowerBound + t.holds[0].range.upperBound) / 2)
        #expect(abs(inside.coordinate.longitude - stop.longitude) < 1e-7)
        // In-segment holds advance the clock across their width.
        #expect(inside.seconds > 300 && inside.seconds < 361)
    }

    @Test func thirtySecondsOfJitterIsNoHold() {
        var pts = F.straight(seconds: 300).points
        let stop = pts.last!.coordinate
        pts.append(contentsOf: F.jitter(seconds: 30, at: stop, start: 301))
        pts.append(contentsOf: F.straight(seconds: 300, start: 331, from: stop).points.dropFirst())
        #expect(F.timeline([RideSegment(points: pts)]).holds.isEmpty)
    }

    @Test func twoRunsSeparatedByAMovingLegAreTwoHolds() {
        var pts = F.straight(seconds: 100).points
        let a = pts.last!.coordinate
        pts.append(contentsOf: F.jitter(seconds: 50, at: a, start: 101))
        let b = F.east(600, from: a)
        pts.append(contentsOf: F.straight(seconds: 100, start: 151, from: a).points.dropFirst())
        pts.append(contentsOf: F.jitter(seconds: 50, at: b, start: 252))
        pts.append(contentsOf: F.straight(seconds: 100, start: 302, from: b).points.dropFirst())
        let t = F.timeline([RideSegment(points: pts)])
        #expect(t.holds.count == 2)
        #expect(t.holds.allSatisfy { $0.kind == .stopped })
    }

    @Test func aLongLegIsSignalLostWhenItMovesAndStoppedWhenItDoesNot() {
        var far = F.straight(seconds: 100).points
        far.append(F.point(F.east(1400), at: 220))                           // 120 s, 800 m
        far.append(contentsOf: F.straight(seconds: 100, start: 221, from: F.east(1400)).points.dropFirst())
        let lost = F.timeline([RideSegment(points: far)])
        #expect(lost.holds.count == 1 && lost.holds[0].kind == .signalLost)

        var near = F.straight(seconds: 100).points
        near.append(F.point(F.east(610), at: 220))                           // 120 s, 10 m
        near.append(contentsOf: F.straight(seconds: 100, start: 221, from: F.east(610)).points.dropFirst())
        let stopped = F.timeline([RideSegment(points: near)])
        #expect(stopped.holds.count == 1 && stopped.holds[0].kind == .stopped)
    }

    // §4.5 never a chord: the lost leg's interior is never sampled
    @Test func aLostSignalLegIsAJumpNotAGlide() {
        var pts = F.straight(seconds: 100).points
        let from = pts.last!.coordinate, to = F.east(1400)
        pts.append(F.point(to, at: 220))
        pts.append(contentsOf: F.straight(seconds: 100, start: 221, from: to).points.dropFirst())
        let t = F.timeline([RideSegment(points: pts)])
        for k in 0...2000 {
            let lon = t.sample(at: Double(k) / 2000).coordinate.longitude
            let strictlyInside = lon > from.longitude + 1e-9 && lon < to.longitude - 1e-9
            #expect(!strictlyInside, "sampled inside the lost leg at \(k)/2000")
        }
    }

    // §4.1 the share cap with many pauses
    @Test func twelvePausesAreCappedAtAQuarterOfTheMovingPlayback() {
        var segments: [RideSegment] = []
        var start: TimeInterval = 0
        var from = F.origin
        for _ in 0..<13 {                                   // 13 segments of 100 s → 1300 s moving
            segments.append(F.straight(seconds: 100, start: start, from: from))
            start += 100 + 30                               // 30 s pauses
            from = F.east(700, from: from)
        }
        let t = F.timeline(segments)
        #expect(t.holds.count == 12)
        let movingPlayback = 1300.0 / 120
        let holdTotal = t.holds.reduce(0.0) { $0 + ($1.range.upperBound - $1.range.lowerBound) } * t.playbackDuration
        #expect(abs(holdTotal - 0.25 * movingPlayback) < 1e-9)
    }
}
```

- [ ] **Step 2: Run it**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineHoldTests`
Expected: all pass. If `aTenMinutePauseIsOneHoldOfMaxHoldWidth` gets width 4, the share cap is not applied; if `sampleInsideAHoldSitsOnTheAnchor` fails at `upperBound`, the span search is returning the hold at its exclusive end (check the `<=` in `spanIndex` against a `playStart` that equals `p`).

- [ ] **Step 3: Commit**

```bash
git add AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift
git commit -m "test(roh-239): holds — pauses, stops, lost signal, widths, share cap

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Speed window, profile, and events

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift` (only if a test fails)
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append a suite)

**Interfaces:**
- Consumes: Task 1's `ReplayTimeline`.
- Produces: pinned §4.6, §4.9, §4.10.

- [ ] **Step 1: Append the suite**

```swift
struct ReplayTimelineSpeedProfileEventTests {
    typealias F = ReplayFixtures

    // §4.6 speed
    @Test func quarterCircleReadsTheArcSpeedNotTheChord() {
        let t = F.timeline([F.quarterCircle(radius: 500, speed: 6)])   // ~130 s → floor, rate ~13
        let w = max(5, t.rate * 0.1)
        for k in 5...19 {                                              // past the first window
            let f = Double(k) / 20
            let s = t.sample(at: f)
            #expect(s.seconds > w)
            #expect(abs((s.speedMetersPerSecond ?? 0) - 6) < 0.05, "at \(f)")
        }
    }

    @Test func speedIsNilAtStartInsideAHoldAndForAZeroSpan() {
        let t = F.timeline([F.straight(seconds: 600), F.straight(seconds: 600, start: 1200, from: F.east(3600))])
        #expect(t.sample(at: 0).speedMetersPerSecond == nil)
        let mid = (t.holds[0].range.lowerBound + t.holds[0].range.upperBound) / 2
        #expect(t.sample(at: mid).speedMetersPerSecond == nil)

        let same = RideSegment(points: (0...3).map { F.point(F.east(Double($0) * 10), at: 0) })
        let z = F.timeline([same])
        #expect(z.sample(at: 0.5).speedMetersPerSecond == nil)
    }

    @Test func windowIsTwelveSecondsAtRate120AndFiveAtRate30() {
        let fast = F.timeline([F.straight(seconds: 2400)])         // rate 120
        let slow = F.timeline([F.straight(seconds: 300)])          // rate 30
        #expect(abs(max(5, fast.rate * 0.1) - 12) < 1e-9)
        #expect(abs(max(5, slow.rate * 0.1) - 5) < 1e-9)
        // A speed change 20 s in: at 24 s ride time the 12 s trailing window is entirely
        // post-change, so the readout is the new speed, not a blend.
        var pts = F.straight(seconds: 20, speed: 6).points
        let c = pts.last!.coordinate
        pts.append(contentsOf: F.straight(seconds: 2400, speed: 3, start: 20, from: c).points.dropFirst())
        let t = F.timeline([RideSegment(points: pts)])
        let at34 = t.sample(at: 34 / t.totalSeconds)              // rate ≈ 120 → w = 12
        #expect(abs((at34.speedMetersPerSecond ?? 0) - 3) < 0.05)
    }

    // §4.9 profile
    @Test func profileRepeatsThroughAHoldAndCarriesAcrossNil() {
        let a = F.straight(seconds: 600, elevation: { i in i == 300 ? nil : 300 + Double(i) / 10 })
        let b = F.straight(seconds: 600, start: 1200, from: F.east(3600), elevation: { _ in 100 })
        let t = F.timeline([a, b])
        let profile = t.profile(sampleCount: 240)
        #expect(profile?.count == 240)
        let hold = t.holds[0]
        let inHold = profile!.enumerated().filter { hold.range.contains(Double($0.offset) / 239) }
        #expect(!inHold.isEmpty)
        #expect(inHold.allSatisfy { abs($0.element - 360) < 1e-9 })      // segment a's last elevation
        for k in 0..<240 {
            let expected = t.sample(at: Double(k) / 239).elevation
            if let expected { #expect(abs(profile![k] - expected) < 1e-9) }
        }
    }

    @Test func profileIsNilWithoutElevationAndFillsLeadingNils() {
        let none = F.timeline([F.straight(seconds: 100, elevation: { _ in nil })])
        #expect(none.profile(sampleCount: 10) == nil)
        let late = F.timeline([F.straight(seconds: 100, elevation: { i in i < 50 ? nil : 420 })])
        #expect(late.profile(sampleCount: 10) == Array(repeating: 420, count: 10))
    }

    // §4.10 events
    @Test func eventsCoverEndsHoldsAndWholeUnits() {
        let t = F.timeline([F.straight(seconds: 300, speed: 6), F.straight(seconds: 300, start: 900, from: F.east(1800))])
        let e = t.events
        #expect(e.first == 0 && e.last == 1)
        #expect(e == e.sorted())
        #expect(zip(e, e.dropFirst()).allSatisfy { $1 - $0 > 1e-9 })
        for hold in t.holds {
            #expect(e.contains { abs($0 - hold.range.lowerBound) < 1e-12 })
            #expect(e.contains { abs($0 - hold.range.upperBound) < 1e-12 })
        }
        // 3600 m total: km marks at 1000, 2000, 3000; mile marks at 1609.344, 3218.688.
        let kmAndMi = e.filter { f in
            let d = t.sample(at: f).distanceMeters
            return [1000.0, 2000, 3000, 1609.344, 3218.688].contains { abs($0 - d) < 0.5 }
        }
        #expect(kmAndMi.count == 5)
    }
}
```

- [ ] **Step 2: Run it**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineSpeedProfileEventTests`
Expected: all pass.

- [ ] **Step 3: Run the whole replay group plus lint, then commit**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimeline` then `swiftlint lint --strict --quiet` from the root.

```bash
git add AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift
git commit -m "test(roh-239): speed window, profile, and events are pinned

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `SyntheticRide` and the scale test

**Files:**
- Create: `AuraCore/Sources/AuraCore/Replay/SyntheticRide.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append a suite)

**Interfaces:**
- Consumes: `Ride`, `RideSegment`, `TrackPoint`, `RideStatsCalculator`.
- Produces: `SyntheticRide.threeHour(startingAt:) -> Ride` (public; the DEBUG seed in Task 11 uses it).

- [ ] **Step 1: Write the failing scale test**

```swift
struct ReplayTimelineScaleTests {
    // §4.12 the working size: 10,800 points, four stops, one pause
    @Test func threeHourRideBuildsAndHoldsTheInvariants() {
        let ride = SyntheticRide.threeHour(startingAt: ReplayFixtures.t0)
        #expect(ride.segments.count == 2)
        #expect(ride.flattenedPoints.count == 10_800)
        let t = ReplayTimeline(segments: ride.segments)
        #expect(t.isReplayable)
        #expect(t.playbackDuration <= 45 * 1.25 + 1e-9)
        #expect(t.holds.map(\.kind) == [.stopped, .paused, .signalLost, .stopped])
        let stats = RideStatsCalculator.stats(segments: ride.segments)
        #expect(abs(t.sample(at: 1).distanceMeters - stats.distanceMeters) < 1e-6)
        for hold in t.holds {
            let s = t.sample(at: hold.range.lowerBound)
            #expect(s.phase == .hold(hold.kind, seconds: hold.seconds))
        }
        var d = -1.0
        for k in 0...1000 {
            let s = t.sample(at: Double(k) / 1000)
            #expect(s.distanceMeters >= d - 1e-9); d = s.distanceMeters
            #expect(s.coordinate.latitude.isFinite && s.coordinate.longitude.isFinite)
        }
        #expect(t.profile(sampleCount: 240)?.count == 240)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineScaleTests`
Expected: compile error, `SyntheticRide` not found.

- [ ] **Step 3: Write the builder**

`AuraCore/Sources/AuraCore/Replay/SyntheticRide.swift`:

```swift
import Foundation

/// Deterministic rides for the replay suites and the DEBUG seed (spec §9). Not a fixture of
/// anything real: a loop around a center at a constant 6 m/s with four stops placed where the
/// playback regime needs them. Lives in the library rather than the test target because the
/// app's DEBUG seed inserts it into the store.
public enum SyntheticRide {
    static let center = Coordinate(latitude: 40.44, longitude: -79.99)

    /// 3 hours, one point per second, 10,800 points in two segments:
    /// - 0:30:00 → 5 min of jitter (a `.stopped` hold)
    /// - 1:30:00 → a 10 min pause gap (segment boundary, `.paused`)
    /// - 2:00:00 → one 120 s leg spanning ~700 m (`.signalLost`)
    /// - 2:30:00 → 90 s of jitter (`.stopped`)
    /// Elevation is a slow three-lobe wave over 300–380 m so the profile has a shape.
    public static func threeHour(startingAt start: Date) -> Ride {
        let speed = 6.0
        let totalSeconds = 10_800
        let radius = speed * Double(totalSeconds) / (2 * .pi)      // one full loop
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320 * cos(center.latitude * .pi / 180)

        func onLoop(_ meters: Double) -> Coordinate {
            let theta = meters / radius
            return Coordinate(latitude: center.latitude + radius * sin(theta) / metersPerDegreeLat,
                              longitude: center.longitude + radius * cos(theta) / metersPerDegreeLon)
        }
        func elevation(_ meters: Double) -> Double { 340 + 40 * sin(3 * meters / radius) }
        func jitter(_ c: Coordinate, _ i: Int) -> Coordinate {
            Coordinate(latitude: c.latitude + 0.2 * sin(Double(i)) / metersPerDegreeLat,
                       longitude: c.longitude + 0.2 * cos(Double(i)) / metersPerDegreeLon)
        }

        var first: [TrackPoint] = []
        var second: [TrackPoint] = []
        var meters = 0.0
        var i = 0
        while i < totalSeconds {
            let stamp = start.addingTimeInterval(Double(i))
            let stationary = (1800..<2100).contains(i) || (9000..<9090).contains(i)
            let lostLeg = i == 7200
            var point: TrackPoint
            if stationary {
                point = TrackPoint(coordinate: jitter(onLoop(meters), i), elevation: elevation(meters), timestamp: stamp)
            } else if lostLeg {
                // The previous point is at i − 1; this one lands 120 s later and 700 m on.
                meters += 700
                point = TrackPoint(coordinate: onLoop(meters), elevation: elevation(meters),
                                   timestamp: start.addingTimeInterval(Double(i) + 119))
            } else {
                point = TrackPoint(coordinate: onLoop(meters), elevation: elevation(meters), timestamp: stamp)
                meters += speed
            }
            if i < 5400 { first.append(point) } else {
                // Second segment starts 10 minutes after the first ended.
                point.timestamp = point.timestamp.addingTimeInterval(600)
                second.append(point)
            }
            i += 1
        }
        let segments = [RideSegment(points: first), RideSegment(points: second)]
        let ended = second[second.count - 1].timestamp
        return Ride(kind: .freeRide, startedAt: start, endedAt: ended, segments: segments,
                    stats: RideStatsCalculator.stats(segments: segments), pausedSeconds: 600,
                    destinationName: nil, routeId: nil, destinationPlaceId: nil)
    }
}
```

Note the lost leg: points after `i == 7200` keep stamping at `start + i`, so the leg from 7199 to 7200 spans 120 s and the leg from 7200 to 7201 is a backwards stamp normalized to zero width. That is deliberate; it exercises §4.2 on the working size. `TrackPoint.timestamp` is `var`, so the `+600` shift compiles.

- [ ] **Step 4: Run the scale test until it passes**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineScaleTests`
Expected: pass. If the hold kinds come out in a different order or count, print `t.holds` and check the stationary windows against `minStopSeconds` (the 90 s run must be ≥ 45 s; the 300 s run is far over).

- [ ] **Step 5: Lint and commit**

```bash
git add AuraCore/Sources/AuraCore/Replay/SyntheticRide.swift AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift
git commit -m "feat(roh-239): SyntheticRide.threeHour and the scale invariants

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `ReplayPlayback` (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Replay/ReplayPlayback.swift`
- Create: `AuraCore/Tests/AuraKitTests/Replay/ReplayPlaybackTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class ReplayPlayback` with `init(playbackDuration:)`, `anchorFraction`, `isPlaying`, `isScrubbing`, `fraction(at:)`, `hasEnded(at:)`, `play(now:)`, `pause(now:)`, `togglePlay(now:)`, `beginScrub(now:)`, `scrub(to:)`, `endScrub(now:)`, `jump(to:)`, `settle(now:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraKit

@MainActor
struct ReplayPlaybackTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func pausedFractionIsTheAnchor() {
        let p = ReplayPlayback(playbackDuration: 20)
        #expect(p.fraction(at: t0) == 0)
        #expect(p.fraction(at: t0 + 100) == 0)
        #expect(p.isPlaying == false)
    }

    @Test func playingAdvancesLinearlyAndClampsAtOne() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        #expect(p.isPlaying)
        #expect(abs(p.fraction(at: t0 + 5) - 0.25) < 1e-12)
        #expect(p.fraction(at: t0 + 20) == 1)
        #expect(p.fraction(at: t0 + 99) == 1)
        #expect(p.hasEnded(at: t0 + 20))
        #expect(p.hasEnded(at: t0 + 19) == false)
    }

    @Test func pauseFreezesWhereItWas() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        p.pause(now: t0 + 5)
        #expect(p.isPlaying == false)
        #expect(abs(p.fraction(at: t0 + 50) - 0.25) < 1e-12)
        p.play(now: t0 + 60)
        #expect(abs(p.fraction(at: t0 + 65) - 0.5) < 1e-12)
    }

    @Test func scrubWhilePlayingResumesFromTheScrubbedFraction() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        p.beginScrub(now: t0 + 5)
        #expect(p.isPlaying == false && p.isScrubbing)
        p.scrub(to: 0.8)
        #expect(p.fraction(at: t0 + 6) == 0.8)
        p.endScrub(now: t0 + 7)
        #expect(p.isPlaying && p.isScrubbing == false)
        #expect(abs(p.fraction(at: t0 + 9) - 0.9) < 1e-12)
    }

    @Test func scrubWhilePausedStaysPaused() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.beginScrub(now: t0)
        p.scrub(to: 0.3)
        p.endScrub(now: t0 + 1)
        #expect(p.isPlaying == false)
        #expect(p.fraction(at: t0 + 9) == 0.3)
    }

    @Test func scrubToTheEndDoesNotResume() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        p.beginScrub(now: t0 + 1)
        p.scrub(to: 1)
        p.endScrub(now: t0 + 2)
        #expect(p.isPlaying == false)
        #expect(p.fraction(at: t0 + 3) == 1)
    }

    @Test func jumpLeavesItPausedAndClamps() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        p.jump(to: 1.7)
        #expect(p.isPlaying == false)
        #expect(p.fraction(at: t0 + 1) == 1)
        p.jump(to: -3)
        #expect(p.fraction(at: t0 + 1) == 0)
    }

    @Test func settleParksAtOneAndPlayRestartsFromZero() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        p.settle(now: t0 + 30)
        #expect(p.isPlaying == false && p.anchorFraction == 1)
        p.play(now: t0 + 40)
        #expect(p.isPlaying)
        #expect(abs(p.fraction(at: t0 + 45) - 0.25) < 1e-12)
    }

    @Test func togglePlayFlips() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.togglePlay(now: t0)
        #expect(p.isPlaying)
        p.togglePlay(now: t0 + 2)
        #expect(p.isPlaying == false)
        #expect(abs(p.fraction(at: t0 + 9) - 0.1) < 1e-12)
    }

    @Test func zeroDurationNeverDividesByZero() {
        let p = ReplayPlayback(playbackDuration: 0)
        p.play(now: t0)
        #expect(p.fraction(at: t0 + 1).isFinite)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayPlaybackTests`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// Playback state for the replay screen (spec D11). The fraction is DERIVED from an anchor,
/// never accumulated: a view reads `fraction(at:)` with its clock's date and writes nothing.
/// Every write is an event — play, pause, scrub, jump, settle — so a body that runs twice in
/// a frame changes nothing, and a pinch that re-runs the map's body cannot speed the ride up.
///
/// In AuraKit rather than the app target for the same reason `ShareUpgradePresenter` is: the
/// app target has no test bundle, and D4's rules are the kind that survive to a whole-branch
/// review when they live in a view.
@MainActor @Observable
public final class ReplayPlayback {
    public let playbackDuration: TimeInterval
    public private(set) var anchorFraction: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isScrubbing = false
    @ObservationIgnored private var anchorDate = Date.distantPast
    @ObservationIgnored private var resumeAfterScrub = false

    public init(playbackDuration: TimeInterval) {
        // Never zero: a zero-length ride is not replayable (D7), and this keeps the division finite.
        self.playbackDuration = max(playbackDuration, 0.001)
    }

    public func fraction(at now: Date) -> Double {
        guard isPlaying else { return anchorFraction }
        return min(1, anchorFraction + now.timeIntervalSince(anchorDate) / playbackDuration)
    }

    public func hasEnded(at now: Date) -> Bool { fraction(at: now) >= 1 }

    /// D4: play at the end restarts from 0.
    public func play(now: Date) {
        if anchorFraction >= 1 { anchorFraction = 0 }
        anchorDate = now
        isPlaying = true
    }

    public func pause(now: Date) {
        anchorFraction = fraction(at: now)
        isPlaying = false
    }

    public func togglePlay(now: Date) {
        if isPlaying { pause(now: now) } else { play(now: now) }
    }

    public func beginScrub(now: Date) {
        resumeAfterScrub = isPlaying
        pause(now: now)
        isScrubbing = true
    }

    public func scrub(to fraction: Double) {
        anchorFraction = Self.clamp(fraction)
    }

    /// D4: resumes iff it was playing when the scrub began and the rider did not scrub to the end.
    public func endScrub(now: Date) {
        isScrubbing = false
        if resumeAfterScrub, anchorFraction < 1 { play(now: now) }
        resumeAfterScrub = false
    }

    /// A tap on the band: move there and stay paused.
    public func jump(to fraction: Double) {
        anchorFraction = Self.clamp(fraction)
        isPlaying = false
    }

    /// Called by the view when it observes `hasEnded`: park at 1, not playing.
    public func settle(now: Date) {
        anchorFraction = 1
        isPlaying = false
    }

    private static func clamp(_ f: Double) -> Double { min(max(f.isFinite ? f : 0, 0), 1) }
}
```

- [ ] **Step 4: Run until green, lint, commit**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayPlaybackTests` then lint from the root.

```bash
git add AuraCore/Sources/AuraKit/Replay/ReplayPlayback.swift AuraCore/Tests/AuraKitTests/Replay/ReplayPlaybackTests.swift
git commit -m "feat(roh-239): ReplayPlayback derives the fraction from an anchor

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `ReplayReadout`, `ReplayBandContent`, and the test identifiers (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Replay/ReplayReadout.swift`
- Create: `AuraCore/Sources/AuraKit/Replay/ReplayBandContent.swift`
- Create: `AuraCore/Tests/AuraKitTests/Replay/ReplayReadoutTests.swift`
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` (append three identifiers inside `RideTestID`)

**Interfaces:**
- Consumes: `ReplaySample`, `ReplayTimeline`, `ReplayHold`, `RideStatsFormatter`, `PauseControlCopy.clock`, `ElevationProfile.classify`, `Ride`.
- Produces: `ReplayReadout(sample:timeline:units:)` with `speedText`, `speedUnit`, `distanceText`, `distanceUnit`, `timeText`, `elevationText`, `holdText`, `accessibilityValue`, `accessibilityLabel`; `ReplayReadout.holdLabel(kind:seconds:)`, `ReplayReadout.subtitle(for:)`; `ReplayBandContent(ride:timeline:)` with `kind` (`.silhouette([Double])` / `.rail`), `holds`, `ReplayBandContent.sampleCount`; `RideTestID.replayEntry`, `.replayPlay`, `.replayBand`.

- [ ] **Step 1: Write the failing tests**

```swift
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
        let metersPerDegreeLon = 111_320 * cos(origin.latitude * .pi / 180)
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
        #expect(r.speedText == "20")
        #expect(r.speedUnit == "mph")
        #expect(r.distanceText == "2.4 / 12.3")
        #expect(r.distanceUnit == "mi")
        #expect(r.timeText == "14:08 / 1:02:11")
        #expect(r.elevationText == "312 ft")
        #expect(r.holdText == nil)
        #expect(r.accessibilityValue == "2.4 miles, 14 minutes")
        #expect(r.accessibilityLabel == "Speed 20 miles per hour. Distance 2.4 of 12.3 miles. Time 14:08 of 1:02:11.")
    }

    @Test func metricStringsAndNilSpeed() {
        let r = ReplayReadout(sample: sample(speed: nil, distance: 3862.4, seconds: 60), timeline: timeline, units: .metric)
        #expect(r.speedText == "—")
        #expect(r.speedUnit == "km/h")
        #expect(r.distanceText == "3.9 / 19.8")
        #expect(r.distanceUnit == "km")
        #expect(r.timeText == "1:00 / 1:02:11")
        #expect(r.elevationText == nil)
        #expect(r.accessibilityLabel.hasPrefix("Speed unavailable."))
    }

    @Test func holdLabels() {
        #expect(ReplayReadout.holdLabel(kind: .stopped, seconds: 600) == "Stopped · 10 min")
        #expect(ReplayReadout.holdLabel(kind: .paused, seconds: 45) == "Paused · 45 s")
        #expect(ReplayReadout.holdLabel(kind: .signalLost, seconds: 180) == "No signal · 3 min")
        #expect(ReplayReadout.holdLabel(kind: .paused, seconds: 3720) == "Paused · 62 min")
        let r = ReplayReadout(sample: sample(speed: nil, distance: 100, seconds: 30,
                                             phase: .hold(.stopped, seconds: 600)),
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
    private func ride(elevation: (Int) -> Double?, gain: Double) -> Ride {
        let origin = Coordinate(latitude: 40.44, longitude: -79.99)
        let metersPerDegreeLon = 111_320 * cos(origin.latitude * .pi / 180)
        let pts = (0...600).map { i in
            TrackPoint(coordinate: Coordinate(latitude: origin.latitude,
                                              longitude: origin.longitude + Double(i) * 6 / metersPerDegreeLon),
                       elevation: elevation(i), timestamp: Date(timeIntervalSince1970: Double(i)))
        }
        let stats = RideStats(distanceMeters: 3600, movingTimeSeconds: 600, averageSpeedMetersPerSecond: 6,
                              maxSpeedMetersPerSecond: 6, elevationGainMeters: gain)
        return Ride(kind: .freeRide, startedAt: .distantPast, endedAt: .distantPast,
                    track: pts, stats: stats, destinationName: nil, routeId: nil, destinationPlaceId: nil)
    }

    @Test func climbIsASilhouetteOnThePlaybackAxis() {
        let r = ride(elevation: { 300 + Double($0) / 5 }, gain: 120)
        let c = ReplayBandContent(ride: r, timeline: ReplayTimeline(segments: r.segments))
        guard case let .silhouette(samples) = c.kind else { Issue.record("expected silhouette"); return }
        #expect(samples.count == ReplayBandContent.sampleCount)
        #expect(samples.first! < samples.last!)
    }

    @Test func flatAndMissingElevationAreARail() {
        let flat = ride(elevation: { _ in 300 }, gain: 2)
        #expect(ReplayBandContent(ride: flat, timeline: ReplayTimeline(segments: flat.segments)).kind == .rail)
        let none = ride(elevation: { _ in nil }, gain: 0)
        #expect(ReplayBandContent(ride: none, timeline: ReplayTimeline(segments: none.segments)).kind == .rail)
    }

    @Test func holdsAreCarriedFromTheTimeline() {
        let r = ride(elevation: { _ in 300 }, gain: 0)
        let t = ReplayTimeline(segments: r.segments)
        #expect(ReplayBandContent(ride: r, timeline: t).holds == t.holds)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayReadoutTests`
Expected: compile error.

- [ ] **Step 3: Implement the readout**

`AuraCore/Sources/AuraKit/Replay/ReplayReadout.swift`:

```swift
import Foundation
import AuraCore

/// Every string the replay's instrument row, hold capsule, elevation tag, and VoiceOver
/// surfaces show, resolved from one sample (spec D5, D7). The views concatenate nothing.
public struct ReplayReadout: Equatable, Sendable {
    public let speedText: String
    public let speedUnit: String
    public let distanceText: String
    public let distanceUnit: String
    public let timeText: String
    public let elevationText: String?
    public let holdText: String?
    /// Short, for the band's `accessibilityValue`: "4.2 miles, 22 minutes".
    public let accessibilityValue: String
    /// Long, for the instrument row's combined element.
    public let accessibilityLabel: String

    public init(sample: ReplaySample, timeline: ReplayTimeline, units: DistanceUnits) {
        let fmt = RideStatsFormatter(units: units)
        speedText = sample.speedMetersPerSecond.map { fmt.speedValue($0) } ?? "—"
        speedUnit = fmt.speedUnit
        let soFar = fmt.distanceValue(sample.distanceMeters)
        let total = fmt.distanceValue(timeline.totalDistanceMeters)
        distanceText = "\(soFar) / \(total)"
        distanceUnit = fmt.distanceUnit
        let elapsed = PauseControlCopy.clock(sample.seconds)
        let totalTime = PauseControlCopy.clock(timeline.totalSeconds)
        timeText = "\(elapsed) / \(totalTime)"
        elevationText = sample.elevation.map { "\(fmt.elevationValue($0)) \(fmt.elevationUnit)" }
        if case let .hold(kind, seconds) = sample.phase {
            holdText = Self.holdLabel(kind: kind, seconds: seconds)
        } else {
            holdText = nil
        }
        let minutes = Int(sample.seconds / 60)
        accessibilityValue = "\(soFar) \(fmt.distanceUnitSpoken), \(minutes) minute\(minutes == 1 ? "" : "s")"
        var parts: [String] = []
        if let holdText { parts.append("\(holdText).") }
        if let speed = sample.speedMetersPerSecond {
            parts.append("Speed \(fmt.speedValue(speed)) \(fmt.speedUnitSpoken).")
        } else {
            parts.append("Speed unavailable.")
        }
        parts.append("Distance \(soFar) of \(total) \(fmt.distanceUnitSpoken).")
        parts.append("Time \(elapsed) of \(totalTime).")
        accessibilityLabel = parts.joined(separator: " ")
    }

    /// "Stopped · 10 min", "Paused · 45 s", "No signal · 3 min". Minutes at or above 60 s
    /// (`RideStatsFormatter.minutes`, which truncates), seconds below.
    public static func holdLabel(kind: ReplayHold.Kind, seconds: TimeInterval) -> String {
        let word: String
        switch kind {
        case .stopped: word = "Stopped"
        case .paused: word = "Paused"
        case .signalLost: word = "No signal"
        }
        let duration = seconds >= 60 ? RideStatsFormatter(units: .metric).minutes(seconds) : "\(Int(seconds)) s"
        return "\(word) · \(duration)"
    }

    /// The History row's three-valued rule: the destination's name, else "Navigated" for a
    /// navigate ride, else "Explore". `HistoryView` keeps its own private copy; this one is tested.
    public static func subtitle(for ride: Ride) -> String {
        if let name = ride.destinationName, !name.isEmpty { return name }
        return ride.kind == .navigate ? "Navigated" : "Explore"
    }
}
```

`AuraCore/Sources/AuraKit/Replay/ReplayBandContent.swift`:

```swift
import AuraCore

/// What the scrub band draws under the playhead (spec D6): the elevation silhouette on the
/// playback axis when the ride clears `ElevationProfile`'s gain gate and has elevation, else
/// a plain rail. Built once by the entry modifier — `ElevationProfile.classify` needs the
/// flattened track, which must never be read in a `body`.
public struct ReplayBandContent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case silhouette([Double])
        case rail
    }
    public static let sampleCount = 240

    public let kind: Kind
    public let holds: [ReplayHold]

    public init(ride: Ride, timeline: ReplayTimeline) {
        let gain = ride.stats?.elevationGainMeters ?? 0
        if case .profile = ElevationProfile.classify(track: ride.flattenedPoints, gainMeters: gain),
           let samples = timeline.profile(sampleCount: Self.sampleCount) {
            kind = .silhouette(samples)
        } else {
            kind = .rail
        }
        holds = timeline.holds
    }
}
```

Append inside `RideTestID` in `RideTestSupport.swift`:

```swift
    /// The summary map's Replay pill (ROH-239).
    public static let replayEntry = "summary.replay"
    /// The replay cover's play/pause control. One identifier for both states.
    public static let replayPlay = "replay.play"
    /// The replay scrub band, an adjustable element whose value is the short readout.
    public static let replayBand = "replay.band"
```

- [ ] **Step 4: Run until green, lint, commit**

Run: `cd AuraCore && swift test --no-parallel --filter "ReplayReadoutTests|ReplayBandContentTests"` then lint. If `imperialStrings` fails on `speedText`, note `speedValue` defaults to 0 decimals and 8.9408 m/s is 20.0 mph exactly.

```bash
git add AuraCore/Sources/AuraKit/Replay AuraCore/Tests/AuraKitTests/Replay AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift
git commit -m "feat(roh-239): ReplayReadout and ReplayBandContent resolve every replay string once

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Route stroke constants, `ReplayMarkerView`, `ReplayMap`

**Files:**
- Modify: `Aura/Sources/Theme/AuraTheme.swift` (append an extension at the end of the file)
- Modify: `Aura/Sources/Ride/StaticRouteMap.swift:34-36` (two literals)
- Create: `Aura/Sources/Ride/Replay/ReplayMarkerView.swift`
- Create: `Aura/Sources/Ride/Replay/ReplayMap.swift`

**Interfaces:**
- Consumes: `ReplayTimeline`, `ReplaySample`, `ReplayPlayback`, `ReplayReadout.holdLabel`, `AuraPuck.ridingBearing`/`browseTop`, `SettingsStore.mapStyle.mapboxStyle`, `.hudControl` button style, `.mapChip`.
- Produces: `ReplayMap(timeline:lines:playback:)`; `AuraTheme.RouteStroke.width`, `.casingWidth`.

- [ ] **Step 1: Add the constants and point `StaticRouteMap` at them**

Append to `Aura/Sources/Theme/AuraTheme.swift`:

```swift
extension AuraTheme {
    /// The cased route stroke the static maps share (summary, replay). Mapbox draws
    /// `lineBorderWidth` INSIDE `lineWidth`: 8 − 2×1.5 = 5 pt of visible mint.
    enum RouteStroke {
        static let width: Double = 8
        static let casingWidth: Double = 1.5
    }
}
```

In `StaticRouteMap.swift`, replace `.lineWidth(8)` with `.lineWidth(AuraTheme.RouteStroke.width)` and `.lineBorderWidth(1.5)` with `.lineBorderWidth(AuraTheme.RouteStroke.casingWidth)`. Leave the comment above them; update its arithmetic reference only if it names the literal.

- [ ] **Step 2: Write the marker**

`Aura/Sources/Ride/Replay/ReplayMarkerView.swift`:

```swift
import SwiftUI
import AuraCore

/// The replay rider (spec D8): the riding triangle rotated to the track bearing while moving,
/// the browse disc in a hold and at the end. Field-full on purpose — the bearing changes every
/// frame — but its position in the map content tree is fixed, so the SDK reuses one hosting
/// view. Rotation and pitch are disabled on the replay map, so a geographic bearing is a
/// screen bearing.
struct ReplayMarkerView: View {
    let sample: ReplaySample
    let reduceMotion: Bool

    private var isMoving: Bool {
        if case .moving = sample.phase { return sample.bearing != nil }
        return false
    }

    /// Reduce Motion rounds to the 8-point compass, the peer-pointer rule (spec D10).
    private var displayBearing: Double {
        let raw = sample.bearing ?? 0
        return reduceMotion ? (raw / 45).rounded() * 45 : raw
    }

    var body: some View {
        Image(uiImage: isMoving ? AuraPuck.ridingBearing : AuraPuck.browseTop)
            .rotationEffect(.degrees(isMoving ? displayBearing : 0))
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 3: Write the map**

`Aura/Sources/Ride/Replay/ReplayMap.swift`:

```swift
import SwiftUI
import MapboxMaps
import Turf
import AuraCore
import AuraKit

/// The replay's map (spec D8): the cased route as a style source under a line layer, and the
/// rider as a `MapViewAnnotation`, both inside one `TimelineView` that runs only while
/// playing. The same structure `NavigateHUDView` runs at 30 Hz: the SDK re-uploads the
/// GeoJSON only when `data` differs, so a frame that moves the marker touches nothing else.
///
/// `lines` is mapped once by the parent; nothing here reads `ride.segments`.
struct ReplayMap: View {
    let timeline: ReplayTimeline
    let lines: [[CLLocationCoordinate2D]]
    let playback: ReplayPlayback

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewport: Viewport = .styleDefault

    private static let sourceID = "aura-replay-route"

    var body: some View {
        TimelineView(.animation(paused: !playback.isPlaying)) { context in
            let sample = timeline.sample(at: playback.fraction(at: context.date))
            Map(viewport: $viewport) {
                if !lines.isEmpty {
                    routeSource
                    LineLayer(id: "aura-replay-route-line", source: Self.sourceID)
                        .lineColor(StyleColor(AuraTheme.routeUIColor))
                        .lineWidth(AuraTheme.RouteStroke.width)
                        .lineBorderColor(StyleColor(AuraTheme.routeCasingUIColor))
                        .lineBorderWidth(AuraTheme.RouteStroke.casingWidth)
                        .lineCap(.round)
                        .lineJoin(.round)
                }
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                    latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude)) {
                    ReplayMarkerView(sample: sample, reduceMotion: reduceMotion)
                }
                .allowOverlapWithPuck(true)
            }
            .gestureOptions(gestureOptions)
            .ornamentOptions(ornamentOptions)
            .mapStyle(settings.mapStyle.mapboxStyle)
            .overlay(alignment: .bottomLeading) {
                if case let .hold(kind, seconds) = sample.phase {
                    Text(ReplayReadout.holdLabel(kind: kind, seconds: seconds))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .padding(.horizontal, AuraTheme.Spacing.md)
                        .padding(.vertical, AuraTheme.Spacing.sm)
                        .mapChip(Capsule())
                        .padding(AuraTheme.Spacing.md)
                        .accessibilityHidden(true)   // the row announces it
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // `viewport.isIdle` is the SDK's own "the rider moved the camera" signal; setting
            // `.overview` on recenter clears it. No camera callback, no latch (spec D7).
            if viewport.isIdle {
                Button(action: recenter) { Image(systemName: "location.fill") }
                    .buttonStyle(.hudControl(active: true))
                    .accessibilityLabel("Recenter map")
                    .padding(AuraTheme.Spacing.md)
            }
        }
        .onAppear(perform: fit)
    }

    private var routeSource: GeoJSONSource {
        var source = GeoJSONSource(id: Self.sourceID)
        source.data = .feature(Feature(geometry: MultiLineString(lines)))
        return source
    }

    private var gestureOptions: GestureOptions {
        var options = GestureOptions()
        options.rotateEnabled = false
        options.pitchEnabled = false
        return options
    }

    private var ornamentOptions: OrnamentOptions {
        var options = OrnamentOptions()
        options.scaleBar.visibility = .hidden
        options.compass.visibility = .hidden
        return options
    }

    private var overview: Viewport {
        .overview(geometry: LineString(lines.flatMap { $0 }),
                  geometryPadding: .init(top: 24, leading: 24, bottom: 24, trailing: 24),
                  maxZoom: 16)
    }

    private func fit() {
        guard lines.flatMap({ $0 }).count > 1 else { return }
        viewport = overview
    }

    /// Snaps under Reduce Motion, flies otherwise — `RideHUDView.recenter()`'s rule.
    private func recenter() {
        if reduceMotion {
            viewport = overview
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) { viewport = overview }
        }
    }
}
```

Check `.hudControl(active:)` against `HUDControlButton.swift`: `ControlCluster` calls `.buttonStyle(.hudControl(active: !isFollowing, metrics: .ride))`, so `.hudControl(active:)` with the default `.standard` metrics exists; if the static helper requires `metrics`, pass `metrics: .standard`.

- [ ] **Step 4: Lint**

Run from the root: `swiftlint lint --strict --quiet`. Expected: no output. Do not build; the orchestrator builds after this task and reports any compile error back with the task.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Theme/AuraTheme.swift Aura/Sources/Ride/StaticRouteMap.swift Aura/Sources/Ride/Replay/ReplayMarkerView.swift Aura/Sources/Ride/Replay/ReplayMap.swift
git commit -m "feat(roh-239): ReplayMap draws the route as a source and the rider as an annotation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

**Orchestrator step (not the implementer's):** run the builder agent: `cd Aura && xcodegen generate` then build the `Aura` scheme for the iPhone 17 simulator. `ReplayMap` is not yet referenced, so this verifies the file compiles in the target.

---

### Task 9: `ReplayScrubBand`

**Files:**
- Create: `Aura/Sources/Ride/Replay/ReplayScrubBand.swift`

**Interfaces:**
- Consumes: `ReplayBandContent`, `ReplayTimeline`, `ReplayPlayback`, `ReplayReadout`, `Sparkline.points(values:in:inset:)` (AuraKit), `RideTestID.replayBand`, `RideStatsFormatter.minutes`.
- Produces: `ReplayScrubBand(content:timeline:playback:readout:fraction:now:)`.

- [ ] **Step 1: Write the band**

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The scrubber (spec D6): the elevation silhouette or a rail on the playback axis, hold
/// strips with captions, a 28 pt thumb on the playhead, and the drag that moves it. The
/// silhouette is a child whose only input is the sample array, so the per-frame playhead
/// invalidation never re-strokes it.
struct ReplayScrubBand: View {
    let content: ReplayBandContent
    let timeline: ReplayTimeline
    let playback: ReplayPlayback
    let readout: ReplayReadout
    /// The playhead's fraction for this frame (the parent resolves it from its clock).
    let fraction: Double
    let now: Date

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragMoved = false
    @State private var holdUnderThumb: Int?

    static let thumb: CGFloat = 28
    static let strokeInset: CGFloat = 2
    private static let bandHeight: CGFloat = 88
    private static let captionMinSeconds: TimeInterval = 120
    private static let captionWidthEstimate: CGFloat = 44

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    strips(width: width, height: geo.size.height)
                    switch content.kind {
                    case let .silhouette(samples):
                        ReplaySilhouette(samples: samples, contrast: contrast)
                            .padding(.horizontal, Self.thumb / 2)
                    case .rail:
                        rail(width: width, height: geo.size.height)
                    }
                    playhead(width: width, height: geo.size.height)
                }
                .contentShape(Rectangle())
                .gesture(drag(width: width))
            }
            .frame(height: Self.bandHeight)
            captions
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ride scrubber")
        .accessibilityValue(readout.accessibilityValue)
        .accessibilityAdjustableAction(adjust)
        .accessibilityIdentifier(RideTestID.replayBand)
        .sensoryFeedback(.selection, trigger: holdUnderThumb) { _, new in dragMoved && new != nil }
        .onChange(of: fraction) { _, new in holdUnderThumb = timeline.holds.firstIndex { $0.range.contains(new) } }
    }

    // MARK: Geometry

    /// x of a fraction inside the drawable width (thumb inset + stroke inset each side).
    private func x(_ f: Double, width: CGFloat) -> CGFloat {
        let inset = Self.thumb / 2 + Self.strokeInset
        return inset + CGFloat(f) * max(width - 2 * inset, 1)
    }

    private func fraction(atX px: CGFloat, width: CGFloat) -> Double {
        let inset = Self.thumb / 2 + Self.strokeInset
        return Double(min(max((px - inset) / max(width - 2 * inset, 1), 0), 1))
    }

    private func thumbY(width: CGFloat, height: CGFloat) -> CGFloat {
        guard case let .silhouette(samples) = content.kind else { return height / 2 }
        let size = CGSize(width: width - Self.thumb, height: height)
        let points = Sparkline.points(values: samples, in: size, inset: Self.strokeInset)
        guard points.count > 1 else { return height / 2 }
        let position = fraction * Double(points.count - 1)
        let i = min(Int(position), points.count - 2)
        let t = CGFloat(position - Double(i))
        return points[i].y + (points[i + 1].y - points[i].y) * t
    }

    // MARK: Layers

    private func strips(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(content.holds.enumerated()), id: \.offset) { _, hold in
            let start = x(hold.range.lowerBound, width: width)
            let end = max(x(hold.range.upperBound, width: width), start + 12)
            Rectangle()
                .fill(AuraTheme.hairline(contrast))
                .frame(width: end - start, height: height)
                .offset(x: start)
        }
    }

    private func rail(width: CGFloat, height: CGFloat) -> some View {
        let start = x(0, width: width), end = x(1, width: width), head = x(fraction, width: width)
        return ZStack(alignment: .leading) {
            Capsule().fill(AuraTheme.textSecondary.opacity(0.25)).frame(width: end - start, height: 6)
            Capsule().fill(AuraTheme.accent).frame(width: max(head - start, 6), height: 6)
        }
        .offset(x: start, y: height / 2 - 3)
    }

    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        let px = x(fraction, width: width)
        let py = thumbY(width: width, height: height)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(AuraTheme.accent).frame(width: 2, height: height).offset(x: px - 1)
            Circle()
                .fill(AuraTheme.accent)
                .overlay(Circle().strokeBorder(AuraTheme.background, lineWidth: 2))
                .frame(width: Self.thumb, height: Self.thumb)
                .offset(x: px - Self.thumb / 2, y: py - Self.thumb / 2)
            if case .silhouette = content.kind, let tag = readout.elevationText {
                Text(tag)
                    .font(AuraTheme.Typography.unit)
                    .foregroundStyle(AuraTheme.textPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.sm)
                    .padding(.vertical, AuraTheme.Spacing.xs)
                    .background(AuraTheme.surface, in: Capsule())
                    .offset(x: min(px + Self.thumb / 2 + 4, width - 72), y: max(py - 12, 0))
            }
        }
        .animation(reduceMotion || playback.isPlaying ? nil : .easeOut(duration: 0.12), value: fraction)
    }

    /// Duration captions under holds of two minutes or more, dropped when they would overlap
    /// the previous caption (spec D6).
    private var captions: some View {
        GeometryReader { geo in
            let placed = Self.captionPlacements(holds: content.holds, width: geo.size.width,
                                                x: { x($0, width: geo.size.width) })
            ForEach(placed, id: \.center) { item in
                Text(RideStatsFormatter(units: .metric).minutes(item.seconds))
                    .font(.caption2)
                    .foregroundStyle(AuraTheme.secondaryText(contrast))
                    .frame(width: Self.captionWidthEstimate)
                    .position(x: item.center, y: 8)
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    struct CaptionPlacement: Hashable { let center: CGFloat; let seconds: TimeInterval }

    static func captionPlacements(holds: [ReplayHold], width: CGFloat,
                                  x: (Double) -> CGFloat) -> [CaptionPlacement] {
        var out: [CaptionPlacement] = []
        var lastRight: CGFloat = -.infinity
        for hold in holds where hold.seconds >= captionMinSeconds {
            let center = (x(hold.range.lowerBound) + x(hold.range.upperBound)) / 2
            let left = center - captionWidthEstimate / 2
            guard left >= lastRight, center + captionWidthEstimate / 2 <= width else { continue }
            out.append(CaptionPlacement(center: center, seconds: hold.seconds))
            lastRight = center + captionWidthEstimate / 2
        }
        return out
    }

    // MARK: Input

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !playback.isScrubbing { playback.beginScrub(now: now) }
                if abs(value.translation.width) > 4 { dragMoved = true }
                playback.scrub(to: fraction(atX: value.location.x, width: width))
            }
            .onEnded { value in
                if dragMoved {
                    playback.endScrub(now: now)
                } else {
                    playback.endScrub(now: now)
                    playback.jump(to: fraction(atX: value.location.x, width: width))
                }
                dragMoved = false
            }
    }

    /// VoiceOver steps between the timeline's events (spec §5), so every hold is reachable.
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let events = timeline.events
        let target: Double?
        switch direction {
        case .increment: target = events.first { $0 > fraction + 1e-9 }
        case .decrement: target = events.last { $0 < fraction - 1e-9 }
        @unknown default: target = nil
        }
        if let target { playback.jump(to: target) }
    }
}

/// The silhouette alone. `Equatable` on its inputs so a playhead move does not re-stroke it.
private struct ReplaySilhouette: View, Equatable {
    let samples: [Double]
    let contrast: ColorSchemeContrast

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.samples == rhs.samples && lhs.contrast == rhs.contrast }

    var body: some View {
        Canvas { context, size in
            let pts = Sparkline.points(values: samples, in: size, inset: ReplayScrubBand.strokeInset)
            guard pts.count > 1 else { return }
            var line = Path()
            line.move(to: pts[0])
            for p in pts.dropFirst() { line.addLine(to: p) }
            var area = line
            area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(AuraTheme.accent.opacity(0.18)))
            context.stroke(line, with: .color(AuraTheme.accent),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuraTheme.hairline(contrast)).frame(height: 1)
        }
        .equatable()
    }
}
```

Note on `endScrub` before `jump` in the tap branch: `beginScrub` paused playback on touch-down; `endScrub` would resume it if it had been playing, and `jump` then pauses again at the tapped fraction. That is D4 ("tap leaves playback paused"). The order matters: `jump` last.

- [ ] **Step 2: Lint and commit**

Run from the root: `swiftlint lint --strict --quiet`.

```bash
git add Aura/Sources/Ride/Replay/ReplayScrubBand.swift
git commit -m "feat(roh-239): ReplayScrubBand — silhouette or rail, hold strips, thumb, drag

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

**Orchestrator step:** builder agent build. `.equatable()` on a `View` that conforms to `Equatable` is the standard SwiftUI idiom; if the compiler rejects placing it inside `body`, apply it at the call site (`ReplaySilhouette(...).equatable()`) instead.

---

### Task 10: `ReplayInstrumentRow` and `RideReplayView`

**Files:**
- Create: `Aura/Sources/Ride/Replay/ReplayInstrumentRow.swift`
- Create: `Aura/Sources/Ride/Replay/RideReplayView.swift`

**Interfaces:**
- Consumes: everything from Tasks 6–9, `UnfinishedRideBadge(checkpointedAt:style:)`, `AccessibilityAnnouncer.announce`, `RideTestID.replayPlay`.
- Produces: `RideReplayView(ride:timeline:band:)`.

- [ ] **Step 1: Write the row**

```swift
import SwiftUI
import AuraKit

/// The three readouts (spec D5): speed as the hero, distance and time with their totals. One
/// combined VoiceOver element. Wraps to two lines at accessibility sizes.
struct ReplayInstrumentRow: View {
    let readout: ReplayReadout
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 40

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                    hero
                    HStack(spacing: AuraTheme.Spacing.xxl) { distance; time }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
                    hero
                    Spacer(minLength: 0)
                    distance
                    time
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readout.accessibilityLabel)
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
            Text(readout.speedText)
                .font(AuraTheme.Typography.metricBrand(heroSize))
                .monospacedDigit()
                .foregroundStyle(AuraTheme.textPrimary)
            Text(readout.speedUnit)
                .font(AuraTheme.Typography.unit)
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    private var distance: some View {
        StatPair(value: readout.distanceText, label: readout.distanceUnit.uppercased())
    }

    private var time: some View {
        StatPair(value: readout.timeText, label: "TIME")
    }
}
```

- [ ] **Step 2: Write the cover**

```swift
import SwiftUI
import CoreLocation
import AuraCore
import AuraKit

/// The replay cover (spec D7). Owns the playback state and the one-time mappings; the map and
/// the controls each run their own `TimelineView` so the map's body never encloses the row.
struct RideReplayView: View {
    let ride: Ride
    let timeline: ReplayTimeline
    let band: ReplayBandContent

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var playback: ReplayPlayback
    @State private var lines: [[CLLocationCoordinate2D]]
    @State private var announcedHold: ReplayPhase?

    init(ride: Ride, timeline: ReplayTimeline, band: ReplayBandContent) {
        self.ride = ride
        self.timeline = timeline
        self.band = band
        _playback = State(initialValue: ReplayPlayback(playbackDuration: timeline.playbackDuration))
        // Mapped once, here, so no body ever walks `ride.segments`.
        _lines = State(initialValue: ride.segments
            .filter { $0.points.count > 1 }
            .map { $0.points.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude,
                                                          longitude: $0.coordinate.longitude) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ReplayMap(timeline: timeline, lines: lines, playback: playback)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous))
                .padding(.horizontal, AuraTheme.Spacing.lg)
            controls
                .padding(.horizontal, AuraTheme.Spacing.xl)
                .padding(.top, AuraTheme.Spacing.lg)
                .padding(.bottom, AuraTheme.Spacing.xl)
        }
        .background(AuraTheme.background.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: AuraTheme.Spacing.md) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.hudControl(active: false))
                .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
                Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .foregroundStyle(AuraTheme.textPrimary)
                    .lineLimit(2)
                Text(ReplayReadout.subtitle(for: ride))
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.secondaryText(contrast))
                    .lineLimit(1)
                if ride.isUnfinished {
                    UnfinishedRideBadge(checkpointedAt: ride.checkpointedAt, style: .full)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AuraTheme.Spacing.lg)
        .padding(.vertical, AuraTheme.Spacing.md)
    }

    private var controls: some View {
        TimelineView(.animation(paused: !playback.isPlaying)) { context in
            let now = context.date
            let fraction = playback.fraction(at: now)
            // The row re-samples at 4 Hz so numerals do not blur at high rate (spec D5); the
            // band's thumb follows the frame.
            let rowDate = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate * 4).rounded(.down) / 4)
            let rowSample = timeline.sample(at: playback.fraction(at: rowDate))
            let readout = ReplayReadout(sample: rowSample, timeline: timeline, units: settings.units)
            let ended = playback.isPlaying && playback.hasEnded(at: now)
            VStack(spacing: AuraTheme.Spacing.lg) {
                ReplayInstrumentRow(readout: readout)
                ReplayScrubBand(content: band, timeline: timeline, playback: playback,
                                readout: readout, fraction: fraction, now: now)
                playButton(now: now)
            }
            .onChange(of: ended) { _, isEnded in
                if isEnded { playback.settle(now: now) }
            }
            .onChange(of: rowSample.phase) { _, phase in
                // A VoiceOver rider's only channel for a stop reached under play (spec §5).
                guard playback.isPlaying, case .hold = phase, phase != announcedHold,
                      let text = readout.holdText else { return }
                announcedHold = phase
                AccessibilityAnnouncer.announce(text)
            }
        }
    }

    private func playButton(now: Date) -> some View {
        Button { playback.togglePlay(now: now) } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(AuraTheme.background)
                .frame(width: 56, height: 56)
                .background(AuraTheme.accent, in: Circle())
        }
        .accessibilityLabel(playback.isPlaying ? "Pause replay" : "Play replay")
        .accessibilityIdentifier(RideTestID.replayPlay)
    }
}
```

- [ ] **Step 3: Lint and commit**

```bash
git add Aura/Sources/Ride/Replay/ReplayInstrumentRow.swift Aura/Sources/Ride/Replay/RideReplayView.swift
git commit -m "feat(roh-239): RideReplayView assembles the cover

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

**Orchestrator step:** builder agent build.

---

### Task 11: Entry modifier, the one summary line, and the DEBUG seed

**Files:**
- Create: `Aura/Sources/Ride/Replay/RideReplayEntry.swift`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:79` (the `StaticRouteMap(segments: segs)` line)
- Modify: `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift` (append one parser and one static)
- Modify: `Aura/Sources/AuraApp.swift:22` (after `let store = AuraApp.makeRideStore()`)
- Test: `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift` (append one test; find the existing suite with `grep -rn "forcesInMemoryStore" AuraCore/Tests/AuraKitTests`)

**Interfaces:**
- Consumes: `RideReplayView`, `ReplayTimeline`, `ReplayBandContent`, `SyntheticRide.threeHour`, `RideStore.save`, `RideTestID.replayEntry`.
- Produces: `View.replayEntry(ride:)`; `SimulatedRideConfig.seedsLongRide(arguments:)`, `.currentSeedsLongRide`; launch argument `-auraSeedLongRide`.

- [ ] **Step 1: Write the failing config test**

Append to the existing `SimulatedRideConfig` suite in `AuraCore/Tests/AuraKitTests/`:

```swift
    @Test func seedLongRideFlag() {
        #expect(SimulatedRideConfig.seedsLongRide(arguments: ["-auraSeedLongRide"]))
        #expect(SimulatedRideConfig.seedsLongRide(arguments: []) == false)
    }
```

Run: `cd AuraCore && swift test --no-parallel --filter SimulatedRideConfig` — expected: compile error.

- [ ] **Step 2: Add the flag**

In `SimulatedRideConfig.swift`, after `suppressesLaunchOrphanSweep`:

```swift
    /// "-auraSeedLongRide" → DEBUG builds insert `SyntheticRide.threeHour` into the store at
    /// launch, so the replay's cap regime (spec ROH-239 §9) is reachable in a simulator without
    /// a three-hour recording. Idempotent: the ride has a fixed id.
    public static func seedsLongRide(arguments: [String]) -> Bool {
        arguments.contains("-auraSeedLongRide")
    }
```

and beside the other `current…` statics:

```swift
    @MainActor public static let currentSeedsLongRide =
        seedsLongRide(arguments: ProcessInfo.processInfo.arguments)
```

Give the synthetic ride a fixed id so re-launching does not duplicate it: in `SyntheticRide.threeHour`, pass `id: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!` to the `Ride` initializer (the first parameter). Run the config suite and the scale suite; both green.

- [ ] **Step 3: Seed in the app**

In `AuraApp.swift`, directly after `let store = AuraApp.makeRideStore()`:

```swift
        #if DEBUG
        if SimulatedRideConfig.currentSeedsLongRide {
            try? store.save(SyntheticRide.threeHour(startingAt: Date().addingTimeInterval(-4 * 3600)))
        }
        #endif
```

`AuraApp.swift` imports `AuraCore` and `AuraKit` already; verify with `grep -n "^import" Aura/Sources/AuraApp.swift`.

- [ ] **Step 4: Write the entry modifier**

`Aura/Sources/Ride/Replay/RideReplayEntry.swift`:

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The summary's way into replay (spec D1): a Replay pill over the map, and the cover. Applied
/// to `StaticRouteMap` before the summary's own frame/clip/opacity modifiers, so the pill is
/// clipped with the map and fades in with it. The map itself stays inert — ROH-84 taught riders
/// that tapping a map makes it live, and this map does not.
///
/// The timeline and band are built once, off the main actor, and gate the pill: no timeline,
/// or not replayable, and nothing is drawn.
private struct ReplayEntryModifier: ViewModifier {
    let ride: Ride
    @State private var timeline: ReplayTimeline?
    @State private var band: ReplayBandContent?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let timeline, timeline.isReplayable, band != nil {
                    Button { isPresented = true } label: {
                        Label("Replay", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AuraTheme.accent)
                            .padding(.horizontal, AuraTheme.Spacing.md)
                            .padding(.vertical, AuraTheme.Spacing.sm)
                    }
                    .mapChip(Capsule())
                    .padding(AuraTheme.Spacing.md)
                    .accessibilityLabel("Replay this ride")
                    .accessibilityIdentifier(RideTestID.replayEntry)
                }
            }
            .fullScreenCover(isPresented: $isPresented) {
                if let timeline, let band {
                    RideReplayView(ride: ride, timeline: timeline, band: band)
                }
            }
            .task(id: ride.id) {
                let ride = ride
                let built = await Task.detached(priority: .userInitiated) {
                    let timeline = ReplayTimeline(segments: ride.segments)
                    return (timeline, ReplayBandContent(ride: ride, timeline: timeline))
                }.value
                timeline = built.0
                band = built.1
            }
    }
}

extension View {
    /// See `ReplayEntryModifier`.
    func replayEntry(ride: Ride) -> some View {
        modifier(ReplayEntryModifier(ride: ride))
    }
}
```

- [ ] **Step 5: The one line**

In `RideSummaryView.swift`, change

```swift
                    StaticRouteMap(segments: segs)
```

to

```swift
                    StaticRouteMap(segments: segs).replayEntry(ride: ride)
```

Confirm with `git diff --stat Aura/Sources/Ride/RideSummaryView.swift` that exactly one line changed.

- [ ] **Step 6: Lint, run the two package suites, commit**

Run from the root: `swiftlint lint --strict --quiet`. Run: `cd AuraCore && swift test --no-parallel --filter "SimulatedRideConfig|ReplayTimelineScaleTests"`.

```bash
git add Aura/Sources/Ride/Replay/RideReplayEntry.swift Aura/Sources/Ride/RideSummaryView.swift AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift AuraCore/Sources/AuraCore/Replay/SyntheticRide.swift Aura/Sources/AuraApp.swift AuraCore/Tests/AuraKitTests
git commit -m "feat(roh-239): Replay pill on the summary map, and a DEBUG seed for the cap regime

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

**Orchestrator step:** builder agent build, then the simulator pass (Task 12).

---

### Task 12: Simulator verification, board, PR (orchestrator)

**Files:**
- Create: `docs/evidence/roh-239/` screenshots
- Modify: none in code unless the pass finds a defect (then a fix commit with its own test where the rule is pure)

- [ ] **Step 1: Seeded long ride, cap regime**

Build and launch on the iPhone 17 simulator with `-auraSeedLongRide -auraInMemoryRideStore`. Home → History → the seeded ride (4 hours ago) → summary. Screenshot: the Replay pill over the map (`summary-pill-history.png`). Tap Replay. Screenshots: fraction 0 with the disc/triangle on the first vertex (`replay-start.png`); tap play and capture mid-ride (`replay-moving.png`); scrub into the first hold (5 min stop at 0:30) and capture the capsule "Stopped · 5 min", the disc, the strip, its caption (`replay-hold.png`); let it run to the end (`replay-ended.png`); pinch, confirm the recenter control appears, tap it (`replay-recenter.png`).

- [ ] **Step 2: Golden and paused fixtures, floor regime**

Run `scripts/golden-ride.sh` (or launch with `-auraSimulatedRide golden`) to land a real recorded ride; open it from the post-ride summary and confirm the pill and the cover (`summary-pill-postride.png`, `replay-golden.png`). Same with the paused fixture: one `.paused` hold, "Paused · N min" (`replay-paused-fixture.png`).

- [ ] **Step 3: Accessibility states**

Settings → Accessibility → Reduce Motion on: play; confirm the glide continues and the pointer snaps in 45° steps (`replay-reduce-motion.png`). Dynamic Type AX3: the row wraps, the band and button do not clip (`replay-ax3.png`). VoiceOver via the accessibility inspector: the band reads "Ride scrubber", its value is the short readout, adjust moves between events.

- [ ] **Step 4: Board and PR**

Move ROH-239 to In Review. File a `Verification`-labeled issue in Device Verification: "Device pass: ride replay on a 3-hour ride — memory under the cover, marker smoothness at 60 Hz and under pinch, no map stutter" (spec §9). Push the branch, open the PR against `main` with `Verification: Tier 1` and the screenshots, linking the Verification issue and ROH-239. Do not merge until the whole-branch review (pipeline step 6) has run.

---

## Self-review

**Spec coverage.** D1 → Task 11. D2 → Tasks 1, 3. D3 → Task 3 (+ capsule in Task 8, strips in Task 9). D4 → Tasks 6, 9. D5 → Tasks 4, 7, 10. D6 → Tasks 4, 7, 9. D7 → Tasks 8, 10, 11 (`isReplayable` gate in 1 and 11). D8 → Task 8. D9 → Tasks 1, 2. D10 → Tasks 8 (45° rounding), 9 (no animation under Reduce Motion), 8 (snap recenter). D11 → Tasks 6, 7, 10. §4.1–4.14 → Tasks 1–7 as labeled. §5 → Tasks 9, 10. §6 file list → matches the file map; `RideTestID` in Task 7; `RouteStroke` in Task 8. §9 → Tasks 5, 11, 12.

**Placeholder scan.** None. Every code step has its code.

**Type consistency.** `ReplayPhase.hold(ReplayHold.Kind, seconds:)` is used identically in Tasks 1, 3, 5, 7, 8, 10. `ReplayPlayback` method names in Task 6 match every call in Tasks 9 and 10 (`beginScrub(now:)`, `scrub(to:)`, `endScrub(now:)`, `jump(to:)`, `togglePlay(now:)`, `settle(now:)`, `hasEnded(at:)`, `fraction(at:)`, `isScrubbing`, `isPlaying`). `ReplayReadout` members in Task 7 match Task 9 (`elevationText`, `accessibilityValue`, `holdText`) and Task 10 (`speedText`, `speedUnit`, `distanceText`, `distanceUnit`, `timeText`, `accessibilityLabel`). `ReplayBandContent.kind` cases `.silhouette([Double])` / `.rail` and `.holds` match Task 9. `ReplayScrubBand.init` parameters `(content:timeline:playback:readout:fraction:now:)` match Task 10. `ReplayMap.init` `(timeline:lines:playback:)` matches Task 10. `AuraTheme.RouteStroke.width`/`.casingWidth` match Task 8's two uses. `SyntheticRide.threeHour(startingAt:)` matches Tasks 5 and 11.
