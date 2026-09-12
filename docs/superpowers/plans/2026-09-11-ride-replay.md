# Ride Replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Version:** v2 (2026-09-11), reconciled after two independent adversarial plan reviews. v1's pure layer was compiled and run by the skeptic reviewer in a scratch package: one compile error, five lint violations, six failing tests. v1's app layer was type-checked by the architecture reviewer: one compile error, and every playback event was driven by a paused `TimelineView`'s frozen date. Every fix below was verified by the reviewer that found it unless marked otherwise. The reconciliation log is at the end.

**Goal:** Scrub a finished ride back on the summary map: a rider marker runs the recorded track while speed, distance, time, and elevation track a scrubber, with every stop the rider remembers visible as a hold.

**Architecture:** A pure `ReplayTimeline` in AuraCore normalizes a ride's segments into a playback axis of moving legs and holds, and samples any fraction of it without allocation. AuraKit holds the playback state machine (`ReplayPlayback`), the readout strings (`ReplayReadout`), the band content and geometry (`ReplayBandContent`, `ReplayBandGeometry`), and the marker style rule, all tested. The app target is a dumb projection: a `MapViewAnnotation` inside a `TimelineView`, a scrub band, an instrument row, and a one-line entry on the summary.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, SwiftUI (iOS 17 deployment target), MapboxMaps 11.28.0 SwiftUI `Map`, XcodeGen-generated project, SwiftLint 0.64.1 `--strict`.

**Spec:** `docs/superpowers/specs/2026-09-11-ride-replay-design.md` (v2.1). Decisions are cited as D1…D11; invariants as §4.N.

## Global Constraints

- Swift language mode 6; every public pure type is `Sendable` and `Equatable`. Stored properties on `Equatable` structs must be nominal types (a tuple stored property breaks synthesis). `@Observable` classes are `@MainActor`.
- The app target has no unit-test bundle. Every rule lives in AuraCore or AuraKit with a Swift Testing suite; SwiftUI files contain layout only. Pixel↔fraction mapping, caption placement, the thumb's y, and the Reduce Motion bearing rule are rules, and live in AuraKit.
- Never read `ride.flattenedPoints` or map `ride.segments` inside a SwiftUI `body` or a `View.init`. Build once in the entry modifier's task, hold in `@State`, pass down.
- No write to observable state inside a view body. Writes happen in event handlers and `.onChange`.
- **`TimelineView`'s `context.date` is for rendering only.** Every call that mutates `ReplayPlayback` passes `Date()` taken in the event handler. A paused schedule's date is frozen; using it as `now` starts playback from wherever the rider hesitated to.
- SwiftLint `--strict` fails on warnings. Beyond the repo's overrides, the defaults that bite here: `type_body_length` 250 lines (extensions do not count), `function_body_length` 50, `cyclomatic_complexity` 10, `nesting` types at most one level deep, `type_name` 3–40 characters (so no `typealias F`), `line_length` 140, `file_length` 500. No `ultraThinMaterial` outside Theme (use `.mapChip`); no async closure default arguments.
- Mapbox `Map` modifiers (`.gestureOptions`, `.ornamentOptions`, `.mapStyle`) go on the `Map` before any generic SwiftUI modifier.
- Package tests: run from `AuraCore/` with `swift test --no-parallel --filter <Suite>`. One `swift test` at a time on this machine. Lint from the repo root: `swiftlint lint --strict --quiet`.
- App builds are run by the orchestrator via the `apple-platform-build-tools:builder` agent. **Compile-error loop:** after each app-target task the orchestrator regenerates (`cd Aura && xcodegen generate`) and builds the `Aura` scheme for the iPhone 17 simulator. On failure the orchestrator sends the error text to the same implementer, who fixes it and `git commit --amend`s the task's commit; the task is not reviewed until the build is green. The `TaskCompleted` gate runs lint and package tests only; it cannot see an app compile error.
- Config values (D2/D3/D5/D7), verbatim: rate 120; minPlayback 10 s; maxPlayback 45 s; minHold 1.5 s; maxHold 4 s; maxHoldShare 0.25; signalGapSeconds 30 s; holdDistanceMeters 50 m; stoppedSpeed 0.5 m/s; minStopSeconds 45 s; minPauseSeconds 5 s; speedWindowFloor 5 s; speedWindowPlayback 0.1 s; coincidentMeters 0.5 m; minReplayableSeconds 60 s; minReplayableMeters 200 m.
- Copy, verbatim: "Replay", "Replay this ride", "Stopped · 10 min", "Paused · 45 s", "No signal · 3 min", "Play replay", "Pause replay", "Ride scrubber", "Recenter map", "Close", "—".
- Files the branch must not touch: `NavigateHUDView.swift`, `RideMapView.swift`, `RideSummaryView+ShareUpgrade.swift`, every file under `Aura/Sources/GroupRide/`, `AppRoute.swift`, `Aura/Sources/Ride/SimulatedRideSupport.swift`, `AuraCore/Sources/AuraKit/SimulatedLocationProvider.swift`, `SimulatedRideFixture.swift`, `HistoryView.swift`. `RideSummaryView.swift` changes by exactly one line. (`SimulatedRideConfig.swift` is edited, by one flag, in Task 11.)
- Commit after every task with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer.

---

## File map

| File | Responsibility |
|---|---|
| `AuraCore/Sources/AuraCore/Replay/ReplaySample.swift` | `ReplaySample`, `ReplayPhase`, `ReplayHold`. |
| `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift` | Types, `Config`, `init` (layout of spans), `Builder`. |
| `AuraCore/Sources/AuraCore/Replay/ReplayTimeline+Sample.swift` | `sample(at:)`, speed window, bearing window, `profile`, `events` (an extension, so `type_body_length` is not hit). |
| `AuraCore/Sources/AuraCore/Replay/SyntheticRide.swift` | `#if DEBUG` deterministic rides for tests and the seed. |
| `AuraCore/Tests/AuraCoreTests/Replay/ReplayFixtures.swift` | Segment builders. |
| `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` | §4.1–4.12. |
| `AuraCore/Sources/AuraKit/Replay/ReplayPlayback.swift` | Anchor-based playback state; D4, D11. |
| `AuraCore/Sources/AuraKit/Replay/ReplayReadout.swift` | Every displayed string; D5, D7 subtitle. |
| `AuraCore/Sources/AuraKit/Replay/ReplayBandContent.swift` | Silhouette or rail, built once; D6. |
| `AuraCore/Sources/AuraKit/Replay/ReplayBandGeometry.swift` | Pixel↔fraction, thumb y, caption placement; D6. |
| `AuraCore/Sources/AuraKit/Replay/ReplayMarkerStyle.swift` | Reduce Motion bearing rounding; D10. |
| `AuraCore/Tests/AuraKitTests/Replay/*Tests.swift` | §4.13–4.16. |
| `Aura/Sources/Theme/AuraTheme.swift` | `RouteStroke` constants and the hold-strip color (append). |
| `Aura/Sources/Ride/StaticRouteMap.swift`, `Aura/Sources/Plan/RoutePreviewView.swift` | Read `RouteStroke` (two literals each). |
| `Aura/Sources/Ride/Replay/ReplayMap.swift` | `TimelineView` → `Map` → source, layer, marker; recenter; hold capsule. D8. |
| `Aura/Sources/Ride/Replay/ReplayMarkerView.swift` | Puck image + rotation, fixed 34 pt frame. |
| `Aura/Sources/Ride/Replay/ReplayScrubBand.swift` | Silhouette/rail, strips, captions, thumb, drag, a11y. D6. |
| `Aura/Sources/Ride/Replay/ReplayInstrumentRow.swift` | Three readouts. D5. |
| `Aura/Sources/Ride/Replay/RideReplayView.swift` | The cover: top bar, map, controls. D7. |
| `Aura/Sources/Ride/Replay/RideReplayEntry.swift` | The modifier, the pill, the one-time build of timeline/band/lines. D1. |
| `Aura/Sources/Ride/RideSummaryView.swift:76` | One line. |
| `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` | Three identifiers. |
| `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift` | `-auraSeedLongRide` flag. |
| `Aura/Sources/AuraApp.swift:22` | DEBUG seed, in-memory store only. |

---

### Task 1: `ReplayTimeline` — types, builder, layout; construction and normalization tests

**Files:**
- Create: `AuraCore/Sources/AuraCore/Replay/ReplaySample.swift`
- Create: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift`
- Create: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline+Sample.swift`
- Create: `AuraCore/Tests/AuraCoreTests/Replay/ReplayFixtures.swift`
- Create: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift`

**Interfaces:**
- Consumes: `RideSegment`, `TrackPoint`, `Coordinate`, `Geo.distance`, `PeerBearing.heading`.
- Produces: `ReplayTimeline(segments:config:)`, `.config`, `.isReplayable`, `.playbackDuration`, `.rate`, `.speedWindowSeconds`, `.totalDistanceMeters`, `.totalSeconds`, `.drawableLines: [[Coordinate]]`, `.holds`, `.events`, `.sample(at:)`, `.profile(sampleCount:)`; `ReplaySample`, `ReplayPhase`, `ReplayHold`. The whole implementation lands here; Tasks 2–4 add the suites that pin sampling, holds, and speed/profile/events.

- [ ] **Step 1: Create the value types**

`ReplaySample.swift`:

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
    /// Course over the trailing speed window (spec D9); the leg's own course before the
    /// window fills. nil in a hold, at the end, and before the first non-coincident leg.
    public var bearing: Double?
    public var elevation: Double?
    /// Trailing mean over the speed window (spec D5.1). nil → "—".
    public var speedMetersPerSecond: Double?
    public var distanceMeters: Double
    /// Σ normalized leg time up to here: pause gaps excluded, in-segment stops included. A
    /// backwards stamp lengthens the leg after it (spec §3).
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

- [ ] **Step 2: Write the fixtures and the construction suite**

`ReplayFixtures.swift`:

```swift
import Foundation
@testable import AuraCore

