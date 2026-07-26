# ROH-98 — Segmented ride model, segment-aware stats, trkseg parser, paused fixture

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat `[TrackPoint]` ride track with an ordered list of `RideSegment`s
everywhere it is read live or after the ride, so a later pass can close a segment on pause
without any consumer silently drawing a straight line across the gap.

**Architecture:** `RideSegment` wraps an ordered `[TrackPoint]`. `Ride.track` is deleted and
replaced by `Ride.segments`; a `Ride(kind:…track:…)` convenience *initializer* survives
(write-side convenience is safe, read-side convenience is the hazard). `RideRecorder` and
`RideSessionCoordinator` publish `segments` too — they are separate properties on separate
types, so deleting `Ride.track` alone would leave the live HUD map compiling and wrong.
Stats and polyline rendering gain segment-aware entry points whose single-segment behavior
is bit-for-bit the old behavior. Nothing a rider can see changes in this pass: pause does
not exist yet, so every ride is still exactly one segment.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM package `AuraCore` (targets `AuraCore`,
`AuraKit`), XCTest + swift-testing, swift-snapshot-testing, SwiftLint 0.64.1, MapboxMaps v11
(app target only).

> **Revision note.** This plan was rewritten after a two-reviewer adversarial gate
> (skeptic + architecture lens). Four blocking compile errors, two missing test call sites
> and one wrong canonical-form decision were found and are fixed below. Where a reviewer
> refuted something the first draft asserted, the correction is marked **[gate]** so an
> implementer does not "helpfully" restore the original.

## Global Constraints

- **The frozen golden-ride literals in `GoldenRideFixture.swift:13-17` and the two
  start-coordinate literals at `:22-23` must stay byte-identical.** That is the regression
  proof that segmentation changed nothing for an unpaused ride. If a literal moves, the
  change is wrong — **do not re-record it.** (Note `:13` — `expectedPointCount` — is inside
  the guarded range; the whole-file `git diff` gate below covers all five.)
- **`RideStatsSnapshotTests`'s recorded JSON reference must not be re-recorded.** Same
  reason: it pins the flat calculator's exact doubles.
- **Zero segments is the canonical encoding of "a ride with no points." [gate]** Every
  value-type convenience initializer that takes a flat track maps `[]` → `segments: []`, and
  `RideRecorder.end(at:)` drops trailing empty segments. Without this rule `Ride` and
  `GPXTrack` — both `Equatable` — each get two encodings of "no points", and
  `RideMapper`'s save/load path silently converts one into the other. Pass 3's `.custom`
  V5→V6 backfill is the most expensive possible place to discover that.
  **Interior empty segments remain legal and must not be dropped** (spec D6) — only trailing.
- **Segment `RideRecorder.track` and `RideSessionCoordinator.track`, not just `Ride.track`.**
  `RideHUDView.swift:68` reads `coordinator.track`, a passthrough to `RideRecorder.track`.
- **Duplicate the `count >= 2` guard per segment in `RideStatsCalculator`. Do NOT move it
  up.** An empty segment would reach `points[0]` unguarded — an index-out-of-range crash on
  the main actor. Empty segments become reachable in Pass 2.
- **Do not add a `stats(from: [RideSegment])` overload. [gate]** The segment entry point is
  `stats(segments:)`. `RideStatsCalculatorTests.swift:12` calls `stats(from: [])` with a bare
  empty literal; a same-labelled overload makes that call ambiguous and the test target stops
  compiling (`error: ambiguous use of 'stats(from:…)'`, reproduced by both reviewers).
- **Retain `GPXTrack.points` as a flattened accessor.** Roughly eighteen parser assertions
  plus `GPXLocationPlayer`, `SimulatedLocationProvider` and `GoldenRideFixture` depend on it.
- **Retain a `Ride(kind:…track:…)` convenience initializer** wrapping its argument in one
  segment. Remove the *read* accessor, keep the *write* one — the asymmetry is deliberate.
- **Do NOT touch `isRecording` semantics, and do not add pause/resume.** That is ROH-99
  (Pass 2) and `isRecording` is load-bearing at five call sites outside the recorder
  (`RideSessionCoordinator.swift:82,121,143`, `RideHUDView.swift:192`, `NavigateHUDView.swift:226`).
- **Do not change `thumbnailData`'s blob shape** (D3). `RideMapper` flattens when producing
  it; `RideSummary.thumbnailCoordinates` and its **five** render sites (`HistoryView.swift:164`,
  `LastRideCard.swift:68`, `LastRideWidget.swift:41,63,94`) are untouched. **[gate]** The spec
  says six and counts `ShareCardView.swift:39`; that site reads `ShareCardContent`, not
  `thumbnailData`, and it *does* become segment-aware in Task 2.
- **`swift build` does not compile test targets.** Every "find what broke" step uses
  `swift build --build-tests`. **[gate]**
- Package tests (`swift test`) and `swiftlint --strict` must be green at the end of every task.
- Spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D1, D3, D4, D10).

## File Structure

**Create**

| File | Responsibility |
| -- | -- |
| `AuraCore/Sources/AuraCore/Models/RideSegment.swift` | The `RideSegment` value type |
| `AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift` | Pure: segments (+ optional self-progress split) → drawable coordinate pieces |
| `AuraCore/Sources/AuraKit/Resources/golden-ride-paused.gpx` | Two-segment golden fixture |
| `AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift` | Its loader + frozen literals |
| `AuraCore/Tests/AuraCoreTests/RideSegmentTests.swift` | `RideSegment`, `Ride.segments`, canonical form, blob shape |
| `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift` | Ribbon piece math |
| `AuraCore/Tests/AuraCoreTests/RideStatsSegmentTests.swift` | Segment-aware stats |
| `AuraCore/Tests/AuraCoreTests/GPXParserSegmentTests.swift` | `<trkseg>` handling |
| `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift` | Paused fixture literals + store lossiness pin |

**Modify**

| File | Change |
| -- | -- |
| `AuraCore/Sources/AuraCore/Models/Ride.swift` | `track` → `segments`; `flattenedPoints`; convenience init |
| `AuraCore/Sources/AuraCore/Stats/RideStatsCalculator.swift` | Per-segment accumulator + `stats(segments:)` |
| `AuraCore/Sources/AuraCore/Playback/GPXTrack.swift` | `segments` + flattened `points` |
| `AuraCore/Sources/AuraCore/Playback/GPXParser.swift` | Honor `<trkseg>` |
| `AuraCore/Sources/AuraCore/Health/WorkoutData.swift` | Flatten (HealthKit pause events are out of scope) |
| `AuraCore/Sources/AuraKit/RideRecorder.swift` | `track` → `segments`; trailing-empty drop in `end` |
| `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` | `track` → `segments` |
| `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift` | Flatten for `trackData` + thumbnail (D3) |
| `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift` | `routeCoordinates` → `routeSegments` |
| `AuraCore/Sources/AuraKit/Summary/ElevationProfileContent.swift` | Flatten (samples only) |
| `AuraCore/Sources/AuraKit/Plotting/Plotting.swift` | Shared-scale segmented `PolylineNormalizer` |
| `AuraCore/Package.swift:23-25` | Register the new `.gpx` resource |
| `Aura/Sources/Ride/RideSummaryView.swift:33,39` | Segment-aware static map |
| `Aura/Sources/Ride/StaticRouteMap.swift:11,16-42` | One polyline per segment; camera fits across all |
| `Aura/Sources/Ride/RideMapView.swift:11,35-38,103-133,170` | Ribbon via `TrackRibbon` |
| `Aura/Sources/Ride/RideHUDView.swift:68` | Pass `coordinator.segments` |
| `Aura/Sources/Shared/RouteThumbnail.swift` | Multi-polyline, one shared scale |
| `Aura/Sources/Ride/ShareCard/ShareCardView.swift:17,39` | Consume `routeSegments` |
| Tests listed per task | `.track` reads → `.flattenedPoints` / `.segments` |

**Explicitly NOT modified [gate]:** `Aura/UITests/RideE2EUITests.swift`. The first draft
rewrote its "band shared by both golden rides" comment as false. It is true: that band is
asserted from `:64` (free-ride E2E) and `:121` (navigate E2E), and both launch with
`-auraSimulatedRide golden` (`:18`, `:88`), so both replay `GoldenRideFixture`. The paused
fixture gets its own band in Pass 6 when a test actually consumes it.

---

### Task 1: `RideSegment` and the segmented rendering primitives

Purely additive — nothing is removed, so the package stays green throughout. These are the
tested pieces Task 2 and Task 4 wire in, so the judgment about *how* a multi-segment track
draws is settled here under unit test rather than inside a SwiftUI view.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/RideSegment.swift`
- Create: `AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift`
- Create: `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`
- Modify: `AuraCore/Sources/AuraKit/Plotting/Plotting.swift`
- Test: `AuraCore/Tests/AuraKitTests/PlottingTests.swift`

**Interfaces:**
- Consumes: `Coordinate`, `TrackPoint`, `Geo.distance(_:_:)`,
  `RouteSplit.splitIndex(geometry:atMeters:)` (all AuraCore).
- Produces:
  - `public struct RideSegment: Codable, Equatable, Sendable { public var points: [TrackPoint]; public init(points: [TrackPoint]) }`
  - `public enum TrackRibbon { public struct Piece: Equatable, Sendable { public let coordinates: [Coordinate]; public let isBehind: Bool; public let sourceIndex: Int }; public static func pieces(segments: [RideSegment], splitAtMeters: Double?) -> [Piece] }`
  - `public static func points(segments: [[Coordinate]], in size: CGSize, inset: CGFloat) -> [[CGPoint]]` on `PolylineNormalizer`

- [ ] **Step 1: Write `RideSegment`**

`AuraCore/Sources/AuraCore/Models/RideSegment.swift`:

```swift
import Foundation

/// One continuous stretch of a ride. A pause closes the current segment and a resume opens
/// a new one, so two points in *different* segments were never adjacent in time or space —
/// which is why the ride model carries segments rather than a flat track with a convention
/// every consumer has to remember (spec D1).
///
/// An **interior** empty segment is legal: a pause before the first fix, or
/// pause → resume → pause with no intervening point, both produce one. Nothing that walks a
/// segment may assume `points` is non-empty. A *trailing* empty segment is dropped when the
/// ride ends, so "no points" has exactly one encoding: zero segments.
///
/// ## Wire-format contract — read before changing this type
///
/// From schema V6 onward this struct's synthesized `Codable` shape (`{"points":[…]}`) is
/// persisted as the `segmentsData` blob and mirrored to CloudKit. Once V6 ships, **any new
/// stored property must be `Optional` or have a default**, or every previously written blob
/// fails to decode. That failure is masked at first by D2's fallback to `trackData`, and
/// becomes unrecoverable ride loss once `trackData` is retired.
///
/// The wrapper object is deliberate rather than incidental: `[[TrackPoint]]` would encode
/// smaller, but per-segment metadata (a pause reason, a resume timestamp) has nowhere to go
/// without a second migration. The `{"points":` overhead is ~12 bytes per segment against a
/// ~1.1 MB three-hour track.
public struct RideSegment: Codable, Equatable, Sendable {
    public var points: [TrackPoint]

    public init(points: [TrackPoint]) { self.points = points }
}
```

- [ ] **Step 2: Write the failing `TrackRibbon` tests**

`AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`:

```swift
import XCTest
@testable import AuraCore