/// Segment builders for the replay suites. One point per second unless a builder says
/// otherwise, so "seconds" and "points − 1" are the same number. Distances use the same
/// sphere `Geo.distance` uses (R = 6 371 000 m), so a fixture's meters are the meters the
/// timeline measures, to ~1e-8.
enum ReplayFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let origin = Coordinate(latitude: 40.44, longitude: -79.99)
    static let metersPerDegree = 6_371_000 * Double.pi / 180

    static func east(_ meters: Double, from: Coordinate = origin) -> Coordinate {
        Coordinate(latitude: from.latitude,
                   longitude: from.longitude + meters / (metersPerDegree * cos(from.latitude * .pi / 180)))
    }

    static func north(_ meters: Double, from: Coordinate = origin) -> Coordinate {
        Coordinate(latitude: from.latitude + meters / metersPerDegree, longitude: from.longitude)
    }

    /// `meters` along `bearing` (degrees clockwise from north), flat-earth.
    static func move(_ meters: Double, bearing: Double, from: Coordinate) -> Coordinate {
        let rad = bearing * .pi / 180
        return north(meters * cos(rad), from: east(meters * sin(rad), from: from))
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
        (0..<seconds).map { i in point(east(0.2 * sin(Double(i)), from: at), at: start + Double(i)) }
    }

    /// A quarter circle of radius `radius` m at `speed` m/s. The arc length is what a leg-sum
    /// speed reads; a chord implementation reads less.
    static func quarterCircle(radius: Double = 500, speed: Double = 6, start: TimeInterval = 0) -> RideSegment {
        let seconds = Int((.pi / 2 * radius / speed).rounded(.down))
        return RideSegment(points: (0...seconds).map { i in
            let theta = Double(i) * speed / radius
            return point(north(radius * sin(theta), from: east(radius * cos(theta))), at: start + Double(i))
        })
    }

    /// Legs alternate between bearings 60° and 120° at 6 m/s: the net course is 90° but every
    /// single leg is 30° off it.
    static func zigzag(seconds: Int, start: TimeInterval = 0) -> RideSegment {
        var pts = [point(origin, at: start)]
        var c = origin
        for i in 1...seconds {
            c = move(6, bearing: i.isMultiple(of: 2) ? 60 : 120, from: c)
            pts.append(point(c, at: start + Double(i)))
        }
        return RideSegment(points: pts)
    }

    static func timeline(_ segments: [RideSegment], config: ReplayTimeline.Config = .init()) -> ReplayTimeline {
        ReplayTimeline(segments: segments, config: config)
    }
}
```

`ReplayTimelineTests.swift`:

```swift
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
```

- [ ] **Step 3: Run to verify it fails to compile**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineConstructionTests`
Expected: compile error, `ReplayTimeline` not found.

- [ ] **Step 4: Write the timeline (types, config, builder, layout)**

`ReplayTimeline.swift`:

```swift
import Foundation

/// A finished ride laid out on a playback axis: moving legs at a constant compression of ride
/// time, and holds — pause gaps, stationary runs, lost-signal legs — at a fixed width each
/// (spec D2, D3). Built once; `sample(at:)` (in `ReplayTimeline+Sample.swift`) is a binary
/// search and allocates nothing.
///
/// Time is normalized here: a leg's `dt` is `max(0, next − prev)`, so a backwards or
/// repeated stamp is a zero-width leg that keeps its distance and occupies no time. Nothing
/// downstream guards `dt > 0` again.
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

    struct Endpoint: Sendable, Equatable {
        var coordinate: Coordinate
        var elevation: Double?
    }

    struct Leg: Sendable, Equatable {
        var segment: Int
        var startIndex: Int
        var start: Endpoint
        var end: Endpoint
        var distance: Double
        var dt: TimeInterval
        var bearing: Double?
    }

    struct Hold: Sendable, Equatable {
        var kind: ReplayHold.Kind
        var seconds: TimeInterval
        var anchor: Endpoint
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

    enum SpanContent: Sendable, Equatable {
        case leg(Leg)
        case hold(Hold)
    }

    struct Span: Sendable, Equatable {
        var content: SpanContent
        var playStart: TimeInterval
        var width: TimeInterval
        /// `playStart / playbackDuration`, stored so the search uses the SAME divided value the
        /// hold ranges are built from. Searching on seconds put a hold's exclusive end back
        /// inside the hold in 94 of 115 sampled gaps (plan review, v1).
        var fractionStart: Double
        var distanceAtStart: Double
        var secondsAtStart: TimeInterval
    }

    /// Per drawable segment: global cumulative seconds and distance at each point, the point
    /// coordinates, and for each point the index the speed/bearing window may not look behind
    /// (the end of the last in-segment hold, spec D5.1).
    struct SegmentIndex: Sendable, Equatable {
        var times: [TimeInterval]
        var distances: [Double]
        var coordinates: [Coordinate]
        var windowFloor: [Int]
    }

    public let config: Config
    public let playbackDuration: TimeInterval
    public let rate: Double
    /// `max(speedWindowFloor, rate × speedWindowPlayback)`: 12 s at 120×, 5 s at 30× (D5.1).
    public let speedWindowSeconds: TimeInterval
    public let totalDistanceMeters: Double
    public let totalSeconds: TimeInterval
    public let isReplayable: Bool
    /// The coordinates of every drawable segment (≥ 2 points), in order. The one definition of
    /// "drawable" the map and the sampler share.
    public let drawableLines: [[Coordinate]]
    public let holds: [ReplayHold]
    public let events: [Double]

    let spans: [Span]
    let segmentIndices: [SegmentIndex]
    let first: Endpoint?
    let last: Endpoint?

    public init(segments: [RideSegment], config: Config = .init()) {
        self.config = config
        let drawable = segments.filter { $0.points.count > 1 }
        var builder = Builder(config: config)
        for (index, segment) in drawable.enumerated() { builder.add(segment, index: index) }
        segmentIndices = builder.segmentIndices
        totalDistanceMeters = builder.cumulativeDistance
        totalSeconds = builder.cumulativeSeconds
        drawableLines = drawable.map { $0.points.map(\.coordinate) }
        first = drawable.first.map { Endpoint(coordinate: $0.points[0].coordinate, elevation: $0.points[0].elevation) }
        last = drawable.last.map { seg in
            let p = seg.points[seg.points.count - 1]
            return Endpoint(coordinate: p.coordinate, elevation: p.elevation)
        }
        let layout = Self.layout(items: builder.items, config: config)
        playbackDuration = layout.duration
        rate = layout.rate
        speedWindowSeconds = max(config.speedWindowFloor, layout.rate * config.speedWindowPlayback)
        spans = layout.spans
        holds = layout.spans.compactMap { span in
            guard case let .hold(hold) = span.content else { return nil }
            return ReplayHold(kind: hold.kind, seconds: hold.seconds,
                              range: span.fractionStart..<((span.playStart + span.width) / layout.duration))
        }
        isReplayable = !drawable.isEmpty
            && layout.movingSpan >= config.minReplayableSeconds
            && totalDistanceMeters >= config.minReplayableMeters
        events = Self.events(spans: spans, holds: holds, duration: layout.duration)
    }

    struct Layout {
        var spans: [Span]
        var duration: TimeInterval
        var rate: Double
        var movingSpan: TimeInterval
    }

    /// D2 + D3: the moving span at constant compression, holds at clamped widths capped as a
    /// share of the moving playback. `duration` is the exact sum, not an accumulation.
    static func layout(items: [Item], config: Config) -> Layout {
        var movingSpan: TimeInterval = 0
        for case let .leg(leg) in items { movingSpan += leg.dt }
        let movingPlayback = min(max(movingSpan / config.rate, config.minPlayback), config.maxPlayback)
        let rate = movingSpan / movingPlayback

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
        let duration = movingPlayback + holdWidths.reduce(0, +)

        var spans: [Span] = []
        var play: TimeInterval = 0, distance = 0.0, seconds: TimeInterval = 0
        var holdCursor = 0
        for item in items {
            switch item {
            case let .skip(d):
                distance += d
            case let .leg(leg):
                let width = movingSpan > 0 ? leg.dt * movingPlayback / movingSpan : 0
                if width > 0 {
                    spans.append(Span(content: .leg(leg), playStart: play, width: width,
                                      fractionStart: play / duration, distanceAtStart: distance, secondsAtStart: seconds))
                    play += width
                }
                distance += leg.distance
                seconds += leg.dt
            case let .hold(hold):
                let width = holdWidths[holdCursor]
                holdCursor += 1
                spans.append(Span(content: .hold(hold), playStart: play, width: width,
                                  fractionStart: play / duration, distanceAtStart: distance, secondsAtStart: seconds))
                play += width
                distance += hold.distance
                if hold.advancesClock { seconds += hold.seconds }
            }
        }
        return Layout(spans: spans, duration: duration, rate: rate, movingSpan: movingSpan)
    }

    /// Walks segments once, classifying legs (spec D2) and emitting items in ride order.
    struct Builder {
        let config: Config
        var items: [Item] = []
        var segmentIndices: [SegmentIndex] = []
        var cumulativeDistance = 0.0
        var cumulativeSeconds: TimeInterval = 0
        private var previousLast: TrackPoint?
        /// Legs of the stationary run being accumulated; flushed at a moving leg or the end.
        private var run: [Leg] = []
        private var lastBearing: Double?
        /// Point indices in the current segment where an in-segment hold ends.
        private var barriers: [Int] = []

        init(config: Config) { self.config = config }

        mutating func add(_ segment: RideSegment, index: Int) {
            let points = segment.points
            addPauseGap(before: points[0])
            lastBearing = nil
            barriers = []
            var times = [cumulativeSeconds], distances = [cumulativeDistance]
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                let dt = max(0, b.timestamp.timeIntervalSince(a.timestamp))
                let d = Geo.distance(a.coordinate, b.coordinate)
                cumulativeDistance += d
                cumulativeSeconds += dt
                times.append(cumulativeSeconds)
                distances.append(cumulativeDistance)
                if d >= config.coincidentMeters { lastBearing = PeerBearing.heading(from: a.coordinate, to: b.coordinate) }
                let leg = Leg(segment: index, startIndex: i - 1,
                              start: Endpoint(coordinate: a.coordinate, elevation: a.elevation),
                              end: Endpoint(coordinate: b.coordinate, elevation: b.elevation),
                              distance: d, dt: dt, bearing: lastBearing)
                classify(leg, endIndex: i)
            }
            flushRun()
            segmentIndices.append(SegmentIndex(times: times, distances: distances,
                                               coordinates: points.map(\.coordinate),
                                               windowFloor: Self.floors(barriers: barriers, count: points.count)))
            previousLast = points[points.count - 1]
        }

        private mutating func addPauseGap(before first: TrackPoint) {
            guard let prev = previousLast else { return }
            let gap = max(0, first.timestamp.timeIntervalSince(prev.timestamp))
            guard gap >= config.minPauseSeconds else { return }
            items.append(.hold(Hold(kind: .paused, seconds: gap,
                                    anchor: Endpoint(coordinate: prev.coordinate, elevation: prev.elevation),
                                    advancesClock: false, distance: 0)))
        }

        private mutating func classify(_ leg: Leg, endIndex: Int) {
            if leg.dt >= config.signalGapSeconds {
                flushRun()
                let kind: ReplayHold.Kind = leg.distance < config.holdDistanceMeters ? .stopped : .signalLost
                items.append(.hold(Hold(kind: kind, seconds: leg.dt, anchor: leg.start,
                                        advancesClock: true, distance: leg.distance)))
                barriers.append(endIndex)
            } else if leg.dt == 0 {
                // Zero width. A real displacement with no time is not "stopped"; it breaks a run.
                if leg.distance >= config.coincidentMeters { flushRun(); items.append(.skip(distance: leg.distance)) }
                else if run.isEmpty { items.append(.skip(distance: leg.distance)) }
                else { run.append(leg) }
            } else if leg.distance / leg.dt < config.stoppedSpeed {
                run.append(leg)
            } else {
                flushRun()
                items.append(.leg(leg))
            }
        }

        private mutating func flushRun() {
            guard let head = run.first, let tail = run.last else { return }
            let seconds = run.reduce(0) { $0 + $1.dt }
            if seconds >= config.minStopSeconds {
                items.append(.hold(Hold(kind: .stopped, seconds: seconds, anchor: head.start,
                                        advancesClock: true, distance: run.reduce(0) { $0 + $1.distance })))
                barriers.append(tail.startIndex + 1)
            } else {
                for leg in run { items.append(leg.dt > 0 ? .leg(leg) : .skip(distance: leg.distance)) }
            }
            run.removeAll(keepingCapacity: true)
        }

        /// `floors[j]` = the greatest barrier ≤ j, or 0.
        static func floors(barriers: [Int], count: Int) -> [Int] {
            var out = [Int](repeating: 0, count: count)
            var current = 0
            var next = 0
            for j in 0..<count {
                while next < barriers.count, barriers[next] <= j { current = barriers[next]; next += 1 }
                out[j] = current
            }
            return out
        }
    }
}
```

- [ ] **Step 5: Write the sampling extension**

`ReplayTimeline+Sample.swift`:

```swift
import Foundation

extension ReplayTimeline {
    /// Total: any fraction, clamped to 0…1. With no drawable segment the sample is the origin
    /// at `.ended`; the entry point never presents such a timeline (`isReplayable`).
    public func sample(at fraction: Double) -> ReplaySample {
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        guard let first else {
            return ReplaySample(coordinate: Coordinate(latitude: 0, longitude: 0), bearing: nil, elevation: nil,
                                speedMetersPerSecond: nil, distanceMeters: 0, seconds: 0, phase: .ended)
        }
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
        let span = spans[spanIndex(atFraction: f)]
        let t = min(max((f * playbackDuration - span.playStart) / span.width, 0), 1)
        switch span.content {
        case let .leg(leg):
            let coordinate = Coordinate(
                latitude: leg.start.coordinate.latitude + (leg.end.coordinate.latitude - leg.start.coordinate.latitude) * t,
                longitude: leg.start.coordinate.longitude + (leg.end.coordinate.longitude - leg.start.coordinate.longitude) * t)
            let seconds = span.secondsAtStart + leg.dt * t
            let window = window(segment: leg.segment, at: seconds)
            return ReplaySample(coordinate: coordinate,
                                bearing: window.bearing ?? leg.bearing,
                                elevation: Self.lerp(leg.start.elevation, leg.end.elevation, t),
                                speedMetersPerSecond: window.speed,
                                distanceMeters: span.distanceAtStart + leg.distance * t,
                                seconds: seconds, phase: .moving)
        case let .hold(hold):
            return ReplaySample(coordinate: hold.anchor.coordinate, bearing: nil, elevation: hold.anchor.elevation,
                                speedMetersPerSecond: nil, distanceMeters: span.distanceAtStart,
                                seconds: hold.advancesClock ? span.secondsAtStart + hold.seconds * t : span.secondsAtStart,
                                phase: .hold(hold.kind, seconds: hold.seconds))
        }
    }

    /// Elevation at `sampleCount` uniform playback fractions (spec D6). nil when no point has one.
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

    // MARK: - Internals

    private static func lerp(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        switch (a, b) {
        case let (a?, b?): return a + (b - a) * t
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Last span whose `fractionStart` ≤ `f`. Spans start at 0 and are contiguous.
    private func spanIndex(atFraction f: Double) -> Int {
        var lo = 0, hi = spans.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if spans[mid].fractionStart <= f { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Spec D5.1 + D9: the trailing window `[T − w, T]` within the segment, never reaching back
    /// past the last in-segment hold. Speed is Σ leg distances over the time span; bearing is
    /// the course between the window's endpoints. Both nil with fewer than two points.
    private func window(segment: Int, at seconds: TimeInterval) -> (speed: Double?, bearing: Double?) {
        let index = segmentIndices[segment]
        let j = Self.lastIndex(in: index.times, atOrBefore: seconds)
        let i = max(Self.firstIndex(in: index.times, atOrAfter: seconds - speedWindowSeconds), index.windowFloor[j])
        guard j > i else { return (nil, nil) }
        let span = index.times[j] - index.times[i]
        let speed = span > 0 ? (index.distances[j] - index.distances[i]) / span : nil
        let a = index.coordinates[i], b = index.coordinates[j]
        let bearing = Geo.distance(a, b) >= config.coincidentMeters ? PeerBearing.heading(from: a, to: b) : nil
        return (speed, bearing)
    }

    static func lastIndex(in times: [TimeInterval], atOrBefore t: TimeInterval) -> Int {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    static func firstIndex(in times: [TimeInterval], atOrAfter t: TimeInterval) -> Int {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] >= t { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// Spec §4.10: 0, every hold edge, every whole km and mi (a mark that falls inside a hold's
    /// folded distance lands on the hold's start), and 1 — sorted, deduplicated, 1 always kept.
    static func events(spans: [Span], holds: [ReplayHold], duration: TimeInterval) -> [Double] {
        var out: [Double] = [0]
        for hold in holds { out.append(hold.range.lowerBound); out.append(hold.range.upperBound) }
        for span in spans {
            let (distance, from): (Double, Double)
            switch span.content {
            case let .leg(leg): (distance, from) = (leg.distance, span.distanceAtStart)
            case let .hold(hold): (distance, from) = (hold.distance, span.distanceAtStart)
            }
            guard distance > 0 else { continue }
            for unit in [1000.0, 1609.344] {
                var k = (from / unit).rounded(.down) + 1
                while k * unit <= from + distance {
                    let within = (k * unit - from) / distance
                    let offset: Double
                    if case .leg = span.content { offset = within * span.width } else { offset = 0 }
                    out.append((span.playStart + offset) / duration)
                    k += 1
                }
            }
        }
        out = out.filter { $0 < 1 - 1e-9 }.sorted()
        var deduped: [Double] = []
        for f in out where deduped.last.map({ f - $0 > 1e-9 }) ?? true { deduped.append(f) }
        deduped.append(1)
        return deduped
    }
}
```

- [ ] **Step 6: Run the construction suite until it passes**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineConstructionTests`
Expected: all 9 pass.

- [ ] **Step 7: Lint and commit**

Run from the root: `swiftlint lint --strict --quiet` — expected: no output. If `cyclomatic_complexity` fires on `Builder.classify`, split the `dt == 0` branch into a helper.

```bash
git add AuraCore/Sources/AuraCore/Replay AuraCore/Tests/AuraCoreTests/Replay
git commit -m "feat(roh-239): ReplayTimeline builds a normalized playback axis

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Sampling on moving legs, totals, bearing, never-a-chord across a pause

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline*.swift` (only if a test fails)
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append)

- [ ] **Step 1: Append the sampling suite**

```swift
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
```

- [ ] **Step 2: Run, fix, commit**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineSamplingTests`. Expected: all pass. `bearingIsSmoothOverTheWindow`: the zig-zag's window endpoints 5 s apart give a course within a few degrees of 90; if it reads 60/120 the sampler is returning `leg.bearing` instead of the window's.

```bash
git add AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift AuraCore/Sources/AuraCore/Replay
git commit -m "test(roh-239): ReplayTimeline sampling, totals, bearing, and the pause chord are pinned

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Holds — pause gaps, stationary runs, lost signal, widths, share cap

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline*.swift` (only if a test fails)
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append)

- [ ] **Step 1: Append the holds suite**

```swift
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
```