/// `TrackRibbon` decides what the live/summary maps actually stroke. Its whole job is that
/// two segments never end up in one polyline, so the map cannot draw the chord across a
/// pause. Pure, so the SwiftUI layers stay dumb projections.
final class TrackRibbonTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: 0))
    }

    private func seg(_ coords: [(Double, Double)]) -> RideSegment {
        RideSegment(points: coords.map { pt($0.0, $0.1) })
    }

    func test_noSplit_onePiecePerSegment() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([(40.0, -80.0), (40.001, -80.0)]),
                       seg([(41.0, -80.0), (41.001, -80.0)])],
            splitAtMeters: nil)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1])
        XCTAssertFalse(pieces.contains { $0.isBehind })
        // The chord: no piece may contain a point from two different segments.
        XCTAssertFalse(pieces.contains {
            $0.coordinates.contains(Coordinate(latitude: 40.001, longitude: -80.0))
            && $0.coordinates.contains(Coordinate(latitude: 41.0, longitude: -80.0))
        })
    }

    /// Runs shorter than two points stroke nothing, but must not shift the `sourceIndex` of
    /// the runs after them.
    func test_segmentsWithFewerThanTwoPoints_areDroppedWithoutShiftingIndices() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([]), seg([(40.0, -80.0)]), seg([(41.0, -80.0), (41.001, -80.0)])],
            splitAtMeters: nil)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].coordinates.count, 2)
        XCTAssertEqual(pieces[0].sourceIndex, 2)
    }

    func test_split_marksRiddenPortionBehind() {
        // Four points ~111 m apart in latitude; split at 150 m lands inside the run.
        let segment = seg([(40.000, -80.0), (40.001, -80.0), (40.002, -80.0), (40.003, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [segment], splitAtMeters: 150)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces[0].isBehind)
        XCTAssertFalse(pieces[1].isBehind)
        // Behind and ahead share the boundary point, so the ribbon has no visual gap.
        XCTAssertEqual(pieces[0].coordinates.last, pieces[1].coordinates.first)
        XCTAssertEqual(pieces.map(\.sourceIndex), [0, 0])
    }

    /// THE discriminating test. Segment 1 is ~111 m; segment 2 starts ~111 km away, so the
    /// pause chord dwarfs everything. Splitting at 261 m must consume segment 1's 111 m and
    /// carry the remaining 150 m into segment 2 — NOT walk the 111 km chord and conclude the
    /// budget is exhausted. A split measured on flattened geometry marks segment 2 wholly
    /// ahead and this test fails.
    func test_split_isMeasuredPerSegment_notAcrossThePauseChord() {
        let one = seg([(40.000, -80.0), (40.001, -80.0)])
        let two = seg([(41.000, -80.0), (41.001, -80.0), (41.002, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [one, two], splitAtMeters: 261)

        let fromOne = pieces.filter { $0.sourceIndex == 0 }
        XCTAssertEqual(fromOne.count, 1)
        XCTAssertTrue(fromOne[0].isBehind, "segment 1 is shorter than the split — wholly ridden")

        let fromTwo = pieces.filter { $0.sourceIndex == 1 }
        XCTAssertEqual(fromTwo.count, 2, "the remaining 150 m must split segment 2")
        XCTAssertTrue(fromTwo[0].isBehind)
        XCTAssertFalse(fromTwo[1].isBehind)
    }

    func test_splitBeyondTotalLength_isAllBehind() {
        let segment = seg([(40.000, -80.0), (40.001, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [segment], splitAtMeters: 100_000)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(pieces[0].isBehind)
    }

    func test_splitAtZero_isAllAhead() {
        let segment = seg([(40.000, -80.0), (40.001, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [segment], splitAtMeters: 0)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertFalse(pieces[0].isBehind)
    }

    func test_noSegments_isEmpty() {
        XCTAssertTrue(TrackRibbon.pieces(segments: [], splitAtMeters: nil).isEmpty)
        XCTAssertTrue(TrackRibbon.pieces(segments: [], splitAtMeters: 100).isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `cd AuraCore && swift test --filter TrackRibbonTests`
Expected: FAIL — `cannot find 'TrackRibbon' in scope`.

- [ ] **Step 4: Implement `TrackRibbon`**

`AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift`:

```swift
import Foundation

/// Turns a ride's segments into the polylines a map should stroke, so no renderer ever has
/// to decide for itself whether two adjacent points belong in the same line. A pause gap is
/// unrepresentable in the output: pieces never span segments.
///
/// `splitAtMeters` is the rider's own progress along the ride (group rides dim what is
/// already ridden), sourced from `recorder.stats.distanceMeters`.
public enum TrackRibbon {
    public struct Piece: Equatable, Sendable {
        public let coordinates: [Coordinate]
        /// True for the already-ridden portion, which the group map dims.
        public let isBehind: Bool
        /// Index into the original `segments` array. Preserved because runs too short to
        /// stroke are dropped, so output position is not input position — and Pass 4 wants
        /// to render the *current* segment differently while paused.
        public let sourceIndex: Int

        public init(coordinates: [Coordinate], isBehind: Bool, sourceIndex: Int) {
            self.coordinates = coordinates
            self.isBehind = isBehind
            self.sourceIndex = sourceIndex
        }
    }

    /// - Parameter splitAtMeters: nil draws every segment as one bright piece. Non-nil splits
    ///   at that cumulative *ridden* distance into behind/ahead pieces.
    /// - Returns: drawable pieces in ride order. Runs of fewer than two coordinates are
    ///   dropped — a single point strokes nothing.
    public static func pieces(segments: [RideSegment], splitAtMeters: Double?) -> [Piece] {
        var result: [Piece] = []
        // The budget is spent segment by segment. It must NOT be resolved by walking the
        // flattened geometry: that walk includes the straight-line chord across each pause,
        // while `splitAtMeters` comes from segment-aware stats and excludes it. Mixing the
        // two measures the split against a longer track than the rider rode, which freezes
        // the ribbon for the length of the chord after every resume.
        var remaining = splitAtMeters ?? 0
        let splitting = splitAtMeters != nil

        for (index, segment) in segments.enumerated() {
            let run = segment.points.map(\.coordinate)
            guard run.count > 1 else { continue }   // strokes nothing, and contributes no length

            guard splitting else {
                result.append(Piece(coordinates: run, isBehind: false, sourceIndex: index))
                continue
            }

            let local = RouteSplit.splitIndex(geometry: run, atMeters: remaining)
            remaining = max(remaining - length(of: run), 0)

            if local <= 1 {
                result.append(Piece(coordinates: run, isBehind: false, sourceIndex: index))
            } else if local >= run.count {
                result.append(Piece(coordinates: run, isBehind: true, sourceIndex: index))
            } else {
                // Overlap by one point so behind and ahead join without a visual gap. The
                // code this replaces used `prefix(split)` beside `suffix(from: split)`, which
                // left the leg between them stroked by neither — a hairline gap in the
                // ribbon. Fixing it is a deliberate change, not a preservation.
                result.append(Piece(coordinates: Array(run.prefix(local)),
                                    isBehind: true, sourceIndex: index))
                result.append(Piece(coordinates: Array(run.suffix(from: local - 1)),
                                    isBehind: false, sourceIndex: index))
            }
        }
        return result
    }

    private static func length(of run: [Coordinate]) -> Double {
        guard run.count > 1 else { return 0 }
        return (1..<run.count).reduce(0.0) { $0 + Geo.distance(run[$1 - 1], run[$1]) }
    }
}
```

For a single-segment ride this is identical to walking the whole geometry, so the unpaused
case is unchanged.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `cd AuraCore && swift test --filter TrackRibbonTests`
Expected: PASS, including `test_split_isMeasuredPerSegment_notAcrossThePauseChord`.

- [ ] **Step 6: Write the failing segmented-`PolylineNormalizer` tests**

Append to `AuraCore/Tests/AuraKitTests/PlottingTests.swift`, matching that file's existing
style (read it first — it may be swift-testing rather than XCTest):

```swift
    func test_segmentedPoints_singleSegment_matchesFlatFunctionExactly() {
        let coords = [Coordinate(latitude: 40.0, longitude: -80.0),
                      Coordinate(latitude: 40.01, longitude: -80.02),
                      Coordinate(latitude: 40.02, longitude: -79.99)]
        let size = CGSize(width: 120, height: 80)
        let flat = PolylineNormalizer.points(coords, in: size, inset: 4)
        let segmented = PolylineNormalizer.points(segments: [coords], in: size, inset: 4)
        XCTAssertEqual(segmented.count, 1)
        XCTAssertEqual(segmented[0], flat)   // byte-identical: no rendering change for unpaused rides
    }

    func test_segmentedPoints_shareOneScale() {
        // Two runs far apart: normalized independently they would each fill the box and
        // land on top of each other. One shared scale keeps their real separation.
        let near = [Coordinate(latitude: 40.000, longitude: -80.0),
                    Coordinate(latitude: 40.001, longitude: -80.0)]
        let far = [Coordinate(latitude: 40.100, longitude: -80.0),
                   Coordinate(latitude: 40.101, longitude: -80.0)]
        let size = CGSize(width: 100, height: 100)
        let segmented = PolylineNormalizer.points(segments: [near, far], in: size, inset: 0)
        XCTAssertEqual(segmented.count, 2)
        // North-up: the higher-latitude run must sit above the other.
        XCTAssertLessThan(segmented[1][0].y, segmented[0][0].y)
        // And neither run spans the full height on its own.
        XCTAssertLessThan(abs(segmented[0][0].y - segmented[0][1].y), 50)
    }

    func test_segmentedPoints_dropsRunsShorterThanTwo() {
        let coords = [Coordinate(latitude: 40.0, longitude: -80.0),
                      Coordinate(latitude: 40.01, longitude: -80.0)]
        let segmented = PolylineNormalizer.points(segments: [[], [coords[0]], coords],
                                                  in: CGSize(width: 50, height: 50), inset: 0)
        XCTAssertEqual(segmented.count, 1)
        XCTAssertEqual(segmented[0].count, 2)
    }

    func test_segmentedPoints_emptyInput_isEmpty() {
        XCTAssertTrue(PolylineNormalizer.points(segments: [], in: CGSize(width: 10, height: 10),
                                                inset: 0).isEmpty)
    }
```

- [ ] **Step 7: Run them and confirm they fail**

Run: `cd AuraCore && swift test --filter PlottingTests`
Expected: FAIL — no `points(segments:in:inset:)` overload.

- [ ] **Step 8: Implement the shared-scale overload**

In `AuraCore/Sources/AuraKit/Plotting/Plotting.swift`, replace the body of
`PolylineNormalizer`. **Note the local `kk`** — assigning `k` and then capturing it in the
`coords.map` closure inside `init` is `error: constant 'self.minX' captured by a closure
before being initialized`. **[gate]**

```swift
public enum PolylineNormalizer {
    /// Equirectangular projection (longitude scaled by cos(mean latitude) so the shape
    /// isn't stretched at city scale), fit *uniformly* into `size` minus `inset` on all
    /// sides, north-up (Y flipped). Returns `[]` for fewer than 2 points or empty size.
    public static func points(_ coords: [Coordinate], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard let transform = Transform(coords: coords, in: size, inset: inset) else { return [] }
        return coords.map(transform.apply)
    }

    /// Several runs fitted through ONE shared transform, so a paused ride's segments keep
    /// their real separation and scale instead of each filling the box (same reasoning as
    /// `Sparkline`'s shared `range`). Runs of fewer than two coordinates stroke nothing and
    /// are dropped. Single-segment input is byte-identical to the flat function above.
    public static func points(segments: [[Coordinate]], in size: CGSize,
                              inset: CGFloat) -> [[CGPoint]] {
        let runs = segments.filter { $0.count > 1 }
        guard let transform = Transform(coords: runs.flatMap { $0 }, in: size, inset: inset)
        else { return [] }
        return runs.map { $0.map(transform.apply) }
    }

    /// The projection + fit, extracted so the flat and segmented entry points cannot drift.
    private struct Transform {
        let k: Double, minX: Double, maxY: Double, scale: Double, offX: CGFloat, offY: CGFloat

        init?(coords: [Coordinate], in size: CGSize, inset: CGFloat) {
            guard coords.count > 1, size.width > 0, size.height > 0 else { return nil }

            let meanLat = coords.reduce(0) { $0 + $1.latitude } / Double(coords.count)
            // Local, not `self.k`: capturing a partially-initialized `self` in the closures
            // below is a compile error.
            let kk = cos(meanLat * .pi / 180)
            let xs = coords.map { $0.longitude * kk }
            let ys = coords.map { $0.latitude }

            let lowX = xs.min()!, maxX = xs.max()!
            let minY = ys.min()!, highY = ys.max()!
            let spanX = max(maxX - lowX, 1e-12), spanY = max(highY - minY, 1e-12)

            let availW = max(size.width - inset * 2, 1)
            let availH = max(size.height - inset * 2, 1)
            let s = min(availW / spanX, availH / spanY)   // uniform → preserve aspect
            let drawnW = spanX * s, drawnH = spanY * s

            k = kk
            minX = lowX
            maxY = highY
            scale = s
            offX = inset + (availW - drawnW) / 2
            offY = inset + (availH - drawnH) / 2
        }

        func apply(_ c: Coordinate) -> CGPoint {
            CGPoint(x: offX + (c.longitude * k - minX) * scale,
                    y: offY + (maxY - c.latitude) * scale)   // flip Y so north is up
        }
    }
}
```

The `CGFloat`/`Double` mixing above is exactly what the original did (SE-0307 implicit
conversion; on 64-bit Apple platforms `CGFloat` is `Double`-backed). A reviewer compared both
implementations over 2000 randomized inputs with zero mismatches. If
`test_segmentedPoints_singleSegment_matchesFlatFunctionExactly` or the existing `PlottingTests`
nevertheless fail, restore the original flat function untouched and give `Transform` the
identical conversion points — do **not** relax the assertion to an accuracy comparison.

- [ ] **Step 9: Run the full package suite**

Run: `cd AuraCore && swift test 2>&1 | tail -20`
Expected: all pass — this task only added API. Baseline for comparison: 611 tests, 132 suites.

- [ ] **Step 10: Lint and commit**

```bash
swiftlint --strict --quiet
git add AuraCore/Sources/AuraCore/Models/RideSegment.swift \
        AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift \
        AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift \
        AuraCore/Sources/AuraKit/Plotting/Plotting.swift \
        AuraCore/Tests/AuraKitTests/PlottingTests.swift
git commit -m "feat(roh-98): add RideSegment, TrackRibbon and shared-scale segmented polyline fitting"
```

---

### Task 2: `Ride.segments` replaces `Ride.track`

Atomic by necessity: a stored property cannot be half-removed. Every forced read site moves
in this commit, each one deciding explicitly whether it flattens or draws per segment.

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Models/Ride.swift`
- Modify: `AuraCore/Sources/AuraCore/Health/WorkoutData.swift:27,32`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift:7,13`
- Modify: `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift:15,35,40`
- Modify: `AuraCore/Sources/AuraKit/Summary/ElevationProfileContent.swift:18`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:33,39`
- Modify: `Aura/Sources/Ride/StaticRouteMap.swift`
- Modify: `Aura/Sources/Shared/RouteThumbnail.swift`
- Modify: `Aura/Sources/Ride/ShareCard/ShareCardView.swift:17,39`
- Create: `AuraCore/Tests/AuraCoreTests/RideSegmentTests.swift`
- Test — **complete list of `Ride.track` reads in tests, verified by grep [gate]:**
  - `AuraCore/Tests/AuraKitTests/RideTrackExternalStorageTests.swift:89,90,95`
  - `AuraCore/Tests/AuraKitTests/RideRecorderTests.swift:43`
  - `AuraCore/Tests/AuraKitTests/RideStoreSummaryTests.swift:38`
  - `AuraCore/Tests/AuraKitTests/GoldenRidePlaybackTests.swift:36`
  - `AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift:105-110`

**Interfaces:**
- Consumes: `RideSegment`, `PolylineNormalizer.points(segments:in:inset:)` (Task 1).
- Produces:
  - `Ride.segments: [RideSegment]`, `Ride.flattenedPoints: [TrackPoint]`
  - designated `Ride.init(id:kind:startedAt:endedAt:segments:stats:destinationName:routeId:destinationPlaceId:)`
  - convenience `Ride.init(id:kind:startedAt:endedAt:track:stats:destinationName:routeId:destinationPlaceId:)`
  - `ShareCardContent.routeSegments: [[Coordinate]]` (replaces `routeCoordinates`)
  - `StaticRouteMap(segments: [[Coordinate]])`, `RouteThumbnail(segments: [[Coordinate]])`

- [ ] **Step 1: Write the failing model test**

`AuraCore/Tests/AuraCoreTests/RideSegmentTests.swift`:

```swift
import XCTest
@testable import AuraCore

final class RideSegmentTests: XCTestCase {
    private func pt(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80.0),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: t))
    }

    private func ride(segments: [RideSegment]) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
             endedAt: Date(timeIntervalSince1970: 100), segments: segments, stats: nil,
             routeId: nil, destinationPlaceId: nil)
    }

    func test_flattenedPoints_concatenatesInSegmentOrder() {
        let r = ride(segments: [RideSegment(points: [pt(40.0, 0), pt(40.1, 10)]),
                                RideSegment(points: [pt(41.0, 600)])])
        XCTAssertEqual(r.flattenedPoints, [pt(40.0, 0), pt(40.1, 10), pt(41.0, 600)])
    }

    func test_flattenedPoints_skipsInteriorEmptySegments() {
        let r = ride(segments: [RideSegment(points: []),
                                RideSegment(points: [pt(40.0, 0)]),
                                RideSegment(points: [])])
        XCTAssertEqual(r.flattenedPoints, [pt(40.0, 0)])
        XCTAssertEqual(r.segments.count, 3, "interior empties are legal and must survive")
    }

    /// The write-side convenience the spec deliberately keeps: a caller that has a flat
    /// track still gets a ride, as exactly one segment.
    func test_trackConvenienceInit_wrapsInOneSegment() {
        let points = [pt(40.0, 0), pt(40.1, 10)]
        let r = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                     endedAt: nil, track: points, stats: nil,
                     routeId: nil, destinationPlaceId: nil)
        XCTAssertEqual(r.segments.count, 1)
        XCTAssertEqual(r.segments[0].points, points)
        XCTAssertEqual(r.flattenedPoints, points)
    }

    /// Canonical form: "no points" is ZERO segments, never one empty one. Without this,
    /// `RideMapper`'s save/load path converts a 0-segment ride into a 1-segment ride and
    /// `Ride`'s `Equatable` round trip stops holding.
    func test_trackConvenienceInit_emptyTrack_isZeroSegments() {
        let r = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                     endedAt: nil, track: [], stats: nil,
                     routeId: nil, destinationPlaceId: nil)
        XCTAssertTrue(r.segments.isEmpty)
        XCTAssertTrue(r.flattenedPoints.isEmpty)
    }

    func test_ride_codableRoundTripsSegments() throws {
        let r = ride(segments: [RideSegment(points: [pt(40.0, 0), pt(40.1, 10)]),
                                RideSegment(points: [pt(41.0, 600)])])
        let back = try JSONDecoder().decode(Ride.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.segments.count, 2)
    }

    /// Pins the ON-DISK SHAPE, not just round-trip consistency. Schema V6 (Pass 3) persists
    /// `[RideSegment]` as the `segmentsData` blob and its V5→V6 backfill must emit bytes an
    /// already-shipped V6 build can decode; a round-trip test is invariant under any
    /// consistent shape change and would not catch a rename.
    func test_rideSegment_encodesAsPointsWrapper() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode([RideSegment(points: []), RideSegment(points: [])])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"[{"points":[]},{"points":[]}]"#)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd AuraCore && swift test --filter RideSegmentTests`
Expected: FAIL — no `segments:` initializer, no `flattenedPoints`.

- [ ] **Step 3: Rewrite `Ride`**

`AuraCore/Sources/AuraCore/Models/Ride.swift`:

```swift
import Foundation

public struct Ride: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case navigate, freeRide }
    public var id: UUID
    public var kind: Kind
    public var startedAt: Date
    public var endedAt: Date?
    /// The ride's track, split at every pause. Points in different segments were never
    /// adjacent — anything that draws a line or measures a delta between two points must
    /// stay inside one segment (spec D1/D4). A ride with no points has ZERO segments.
    public var segments: [RideSegment]
    public var stats: RideStats?
    /// Human-readable destination (e.g. "The Church Brew Works") for a navigate ride,
    /// denormalized so History can show it without re-resolving the Place. nil for free rides.
    public var destinationName: String?
    public var routeId: UUID?
    public var destinationPlaceId: UUID?

    public init(id: UUID = UUID(), kind: Kind, startedAt: Date, endedAt: Date?,
                segments: [RideSegment], stats: RideStats?, destinationName: String? = nil,
                routeId: UUID?, destinationPlaceId: UUID?) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.segments = segments; self.stats = stats; self.destinationName = destinationName
        self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
    }

    /// Builds a single-segment ride from a flat track. Retained deliberately: making a ride
    /// out of points you already know are contiguous is safe, whereas *reading* a ride back
    /// as a flat track is the thing that silently draws across a pause. Hence there is no
    /// matching `track` accessor — use `segments`, or `flattenedPoints` and say so.
    ///
    /// An empty track yields ZERO segments, not one empty segment. That keeps "no points"
    /// single-valued: `RideRecorder.end` drops its trailing empty segment, so a fix-less ride
    /// and its persisted round trip agree, and `Ride`'s `Equatable` survives a save/load.
    public init(id: UUID = UUID(), kind: Kind, startedAt: Date, endedAt: Date?,
                track: [TrackPoint], stats: RideStats?, destinationName: String? = nil,
                routeId: UUID?, destinationPlaceId: UUID?) {
        self.init(id: id, kind: kind, startedAt: startedAt, endedAt: endedAt,
                  segments: track.isEmpty ? [] : [RideSegment(points: track)], stats: stats,
                  destinationName: destinationName, routeId: routeId,
                  destinationPlaceId: destinationPlaceId)
    }

    /// Every point in ride order, pause gaps closed up. Correct for consumers that treat the
    /// track as a bag of samples (elevation series, HealthKit route, encoded blob) and wrong
    /// for anything measuring between consecutive points or stroking a line.
    ///
    /// **O(n), and it allocates a fresh array on every access** — up to ~10,800 points on a
    /// three-hour ride. Bind it to a `let` before use, and never read it inside a SwiftUI
    /// `body` (the live HUD re-evaluates at 30 fps under `TimelineView`).
    public var flattenedPoints: [TrackPoint] { segments.flatMap(\.points) }
}
```

- [ ] **Step 4: Find every broken read**

Run: `cd AuraCore && swift build --build-tests 2>&1 | grep -E "error:" | sort -u`

`--build-tests` is required: plain `swift build` skips test targets entirely and would hide
four of the sites below. Note also that compilation stops at the first failing target, so
expect to run this repeatedly as you fix each layer (`AuraCore` → `AuraKit` → tests).

Expected sites, and nothing else: `WorkoutData.swift:27,32`, `RideMapper.swift:7,13`,
`ShareCardContent.swift:35,40`, `ElevationProfileContent.swift:18`, plus the five test files
listed above. `RideSummaryView.swift:33,39` is app-target and will not appear here — it is
handled in Step 10. If a source site appears that is not on this list, stop and report it.

- [ ] **Step 5: Migrate the flatteners**

`WorkoutData.swift`:

```swift
    /// Maps a finished ride. `end` falls back from `endedAt` to the last track
    /// timestamp to `startedAt`, then is clamped to `>= start` so a degenerate or
    /// clock-skewed ride can never produce `end < start` (which `HKWorkoutBuilder`
    /// rejects).
    ///
    /// Flattens deliberately: Slice A does not write `HKWorkoutEvent(type: .pause)`, so a
    /// ride ended after a long pause is still written to Health with wall-clock duration.
    /// Known inaccuracy, listed as out of scope in the segmented-rides spec.
    public init(from ride: Ride) {
        let points = ride.flattenedPoints
        let rawEnd = ride.endedAt ?? points.last?.timestamp ?? ride.startedAt
        self.externalID = ride.id
        self.start = ride.startedAt
        self.end = max(rawEnd, ride.startedAt)
        self.distanceMeters = ride.stats?.distanceMeters ?? 0
        self.route = points
    }
```

`RideMapper.record`:

```swift
    public static func record(from ride: Ride) throws -> RideRecord {
        let encoder = JSONEncoder()
        // Both blobs stay flat on purpose. `thumbnailData` is read by older builds syncing
        // the same CloudKit records with a bare `try?` that falls back to blank (D3), and
        // `trackData` gains a segmented sibling (`segmentsData`) in the V6 schema pass —
        // changing either shape here would blank History on a mixed-version fleet.
        // Consequence until V6: a multi-segment ride saved and reloaded comes back as one
        // segment. Pinned by `multiSegmentRideFlattensThroughTheStoreUntilV6`.
        let points = ride.flattenedPoints
        let thumb = TrackSimplifier.thumbnail(from: points.map(\.coordinate))
        return RideRecord(
            id: ride.id,
            kindRaw: ride.kind.rawValue,
            startedAt: ride.startedAt,
            endedAt: ride.endedAt,
            trackData: try encoder.encode(points),
            ...
```

Leave `RideMapper.ride(from:)` at `:31` alone — its `track:` argument now resolves to the
convenience initializer, and with the canonical-form rule an empty `trackData` correctly
yields zero segments. Leave `summary` entirely alone.

`ElevationProfileContent.swift:18` — flatten, with an honest comment. **[gate]** The first
draft claimed a pause "changes nothing about what it draws"; that is false, because
`Sparkline.points` spaces X evenly *by index*, so a 600-second stop occupies zero horizontal
space and the boundary shows a one-step vertical cliff:

```swift
        // Flattened deliberately: the silhouette is a series of elevation samples, not a
        // geometric walk between consecutive points. Two known consequences, accepted for
        // Slice A: the sparkline is index-spaced, so a pause occupies no horizontal space,
        // and the elevation step across a boundary renders as a one-step cliff. Cumulative
        // gain (which does respect segment boundaries) arrives pre-computed in `stats`.
        kind = ElevationProfile.classify(track: ride.flattenedPoints,
                                         gainMeters: stats.elevationGainMeters)
```

- [ ] **Step 6: Migrate `ShareCardContent` to segments**

Replace `routeCoordinates` with `routeSegments`:

```swift
    /// The route to stroke, one run per ride segment. Empty when there is nothing to draw.
    /// Segmented rather than flattened: a share card that connected two segments would draw
    /// a straight line across the café stop.
    public let routeSegments: [[Coordinate]]
```

and in the initializer:

```swift
        routeSegments = ride.segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }

        // The card draws the silhouette only for a real climb, gated on cumulative gain
        // via the shared classifier so the card and the ride summary never disagree.
        if case .profile(let samples) = ElevationProfile.classify(
            track: ride.flattenedPoints, gainMeters: stats.elevationGainMeters) {
```

Update `ShareCardContentTests.swift:105-110` (read the file first and match its existing
`point(_:_:elevation:)` helper signature exactly):

```swift
    @Test func routeSegments_needTwoPointsInARun() {
        let multi = ride(track: [point(0, 0), point(1, 1)], stats: stats())
        #expect(ShareCardContent(ride: multi, units: .imperial).routeSegments.count == 1)
        #expect(ShareCardContent(ride: multi, units: .imperial).routeSegments[0].count == 2)
        let single = ride(track: [point(0, 0)], stats: stats())
        #expect(ShareCardContent(ride: single, units: .imperial).routeSegments.isEmpty)
    }

    @Test func routeSegments_keepSegmentsApart() {
        let paused = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                          endedAt: nil,
                          segments: [RideSegment(points: [point(0, 0), point(0, 1)]),
                                     RideSegment(points: [point(5, 5), point(5, 6)])],
                          stats: stats(), routeId: nil, destinationPlaceId: nil)
        let content = ShareCardContent(ride: paused, units: .imperial)
        #expect(content.routeSegments.count == 2)
        #expect(content.routeSegments.allSatisfy { $0.count == 2 })
    }
```

- [ ] **Step 7: Fix the five test read sites**

- `RideRecorderTests.swift:43` → `XCTAssertEqual(ride.flattenedPoints.count, 2)`
- `RideTrackExternalStorageTests.swift:89,90` → `ride.flattenedPoints.count` / `ride.flattenedPoints == track`
- `RideTrackExternalStorageTests.swift:95` → `all.first?.flattenedPoints == track`
- `RideStoreSummaryTests.swift:38` → `#expect(full.flattenedPoints.count == 2)`
- `GoldenRidePlaybackTests.swift:36` → `#expect(ride.flattenedPoints.count == GoldenRideFixture.expectedPointCount)`
  — the four frozen literal comparisons below it stay exactly as they are.

Run: `cd AuraCore && swift test 2>&1 | grep -E "error:|failed" | head -20`
Expected: empty.

- [ ] **Step 8: Confirm the frozen literals did not move**

```bash
git diff --stat AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift \
                AuraCore/Tests/AuraCoreTests/__Snapshots__
```
Expected: **no output.** Any diff means the change altered computed ride values — stop and
investigate rather than re-recording.

- [ ] **Step 9: Make the app target compile — `StaticRouteMap` and `RouteThumbnail`**

`Aura/Sources/Ride/StaticRouteMap.swift` — the current file is 43 lines; replace `:11`,
`:16-18`, `:21-29` and `:35-42`. Note the group must use the **data-driven** initializer:
`PolylineAnnotationGroup`'s builder is `@ArrayBuilder`, which has no `buildArray`, so a
`for` loop inside the trailing closure does not compile. **[gate]**

```swift
struct StaticRouteMap: View {
    /// One coordinate run per ride segment. Separate polylines, so a pause gap never
    /// becomes a straight line across the map.
    let segments: [[Coordinate]]

    @Environment(SettingsStore.self) private var settings
    @State private var viewport: Viewport = .styleDefault

    private var clSegments: [[CLLocationCoordinate2D]] {
        segments
            .filter { $0.count > 1 }
            .map { $0.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
    }

    /// Every drawn point, for the camera fit. Fitting the overview *across* segments is
    /// correct — only stroking across them is not.
    private var allCoords: [CLLocationCoordinate2D] { clSegments.flatMap { $0 } }

    var body: some View {
        Map(viewport: $viewport) {
            PolylineAnnotationGroup(Array(clSegments.enumerated()), id: \.offset) { item in
                PolylineAnnotation(lineCoordinates: item.element)
                    .lineColor(StyleColor(AuraTheme.routeUIColor))
                    .lineWidth(5)
            }
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        .allowsHitTesting(false)
        .onAppear(perform: fit)
    }

    private func fit() {
        guard allCoords.count > 1 else { return }
        viewport = .overview(
            geometry: LineString(allCoords),
            geometryPadding: .init(top: 24, leading: 24, bottom: 24, trailing: 24),
            maxZoom: 16
        )
    }
}
```

The old `if clCoords.count > 1` wrapper is no longer needed: `clSegments` is already filtered,
and an empty data array yields an empty group.

`Aura/Sources/Shared/RouteThumbnail.swift`:

```swift
struct RouteThumbnail: View {
    /// One coordinate run per ride segment, fitted through a single shared scale.
    let segments: [[Coordinate]]
    var lineColor: Color = AuraTheme.routeLine
    var lineWidth: CGFloat = 2

    /// Flat-track convenience for the callers that read the pre-baked, deliberately
    /// un-segmented `thumbnailData` blob (History rows, Last Ride card, widgets).
    init(coordinates: [Coordinate], lineColor: Color = AuraTheme.routeLine,
         lineWidth: CGFloat = 2) {
        self.init(segments: [coordinates], lineColor: lineColor, lineWidth: lineWidth)
    }

    init(segments: [[Coordinate]], lineColor: Color = AuraTheme.routeLine,
         lineWidth: CGFloat = 2) {
        self.segments = segments
        self.lineColor = lineColor
        self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { context, size in
            let runs = PolylineNormalizer.points(segments: segments, in: size,
                                                 inset: lineWidth + 3)
            var path = Path()
            for pts in runs where pts.count > 1 {
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(lineColor),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
```

The `coordinates:` convenience keeps the five `thumbnailData` render sites untouched, per D3.

- [ ] **Step 10: Wire the two remaining app read sites**

`Aura/Sources/Ride/RideSummaryView.swift`:

```swift
    private var routeSegments: [[Coordinate]] {
        ride.segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }
    }
    private var hasRoute: Bool { !routeSegments.isEmpty }
```

and at `:39` → `StaticRouteMap(segments: routeSegments)`.

`Aura/Sources/Ride/ShareCard/ShareCardView.swift`:
- `:17` → `private var hasRoute: Bool { !content.routeSegments.isEmpty }`
- `:39` → `RouteThumbnail(segments: content.routeSegments, lineColor: AuraTheme.routeLine, lineWidth: 3)`
- The three `#Preview` rides at `:166,182,194` use `track:` and need no change.

- [ ] **Step 11: Verify the app target builds**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an
iPhone simulator and report only errors. `swift test` does not compile the app target, so
this is the only check that catches a broken SwiftUI call site.
Expected: build succeeds.

- [ ] **Step 12: Full verification and commit**

```bash
cd AuraCore && swift test 2>&1 | tail -5
swiftlint --strict --quiet
git diff --stat AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift   # must be empty
git add -A
git commit -m "feat(roh-98): replace Ride.track with Ride.segments across every read surface"
```

---

### Task 3: Segment-aware `RideStatsCalculator`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Stats/RideStatsCalculator.swift`
- Create: `AuraCore/Tests/AuraCoreTests/RideStatsSegmentTests.swift`

**Interfaces:**
- Consumes: `RideSegment` (Task 1).
- Produces: `RideStatsCalculator.stats(segments: [RideSegment], movingSpeedThreshold: Double = 0.5, elevationNoiseThreshold: Double = 1.0) -> RideStats`, alongside the unchanged flat
  `stats(from points: [TrackPoint], …)`.

**Naming is load-bearing. [gate]** The entry point is `stats(segments:)`, **not** an overload
of `stats(from:)`. `RideStatsCalculatorTests.swift:12` calls `stats(from: [])` with a bare
empty literal, which a same-labelled overload renders ambiguous — the `AuraCoreTests` target
then fails to build and Task 3 can never reach a green step.

- [ ] **Step 1: Write the failing tests**

`AuraCore/Tests/AuraCoreTests/RideStatsSegmentTests.swift`:

```swift
import XCTest
@testable import AuraCore

/// Segment-aware stats. The contract is that nothing is ever measured *between* two
/// segments: the pause gap contributes no distance, no moving time, no elevation gain and
/// cannot set max speed.
final class RideStatsSegmentTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double, ele: Double?, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: ele, timestamp: Date(timeIntervalSince1970: t))
    }

    /// Two short northward runs, separated by a big jump in space and time.
    private var first: [TrackPoint] {
        [pt(40.4400, -80.0, ele: 250, t: 0), pt(40.4410, -80.0, ele: 256, t: 20)]
    }
    private var second: [TrackPoint] {
        [pt(40.5400, -80.0, ele: 400, t: 900), pt(40.5410, -80.0, ele: 406, t: 920)]
    }

    func test_singleSegment_matchesFlatEntryPointExactly() {
        let flat = RideStatsCalculator.stats(from: first)
        let segmented = RideStatsCalculator.stats(segments: [RideSegment(points: first)])
        XCTAssertEqual(segmented, flat)   // exact, not approximate: unpaused rides must not move
    }

    func test_distanceAndMovingTime_sumAcrossSegments_excludingTheGap() {
        let a = RideStatsCalculator.stats(from: first)
        let b = RideStatsCalculator.stats(from: second)
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        XCTAssertEqual(combined.distanceMeters, a.distanceMeters + b.distanceMeters, accuracy: 1e-9)
        XCTAssertEqual(combined.movingTimeSeconds, a.movingTimeSeconds + b.movingTimeSeconds,
                       accuracy: 1e-9)
        // The gap is ~11 km and 880 s. Flattening would swamp both numbers.
        let flattened = RideStatsCalculator.stats(from: first + second)
        XCTAssertLessThan(combined.distanceMeters, flattened.distanceMeters - 1000)
        XCTAssertLessThan(combined.movingTimeSeconds, flattened.movingTimeSeconds - 500)
    }

    func test_maxSpeed_isTheMaxOverSegments_neverTheGap() {
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        let a = RideStatsCalculator.stats(from: first)
        let b = RideStatsCalculator.stats(from: second)
        XCTAssertEqual(combined.maxSpeedMetersPerSecond,
                       max(a.maxSpeedMetersPerSecond, b.maxSpeedMetersPerSecond), accuracy: 1e-9)
    }

    func test_averageSpeed_isTotalDistanceOverTotalMovingTime_notAnAverageOfAverages() {
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        XCTAssertEqual(combined.averageSpeedMetersPerSecond,
                       combined.distanceMeters / combined.movingTimeSeconds, accuracy: 1e-9)
    }

    func test_elevationBaseline_resetsAtSegmentBoundary() {
        // Segment 1 climbs +6, segment 2 climbs +6. The +144 step *between* them is not a
        // climb the rider rode, so it must not appear in gain.
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        XCTAssertEqual(combined.elevationGainMeters, 12, accuracy: 1e-9)
    }

    func test_elevationBaseline_stillBridgesNilWithinASegment() {
        let bridged = [pt(40.44, -80.0, ele: 250, t: 0),
                       pt(40.441, -80.0, ele: nil, t: 20),
                       pt(40.442, -80.0, ele: 256, t: 40)]
        let stats = RideStatsCalculator.stats(segments: [RideSegment(points: bridged)])
        XCTAssertEqual(stats.elevationGainMeters, 6, accuracy: 1e-9)
    }

    // MARK: Degenerate segments — reachable once pause exists (spec D6)

    func test_emptySegments_contributeNothingAndDoNotCrash() {
        let stats = RideStatsCalculator.stats(segments: [RideSegment(points: []),
                                                         RideSegment(points: first),
                                                         RideSegment(points: [])])
        XCTAssertEqual(stats, RideStatsCalculator.stats(from: first))
    }

    func test_singlePointSegments_contributeNothing() {
        let stats = RideStatsCalculator.stats(segments: [RideSegment(points: [first[0]]),
                                                         RideSegment(points: first)])
        XCTAssertEqual(stats, RideStatsCalculator.stats(from: first))
    }

    func test_noSegments_isZero() {
        XCTAssertEqual(RideStatsCalculator.stats(segments: []), .zero)
    }

    func test_onlyEmptySegments_isZero() {
        XCTAssertEqual(RideStatsCalculator.stats(segments: [RideSegment(points: []),
                                                            RideSegment(points: [])]), .zero)
    }
}
```

- [ ] **Step 2: Run and confirm they fail**

Run: `cd AuraCore && swift test --filter RideStatsSegmentTests`
Expected: FAIL — no `stats(segments:)`.

- [ ] **Step 3: Implement**

Rewrite `AuraCore/Sources/AuraCore/Stats/RideStatsCalculator.swift`. The pairwise walk moves
verbatim into a private accumulator that keeps the `count >= 2` guard *inside* it, so the
guard is naturally duplicated per segment and no body can ever reach `points[0]` unguarded:

```swift
import Foundation

public enum RideStatsCalculator {
    /// Computes ride statistics from an ordered list of GPS samples.
    /// - movingSpeedThreshold: segments slower than this (m/s) are treated as "stopped".
    /// - elevationNoiseThreshold: positive elevation deltas smaller than this (m) are ignored as GPS noise.
    ///
    /// Retained beside `stats(segments:)` for callers that genuinely hold one contiguous run
    /// of points (the golden-ride record helper, the stats snapshot test).
    public static func stats(from points: [TrackPoint],
                             movingSpeedThreshold: Double = 0.5,
                             elevationNoiseThreshold: Double = 1.0) -> RideStats {
        finish(walk(points, movingSpeedThreshold: movingSpeedThreshold,
                    elevationNoiseThreshold: elevationNoiseThreshold))
    }

    /// Statistics over a segmented ride. Every pairwise quantity is computed strictly
    /// *inside* a segment, so a pause contributes no distance, no moving time, no elevation
    /// gain and can never set max speed. Distance, moving time and gain sum; max speed is the
    /// maximum over segments; average speed is recomputed once from the totals rather than
    /// averaged from per-segment averages (spec D4).
    ///
    /// Deliberately NOT an overload of `stats(from:)`: an existing call site passes a bare
    /// `[]` literal, which two same-labelled array overloads render ambiguous.
    public static func stats(segments: [RideSegment],
                             movingSpeedThreshold: Double = 0.5,
                             elevationNoiseThreshold: Double = 1.0) -> RideStats {
        var total = Accumulator()
        for segment in segments {
            // The `count >= 2` guard lives inside `walk`, so it is applied per segment
            // rather than once for the whole ride. Moving it up would leave the per-segment
            // body reaching `points[0]` on an empty segment — an index-out-of-range crash on
            // the main actor, and empty segments are reachable once pause exists (D6).
            total.merge(walk(segment.points, movingSpeedThreshold: movingSpeedThreshold,
                             elevationNoiseThreshold: elevationNoiseThreshold))
        }
        return finish(total)
    }

    /// Per-segment totals, before average speed is derived.
    private struct Accumulator {
        var distance = 0.0
        var movingTime = 0.0
        var maxSpeed = 0.0
        var elevationGain = 0.0

        mutating func merge(_ other: Accumulator) {
            distance += other.distance
            movingTime += other.movingTime
            maxSpeed = max(maxSpeed, other.maxSpeed)
            elevationGain += other.elevationGain
        }
    }

    /// The pairwise walk over ONE contiguous run of points. Fewer than two points has no
    /// pairs and therefore contributes nothing.
    private static func walk(_ points: [TrackPoint],
                             movingSpeedThreshold: Double,
                             elevationNoiseThreshold: Double) -> Accumulator {
        var acc = Accumulator()
        guard points.count >= 2 else { return acc }

        // Carry the last known elevation forward across points that lack one, so a
        // climb straddling a nil-elevation sample is bridged rather than dropped. Local to
        // this run, so the baseline resets at every segment boundary — the step across a
        // pause is elevation the rider did not ride under power.
        var lastElevation = points[0].elevation

        for i in 1..<points.count {
            let prev = points[i - 1], curr = points[i]
            let segDistance = Geo.distance(prev.coordinate, curr.coordinate)
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            acc.distance += segDistance

            if dt > 0 {
                let speed = segDistance / dt
                if speed >= movingSpeedThreshold {
                    acc.movingTime += dt
                    acc.maxSpeed = max(acc.maxSpeed, speed)
                }
            }

            if let e2 = curr.elevation {
                if let e1 = lastElevation {
                    let delta = e2 - e1
                    if delta >= elevationNoiseThreshold { acc.elevationGain += delta }
                }
                lastElevation = e2
            }
        }
        return acc
    }

    private static func finish(_ acc: Accumulator) -> RideStats {
        let avgSpeed = acc.movingTime > 0 ? acc.distance / acc.movingTime : 0
        return RideStats(distanceMeters: acc.distance,
                         movingTimeSeconds: acc.movingTime,
                         averageSpeedMetersPerSecond: avgSpeed,
                         maxSpeedMetersPerSecond: acc.maxSpeed,
                         elevationGainMeters: acc.elevationGain)
    }
}
```

The flat entry point now returns `finish(walk(...))` rather than an explicit `.zero` for
fewer than two points. That is the same value: `RideStats.zero` (`RideStats.swift:18-20`) is
all zeros, and `finish` of an empty accumulator produces exactly that. The zero/one-point
coverage lives in **`RideStatsCalculatorTests.swift:11-14`** (not `RideStatsCalculatorEdgeTests`,
as the first draft claimed **[gate]**) and must stay green unmodified.

- [ ] **Step 4: Run the new tests**

Run: `cd AuraCore && swift test --filter RideStatsSegmentTests`
Expected: PASS.

- [ ] **Step 5: Run the frozen-value tests specifically**

Run: `cd AuraCore && swift test --filter "RideStatsSnapshotTests|RideStatsCalculatorTests|RideStatsCalculatorEdgeTests|GoldenRide"`
Expected: PASS with **no snapshot re-record**. If the snapshot test reports a diff, the
refactor changed the arithmetic — fix the refactor, never the reference.

- [ ] **Step 6: Full suite, lint, commit**

```bash
cd AuraCore && swift test 2>&1 | tail -5
swiftlint --strict --quiet
git status --porcelain AuraCore/Tests/AuraCoreTests/__Snapshots__   # must be empty
git add AuraCore/Sources/AuraCore/Stats/RideStatsCalculator.swift \
        AuraCore/Tests/AuraCoreTests/RideStatsSegmentTests.swift
git commit -m "feat(roh-98): compute ride stats per segment, never across a pause"
```

---

### Task 4: Segmented recorder, coordinator and live HUD map

The live map is the surface a rider stares at during a pause, and it reads
`coordinator.track` → `recorder.track` — different properties on different types, untouched
by Task 2.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideRecorder.swift`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:18`
- Modify: `Aura/Sources/Ride/RideMapView.swift:11,35-38,103-133,170`
- Modify: `Aura/Sources/Ride/RideHUDView.swift:68`
- Test: `AuraCore/Tests/AuraKitTests/RideRecorderTests.swift:23,29`,
  `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift:79`

**Interfaces:**
- Consumes: `RideSegment`, `TrackRibbon.pieces(segments:splitAtMeters:)` (Task 1),
  `RideStatsCalculator.stats(segments:)` (Task 3), `Ride.init(…segments:…)` (Task 2).
- Produces: `RideRecorder.segments: [RideSegment]`, `RideRecorder.flattenedPoints: [TrackPoint]`,
  `RideSessionCoordinator.segments: [RideSegment]`, `RideMapView(segments:…)`.

- [ ] **Step 1: Update the recorder tests to the new shape (they must fail)**

In `AuraCore/Tests/AuraKitTests/RideRecorderTests.swift`:

```swift
    func test_recordingPoints_matchesRideStatsCalculator() {
        // …unchanged setup…
        XCTAssertEqual(recorder.stats, RideStatsCalculator.stats(from: points))
        XCTAssertEqual(recorder.segments, [RideSegment(points: points)])
        XCTAssertEqual(recorder.flattenedPoints, points)
    }

    func test_ignoresPointsWhenNotRecording() {
        let recorder = RideRecorder()
        recorder.record(pt(40.44, ele: 250, t: 0)) // before start
        XCTAssertTrue(recorder.flattenedPoints.isEmpty)
        XCTAssertEqual(recorder.stats, .zero)
    }

    /// An unpaused ride is exactly one open segment from `start` onward — including before
    /// the first fix arrives, so `record` always has somewhere to append.
    func test_start_opensExactlyOneSegment() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(recorder.segments.count, 1)
        XCTAssertTrue(recorder.flattenedPoints.isEmpty)
    }

    /// Restarting must not leave the previous ride's segment behind.
    func test_restart_resetsToOneEmptySegment() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        recorder.record(pt(40.44, ele: 250, t: 0))
        recorder.start(at: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(recorder.segments.count, 1)
        XCTAssertTrue(recorder.flattenedPoints.isEmpty)
        XCTAssertEqual(recorder.stats, .zero)
    }

    func test_end_returnsRideWithStatsAndEndTime() {
        // …unchanged setup…
        XCTAssertEqual(ride.flattenedPoints.count, 2)
        XCTAssertEqual(ride.segments.count, 1)
        XCTAssertFalse(recorder.isRecording)
    }

    /// Canonical form: a ride that never got a fix ends with ZERO segments, matching what
    /// `Ride(track: [])` produces and what a save/load round trip returns. Without the
    /// trailing-empty drop, `segments.count` changes across persistence on an `Equatable` type.
    func test_end_withNoFixes_producesZeroSegments() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        let ride = recorder.end(at: Date(timeIntervalSince1970: 60))
        XCTAssertTrue(ride.segments.isEmpty)
    }
```

And in `RideSessionCoordinatorTests.swift:79`:

```swift
        #expect(c.segments.count == 1)
        #expect(c.segments.first?.points.count == 3)
```

- [ ] **Step 2: Run and confirm they fail**

Run: `cd AuraCore && swift test --filter "RideRecorderTests|RideSessionCoordinatorTests"`
Expected: FAIL — no `segments` on either type.

- [ ] **Step 3: Segment the recorder**

In `AuraCore/Sources/AuraKit/RideRecorder.swift`. **Do not add `pause`/`resume` and do not
change `isRecording` — that is ROH-99.** There is exactly one open segment for the whole ride
at this pass:

```swift
    public private(set) var isRecording = false
    /// The ride so far, split at pauses. Pause does not exist yet, so this is always exactly
    /// one open segment from `start(at:)` onward — the shape lands now so the live map, the
    /// summary and the stats all read segments before anything can create a second one.
    public private(set) var segments: [RideSegment] = []
    public private(set) var stats: RideStats = .zero
```

```swift
    /// Every recorded point in order. **O(n) and allocating on every access** — bind to a
    /// `let`, never read from a SwiftUI `body`.
    public var flattenedPoints: [TrackPoint] { segments.flatMap(\.points) }

    public func start(at date: Date) {
        segments = [RideSegment(points: [])]
        stats = .zero
        startedAt = date
        isRecording = true
        smoother.reset()
        currentSpeedMetersPerSecond = 0
        lastPoint = nil
    }

    public func record(_ point: TrackPoint) {
        guard isRecording, !segments.isEmpty else { return }
        segments[segments.count - 1].points.append(point)
        stats = RideStatsCalculator.stats(segments: segments)
        // Doppler speed when present, else position-delta from the previous fix; fed to
        // the smoother at the GPS timestamp (NOT wall-clock) so sim/GPX replay is
        // deterministic.
        let instant = InstantaneousSpeed.between(previous: lastPoint, current: point)
        currentSpeedMetersPerSecond = smoother.add(instant, at: point.timestamp)
        lastPoint = point
    }

    @discardableResult
    public func end(at date: Date, destinationName: String? = nil) -> Ride {
        isRecording = false
        // Drop trailing empty segments so "no points" has one encoding — zero segments —
        // matching `Ride(track: [])` and the persisted round trip. INTERIOR empties are
        // legal and must survive (spec D6); only the tail goes.
        var closed = segments
        while let last = closed.last, last.points.isEmpty { closed.removeLast() }
        return Ride(kind: kind, startedAt: startedAt ?? date, endedAt: date,
                    segments: closed, stats: stats, destinationName: destinationName,
                    routeId: nil, destinationPlaceId: nil)
    }
```

The `!segments.isEmpty` guard makes the array access provably safe rather than relying on
`isRecording` and `segments` agreeing; it is not a semantic change to `isRecording`.

(A reviewer confirmed `segments[i].points.append` is not an O(n) copy: `@Observable`
synthesizes a `_modify` accessor and `Array.subscript` has one, so the append happens in
place on a uniquely-referenced buffer — same cost as the old `track.append`.)

- [ ] **Step 4: Segment the coordinator**

`RideSessionCoordinator.swift:18`:

```swift
    public var segments: [RideSegment] { recorder.segments }
```

**Do not add a `flattenedPoints` passthrough here.** No production code needs one — the only
consumer of `coordinator.track` was the HUD map, which now takes segments — and a public
O(n)-allocating property with no caller is exactly the kind of inviting hazard the review
gate flagged. Add it in a later pass if a real caller appears. **[gate]**

Then run `swift build --build-tests` and fix any consumer the compiler names. Confirm
`grep -rn "\.track\b" AuraCore/Sources` returns nothing.

- [ ] **Step 5: Run the package suite**

Run: `cd AuraCore && swift test 2>&1 | tail -5`
Expected: all pass. `GoldenRidePlaybackTests` was already migrated in Task 2 Step 7 — it
needs no further change here.

- [ ] **Step 6: Make the live map draw per segment**

`Aura/Sources/Ride/RideMapView.swift` — replace `:11` (`let track:`), the `trackCoordinates`
computed property at `:35-38`, and the whole `routeRibbon` at `:103-133`:

```swift
    /// The recorded ride, split at pauses. One polyline per segment, so the map never
    /// strokes the chord across a stop.
    let segments: [RideSegment]
```

```swift
    private var ribbonPieces: [TrackRibbon.Piece] {
        // Solo rides (no peers) draw one bright ribbon; group rides dim what's already
        // ridden at the rider's own progress.
        TrackRibbon.pieces(segments: segments, splitAtMeters: peers.isEmpty ? nil : selfProgress)
    }

    @MapContentBuilder
    private var routeRibbon: some MapContent {
        // Keep the emptiness guard: an empty group still creates a Mapbox annotation manager
        // (a style source + layer) per map mount, where today there was none.
        if !ribbonPieces.isEmpty {
            PolylineAnnotationGroup(Array(ribbonPieces.enumerated()), id: \.offset) { item in
                PolylineAnnotation(lineCoordinates: item.element.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .lineColor(StyleColor(item.element.isBehind || !detourRoute.isEmpty
                    ? UIColor(AuraTheme.routeLine.opacity(0.25))
                    : AuraTheme.routeUIColor))
                .lineWidth(6)
            }
        }
    }
```

Two notes for the implementer:
- The **data-driven** `PolylineAnnotationGroup(_:id:content:)` init is required. The trailing-
  closure init takes an `@ArrayBuilder`, which has no `buildArray`, so a `for` loop there is
  `error: closure containing control flow statement cannot be used with result builder`. Keying
  by `\.offset` matches what the builder init already does internally, so annotation identity
  is unchanged from today. **[gate]**
- The colour expression reproduces all three of today's cases (behind → dimmed; anything while
  a detour is active → dimmed; otherwise bright). `?:` binds looser than `||`, so it parses as
  intended.

Leave `detourPolyline`, `gemAnnotations`, `PeerAnnotations` and every map modifier untouched.

`Aura/Sources/Ride/RideHUDView.swift:68` → `RideMapView(segments: coordinator.segments,`.
`Aura/Sources/Ride/RideMapView.swift:170` (the `#Preview`) → wrap its `track` local:
`RideMapView(segments: [RideSegment(points: track)], peers: peers, …)`.
Then grep for any other `RideMapView(` call site and update it the same way.

- [ ] **Step 7: Build the app target**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an
iPhone simulator.
Expected: build succeeds.

- [ ] **Step 8: Lint and commit**

```bash
cd AuraCore && swift test 2>&1 | tail -5
swiftlint --strict --quiet
git add -A
git commit -m "feat(roh-98): segment RideRecorder, RideSessionCoordinator and the live HUD ribbon"
```

---

### Task 5: `GPXParser` honors `<trkseg>`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Playback/GPXTrack.swift`
- Modify: `AuraCore/Sources/AuraCore/Playback/GPXParser.swift`
- Create: `AuraCore/Tests/AuraCoreTests/GPXParserSegmentTests.swift`

**Interfaces:**
- Consumes: `RideSegment` (Task 1).
- Produces: `GPXTrack.segments: [RideSegment]`, `GPXTrack.points: [TrackPoint]` (flattened,
  read-only), `GPXTrack.init(segments:)`, `GPXTrack.init(points:)`.

- [ ] **Step 1: Write the failing tests**

`AuraCore/Tests/AuraCoreTests/GPXParserSegmentTests.swift`:

```swift
import XCTest
@testable import AuraCore

/// `<trkseg>` handling. `GPXTrack.points` stays a flattened accessor so every existing
/// parser assertion, `GPXLocationPlayer`, `SimulatedLocationProvider` and
/// `GoldenRideFixture` are unaffected (spec D10).
final class GPXParserSegmentTests: XCTestCase {
    private func gpx(_ body: String) -> String {
        "<?xml version=\"1.0\"?>\n<gpx version=\"1.1\"><trk>\(body)</trk></gpx>"
    }

    private func trkpt(_ lat: Double, _ time: String) -> String {
        "<trkpt lat=\"\(lat)\" lon=\"-80.0\"><ele>250.0</ele><time>\(time)</time></trkpt>"
    }

    func test_twoTrksegs_yieldTwoSegments() throws {
        let track = try GPXParser.parse(gpx("""
        <trkseg>\(trkpt(40.44, "2026-06-22T14:00:00Z"))\(trkpt(40.45, "2026-06-22T14:00:20Z"))</trkseg>
        <trkseg>\(trkpt(40.54, "2026-06-22T14:15:00Z"))\(trkpt(40.55, "2026-06-22T14:15:20Z"))</trkseg>
        """))
        XCTAssertEqual(track.segments.count, 2)
        XCTAssertEqual(track.segments[0].points.count, 2)
        XCTAssertEqual(track.segments[1].points.count, 2)
    }

    func test_points_flattensInDocumentOrder() throws {
        let track = try GPXParser.parse(gpx("""
        <trkseg>\(trkpt(40.44, "2026-06-22T14:00:00Z"))</trkseg>
        <trkseg>\(trkpt(40.54, "2026-06-22T14:15:00Z"))</trkseg>
        """))
        XCTAssertEqual(track.points.count, 2)
        XCTAssertEqual(track.points[0].coordinate.latitude, 40.44, accuracy: 0.0001)
        XCTAssertEqual(track.points[1].coordinate.latitude, 40.54, accuracy: 0.0001)
    }

    func test_singleTrkseg_isOneSegment() throws {
        let track = try GPXParser.parse(gpx(
            "<trkseg>\(trkpt(40.44, "2026-06-22T14:00:00Z"))\(trkpt(40.45, "2026-06-22T14:00:20Z"))</trkseg>"))
        XCTAssertEqual(track.segments.count, 1)
        XCTAssertEqual(track.segments[0].points.count, 2)
    }

    /// A `<trkseg>` whose points were all skipped as incomplete carries no information, so
    /// it is dropped rather than emitted as an empty segment that consumers must tolerate.
    func test_trksegWithNoValidPoints_isDropped() throws {
        let track = try GPXParser.parse(gpx("""
        <trkseg></trkseg>
        <trkseg><trkpt lat="40.44" lon="-80.0"></trkpt></trkseg>
        <trkseg>\(trkpt(40.54, "2026-06-22T14:15:00Z"))</trkseg>
        """))
        XCTAssertEqual(track.segments.count, 1)
        XCTAssertEqual(track.segments[0].points.count, 1)
    }

    func test_emptyGPX_hasNoSegmentsAndNoPoints() throws {
        let track = try GPXParser.parse("<?xml version=\"1.0\"?><gpx></gpx>")
        XCTAssertTrue(track.segments.isEmpty)
        XCTAssertTrue(track.points.isEmpty)
    }

    /// Defensive: a `<trkpt>` outside any `<trkseg>` is malformed GPX. It must land
    /// somewhere rather than crash or vanish silently.
    func test_trackpointOutsideTrkseg_isKept() throws {
        let track = try GPXParser.parse(gpx(trkpt(40.44, "2026-06-22T14:00:00Z")))
        XCTAssertEqual(track.points.count, 1)
        XCTAssertEqual(track.segments.count, 1)
    }
}
```

- [ ] **Step 2: Run and confirm they fail**

Run: `cd AuraCore && swift test --filter GPXParserSegmentTests`
Expected: FAIL — `GPXTrack` has no `segments`.

- [ ] **Step 3: Segment `GPXTrack`**

`AuraCore/Sources/AuraCore/Playback/GPXTrack.swift`:

```swift
public struct GPXTrack: Equatable, Sendable {
    /// One entry per `<trkseg>` that produced at least one usable point.
    public var segments: [RideSegment]

    /// Every point in document order. Retained as a flattened accessor because replay
    /// (`GPXLocationPlayer`, `SimulatedLocationProvider`) genuinely wants one stream of
    /// fixes — the pause gap is a gap in *time*, which the schedule already honors.
    public var points: [TrackPoint] { segments.flatMap(\.points) }

    public init(segments: [RideSegment]) { self.segments = segments }

    /// Single-segment convenience for hand-built tracks. An empty `points` yields zero
    /// segments, matching what the parser returns for a document with no usable trackpoints
    /// — `GPXTrack` is `Equatable`, so the two must not disagree.
    public init(points: [TrackPoint]) {
        self.segments = points.isEmpty ? [] : [RideSegment(points: points)]
    }
}
```

- [ ] **Step 4: Teach the parser about `<trkseg>`**

In `GPXParser.Delegate`, replace `var points: [TrackPoint] = []`:

```swift
        /// Completed segments, plus the one currently open. A `<trkseg>` opens a segment;
        /// a `<trkpt>` outside one opens a defensive segment rather than being dropped.
        var segments: [[TrackPoint]] = []
        private var current: [TrackPoint]?
```

`didStartElement`:

```swift
            buffer = ""
            if el == "trkseg" {
                closeCurrentSegment()
                current = []
            }
            if el == "trkpt" {
                if current == nil { current = [] }   // malformed: trkpt outside a trkseg
                // nil when the attribute is missing or non-numeric; an explicit
                // "0" still parses to 0.0, so legitimate (0,0) points survive.
                lat = Double(attrs["lat"] ?? "")
                lon = Double(attrs["lon"] ?? "")
                ele = nil; time = nil
            }
```

`didEndElement` — the `trkpt` case appends into `current`, and a `trkseg` case closes it:

```swift
            case "trkpt":
                // …existing comment and guard, unchanged…
                guard let lat, let lon, let time else { break }
                current?.append(TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                                           elevation: ele, timestamp: time))
            case "trkseg":
                closeCurrentSegment()
```

plus the helper and the document end:

```swift
        /// Drops segments that produced no usable point: an empty `<trkseg>` carries no
        /// information, and emitting it would make `segments.count` depend on GPX authoring
        /// noise rather than on real pauses.
        ///
        /// Consequence, stated so a later pass does not trip over it: an EMPTY segment can
        /// never be produced through GPX, so `PausedGoldenRideFixture` cannot exercise the
        /// pause-before-first-fix or pause→resume→pause states that spec D6 makes legal.
        /// Pass 2 owns synthesizing those at the recorder; the per-segment `count >= 2`
        /// guard is unit-tested directly in `RideStatsSegmentTests`.
        private func closeCurrentSegment() {
            if let current, !current.isEmpty { segments.append(current) }
            current = nil
        }

        func parserDidEndDocument(_ parser: XMLParser) { closeCurrentSegment() }
```

and `GPXParser.parse` returns:

```swift
        return GPXTrack(segments: delegate.segments.map { RideSegment(points: $0) })
```

- [ ] **Step 5: Run the parser suites**

Run: `cd AuraCore && swift test --filter "GPXParser"`
Expected: PASS — including every pre-existing assertion in `GPXParserTests` and
`GPXParserEdgeTests`, unmodified. (`golden-ride.gpx` already contains exactly one `<trkseg>`,
so the existing fixture still yields one segment and 90 flattened points.)

- [ ] **Step 6: Full suite, lint, commit**

```bash
cd AuraCore && swift test 2>&1 | tail -5
swiftlint --strict --quiet
git diff --stat AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift   # must be empty
git add AuraCore/Sources/AuraCore/Playback/ AuraCore/Tests/AuraCoreTests/GPXParserSegmentTests.swift
git commit -m "feat(roh-98): parse GPX trkseg boundaries into ride segments"
```

---

### Task 6: The paused golden fixture

The only way to construct a multi-segment ride and look at it. Without it this pass's read
surfaces merge unverified.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Resources/golden-ride-paused.gpx`
- Create: `AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift`
- Create: `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift`
- Modify: `AuraCore/Package.swift:23-25`

**Interfaces:**
- Consumes: `GPXParser`, `GPXTrack.segments`, `RideStatsCalculator.stats(segments:)`,
  `ShareCardContent`, `TrackRibbon`, `WorkoutData`, `RideStore`.
- Produces: `PausedGoldenRideFixture` with `track()`, `ride()`, `expectedSegmentCount`,
  `expectedSegmentPointCounts`, `expectedPointCount`, and both segmented and flattened
  frozen literals.

- [ ] **Step 1: Generate the fixture file**

Run from the repo root (a throwaway generator — do **not** commit the script):

```bash
python3 - <<'PY' > AuraCore/Sources/AuraKit/Resources/golden-ride-paused.gpx
from datetime import datetime, timedelta, timezone

t0 = datetime(2026, 7, 22, 12, 0, 0, tzinfo=timezone.utc)
lines = ['<?xml version="1.0"?>', '<gpx version="1.1"><trk>']

def pt(lat, lon, ele, t):
    return ('  <trkpt lat="%.6f" lon="%.6f"><ele>%d</ele><time>%s</time></trkpt>'
            % (lat, lon, ele, t.strftime('%Y-%m-%dT%H:%M:%SZ')))

# Segment 1 — 30 fixes, 5 s apart, north, climbing +2 m per fix (240 → 298).
lines.append('<trkseg>')
for i in range(30):
    lines.append(pt(40.480000 + i * 0.000292, -79.760000, 240 + 2 * i, t0 + timedelta(seconds=5 * i)))
lines.append('</trkseg>')

# 600 s pause. The rider walks the bike ~507 m east and ~42 m up; none of it is recorded.
t1 = t0 + timedelta(seconds=145 + 600)
lines.append('<trkseg>')
for i in range(30):
    lines.append(pt(40.488468, -79.754000 + i * 0.000384, 340, t1 + timedelta(seconds=5 * i)))
lines.append('</trkseg>')

lines.append('</trk></gpx>')
print('\n'.join(lines))
PY
```

Verify: `grep -c trkpt AuraCore/Sources/AuraKit/Resources/golden-ride-paused.gpx` → 60,
`grep -c "<trkseg>" …` → 2.

The gap is deliberately large in all three dimensions — ~507 m, 600 s, +42 m — so a
regression that flattens the segments changes distance, moving time *and* elevation gain by
far more than any floating-point tolerance. The boundary speed (507 m / 600 s = 0.85 m/s)
clears the 0.5 m/s moving-time threshold, so the flattened figure really does absorb the whole
stop.

- [ ] **Step 2: Register the resource**

`AuraCore/Package.swift:23-25`:

```swift
        .target(name: "AuraKit", dependencies: ["AuraCore"],
                resources: [.process("Resources/gems.json"),
                            .process("Resources/golden-ride.gpx"),
                            .process("Resources/golden-ride-paused.gpx")]),
```

- [ ] **Step 3: Write the fixture with placeholder literals**

`AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift`:

```swift
import Foundation
import AuraCore

/// The paused counterpart to `GoldenRideFixture` (ROH-98): the same authored-GPX approach,
/// but two `<trkseg>`s separated by a 600 s stop during which the rider moved ~507 m east
/// and ~42 m up on foot.
///
/// It is a *second* fixture rather than a re-recording of the first on purpose. Leaving
/// `golden-ride.gpx`'s literals byte-identical is what proves segmentation changed nothing
/// for an unpaused ride; re-recording it would have destroyed that evidence and forced a
/// coupled edit across `GoldenRideFixture`, `GoldenRidePlaybackTests` and the non-derived
/// hero bands in `RideE2EUITests`.
///
/// Both the segmented and the flattened literals are frozen. The flattened ones are the
/// *wrong* answer, kept so a regression that silently flattens is caught by an equality
/// failure rather than by a fuzzy inequality. Refresh via
/// `GOLDEN_RECORD=1 swift test --filter recordPausedTruthLiterals` and paste — never
/// recompute at test time.
///
/// Note this fixture cannot contain an EMPTY segment: `GPXParser` drops `<trkseg>`s with no
/// usable points. The empty-segment cases spec D6 makes legal are covered directly in
/// `RideStatsSegmentTests` and `TrackRibbonTests`, and Pass 2 owns producing them live.
public enum PausedGoldenRideFixture {
    public static let expectedSegmentCount = 2
    public static let expectedSegmentPointCounts = [30, 30]
    public static let expectedPointCount = 60

    /// Segment-aware truth: the pause contributes no distance, no moving time, no climb.
    public static let expectedDistanceMeters = 0.0            // GOLDEN_RECORD
    public static let expectedElevationGainMeters = 0.0       // GOLDEN_RECORD
    public static let expectedMovingTimeSeconds = 0.0         // GOLDEN_RECORD

    /// What the same points produce if a consumer flattens them — the bug this pass exists
    /// to make unrepresentable.
    public static let flattenedDistanceMeters = 0.0           // GOLDEN_RECORD
    public static let flattenedElevationGainMeters = 0.0      // GOLDEN_RECORD
    public static let flattenedMovingTimeSeconds = 0.0        // GOLDEN_RECORD

    public static func track() throws -> GPXTrack {
        guard let url = Bundle.module.url(forResource: "golden-ride-paused",
                                          withExtension: "gpx") else {
            throw GoldenRideFixture.FixtureError.missingResource
        }
        return try GPXParser.parse(String(contentsOf: url, encoding: .utf8))
    }

    /// The fixture as a finished two-segment `Ride`, for the surfaces that take a ride.
    public static func ride() throws -> Ride {
        let segments = try track().segments
        let points = segments.flatMap(\.points)
        return Ride(kind: .freeRide,
                    startedAt: points.first?.timestamp ?? Date(timeIntervalSince1970: 0),
                    endedAt: points.last?.timestamp,
                    segments: segments,
                    stats: RideStatsCalculator.stats(segments: segments),
                    routeId: nil, destinationPlaceId: nil)
    }
}
```

- [ ] **Step 4: Write the tests, including the record helper**

`AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite(.swiftDataSerialized)
struct PausedGoldenRideFixtureTests {
    private func close(_ a: Double, _ b: Double, within tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func fixtureLoadsAsTwoSegments() throws {
        let track = try PausedGoldenRideFixture.track()
        #expect(track.segments.count == PausedGoldenRideFixture.expectedSegmentCount)
        #expect(track.segments.map(\.points.count) == PausedGoldenRideFixture.expectedSegmentPointCounts)
        #expect(track.points.count == PausedGoldenRideFixture.expectedPointCount)
        #expect(track.segments[0].points.first?.elevation == 240)
        #expect(track.segments[1].points.first?.elevation == 340)
    }

    @Test func pauseGapIsRealInSpaceAndTime() throws {
        let track = try PausedGoldenRideFixture.track()
        let lastOfFirst = try #require(track.segments[0].points.last)
        let firstOfSecond = try #require(track.segments[1].points.first)
        #expect(firstOfSecond.timestamp.timeIntervalSince(lastOfFirst.timestamp) == 600)
        #expect(Geo.distance(lastOfFirst.coordinate, firstOfSecond.coordinate) > 400)
    }

    @Test func segmentedStatsMatchTheFrozenLiterals() throws {
        let stats = RideStatsCalculator.stats(segments: try PausedGoldenRideFixture.track().segments)
        #expect(close(stats.distanceMeters, PausedGoldenRideFixture.expectedDistanceMeters))
        #expect(close(stats.elevationGainMeters, PausedGoldenRideFixture.expectedElevationGainMeters))
        #expect(close(stats.movingTimeSeconds, PausedGoldenRideFixture.expectedMovingTimeSeconds))
        #expect(stats.elevationGainMeters > 0)   // hard floor: silent-flat must fail
    }

    /// The regression the whole pass exists to prevent: flattening the segments inflates
    /// every headline number. Frozen on both sides so a drift in either is a hard failure.
    @Test func flatteningInflatesEveryNumber() throws {
        let track = try PausedGoldenRideFixture.track()
        let flat = RideStatsCalculator.stats(from: track.points)
        #expect(close(flat.distanceMeters, PausedGoldenRideFixture.flattenedDistanceMeters))
        #expect(close(flat.elevationGainMeters, PausedGoldenRideFixture.flattenedElevationGainMeters))
        #expect(close(flat.movingTimeSeconds, PausedGoldenRideFixture.flattenedMovingTimeSeconds))

        let segmented = RideStatsCalculator.stats(segments: track.segments)
        #expect(flat.distanceMeters > segmented.distanceMeters + 400)
        #expect(flat.movingTimeSeconds > segmented.movingTimeSeconds + 500)
        #expect(flat.elevationGainMeters > segmented.elevationGainMeters + 40)
    }

    /// The read surfaces migrated in this pass, exercised against a real two-segment ride.
    @Test func rideReadSurfacesStaySegmented() throws {
        let ride = try PausedGoldenRideFixture.ride()
        #expect(ride.segments.count == 2)
        #expect(ride.flattenedPoints.count == PausedGoldenRideFixture.expectedPointCount)

        // Share card: two runs, never one.
        #expect(ShareCardContent(ride: ride, units: .metric).routeSegments.count == 2)

        // Live/summary ribbon: no piece spans the gap.
        #expect(TrackRibbon.pieces(segments: ride.segments, splitAtMeters: nil).count == 2)

        // HealthKit route flattens deliberately (spec: pause events out of scope).
        #expect(WorkoutData(from: ride).route.count == PausedGoldenRideFixture.expectedPointCount)
    }

    /// Pins the KNOWN-WRONG behavior, so Pass 3 flipping it is visible as a test change
    /// rather than as silence. `RideMapper` writes only the flat `trackData` blob until
    /// schema V6 (ROH-100) adds `segmentsData`, so a multi-segment ride collapses to one
    /// segment across a save/load. Safe today only because no rider can create one — the
    /// spec gates any user-reachable pause control behind V6.
    @Test func multiSegmentRideFlattensThroughTheStoreUntilV6() throws {
        let ride = try PausedGoldenRideFixture.ride()
        let store = try RideStore.inMemory()
        try store.save(ride)
        let reloaded = try #require(try store.ride(id: ride.id))
        #expect(reloaded.segments.count == 1)
        #expect(reloaded.flattenedPoints.count == PausedGoldenRideFixture.expectedPointCount)
    }

    /// Re-record helper, mirroring `GoldenRideFixtureTests.recordTruthLiterals`. Run with
    /// GOLDEN_RECORD=1 and paste the printed literals. Skipped otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLDEN_RECORD"] != nil))
    func recordPausedTruthLiterals() throws {
        let track = try PausedGoldenRideFixture.track()
        let segmented = RideStatsCalculator.stats(segments: track.segments)
        let flat = RideStatsCalculator.stats(from: track.points)
        print("""
        GOLDEN_RECORD (paused) →
            expectedSegmentCount = \(track.segments.count)
            expectedSegmentPointCounts = \(track.segments.map(\.points.count))
            expectedPointCount = \(track.points.count)
            expectedDistanceMeters = \(segmented.distanceMeters)
            expectedElevationGainMeters = \(segmented.elevationGainMeters)
            expectedMovingTimeSeconds = \(segmented.movingTimeSeconds)
            flattenedDistanceMeters = \(flat.distanceMeters)
            flattenedElevationGainMeters = \(flat.elevationGainMeters)
            flattenedMovingTimeSeconds = \(flat.movingTimeSeconds)
        """)
    }
}
```

(The `.swiftDataSerialized` suite trait is required because
`multiSegmentRideFlattensThroughTheStoreUntilV6` opens a `RideStore` — see the project rule
recorded for ROH-65. Copy the trait usage from `GoldenRidePlaybackTests.swift:10-11`.)

- [ ] **Step 5: Run and confirm the literal tests fail**

Run: `cd AuraCore && swift test --filter PausedGoldenRideFixtureTests`
Expected: shape tests PASS; the two literal tests FAIL against the `0.0` placeholders.

- [ ] **Step 6: Record and paste the literals**

Run: `cd AuraCore && GOLDEN_RECORD=1 swift test --filter recordPausedTruthLiterals 2>&1 | grep -A 12 "GOLDEN_RECORD"`

Paste every printed value into `PausedGoldenRideFixture.swift`, replacing the `0.0`
placeholders and deleting the `// GOLDEN_RECORD` markers.

Sanity-check before accepting. These were computed independently against `Geo.distance`
(haversine, R = 6 371 000) — segmented **1883.35 m** / 290 s / 58 m, flattened
**2390.75 m** / 890 s / 100 m. Distances should match to within a metre or so; moving time
and gain should match exactly. If the printed numbers are far from these, the generator or
the calculator is wrong — investigate rather than pasting.

- [ ] **Step 7: Re-run**

Run: `cd AuraCore && swift test --filter PausedGoldenRideFixtureTests`
Expected: all PASS.

- [ ] **Step 8: Full verification**

```bash
cd AuraCore && swift test 2>&1 | tail -5
swiftlint --strict --quiet
```

Then confirm the non-negotiable, one last time, across the whole branch:

```bash
git diff main --stat -- AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift \
                        AuraCore/Tests/AuraCoreTests/__Snapshots__
```

Expected: **no output.** All five golden literals, the two start-coordinate literals and the
stats snapshot are untouched across every commit on this branch.

- [ ] **Step 9: Commit**

```bash
git add AuraCore/Sources/AuraKit/Resources/golden-ride-paused.gpx \
        AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift \
        AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift \
        AuraCore/Package.swift
git commit -m "test(roh-98): add the paused golden-ride fixture and its frozen literals"
```

---

## Decisions the review gate settled

Recorded so a later pass does not silently reverse them.

1. **Zero segments is canonical for "no points."** `Ride(track: [])` and `GPXTrack(points: [])`
   both yield `[]`, and `RideRecorder.end` drops trailing empty segments. The first draft used
   one empty segment and deferred the question; that gives `Ride` (an `Equatable` type) two
   encodings, which `RideMapper`'s save/load path silently converts between — and Pass 3's
   `.custom` V5→V6 backfill would have been the first place it cost anything.
2. **`stats(segments:)`, not an overload of `stats(from:)`.** An existing call site passes a
   bare `[]`, which two same-labelled array overloads make ambiguous.
3. **`TrackRibbon` spends the split budget per segment, not across flattened geometry.**
   `splitAtMeters` comes from segment-aware stats and excludes the pause chord; walking the
   flattened geometry includes it, which would freeze the ribbon for the chord's length after
   every resume. Single-segment behavior is unchanged either way.
4. **The behind/ahead pieces overlap by one point.** The code being replaced left the leg
   between `prefix(split)` and `suffix(from: split)` stroked by neither. That is a fix, not a
   preservation — do not "restore" the gap.
5. **`RideSegment` keeps the `{"points": […]}` wrapper** rather than encoding as
   `[[TrackPoint]]`, so Pass 2/3 can add per-segment metadata without a second migration. Any
   field added after V6 ships must be Optional or defaulted.
6. **`Aura/UITests/RideE2EUITests.swift` is not touched.** Its "shared by both golden rides"
   comment is accurate — both E2Es replay `golden-ride.gpx`.