- [ ] **Step 2: Run, fix, commit**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineHoldTests`. Expected: all pass. `sixtySecondsOfJitterIsOneStoppedHold` expects 61 s: the leg from the last straight point into the first jitter point is ~0.2 m over 1 s, so it joins the run (v1 said 60 and was wrong).

```bash
git add AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift AuraCore/Sources/AuraCore/Replay
git commit -m "test(roh-239): holds — pauses, stops, lost signal, widths, share cap

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Speed window, profile, events

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Replay/ReplayTimeline*.swift` (only if a test fails)
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append)

- [ ] **Step 1: Append the suite**

```swift
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

    /// D5.1: the window never reaches back across a hold, so a lost leg's 900 m / 120 s never
    /// fabricates a speed for the seconds after it.
    @Test func speedAfterALostLegIgnoresTheGap() {
        var pts = Fixtures.straight(seconds: 200).points
        let to = Fixtures.east(2100)
        pts.append(Fixtures.point(to, at: 320))                                        // 120 s, 900 m
        pts.append(contentsOf: Fixtures.straight(seconds: 200, start: 321, from: to).points.dropFirst())
        let t = Fixtures.timeline([RideSegment(points: pts)])
        let hold = t.holds[0]
        let justAfter = t.sample(at: hold.range.upperBound + 0.002)
        #expect(justAfter.seconds > 320 && justAfter.seconds < 326)
        #expect(justAfter.speedMetersPerSecond == nil || abs((justAfter.speedMetersPerSecond ?? 0) - 6) < 0.1)
        let later = t.sample(at: (hold.range.upperBound + 1) / 2)
        #expect(abs((later.speedMetersPerSecond ?? 0) - 6) < 0.05)
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
```

- [ ] **Step 2: Run the whole replay group, lint, commit**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimeline` then `swiftlint lint --strict --quiet`. In `profileRepeatsThroughAHoldAndCarriesAcrossNil` the second filter is deliberately loose; if it selects zero indices, replace it with a direct check that `t.sample(at:)` at the fraction of ride-second 300 has an elevation within 0.2 of 330.

```bash
git add AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift AuraCore/Sources/AuraCore/Replay
git commit -m "test(roh-239): speed window, profile, and events are pinned

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `SyntheticRide` and the scale test

**Files:**
- Create: `AuraCore/Sources/AuraCore/Replay/SyntheticRide.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift` (append)

**Interfaces:**
- Produces: `SyntheticRide.threeHour(startingAt:) -> Ride` (public, `#if DEBUG`; fixed id `00000000-0000-0000-0000-00000000C0DE`). Spec deviation, stated: the builder lives in the library rather than the test target because the DEBUG seed (Task 11) inserts it into the store; `#if DEBUG` keeps it out of release.

- [ ] **Step 1: Write the failing scale test**

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineScaleTests` — compile error, `SyntheticRide` not found.

- [ ] **Step 3: Write the builder**

```swift
#if DEBUG
import Foundation

/// Deterministic rides for the replay suites and the DEBUG seed (spec §9). Not a fixture of
/// anything real: a loop around a center at a constant 6 m/s with four stops placed where the
/// playback regime needs them. In the library rather than the test target because the app's
/// DEBUG seed inserts it into the store; `#if DEBUG` keeps it out of release.
public enum SyntheticRide {
    static let center = Coordinate(latitude: 40.44, longitude: -79.99)
    public static let threeHourID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    /// 3 hours, one point per second, 10,800 points in two segments (split at i == 5400):
    /// - i 1800…2099: 300 s of jitter (a `.stopped` hold)
    /// - between i 5399 and 5400: the second segment starts 601 s after the first ends (`.paused`)
    /// - i 7200 (in the second segment): one leg stamped 120 s late spanning 700 m (`.signalLost`),
    ///   followed by a backwards stamp that normalizes to zero width
    /// - i 9000…9089: 90 s of jitter (`.stopped`)
    /// Elevation is a slow three-lobe wave over 300–380 m so the profile has a shape.
    public static func threeHour(startingAt start: Date) -> Ride {
        let speed = 6.0
        let totalSeconds = 10_800
        let radius = speed * Double(totalSeconds) / (2 * .pi)
        let metersPerDegreeLat = 6_371_000 * Double.pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * cos(center.latitude * .pi / 180)

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

        var first: [TrackPoint] = [], second: [TrackPoint] = []
        var meters = 0.0
        for i in 0..<totalSeconds {
            let stamp = start.addingTimeInterval(Double(i))
            let stationary = (1800..<2100).contains(i) || (9000..<9090).contains(i)
            var point: TrackPoint
            if stationary {
                point = TrackPoint(coordinate: jitter(onLoop(meters), i), elevation: elevation(meters), timestamp: stamp)
            } else if i == 7200 {
                meters += 700
                point = TrackPoint(coordinate: onLoop(meters), elevation: elevation(meters),
                                   timestamp: stamp.addingTimeInterval(119))
            } else {
                point = TrackPoint(coordinate: onLoop(meters), elevation: elevation(meters), timestamp: stamp)
                meters += speed
            }
            if i < 5400 {
                first.append(point)
            } else {
                point.timestamp = point.timestamp.addingTimeInterval(600)
                second.append(point)
            }
        }
        let segments = [RideSegment(points: first), RideSegment(points: second)]
        return Ride(id: threeHourID, kind: .freeRide, startedAt: start, endedAt: second[second.count - 1].timestamp,
                    segments: segments, stats: RideStatsCalculator.stats(segments: segments), pausedSeconds: 601,
                    destinationName: nil, routeId: nil, destinationPlaceId: nil)
    }
}
#endif
```

- [ ] **Step 4: Run until green, lint, commit**

Run: `cd AuraCore && swift test --no-parallel --filter ReplayTimelineScaleTests`.

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
- Produces: `@MainActor @Observable public final class ReplayPlayback` with `init(playbackDuration:)`, `anchorFraction`, `isPlaying`, `isScrubbing`, `fraction(at:)`, `hasEnded(at:)`, `play(now:)`, `pause(now:)`, `togglePlay(now:)`, `beginScrub(now:)`, `scrub(to:)`, `endScrub(now:)`, `tap(to:now:)`, `cancelScrub()`, `settle()`. Every `now` is the caller's live `Date()`, never a `TimelineView` date.

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
        #expect(p.fraction(at: t0) == 0 && p.fraction(at: t0 + 100) == 0)
        #expect(p.isPlaying == false)
    }

    @Test func playingAdvancesLinearlyAndClampsBothEnds() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0)
        #expect(p.isPlaying)
        #expect(abs(p.fraction(at: t0 + 5) - 0.25) < 1e-12)
        #expect(p.fraction(at: t0 + 20) == 1 && p.fraction(at: t0 + 99) == 1)
        #expect(p.fraction(at: t0 - 5) == 0)                          // a quantized-down date never goes negative
        #expect(p.hasEnded(at: t0 + 20) && p.hasEnded(at: t0 + 19) == false)
    }

    /// The rule the view must honor: `play` anchors at the date it is GIVEN. A rider who looks
    /// at the paused screen for a minute and then taps Play starts at 0, not at 1.
    @Test func playAfterALongPauseStartsAtZero() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0 + 60)
        #expect(p.fraction(at: t0 + 60) == 0)
        #expect(abs(p.fraction(at: t0 + 65) - 0.25) < 1e-12)
    }

    @Test func pauseFreezesWhereItWas() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.pause(now: t0 + 5)
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
        p.beginScrub(now: t0); p.scrub(to: 0.3); p.endScrub(now: t0 + 1)
        #expect(p.isPlaying == false && p.fraction(at: t0 + 9) == 0.3)
    }

    @Test func scrubToTheEndDoesNotResume() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1); p.scrub(to: 1); p.endScrub(now: t0 + 2)
        #expect(p.isPlaying == false && p.fraction(at: t0 + 3) == 1)
    }

    /// D4: a tap on the band lands paused at the tapped fraction, whatever was happening.
    @Test func tapWhilePlayingLandsPaused() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1)
        p.tap(to: 0.4, now: t0 + 1)
        #expect(p.isPlaying == false && p.isScrubbing == false)
        #expect(p.fraction(at: t0 + 30) == 0.4)
        p.tap(to: 1.7, now: t0 + 2)
        #expect(p.fraction(at: t0 + 3) == 1)
    }

    @Test func aSecondBeginScrubDoesNotOverwriteTheResumeIntent() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1); p.beginScrub(now: t0 + 2)
        p.endScrub(now: t0 + 3)
        #expect(p.isPlaying)
    }

    @Test func cancelScrubClearsTheLatch() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 1); p.cancelScrub()
        #expect(p.isScrubbing == false && p.isPlaying == false)
        p.beginScrub(now: t0 + 5); p.endScrub(now: t0 + 6)
        #expect(p.isPlaying == false)                                 // the old "was playing" did not leak
    }

    @Test func settleParksAtOneAndPlayRestartsFromZero() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.settle()
        #expect(p.isPlaying == false && p.anchorFraction == 1)
        p.play(now: t0 + 40)
        #expect(abs(p.fraction(at: t0 + 45) - 0.25) < 1e-12)
    }

    @Test func togglePlayFlips() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.togglePlay(now: t0); #expect(p.isPlaying)
        p.togglePlay(now: t0 + 2); #expect(p.isPlaying == false)
        #expect(abs(p.fraction(at: t0 + 9) - 0.1) < 1e-12)
    }

    @Test func zeroDurationNeverDividesByZero() {
        let p = ReplayPlayback(playbackDuration: 0)
        p.play(now: t0)
        #expect(p.fraction(at: t0 + 1).isFinite)
    }

    @Test func playWhileScrubbingIsIgnored() {
        let p = ReplayPlayback(playbackDuration: 20)
        p.play(now: t0); p.beginScrub(now: t0 + 2); p.scrub(to: 0.4)
        p.play(now: t0 + 3)                                   // second finger on Play mid-drag
        #expect(p.isPlaying == false && p.isScrubbing)
        #expect(abs(p.fraction(at: t0 + 4) - 0.4) < 1e-9)     // still parked where the drag left it
        p.endScrub(now: t0 + 5)                               // the drag's own resume rule still applies
        #expect(p.isPlaying && p.isScrubbing == false)
        #expect(abs(p.fraction(at: t0 + 7) - 0.5) < 1e-9)     // 0.4 + 2 s / 20 s
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `cd AuraCore && swift test --no-parallel --filter ReplayPlaybackTests` → compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// Playback state for the replay screen (spec D11). The fraction is DERIVED from an anchor,
/// never accumulated: a view reads `fraction(at:)` with its clock's date and writes nothing.
/// Every write is an event, and every event takes the caller's LIVE `Date()`. A paused
/// `TimelineView` hands out a frozen date; anchoring on it starts playback from wherever
/// the rider hesitated to (plan review, v1).
///
/// In AuraKit rather than the app target for the reason `ShareUpgradePresenter` is: the app
/// target has no test bundle.
@MainActor @Observable
public final class ReplayPlayback {
    public let playbackDuration: TimeInterval
    public private(set) var anchorFraction: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isScrubbing = false
    @ObservationIgnored private var anchorDate = Date.distantPast
    @ObservationIgnored private var resumeAfterScrub = false

    public init(playbackDuration: TimeInterval) {
        self.playbackDuration = max(playbackDuration, 0.001)
    }

    public func fraction(at now: Date) -> Double {
        guard isPlaying else { return anchorFraction }
        return Self.clamp(anchorFraction + now.timeIntervalSince(anchorDate) / playbackDuration)
    }

    public func hasEnded(at now: Date) -> Bool { fraction(at: now) >= 1 }

    /// D4: play at the end restarts from 0.
    /// A scrub owns playback until it ends (spec D4); Play mid-drag is a no-op.
    public func play(now: Date) {
        guard !isScrubbing else { return }
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

    /// Idempotent: a second touch-down during a scrub keeps the first one's resume intent.
    public func beginScrub(now: Date) {
        guard !isScrubbing else { return }
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

    /// A tap on the band (a drag that never moved): land there, paused, whatever was happening.
    public func tap(to fraction: Double, now: Date) {
        isScrubbing = false
        resumeAfterScrub = false
        anchorFraction = Self.clamp(fraction)
        isPlaying = false
    }

    /// A drag that never delivered `onEnded` (system gesture, dismissal): drop the latch.
    public func cancelScrub() {
        isScrubbing = false
        resumeAfterScrub = false
    }

    /// Called by the view when it observes `hasEnded`: park at 1, not playing.
    public func settle() {
        anchorFraction = 1
        isPlaying = false
    }

    private static func clamp(_ f: Double) -> Double { min(max(f.isFinite ? f : 0, 0), 1) }
}
```

- [ ] **Step 4: Run until green, lint, commit**

```bash
git add AuraCore/Sources/AuraKit/Replay/ReplayPlayback.swift AuraCore/Tests/AuraKitTests/Replay/ReplayPlaybackTests.swift
git commit -m "feat(roh-239): ReplayPlayback derives the fraction from an anchor

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `ReplayReadout`, `ReplayBandContent`, `ReplayBandGeometry`, `ReplayMarkerStyle`, identifiers (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Replay/ReplayReadout.swift`, `ReplayBandContent.swift`, `ReplayBandGeometry.swift`, `ReplayMarkerStyle.swift`
- Create: `AuraCore/Tests/AuraKitTests/Replay/ReplayReadoutTests.swift`, `ReplayBandGeometryTests.swift`
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` (append three identifiers inside `RideTestID`)

**Interfaces:**
- Produces: `ReplayReadout(sample:timeline:units:)` with `speedText`, `speedUnit`, `distanceText`, `distanceUnit`, `timeText`, `elevationText`, `holdText`, `accessibilityValue`, `accessibilityLabel`; `ReplayReadout.holdLabel(kind:seconds:)`, `.subtitle(for:)`. `ReplayBandContent(ride:timeline:)` with `kind` (`.silhouette([Double])`/`.rail`), `holds`, `.sampleCount`. `ReplayBandGeometry(width:thumb:strokeInset:)` with `x(_:)`, `fraction(atX:)`, `thumbY(fraction:samples:height:)`, `stripFrame(_:)`, `captionCenters(holds:captionWidth:minSeconds:)`. `ReplayMarkerStyle.displayBearing(_:reduceMotion:)`. `RideTestID.replayEntry`, `.replayPlay`, `.replayBand`.

- [ ] **Step 1: Write the failing tests**

`ReplayReadoutTests.swift` — the `ReplayReadoutTests` and `ReplayBandContentTests` suites from plan v1 are unchanged **except**: in `ReplayBandContentTests.holdsAreCarriedFromTheTimeline`, build the ride from two segments with a 300 s gap so the timeline has one hold, and assert `c.holds.count == 1 && c.holds[0].kind == .paused`. (Copy the v1 suites verbatim from the reconciliation log's pointer; the skeptic ran them green, 17/17.)

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
```

`ReplayBandGeometryTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ReplayBandGeometryTests {
    let g = ReplayBandGeometry(width: 343, thumb: 28, strokeInset: 2)

    @Test func endpointsAreInsetByHalfTheThumbPlusTheStroke() {
        #expect(g.x(0) == 16 && g.x(1) == 327)
        #expect(abs(g.x(0.5) - 171.5) < 1e-9)
    }

    @Test func fractionAtXIsTheInverseAndClamps() {
        for f in stride(from: 0.0, through: 1, by: 0.05) { #expect(abs(g.fraction(atX: g.x(f)) - f) < 1e-12) }
        #expect(g.fraction(atX: -50) == 0 && g.fraction(atX: 999) == 1)
    }

    @Test func degenerateWidthNeverDividesByZero() {
        let tiny = ReplayBandGeometry(width: 10, thumb: 28, strokeInset: 2)
        #expect(tiny.fraction(atX: 5).isFinite && tiny.x(0.5).isFinite)
    }

    @Test func thumbYFollowsTheSilhouetteAndCentersOnTheRail() {
        let rising: [Double] = [0, 10, 20, 30, 40]
        let top = g.thumbY(fraction: 1, samples: rising, height: 88)
        let bottom = g.thumbY(fraction: 0, samples: rising, height: 88)
        #expect(top < bottom)
        let mid = g.thumbY(fraction: 0.5, samples: rising, height: 88)
        #expect(abs(mid - (top + bottom) / 2) < 1e-9)
        #expect(g.thumbY(fraction: 0.3, samples: nil, height: 88) == 44)
    }

    @Test func stripsHaveAMinimumWidth() {
        let narrow = ReplayHold(kind: .paused, seconds: 60, range: 0.5..<0.501)
        let frame = g.stripFrame(narrow)
        #expect(frame.width == 12)
        #expect(abs((frame.x + 6) - (g.x(0.5) + g.x(0.501)) / 2) < 1e-9)
        let wide = ReplayHold(kind: .paused, seconds: 600, range: 0.2..<0.4)
        #expect(abs(g.stripFrame(wide).width - (g.x(0.4) - g.x(0.2))) < 1e-9)
    }

    /// A short hold near either end of the ride would otherwise widen past `x(0)`/`x(1)` — the
    /// farthest the thumb can actually sit — since the naive fix only extends rightward.
    @Test func stripsNearTheEndsStayOnTheTrack() {
        let nearEnd = ReplayHold(kind: .paused, seconds: 60, range: 0.997..<0.9985)
        let endFrame = g.stripFrame(nearEnd)
        #expect(endFrame.width == 12)
        #expect(endFrame.x + endFrame.width <= g.x(1) + 1e-9)

        let nearStart = ReplayHold(kind: .paused, seconds: 60, range: 0.001..<0.002)
        let startFrame = g.stripFrame(nearStart)
        #expect(startFrame.width == 12)
        #expect(startFrame.x >= g.x(0) - 1e-9)
    }

    @Test func captionsDropWhenTheyWouldOverlapAndSkipShortHolds() {
        let holds = [
            ReplayHold(kind: .stopped, seconds: 600, range: 0.10..<0.14),   // caption
            ReplayHold(kind: .stopped, seconds: 300, range: 0.15..<0.18),   // overlaps → dropped
            ReplayHold(kind: .paused, seconds: 60, range: 0.50..<0.52),     // under 120 s → none
            ReplayHold(kind: .signalLost, seconds: 180, range: 0.80..<0.83) // caption
        ]
        let centers = g.captionCenters(holds: holds, captionWidth: 44, minSeconds: 120)
        #expect(centers.map(\.seconds) == [600, 180])
        #expect(abs(centers[0].center - (g.x(0.10) + g.x(0.14)) / 2) < 1e-9)
    }
}

struct ReplayMarkerStyleTests {
    @Test func reduceMotionRoundsToTheEightPointCompass() {
        #expect(ReplayMarkerStyle.displayBearing(100, reduceMotion: true) == 90)
        #expect(ReplayMarkerStyle.displayBearing(113, reduceMotion: true) == 135)
        #expect(ReplayMarkerStyle.displayBearing(113, reduceMotion: false) == 113)
        #expect(ReplayMarkerStyle.displayBearing(nil, reduceMotion: true) == nil)
        #expect(ReplayMarkerStyle.displayBearing(359, reduceMotion: true) == 0)
        #expect(ReplayMarkerStyle.displayBearing(-30, reduceMotion: true) == 315)
        #expect(ReplayMarkerStyle.displayBearing(112.5, reduceMotion: true) == 135)
        #expect(ReplayMarkerStyle.displayBearing(337.5, reduceMotion: true) == 0)
        #expect(ReplayMarkerStyle.displayBearing(360, reduceMotion: true) == 0)
        #expect(ReplayMarkerStyle.displayBearing(-30, reduceMotion: false) == -30)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `cd AuraCore && swift test --no-parallel --filter "ReplayReadoutTests|ReplayBandGeometryTests"` → compile error.

- [ ] **Step 3: Implement**

`ReplayReadout.swift` and `ReplayBandContent.swift` are unchanged from plan v1 (the skeptic ran them green); the log at the end of this file points at them. Reproduced here so the task is self-contained:

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
    public let accessibilityValue: String
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

    /// The History row's three-valued rule; `HistoryView` keeps its own private copy.
    public static func subtitle(for ride: Ride) -> String {
        if let name = ride.destinationName, !name.isEmpty { return name }
        return ride.kind == .navigate ? "Navigated" : "Explore"
    }
}
```

```swift
import AuraCore

/// What the scrub band draws under the playhead (spec D6). Built once by the entry modifier —
/// `ElevationProfile.classify` needs the flattened track, which must never be read in a `body`.
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

`ReplayBandGeometry.swift`:

```swift
import Foundation
import AuraCore

/// The scrub band's pixel arithmetic (spec D6), out of the view so it can be pinned: the
/// fraction↔x mapping the rider's finger depends on, the thumb's y on the silhouette, strip
/// frames with their minimum width, and caption placement with the overlap-drop rule.
public struct ReplayBandGeometry: Equatable, Sendable {
    public let width: Double
    public let thumb: Double
    public let strokeInset: Double
    public static let minStripWidth: Double = 12

    public init(width: Double, thumb: Double, strokeInset: Double) {
        self.width = width; self.thumb = thumb; self.strokeInset = strokeInset
    }

    private var inset: Double { thumb / 2 + strokeInset }
    private var drawable: Double { max(width - 2 * inset, 1) }

    public func x(_ fraction: Double) -> Double { inset + fraction * drawable }

    public func fraction(atX px: Double) -> Double { min(max((px - inset) / drawable, 0), 1) }

    /// y of the silhouette at `fraction` in a band of `height`, using the same mapping
    /// `Sparkline.points` draws with (the silhouette is inset by `thumb / 2` horizontally and
    /// `strokeInset` all round). `samples == nil` is the rail: vertical center.
    public func thumbY(fraction: Double, samples: [Double]?, height: Double) -> Double {
        guard let samples, samples.count > 1 else { return height / 2 }
        let size = CGSize(width: width - thumb, height: height)
        let points = Sparkline.points(values: samples, in: size, inset: strokeInset)
        guard points.count > 1 else { return height / 2 }
        let position = min(max(fraction, 0), 1) * Double(points.count - 1)
        let i = min(Int(position), points.count - 2)
        let t = position - Double(i)
        return points[i].y + (points[i + 1].y - points[i].y) * t
    }

    public struct Frame: Equatable, Sendable { public var x: Double; public var width: Double }

    /// Below the minimum, widens symmetrically about the hold's own center rather than only
    /// rightward, then shifts the whole frame back inside `[x(0), x(1)]` if the widening pushed
    /// either edge past the thumb's actual travel — a hold near either end of the ride must not
    /// draw a strip the thumb can never reach.
    public func stripFrame(_ hold: ReplayHold) -> Frame {
        var minX = x(hold.range.lowerBound)
        var maxX = x(hold.range.upperBound)
        if maxX - minX < Self.minStripWidth {
            let center = (minX + maxX) / 2
            minX = center - Self.minStripWidth / 2
            maxX = center + Self.minStripWidth / 2
        }
        let low = x(0), high = x(1)
        if minX < low {
            maxX += low - minX
            minX = low
        }
        if maxX > high {
            minX -= maxX - high
            maxX = high
        }
        return Frame(x: minX, width: maxX - minX)
    }

    public struct Caption: Equatable, Sendable { public var center: Double; public var seconds: TimeInterval }

    /// Captions for holds of at least `minSeconds`, centered under their strips, left to right; a
    /// caption whose `captionWidth` box would overlap the previous one, or overflow the band, is dropped.
    public func captionCenters(holds: [ReplayHold], captionWidth: Double, minSeconds: TimeInterval) -> [Caption] {
        var out: [Caption] = []
        var lastRight = -Double.infinity
        for hold in holds where hold.seconds >= minSeconds {
            let frame = stripFrame(hold)
            let center = frame.x + frame.width / 2
            let left = center - captionWidth / 2, right = center + captionWidth / 2
            guard left >= lastRight, right <= width else { continue }
            out.append(Caption(center: center, seconds: hold.seconds))
            lastRight = right
        }
        return out
    }
}
```

`ReplayMarkerStyle.swift`:

```swift
/// The marker's Reduce Motion rule (spec D10): round the course to the 8-point compass, the
/// peer-pointer precedent. Out of the view so it is pinned.
public enum ReplayMarkerStyle {
    public static func displayBearing(_ raw: Double?, reduceMotion: Bool) -> Double? {
        guard let raw else { return nil }
        guard reduceMotion else { return raw }
        let rounded = ((raw / 45).rounded() * 45).truncatingRemainder(dividingBy: 360)
        return rounded < 0 ? rounded + 360 : rounded
    }
}
```

Append inside `RideTestID`:

```swift
    /// The summary map's Replay pill (ROH-239).
    public static let replayEntry = "summary.replay"
    /// The replay cover's play/pause control. One identifier for both states.
    public static let replayPlay = "replay.play"
    /// The replay scrub band, an adjustable element whose value is the short readout.
    public static let replayBand = "replay.band"
```

- [ ] **Step 4: Run until green, lint, commit**

Run: `cd AuraCore && swift test --no-parallel --filter "ReplayReadoutTests|ReplayBandContentTests|ReplayBandGeometryTests|ReplayMarkerStyleTests"`. `Sparkline.points` takes `CGSize`; AuraKit already imports Foundation/CoreGraphics through `Plotting.swift`, so `CGSize` resolves.

```bash
git add AuraCore/Sources/AuraKit/Replay AuraCore/Tests/AuraKitTests/Replay AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift
git commit -m "feat(roh-239): replay readout, band content and geometry, marker style — all pinned

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Route stroke constants, `ReplayMarkerView`, `ReplayMap`

**Files:**
- Modify: `Aura/Sources/Theme/AuraTheme.swift` (append an extension at the end)
- Modify: `Aura/Sources/Ride/StaticRouteMap.swift:38,40` and `Aura/Sources/Plan/RoutePreviewView.swift:362,364` (the `.lineWidth(8)` / `.lineBorderWidth(1.5)` literals)
- Create: `Aura/Sources/Ride/Replay/ReplayMarkerView.swift`, `Aura/Sources/Ride/Replay/ReplayMap.swift`

**Interfaces:**
- Consumes: `ReplayTimeline`, `ReplaySample`, `ReplayPlayback`, `ReplayReadout.holdLabel`, `ReplayMarkerStyle`, `AuraPuck.ridingBearing`/`browseTop`, `.hudControl(active:)`, `.mapChip`.
- Produces: `ReplayMap(timeline:lines:playback:)`; `AuraTheme.RouteStroke.width`, `.casingWidth`; `AuraTheme.replayHoldStrip`.

- [ ] **Step 1: Theme constants**

Append to `AuraTheme.swift`:

```swift
extension AuraTheme {
    /// The cased route stroke the Mapbox line surfaces share (summary, route preview, replay).
    /// Mapbox draws `lineBorderWidth` INSIDE `lineWidth`: 8 − 2×1.5 = 5 pt of visible mint.
    /// The share card's Core Graphics stroke (`ShareCardLayout`, AuraKit) expresses the same 5 pt
    /// core as an 8 pt casing under a 5 pt line; the two are not one constant because they are
    /// different drawing models. Keep `width − 2 × casingWidth == ShareCardLayout.routeStrokeWidth`.
    enum RouteStroke {
        static let width: Double = 8
        static let casingWidth: Double = 1.5
    }

    /// The replay band's hold strip. Brighter than a hairline on purpose: it is the band's
    /// headline signal for a 45–119 s stop, and it draws ABOVE the silhouette's 18% fill.
    /// PO eyeball owed on the simulator pass (spec D6).
    static let replayHoldStrip = Color.white.opacity(0.28)
}
```

Replace the four literals with `AuraTheme.RouteStroke.width` / `AuraTheme.RouteStroke.casingWidth`. No other change in either file.

- [ ] **Step 2: The marker**

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The replay rider (spec D8): the riding triangle rotated to the sampled course while moving,
/// the browse disc in a hold and at the end. Fixed 34 pt frame so swapping images (32 pt vs
/// 34 pt canvases) never shifts the annotation. Rotation and pitch are disabled on the replay
/// map, so a geographic bearing is a screen bearing.
struct ReplayMarkerView: View {
    let sample: ReplaySample
    let reduceMotion: Bool

    private var bearing: Double? {
        guard case .moving = sample.phase else { return nil }
        return ReplayMarkerStyle.displayBearing(sample.bearing, reduceMotion: reduceMotion)
    }

    var body: some View {
        Image(uiImage: bearing == nil ? AuraPuck.browseTop : AuraPuck.ridingBearing)
            .rotationEffect(.degrees(bearing ?? 0))
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 3: The map**

```swift
import SwiftUI
import MapboxMaps
import Turf
import AuraCore
import AuraKit

/// The replay's map (spec D8): the cased route as a style source under a line layer, and the
/// rider as a `MapViewAnnotation`, inside one `TimelineView` that runs only while playing. The
/// structure `NavigateHUDView` runs at 30 Hz: the SDK re-uploads GeoJSON only when `data`
/// differs, so a frame that moves the marker touches nothing else.
///
/// `lines` is built once by the entry modifier from `ReplayTimeline.drawableLines`.
/// `context.date` is used for RENDERING ONLY; every mutation takes `Date()`.
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
                        .accessibilityHidden(true)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // `viewport.isIdle` is the SDK's write-back when the viewport manager goes idle,
            // which a rider gesture causes; recenter's `.overview` clears it. A failed initial
            // fit would also show it (spec §10) — accepted.
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

- [ ] **Step 4: Lint, commit; orchestrator builds**

Run from the root: `swiftlint lint --strict --quiet`.

```bash
git add Aura/Sources/Theme/AuraTheme.swift Aura/Sources/Ride/StaticRouteMap.swift Aura/Sources/Plan/RoutePreviewView.swift Aura/Sources/Ride/Replay/ReplayMarkerView.swift Aura/Sources/Ride/Replay/ReplayMap.swift
git commit -m "feat(roh-239): ReplayMap draws the route as a source and the rider as an annotation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

**Orchestrator:** `cd Aura && xcodegen generate`, then build via the builder agent. On failure, the error goes back to this implementer, who amends this commit.

---

### Task 9: `ReplayScrubBand`

**Files:**
- Create: `Aura/Sources/Ride/Replay/ReplayScrubBand.swift`

**Interfaces:**
- Consumes: `ReplayBandContent`, `ReplayBandGeometry`, `ReplayTimeline`, `ReplayPlayback`, `ReplayReadout`, `Sparkline.points`, `RideTestID.replayBand`, `RideStatsFormatter.minutes`, `AuraTheme.replayHoldStrip`.
- Produces: `ReplayScrubBand(content:timeline:playback:readout:fraction:)`. No `now` parameter: the band takes `Date()` in its own handlers.

- [ ] **Step 1: Write the band**

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The scrubber (spec D6). Geometry comes from `ReplayBandGeometry`; this file only draws and
/// forwards touches. The silhouette is an `Equatable` child so the per-frame playhead
/// invalidation never re-strokes it. Strips draw ABOVE the silhouette.
struct ReplayScrubBand: View {
    let content: ReplayBandContent
    let timeline: ReplayTimeline
    let playback: ReplayPlayback
    /// Resolved at the playhead's own fraction, so the elevation tag and the spoken value
    /// match the thumb, not the 4 Hz instrument row.
    let readout: ReplayReadout
    let fraction: Double

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var captionWidth: CGFloat = 44
    @State private var dragMoved = false
    @State private var holdUnderThumb: Int?

    static let thumb: CGFloat = 28
    static let strokeInset: CGFloat = 2
    private static let bandHeight: CGFloat = 88
    private static let captionMinSeconds: TimeInterval = 120

    private var samples: [Double]? {
        if case let .silhouette(s) = content.kind { return s }
        return nil
    }

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            GeometryReader { geo in
                let g = ReplayBandGeometry(width: geo.size.width, thumb: Self.thumb, strokeInset: Self.strokeInset)
                ZStack(alignment: .topLeading) {
                    if let samples {
                        ReplaySilhouette(samples: samples, contrast: contrast)
                            .equatable()
                            .padding(.horizontal, Self.thumb / 2)
                    } else {
                        rail(g, height: geo.size.height)
                    }
                    strips(g, height: geo.size.height)
                    playhead(g, height: geo.size.height)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(drag(g))
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
        .onChange(of: fraction) { _, new in
            let index = timeline.holds.firstIndex { $0.range.contains(new) }
            if index != holdUnderThumb { holdUnderThumb = index }
        }
        .onDisappear { playback.cancelScrub() }
    }

    // MARK: Layers

    private func strips(_ g: ReplayBandGeometry, height: CGFloat) -> some View {
        ForEach(Array(content.holds.enumerated()), id: \.offset) { _, hold in
            let frame = g.stripFrame(hold)
            Rectangle()
                .fill(AuraTheme.replayHoldStrip)
                .frame(width: frame.width, height: height)
                .offset(x: frame.x)
        }
    }

    private func rail(_ g: ReplayBandGeometry, height: CGFloat) -> some View {
        let start = g.x(0), end = g.x(1), head = g.x(fraction)
        return ZStack(alignment: .leading) {
            Capsule().fill(AuraTheme.textSecondary.opacity(0.25)).frame(width: end - start, height: 6)
            Capsule().fill(AuraTheme.accent).frame(width: max(head - start, 6), height: 6)
        }
        .offset(x: start, y: height / 2 - 3)
    }

    private func playhead(_ g: ReplayBandGeometry, height: CGFloat) -> some View {
        let px = g.x(fraction)
        let py = g.thumbY(fraction: fraction, samples: samples, height: height)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(AuraTheme.accent).frame(width: 2, height: height).offset(x: px - 1)
            Circle()
                .fill(AuraTheme.accent)
                .overlay(Circle().strokeBorder(AuraTheme.background, lineWidth: 2))
                .frame(width: Self.thumb, height: Self.thumb)
                .offset(x: px - Self.thumb / 2, y: py - Self.thumb / 2)
            if samples != nil, let tag = readout.elevationText {
                Text(tag)
                    .font(AuraTheme.Typography.unit)
                    .foregroundStyle(AuraTheme.textPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.sm)
                    .padding(.vertical, AuraTheme.Spacing.xs)
                    .background(AuraTheme.surface, in: Capsule())
                    .offset(x: min(px + Self.thumb / 2 + 4, g.width - 72), y: max(py - 12, 0))
            }
        }
        .animation(reduceMotion || playback.isPlaying ? nil : .easeOut(duration: 0.12), value: fraction)
    }

    private var captions: some View {
        GeometryReader { geo in
            let g = ReplayBandGeometry(width: geo.size.width, thumb: Self.thumb, strokeInset: Self.strokeInset)
            let placed = g.captionCenters(holds: content.holds, captionWidth: captionWidth,
                                          minSeconds: Self.captionMinSeconds)
            ForEach(placed, id: \.center) { item in
                Text(RideStatsFormatter(units: .metric).minutes(item.seconds))
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(AuraTheme.secondaryText(contrast))
                    .frame(width: captionWidth)
                    .position(x: item.center, y: geo.size.height / 2)
            }
        }
        .frame(height: max(16, captionWidth * 0.4))
        .accessibilityHidden(true)
    }

    // MARK: Input

    private func drag(_ g: ReplayBandGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !playback.isScrubbing { playback.beginScrub(now: Date()) }
                if abs(value.translation.width) > 4 { dragMoved = true }
                playback.scrub(to: g.fraction(atX: value.location.x))
            }
            .onEnded { value in
                if dragMoved {
                    playback.endScrub(now: Date())
                } else {
                    playback.tap(to: g.fraction(atX: value.location.x), now: Date())
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
        if let target { playback.tap(to: target, now: Date()) }
    }
}

/// The silhouette alone. `Equatable` on its inputs; the caller applies `.equatable()`.
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
    }
}
```

`Sparkline.points` takes `CGSize` and `CGFloat`; `ReplayBandGeometry` is `Double`-typed and `CGFloat` bridges implicitly on 64-bit. If the compiler complains at `ReplayBandGeometry(width: geo.size.width, …)`, wrap with `Double(...)`.

- [ ] **Step 2: Lint, commit; orchestrator builds**

```bash
git add Aura/Sources/Ride/Replay/ReplayScrubBand.swift
git commit -m "feat(roh-239): ReplayScrubBand — silhouette or rail, hold strips, thumb, drag

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `ReplayInstrumentRow` and `RideReplayView`

**Files:**
- Create: `Aura/Sources/Ride/Replay/ReplayInstrumentRow.swift`, `Aura/Sources/Ride/Replay/RideReplayView.swift`

**Interfaces:**
- Consumes: Tasks 6–9, `UnfinishedRideBadge(checkpointedAt:style:)`, `AccessibilityAnnouncer.announce`, `RideTestID.replayPlay`.
- Produces: `RideReplayView(ride:timeline:band:lines:)`. `lines` arrives pre-mapped; nothing here touches `ride.segments`.

- [ ] **Step 1: The row** — unchanged from plan v1:

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
                .font(AuraTheme.Typography.metricBrand(min(heroSize, 56)))
                .monospacedDigit()
                .foregroundStyle(AuraTheme.textPrimary)
            Text(readout.speedUnit)
                .font(AuraTheme.Typography.unit)
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    private var distance: some View { StatPair(value: readout.distanceText, label: readout.distanceUnit.uppercased()) }
    private var time: some View { StatPair(value: readout.timeText, label: "TIME") }
}
```

- [ ] **Step 2: The cover**

```swift
import SwiftUI
import CoreLocation
import AuraCore
import AuraKit

/// The replay cover (spec D7). Owns the playback state; the map and the controls each run their
/// own `TimelineView`, so the map's body never encloses the row. `context.date` renders; every
/// mutation takes `Date()`.
struct RideReplayView: View {
    let ride: Ride
    let timeline: ReplayTimeline
    let band: ReplayBandContent
    let lines: [[CLLocationCoordinate2D]]

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var playback: ReplayPlayback
    @State private var lastAnnouncedHold: ReplayPhase?

    init(ride: Ride, timeline: ReplayTimeline, band: ReplayBandContent, lines: [[CLLocationCoordinate2D]]) {
        self.ride = ride
        self.timeline = timeline
        self.band = band
        self.lines = lines
        _playback = State(initialValue: ReplayPlayback(playbackDuration: timeline.playbackDuration))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ReplayMap(timeline: timeline, lines: lines, playback: playback)
                .frame(minHeight: 200, maxHeight: .infinity)
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
            // band's thumb, tag, and spoken value follow the frame.
            let rowDate = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate * 4).rounded(.down) / 4)
            let rowSample = timeline.sample(at: playback.fraction(at: rowDate))
            let rowReadout = ReplayReadout(sample: rowSample, timeline: timeline, units: settings.units)
            let bandReadout = ReplayReadout(sample: timeline.sample(at: fraction), timeline: timeline, units: settings.units)
            let ended = playback.isPlaying && playback.hasEnded(at: now)
            VStack(spacing: AuraTheme.Spacing.lg) {
                ReplayInstrumentRow(readout: rowReadout)
                ReplayScrubBand(content: band, timeline: timeline, playback: playback,
                                readout: bandReadout, fraction: fraction)
                playButton
            }
            .onChange(of: ended) { _, isEnded in
                if isEnded { playback.settle() }
            }
            .onChange(of: rowSample.phase) { _, phase in
                // A VoiceOver rider's only channel for a stop reached under play (spec §5). Reset
                // between holds so two identical stops are both announced.
                guard case .hold = phase else { lastAnnouncedHold = nil; return }
                guard playback.isPlaying, phase != lastAnnouncedHold, let text = rowReadout.holdText else { return }
                lastAnnouncedHold = phase
                AccessibilityAnnouncer.announce(text)
            }
        }
    }

    private var playButton: some View {
        Button { playback.togglePlay(now: Date()) } label: {
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

- [ ] **Step 3: Lint, commit; orchestrator builds**

```bash
git add Aura/Sources/Ride/Replay/ReplayInstrumentRow.swift Aura/Sources/Ride/Replay/RideReplayView.swift
git commit -m "feat(roh-239): RideReplayView assembles the cover

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Entry modifier, the one summary line, the DEBUG seed

**Files:**
- Create: `Aura/Sources/Ride/Replay/RideReplayEntry.swift`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:76`
- Modify: `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift` (one parser + one static)
- Modify: `Aura/Sources/AuraApp.swift:22` (after `let store = AuraApp.makeRideStore()`)
- Test: `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift` (append one test)

- [ ] **Step 1: Failing config test**

```swift
    @Test func seedLongRideFlag() {
        #expect(SimulatedRideConfig.seedsLongRide(arguments: ["-auraSeedLongRide"]))
        #expect(SimulatedRideConfig.seedsLongRide(arguments: []) == false)
    }
```

Run: `cd AuraCore && swift test --no-parallel --filter SimulatedRideConfig` → compile error.

- [ ] **Step 2: The flag**

After `suppressesLaunchOrphanSweep` in `SimulatedRideConfig.swift`:

```swift
    /// "-auraSeedLongRide" → DEBUG builds insert `SyntheticRide.threeHour` into the store at
    /// launch, so the replay's cap regime (ROH-239 spec §9) is reachable in a simulator. Honored
    /// ONLY with an ephemeral store: the persistent store mirrors to the developer's real iCloud.
    public static func seedsLongRide(arguments: [String]) -> Bool {
        arguments.contains("-auraSeedLongRide")
    }
```

and beside the other `current…` statics: `@MainActor public static let currentSeedsLongRide = seedsLongRide(arguments: ProcessInfo.processInfo.arguments)`. Run the config suite green.

- [ ] **Step 3: Seed in the app, ephemeral store only**

Directly after `let store = AuraApp.makeRideStore()` in `AuraApp.swift`:

```swift
        #if DEBUG
        // Never into the persistent store: it mirrors to iCloud (RideStore.persistent()).
        if SimulatedRideConfig.currentSeedsLongRide, store.isEphemeral {
            try? store.save(SyntheticRide.threeHour(startingAt: Date().addingTimeInterval(-4 * 3600)))
        }
        #endif
```

- [ ] **Step 4: The entry modifier**

```swift
import SwiftUI
import CoreLocation
import AuraCore
import AuraKit

/// The summary's way into replay (spec D1): a Replay pill over the map, and the cover. Applied to
/// `StaticRouteMap` before the summary's own frame/clip/opacity modifiers, so the pill is clipped
/// with the map and fades in with it. The map itself stays inert (ROH-84 taught riders that
/// tapping a map makes it live).
///
/// Everything the cover needs — timeline, band, drawable lines — is built here, once, off the
/// main actor, and passed down; no `View.init` or `body` walks `ride.segments` again.
private struct ReplayEntryModifier: ViewModifier {
    let ride: Ride
    @State private var built: Built?
    @State private var isPresented = false

    struct Built: Sendable {
        var timeline: ReplayTimeline
        var band: ReplayBandContent
        var lines: [[CLLocationCoordinate2D]]
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let built, built.timeline.isReplayable {
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
                if let built {
                    RideReplayView(ride: ride, timeline: built.timeline, band: built.band, lines: built.lines)
                }
            }
            .task(id: ride.id) {
                let ride = ride
                built = await Task.detached(priority: .userInitiated) {
                    let timeline = ReplayTimeline(segments: ride.segments)
                    let lines = timeline.drawableLines.map { line in
                        line.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    }
                    return Built(timeline: timeline, band: ReplayBandContent(ride: ride, timeline: timeline), lines: lines)
                }.value
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

`CLLocationCoordinate2D` is `Sendable` in the iOS 17 SDK; if the compiler disagrees inside `Task.detached`, build `lines` on the main actor after the `await` from `timeline.drawableLines` instead (it is a trivial map).

- [ ] **Step 5: The one line**

`RideSummaryView.swift:76`: `StaticRouteMap(segments: segs)` → `StaticRouteMap(segments: segs).replayEntry(ride: ride)`. Confirm with `git diff --stat` that exactly one line changed in that file.

- [ ] **Step 6: Lint, package suites, commit; orchestrator builds**

Run: `swiftlint lint --strict --quiet`; `cd AuraCore && swift test --no-parallel --filter "SimulatedRideConfig|ReplayTimelineScaleTests"`.

```bash
git add Aura/Sources/Ride/Replay/RideReplayEntry.swift Aura/Sources/Ride/RideSummaryView.swift AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift Aura/Sources/AuraApp.swift AuraCore/Tests/AuraKitTests
git commit -m "feat(roh-239): Replay pill on the summary map, and a DEBUG seed for the cap regime

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Simulator verification, board, PR (orchestrator)

- [ ] **Step 1: Seeded long ride, cap regime.** Launch on the iPhone 17 simulator with `-auraSeedLongRide -auraInMemoryRideStore` (both; the seed refuses a persistent store). Home → History → the seeded ride → summary. Screenshots into `docs/evidence/roh-239/`: `summary-pill-history.png`; then Replay: `replay-start.png` (marker on the first vertex), `replay-moving.png`, `replay-hold.png` (scrub into the 5-minute stop: capsule "Stopped · 5 min", disc, strip, caption), `replay-ended.png`, `replay-recenter.png` (after a pinch). **Also:** open the cover, wait 30 s, tap Play, confirm playback starts at 0 (the v1 clock defect). **PO eyeball owed:** strip color and z-order (D6).
- [ ] **Step 2: Golden and paused fixtures, floor regime.** `scripts/golden-ride.sh` or `-auraSimulatedRide golden`: post-ride summary pill (`summary-pill-postride.png`), cover (`replay-golden.png`). Paused fixture: `replay-paused-fixture.png` with "Paused · N min". Also a no-elevation ride if a fixture exists: the rail, and a drag to the far right end lands at fraction 1.
- [ ] **Step 3: Accessibility.** Reduce Motion on: glide continues, pointer in 45° steps (`replay-reduce-motion.png`). AX3: row wraps, band and button do not clip, map ≥ 200 pt (`replay-ax3.png`). Accessibility inspector: the band reads "Ride scrubber", value is the short readout, adjust steps between events.
- [ ] **Step 4: Board and PR.** ROH-239 → In Review. File the Device Verification issue (spec §9). Push, open the PR against `main` with `Verification: Tier 1`, the screenshots, and links. Do not merge before the whole-branch review (pipeline step 6).

---

## Self-review (v2)

**Spec coverage.** D1 → 11. D2 → 1. D3 → 1, 3, 8 (capsule), 9 (strips). D4 → 6, 9. D5 → 1, 4, 7, 10. D6 → 4, 7, 9. D7 → 8, 10, 11. D8 → 8. D9 → 1, 2. D10 → 7 (`ReplayMarkerStyle`), 8, 9. D11 → 6, 7, 10, 11. §4.1–4.12 → 1–5; §4.13 → 6; §4.14–4.16 → 7. §5 → 9, 10. §6 → file map. §9 → 5, 11, 12.

**Type consistency.** `ReplayPhase.hold(ReplayHold.Kind, seconds:)` everywhere. `ReplayPlayback`: `beginScrub(now:)`, `scrub(to:)`, `endScrub(now:)`, `tap(to:now:)`, `cancelScrub()`, `togglePlay(now:)`, `settle()`, `hasEnded(at:)`, `fraction(at:)`, `isScrubbing`, `isPlaying` — Tasks 6, 9, 10 agree. `ReplayBandGeometry(width:thumb:strokeInset:)`, `x(_:)`, `fraction(atX:)`, `thumbY(fraction:samples:height:)`, `stripFrame(_:)` → `Frame{x,width}`, `captionCenters(holds:captionWidth:minSeconds:)` → `[Caption{center,seconds}]` — Tasks 7, 9 agree. `ReplayScrubBand(content:timeline:playback:readout:fraction:)` — Tasks 9, 10. `ReplayMap(timeline:lines:playback:)` — 8, 10. `RideReplayView(ride:timeline:band:lines:)` — 10, 11. `ReplayTimeline.drawableLines`, `.speedWindowSeconds` — 1, 4, 11. `SyntheticRide.threeHour(startingAt:)`, `.threeHourID` — 5, 11. `AuraTheme.RouteStroke`, `.replayHoldStrip` — 8, 9.

**Placeholders.** None.

## Reconciliation log (v1 → v2)

Two independent reviewers (`review-skeptic` on the pure layer, `review-architecture` on the app layer), refuting stance, 2026-09-11. The skeptic reconstructed Tasks 1–7 in a scratch SwiftPM package and ran them; the architect type-checked the app-layer expressions against the SDK.

| # | Finding | Resolution |
|---|---|---|
| S1 | Tuple stored properties break `Equatable` synthesis (compile error) | `Endpoint` struct |
| S2 | Five SwiftLint rules fire (`type_name` "F", `type_body_length`, `function_body_length`, `cyclomatic_complexity`, `nesting`) | `typealias Fixtures`; `SpanContent` hoisted; `init` → `layout(items:config:)`; sampling in an extension file; `Builder.classify`/`addPauseGap` split out; rules listed in Global Constraints |
| S3 | Searching spans on seconds put a hold's exclusive end inside the hold (94/115 gaps) | `Span.fractionStart`, search on fractions; sweep test over 115 gaps |
| S4 | `backwardsStamp` expected 198, code gives 239, and the fixture accidentally made a hold | Fixture restamps 1 s before its predecessor; expects 201 and no hold |
| S5 | Fixture used 111 320 m/° against haversine's 6 371 000 m sphere; 3 tolerances failed | `metersPerDegree = 6_371_000 × π/180`; tolerances 0.01 m |
| S6 | `totalSeconds` is Σ leg dt, not Σ segment spans | Spec §3/D5.3 corrected to Σ normalized leg dt; sample doc says so |
| S7 | km/mi marks inside a hold's folded distance were dropped | `events` walks holds too, mark lands on the hold's start; test |
| S8 | `playbackDuration == 10` on an accumulated double | `duration` is the exact sum; tolerances anyway |
| S9 | "Expected: all pass" claims were false; Tasks 2–4 had no red target | Expectations corrected from executed values; hint text rewritten |
| S10 | `holdsAreCarried` was `[] == []` | Two-segment fixture with a pause |
| S11 | `speedWindow` test re-derived the formula | `speedWindowSeconds` public; straddling-window negative control (4.5 m/s) |
| S12 | Untested: zero-width later point (unfalsifiable, dropped from spec §4.2); pause chord; speed after a lost leg (spec contradiction) | Pause-chord test with a northward second segment; `windowFloor` barrier so the window never crosses a hold; test |
| S13 | `SyntheticRide` prose wrong (601 s pause; lost leg is in segment 2) | Doc comment corrected; test pins 601 |
| S14 | Generator ships in the release library | `#if DEBUG`; deviation stated |
| S15 | Stale line refs; "two identifiers" | 38/40, 362/364, 76; three identifiers (spec fixed) |
| S-susp | `fraction(at:)` no lower clamp; dedupe can drop 1.0; zero-dt teleport folded into a run | Clamped; 1 appended last after filtering; teleport breaks the run + test |
| A1 | Paused `TimelineView` date drove `play`/`endScrub` → replay jumps to wherever the rider hesitated | Global constraint; `Date()` in every handler; band drops `now`; `playAfterALongPauseStartsAtZero` test; Task 12 checks it |
| A2 | `.equatable()` inside `body` is a compile error | At the call site |
| A3 | Seed wrote into the CloudKit-mirrored store | Gated on `store.isEphemeral`; Task 12 passes both flags |
| A4 | Rail-mode hit area 32 pt narrower than the band | `.frame(width:height:alignment:)` on the ZStack |
| A5 | Strips under the silhouette fill at 14% white | Strips above; `AuraTheme.replayHoldStrip` 0.28; PO eyeball queued |
| A6 | Per-leg bearing = 120 heading changes per playback second | Bearing over the trailing window in the pure layer; zig-zag test |
| A7 | Tap rule was an untested call ordering | `ReplayPlayback.tap(to:now:)` + test |
| A8 | Pixel math, caption rule, thumb y, 45° rounding lived in the app target | `ReplayBandGeometry`, `ReplayMarkerStyle` in AuraKit with suites; `@ScaledMetric` caption width |
| A9 | `lines` derived twice and per `View.init` | `ReplayTimeline.drawableLines`; built once in the modifier's task |
| A10 | Map could squeeze to nothing at AX sizes | `minHeight: 200`; hero capped at 56 |
| A11 | No compile-error loop | Global constraint: orchestrator builds, implementer amends |
| A12 | Elevation tag/spoken value from the 4 Hz sample, thumb from the frame | Second readout at the band's fraction |
| A13–23 | Line refs; `RouteStroke` scope; repeated-hold announcement; `holdUnderThumb` churn; lower clamp; scrub latch; `isIdle` semantics; forbidden-file name; identifiers; 32 vs 34 pt canvases; Task 1 lint | All applied: `RoutePreviewView` included; announcement reset; guarded write; `cancelScrub` on disappear; `isIdle` caveat in code + spec §10; real file names; fixed 34 pt marker frame |

Not adopted: the architect's suggestion to prefer `MapViewAnnotation` was already v2 of the spec; the skeptic's note that `profile(sampleCount: 1)` conflates two nils is unreachable (`sampleCount` is a constant 240) and left as is.
