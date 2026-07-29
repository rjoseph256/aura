# ROH-105 dead peer/split deletion — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the peer-rendering and route-splitting code that `RideMapView` and `TrackRibbon` carry but never execute, without changing anything a rider sees.

**Architecture:** App target first, package second, so **every commit builds**. Task 1 removes the peer path from `RideMapView` while still calling today's `TrackRibbon` API. Task 2 then removes that API and updates its single remaining call site. Task 3 isolates the one line on this branch that can actually regress a rider. Task 4 rebuilds the peer preview on `PeerAnnotations` and corrects the doc comments the deletion falsified.

**Tech Stack:** Swift 6 language mode, SwiftUI, MapboxMaps v11 (11.26.0), Swift Testing + XCTest, SwiftLint (`--strict`), XcodeGen (`Aura/project.yml`).

Spec: [`docs/superpowers/specs/2026-07-27-roh105-dead-peer-split-deletion-design.md`](../specs/2026-07-27-roh105-dead-peer-split-deletion-design.md) (revision 2, post-gate).

Revision 2 of this plan, after a two-reviewer adversarial gate. Revision 1 had a test gate computed across two unrelated scoreboards, a commit order that left the app target unbuildable, a verification grep that would have flagged live production code, a preview that renders nothing, and an instruction that contradicted itself. Each fix is noted at the step that carries it.

## Global Constraints

- **No rider-visible behavior may change.** Every deletion is of code that cannot execute in a shipped build. Any diff hunk that alters what renders is out of scope and must be raised, not written. The single exception is Task 3, which is isolated for exactly that reason.
- **Every commit must build both the package and the app target.** Task 1 deliberately keeps calling `TrackRibbon.pieces(segments:splitAtMeters:)` so that it does. Do not "optimize" by pulling Task 2's API change forward.
- **`swift test` prints two independent totals; read both.** Swift Testing reports `Test run with N tests in M suites`, XCTest reports `Executed N tests`. `TrackRibbonTests` is `XCTestCase`; `RouteSplitTests` is Swift Testing. Measured baseline: **694 tests in 142 suites (Swift Testing)** and **219 (XCTest)**. Expected after Task 2: **689 in 141 suites** and **215**. Task 3 adds one XCTest, taking it to **216**.
- **`--no-parallel` is mandatory** for `swift test`. Several suites build SwiftData `ModelContainer`s and abort intermittently under Swift Testing's default parallel execution.
- **Remove parameters, never default them.** `splitAtMeters: Double? = nil` would keep all call sites compiling and silently skip the call-site audit that is the point of this change. It is also a public default argument across a module boundary, the family ROH-110 was burned by.
- **`.onCameraChanged` must precede `.ignoresSafeArea()`.** Misordering is a compile error (`onCameraChanged` is declared once, at `Map+Events.swift:71`, on `public extension Map`, returning `Self`), not a silent no-op.
- **Do not reorder `routeRibbon` / `detourPolyline` / `gemAnnotations`** inside the `Map` content builder.
- **`swiftlint lint --strict` must pass on the whole repo** (`scripts/lint.sh`). Lint before pushing.
- **Edit by symbol, not by line number.** Every line number in this plan refers to the **original, pre-change file**. Steps within a task shift them.
- `PeerAnnotations`, `PeerAnnotationDriver`, `ClusterDeclutter`, `GroupMapDots` and `NavigateHUDView` keep their implementations.

---

### Task 1: RideMapView loses the peer path

App target only. `TrackRibbon`'s API is untouched, so this commit builds against today's `AuraCore`.

*Revision 2 moved this ahead of the package change.* Revision 1 deleted the API first and committed, leaving `RideMapView:40` and `:115` referencing removed members. Neither `swift test` (package only) nor SwiftLint (does not compile) nor CI (`.github/workflows/ci.yml` triggers on `pull_request` and `push: main`, so it builds PR heads, never intermediate commits) would have caught it, and the two commits could not be reverted independently.

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift`

**Interfaces:**
- Consumes: `TrackRibbon.pieces(segments:splitAtMeters:)` and `TrackRibbon.Piece` **as they exist today**, unchanged.
- Produces: `RideMapView` with properties `segments`, `gems`, `seenGemIDs`, `onSelectGem`, `detourRoute`, `cameraBox`, `viewport`. `RideHUDView.swift:68-74` already passes exactly this set and **must not be edited**. If this task requires touching `RideHUDView`, stop and report.

- [ ] **Step 1: Confirm the baseline**

```bash
cd AuraCore && swift test --no-parallel 2>&1 | grep -E "Test run with|Executed [0-9]+ tests" | sort -u
```
Expected: `Test run with 694 tests in 142 suites passed` and `Executed 219 tests`. If either differs, stop and report.

- [ ] **Step 2: Replace the declarations and body**

In `Aura/Sources/Ride/RideMapView.swift`, replace everything from the top of the file through the closing brace of `var body` (originally lines 1-75) with:

```swift
import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Mapbox map that follows the rider and draws the live recorded track, in the user's chosen
/// style. Explore-HUD only, and solo by construction: group rides run through
/// `NavigateHUDView`, which strokes the *planned route* and owns its own peer dots.
struct RideMapView: View {
    /// The recorded ride, split at pauses. One polyline per segment, so the map never
    /// strokes the chord across a stop.
    let segments: [RideSegment]
    var gems: [Gem] = []
    var seenGemIDs: Set<String> = []
    var onSelectGem: (Gem) -> Void = { _ in }
    /// The active detour route geometry, if any. When non-empty, the recorded track dims
    /// (see `routeRibbon`) so the bright detour polyline reads as the thing to follow.
    var detourRoute: [Coordinate] = []
    /// Mirrors the live camera for the +/- zoom pill (ROH-57); nil in previews. Written every
    /// frame by `.onCameraChanged`, read only at tap time (see `MapZoomCameraBox`).
    var cameraBox: MapZoomCameraBox?

    @Environment(SettingsStore.self) private var settings
    @Binding var viewport: Viewport

    private var ribbonPieces: [TrackRibbon.Piece] {
        TrackRibbon.pieces(segments: segments, splitAtMeters: nil)
    }

    private var detourRouteCoordinates: [CLLocationCoordinate2D] {
        detourRoute.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            routeRibbon
            detourPolyline
            gemAnnotations
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        // Mirror the live camera into the zoom box. Must precede `.ignoresSafeArea()`, which
        // type-erases the view: `onCameraChanged` is declared on `Map` and returns `Self`, so
        // ordering it after `.ignoresSafeArea()` fails to compile.
        .onCameraChanged { ctx in
            guard let cameraBox else { return }
            cameraBox.zoom = ctx.cameraState.zoom
            cameraBox.center = ctx.cameraState.center
            cameraBox.bearing = ctx.cameraState.bearing
            cameraBox.pitch = ctx.cameraState.pitch
        }
        .ignoresSafeArea()
    }
```

`splitAtMeters: nil` is deliberate and temporary: it is what the old `peers.isEmpty ? nil : selfProgress` expression always evaluated to. Task 2 removes it.

- [ ] **Step 3: Delete syncPeers() and project()**

Delete both methods outright (originally lines 77-88). `project` existed only to give the peer driver a screen-space projection and was the only reason the body was wrapped in `MapReader`. `NavigateHUDView.swift:355` has its own copy, which stays.

- [ ] **Step 4: Collapse the dim rule in routeRibbon**

Replace the `routeRibbon` property (originally lines 101-121) with:

```swift
    /// The recorded track. While a detour is active (`detourRoute` non-empty), it dims to a
    /// quarter opacity so the bright `detourPolyline` reads as the thing to follow.
    @MapContentBuilder
    private var routeRibbon: some MapContent {
        // Keep the emptiness guard: an empty group still creates a Mapbox annotation manager
        // (a style source + layer) per map mount, where today there was none. Hit on every
        // ride start, since recording begins in a `.task` that runs after the first body pass.
        let pieces = ribbonPieces
        if !pieces.isEmpty {
            PolylineAnnotationGroup(Array(pieces.enumerated()), id: \.offset) { item in
                PolylineAnnotation(lineCoordinates: item.element.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .lineColor(StyleColor(detourRoute.isEmpty
                    ? AuraTheme.routeUIColor
                    : UIColor(AuraTheme.routeLine.opacity(0.25))))
                .lineWidth(6)
            }
        }
    }
```

Only the `item.element.isBehind ||` term is dropped, which was constant-false because `splitAtMeters` is nil. The branches are swapped so the common case reads first, so **check the polarity twice**: bright when `detourRoute.isEmpty`, dim when a detour is active. The `id: \.offset` key is unchanged here on purpose; Task 3 owns that change.

Leave `detourPolyline` and `gemAnnotations` exactly as they are.

- [ ] **Step 5: Strip the peers from the preview**

Replace the `#Preview` block (originally lines 137-160) with:

```swift
#Preview {
    @Previewable @State var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
    let track = stride(from: 0, through: 1200, by: 40).map { meters in
        TrackPoint(coordinate: Coordinate(latitude: 37.7700 + Double(meters) * 0.00003,
                                          longitude: -122.4210 + Double(meters) * 0.00002),
                  elevation: nil, timestamp: Date())
    }
    return RideMapView(segments: [RideSegment(points: track)], viewport: $viewport)
        .environment(SettingsStore())
}
```

*Revision 2 removed a hedge here* that told the implementer not to delete the old four-peer fixture until Task 4 landed it. That was unobeyable: Step 2 removes the properties the old preview passes, so keeping it fails to compile. This step is mandatory. Task 4 Step 2 carries a corrected fixture verbatim, so nothing needs recovering from git history.

- [ ] **Step 6: Build the app target**

The app target has no unit tests (`Aura/project.yml:120-121` declares `AuraUITests` as the only test target, `type: bundle.ui-testing`), so compilation is the check, and it is a real one: every deleted symbol is either still referenced or it is not.

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator, report pass/fail and errors only.

Expected: build succeeds. An unresolved `MapProxy`/`MapReader` symbol means Step 3 removed `project` but left a caller. `value of type 'some View' has no member 'onCameraChanged'` means Step 2's modifier order was not preserved.

- [ ] **Step 7: Lint and commit**

```bash
./scripts/lint.sh
git add Aura/Sources/Ride/RideMapView.swift
git commit -m "refactor(roh-105): delete RideMapView's dead peer path

The sole production caller (RideHUDView) never passed peers, so the driver, the
annotations, the projection helper, the MapReader that existed to feed it and the
permanently-paused TimelineView were all unreachable. Removing them unwraps two
containers from around the Map; the same chain already ships in RoutePreviewView
and HomeLiveMap.

Still calls TrackRibbon.pieces(segments:splitAtMeters:) with the nil the old
expression always produced, so this commit builds on its own. The next one
removes the parameter."
```

---

### Task 2: TrackRibbon loses splitting; RouteSplit is deleted

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift`
- Delete: `AuraCore/Sources/AuraCore/GroupRide/RouteSplit.swift`
- Delete: `AuraCore/Tests/AuraCoreTests/GroupRide/RouteSplitTests.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`
- Modify: `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift:61`
- Modify: `Aura/Sources/Ride/RideMapView.swift` (the one call site, `ribbonPieces`)
- Modify: `docs/ROADMAP.md:504`

**Interfaces:**
- Consumes: `RideMapView.ribbonPieces` as Task 1 left it.
- Produces: `TrackRibbon.pieces(segments: [RideSegment]) -> [TrackRibbon.Piece]`, where `Piece` is `public struct Piece: Equatable, Sendable` with exactly two stored properties, `public let coordinates: [Coordinate]` and `public let sourceIndex: Int`, and initializer `public init(coordinates: [Coordinate], sourceIndex: Int)`. Task 3 keys a Mapbox annotation group on `sourceIndex`.

- [ ] **Step 1: Rewrite the tests first, so the compiler drives the deletion**

This is the TDD cycle inverted for a removal: the tests move to the new API, fail to compile against the old one, and the implementation change is what makes them pass.

In `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`, keep `import XCTest`, `@testable import AuraCore`, the type doc, the `final class TrackRibbonTests: XCTestCase {` declaration and the `pt`/`seg` helpers exactly as they are. Delete four split tests: `test_split_marksRiddenPortionBehind`, `test_split_isMeasuredPerSegment_notAcrossThePauseChord`, `test_splitBeyondTotalLength_isAllBehind`, `test_splitAtZero_isAllAhead`.

Rewrite the three survivors as:

```swift
    func test_onePiecePerSegment() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([(40.0, -80.0), (40.001, -80.0)]),
                       seg([(41.0, -80.0), (41.001, -80.0)])])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1])
        // The chord: no piece may contain a point from two different segments.
        XCTAssertFalse(pieces.contains {
            $0.coordinates.contains(Coordinate(latitude: 40.001, longitude: -80.0))
            && $0.coordinates.contains(Coordinate(latitude: 41.0, longitude: -80.0))
        })
    }

    /// Runs shorter than two points stroke nothing, but must not shift the `sourceIndex` of
    /// the runs after them. Reachable today: start a ride, pause before the first GPS fix,
    /// resume — that leaves an interior segment with no points, so output position and input
    /// position genuinely diverge.
    func test_segmentsWithFewerThanTwoPoints_areDroppedWithoutShiftingIndices() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([]), seg([(40.0, -80.0)]), seg([(41.0, -80.0), (41.001, -80.0)])])
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].coordinates.count, 2)
        XCTAssertEqual(pieces[0].sourceIndex, 2)
    }

    /// Reached on every Explore ride: `RideHUDView` starts recording in `.task`, which runs
    /// after the first body evaluation, so the first render of every mount asks for pieces
    /// from an empty segment list. `RideMapView`'s `if !pieces.isEmpty` guard depends on this.
    func test_noSegments_isEmpty() {
        XCTAssertTrue(TrackRibbon.pieces(segments: []).isEmpty)
    }
```

- [ ] **Step 2: Update the other test-target caller**

In `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift:61`, change:

```swift
        #expect(TrackRibbon.pieces(segments: ride.segments, splitAtMeters: nil).count == 2)
```

to:

```swift
        #expect(TrackRibbon.pieces(segments: ride.segments).count == 2)
```

Leave the surrounding comment and every other assertion in that test untouched.

- [ ] **Step 3: Run the tests to verify they fail to compile**

```bash
cd AuraCore && swift test --no-parallel 2>&1 | grep -E "error:" | head -5
```
Expected: FAIL, with `extra argument 'splitAtMeters' in call` or `missing argument` errors. This confirms the tests are bound to the new API before the implementation moves.

- [ ] **Step 4: Rewrite TrackRibbon**

Replace the whole of `AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift` with:

```swift
import Foundation

/// Turns a ride's segments into the polylines a map should stroke, so no renderer ever has
/// to decide for itself whether two adjacent points belong in the same line. A pause gap is
/// unrepresentable in the output: pieces never span segments.
///
/// Two rules are worth knowing before extending this, both learned the expensive way.
///
/// **Progress along a segmented track must be spent per segment.** It must never be resolved
/// by walking the flattened geometry: that walk includes the straight-line chord across each
/// pause, while segment-aware stats exclude it. Mixing the two measures progress against a
/// longer track than the rider rode, which freezes anything keyed to it for the length of the
/// chord after every resume. A behind/ahead ribbon split that made this mistake shipped dead
/// and was removed in ROH-105; the trap outlived the feature.
///
/// **`sourceIndex` is stable only because the recorder appends solely to the last segment**
/// (`RideRecorder.record`, and `resume(at:)` which appends a fresh one). Any future path that
/// backfills an interior segment — checkpoint restore, GPX import, a replay harness — renumbers
/// these indices, which churns Mapbox annotation identity in `RideMapView`.
public enum TrackRibbon {
    public struct Piece: Equatable, Sendable {
        public let coordinates: [Coordinate]
        /// Index into the original `segments` array. Preserved because runs too short to
        /// stroke are dropped, so output position is not input position.
        ///
        /// **`RideMapView` keys its Mapbox annotation group on this, so it must stay unique
        /// across the returned array.** Duplicate IDs collide silently in Mapbox: both
        /// annotations receive the same feature id, and tap resolution finds only the first.
        /// A future rule that emits more than one piece per segment (Pass 4 / ROH-101 renders
        /// the current segment differently while paused) must introduce a compound key rather
        /// than reusing this one. `TrackRibbonTests.test_sourceIndicesAreUnique` guards it.
        public let sourceIndex: Int

        public init(coordinates: [Coordinate], sourceIndex: Int) {
            self.coordinates = coordinates
            self.sourceIndex = sourceIndex
        }
    }

    /// - Returns: drawable pieces in ride order, one per segment. Runs of fewer than two
    ///   coordinates are dropped — a single point strokes nothing — without shifting the
    ///   `sourceIndex` of the runs after them.
    public static func pieces(segments: [RideSegment]) -> [Piece] {
        segments.enumerated().compactMap { index, segment in
            let run = segment.points.map(\.coordinate)
            guard run.count > 1 else { return nil }   // strokes nothing
            return Piece(coordinates: run, sourceIndex: index)
        }
    }
}
```

- [ ] **Step 5: Update the single production call site**

In `Aura/Sources/Ride/RideMapView.swift`, change `ribbonPieces` from:

```swift
        TrackRibbon.pieces(segments: segments, splitAtMeters: nil)
```

to:

```swift
        TrackRibbon.pieces(segments: segments)
```

This is the call-site audit the Global Constraints require, and it is why the parameter is removed rather than defaulted.

- [ ] **Step 6: Delete RouteSplit and its tests**

```bash
git rm AuraCore/Sources/AuraCore/GroupRide/RouteSplit.swift \
       AuraCore/Tests/AuraCoreTests/GroupRide/RouteSplitTests.swift
```

`Aura/project.yml:7-8` declares `AuraCore` as a local path package and SwiftPM globs the directories, so no manifest edit is needed.

- [ ] **Step 7: Run the tests**

```bash
cd AuraCore && swift test --no-parallel 2>&1 | grep -E "Test run with|Executed [0-9]+ tests" | sort -u
```
Expected: `Test run with 689 tests in 141 suites passed` and `Executed 215 tests`.

*Revision 2 corrects these numbers.* Revision 1 asserted 685/141 by subtracting four XCTest deletions from the Swift Testing total. They are separate scoreboards: `RouteSplitTests` (Swift Testing, 5 tests, 1 suite) moves 694/142 to 689/141, and the four `TrackRibbonTests` deletions (XCTest) move 219 to 215.

- [ ] **Step 8: Build the app target**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator. Expected: succeeds. This is what proves the commit is green on both halves.

- [ ] **Step 9: Update the ROADMAP entry**

In `docs/ROADMAP.md:504`, change `GroupRosterViewData, RouteSplit); an` to `GroupRosterViewData); an`. This is a historical Wave 4 record: drop only the name of the helper that no longer exists, and do not rewrite the surrounding narrative.

- [ ] **Step 10: Lint and commit**

```bash
./scripts/lint.sh
git add -A
git commit -m "refactor(roh-105): drop TrackRibbon's unreachable split branch and RouteSplit

pieces(segments:splitAtMeters:) was only ever called with nil, so the budget
walk, the RouteSplit call, the overlap fix, length(of:) and Piece.isBehind were
all unreachable. RouteSplit had no other caller.

Keeps the three tests covering reachable behavior, including the empty-input
case hit on every ride start. Preserves the per-segment-progress trap and the
sourceIndex stability rule as doc comments, since both outlived the code that
taught them.

689 tests in 141 suites (Swift Testing) and 215 (XCTest), from 694/142 and 219."
```

---

### Task 3: Key the annotation group on sourceIndex

Isolated deliberately. Everything else on this branch is provably dead-code removal; this is the one line that touches live rendering, so it gets its own revertable commit.

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift` (`routeRibbon`)
- Modify: `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`

**Interfaces:**
- Consumes: `TrackRibbon.Piece.sourceIndex` from Task 2.
- Produces: no API change.

- [ ] **Step 1: Write the failing uniqueness test**

Keying Mapbox annotations on `sourceIndex` makes uniqueness load-bearing, and nothing enforces it. Add to `TrackRibbonTests`:

```swift
    /// `RideMapView` keys its `PolylineAnnotationGroup` on `sourceIndex`. Mapbox stores the
    /// element id in a persistent map and assigns both colliding elements the same feature id,
    /// silently — tap resolution then finds only the first. Uniqueness holds structurally today
    /// (one piece per segment); this test is what makes a future change to that visible.
    func test_sourceIndicesAreUnique() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([(40.0, -80.0), (40.001, -80.0)]),
                       seg([]),
                       seg([(41.0, -80.0), (41.001, -80.0), (41.002, -80.0)])])
        XCTAssertEqual(Set(pieces.map(\.sourceIndex)).count, pieces.count)
    }
```

- [ ] **Step 2: Run it**

```bash
cd AuraCore && swift test --no-parallel --filter TrackRibbonTests 2>&1 | tail -5
```
Expected: PASS. This test documents an invariant that already holds rather than driving new behavior, which is why it is written before the change that starts depending on it.

- [ ] **Step 3: Switch the annotation key**

In `Aura/Sources/Ride/RideMapView.swift`, in `routeRibbon`, change:

```swift
            PolylineAnnotationGroup(Array(pieces.enumerated()), id: \.offset) { item in
                PolylineAnnotation(lineCoordinates: item.element.coordinates.map {
```

to:

```swift
            PolylineAnnotationGroup(pieces, id: \.sourceIndex) { piece in
                PolylineAnnotation(lineCoordinates: piece.coordinates.map {
```

The initializer is `public init(_ data: Data, id: KeyPath<Data.Element, ID>, content: ...)` on `PolylineAnnotationGroup<Data: RandomAccessCollection, ID: Hashable>`. `[TrackRibbon.Piece]` satisfies `RandomAccessCollection` and `Int` satisfies `Hashable`; the element needs neither `Identifiable` nor `Hashable`.

Why: keying by output position is stable today only by accident of a `RideRecorder` invariant three files away. Interior short segments are already reachable (start a ride, pause before the first fix, resume), so `offset != sourceIndex` is a live state, and `sourceIndex` is the identity the ribbon actually means.

- [ ] **Step 4: Build and commit**

Delegate the build to the `apple-platform-build-tools:builder` agent. Then:

```bash
./scripts/lint.sh
git add Aura/Sources/Ride/RideMapView.swift AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift
git commit -m "fix(roh-105): key the ribbon's annotation group on sourceIndex

Output position and input position diverge whenever a segment is too short to
stroke, which is reachable (pause before the first GPS fix, then resume). The
enumerated offset was stable only by accident of RideRecorder appending solely
to the last segment. Adds the uniqueness test that keying on sourceIndex now
depends on."
```

---

### Task 4: Rebuild the peer preview on PeerAnnotations; fix the falsified doc comments

The fixture that lived on `RideMapView` **rendered nothing**, and had since it was written. `RidePeer.lastUpdate` defaults to nil (`PeerStatus.swift:21-23`) and the fixture never set it, so `PeerInterpolators.commit` skipped every peer at `PeerInterpolator.swift:116`, `byID` stayed empty, `position(_:at:)` returned nil for everyone, and `frame` produced `PeerFrame(dots: [])`. Verified by execution during review: `visiblePeers` = 3, dots rendered = 0.

So this task does not relocate a working fixture. It writes the one that was intended, on the type that owns the rendering.

**Files:**
- Modify: `Aura/Sources/GroupRide/PeerAnnotations.swift`
- Modify: `AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

**Interfaces:**
- Consumes: `PeerAnnotationDriver.updateSet(peers:selfUserID:nameMap:reduceMotion:now:)` (`PeerAnnotations.swift:67-68`) and `frame(now:project:)` (`:93`), both unchanged.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Correct the "shared by both hosts" claim**

In `Aura/Sources/GroupRide/PeerAnnotations.swift`, the type doc ends line 7 with `Shared by both hosts.` Replace that sentence:

```swift
/// `frame` by `PeerAnnotationDriver`, so this only rebuilds ≤7 annotations. `NavigateHUDView`
/// is the only host; `RideMapView` carried a second, dead copy until ROH-105.
```

- [ ] **Step 2: Add a preview that actually renders**

Append to the end of `Aura/Sources/GroupRide/PeerAnnotations.swift`:

```swift
/// The peer-dot states that can actually reach the map, over a real one. Rebuilt in ROH-105:
/// the fixture this replaces (on `RideMapView`) set no `lastUpdate`, so the interpolator
/// skipped every peer and it rendered an empty map from the day it was written.
///
/// Covers riding, stopped and dropped styling, the heading pointer, the liveness pulse,
/// monogram widening (Mara / Marco collide on "M"), and declutter (they also sit ~14pt apart,
/// inside the 26pt enter radius). The `.awaiting` dot is deliberately absent: an awaiting peer
/// has no coordinate by definition, `GroupMapDots.visiblePeers` filters on exactly that, so it
/// can never appear here. Its styling is covered by `GroupRosterSheet`'s previews.
#Preview {
    @Previewable @State var viewport: Viewport = .camera(
        center: CLLocationCoordinate2D(latitude: 37.7746, longitude: -122.4186), zoom: 15)
    let now = Date()
    let driver = PeerAnnotationDriver()
    let peers: [RidePeer] = [
        RidePeer(userID: UUID(), displayName: "Mara",
                 coordinate: Coordinate(latitude: 37.7752, longitude: -122.4192),
                 progressMeters: 900, motionState: .moving,
                 lastUpdate: now, status: .riding),
        RidePeer(userID: UUID(), displayName: "Marco",
                 coordinate: Coordinate(latitude: 37.7751, longitude: -122.4191),
                 progressMeters: 880, motionState: .moving,
                 lastUpdate: now, status: .riding),
        RidePeer(userID: UUID(), displayName: "Devon",
                 coordinate: Coordinate(latitude: 37.7742, longitude: -122.4182),
                 progressMeters: 450, motionState: .stopped,
                 lastUpdate: now, status: .stopped),
        // A dropped peer keeps its last known fix; what makes it dropped is the silence since.
        RidePeer(userID: UUID(), displayName: "Sam",
                 coordinate: Coordinate(latitude: 37.7732, longitude: -122.4172),
                 progressMeters: 200, motionState: .stopped,
                 lastUpdate: now.addingTimeInterval(-120), status: .dropped)
    ]
    driver.updateSet(peers: peers, selfUserID: nil, nameMap: [:],
                     reduceMotion: false, now: now)
    // A linear stand-in for Mapbox's projection: ~10 points per 0.0001°, enough for the
    // declutter radii to mean what they mean on screen. A preview has no live MapProxy, and
    // returning nil for any peer disables declutter entirely (`canDeclutter`, above).
    return Map(viewport: $viewport) {
        PeerAnnotations(frame: driver.frame(now: now, project: { c in
            ClusterDeclutter.Point2D(x: (c.longitude + 122.4200) * 100_000,
                                     y: (37.7760 - c.latitude) * 100_000)
        }))
    }
    .ignoresSafeArea()
}
```

Every peer carries a coordinate and a `lastUpdate`, which is what the old fixture missed. `PeerInterpolator.commit`'s first-fix branch (`lastRecordedAt == nil`) sets `from = to = fix` with `duration = 0`, so one `updateSet` plus an immediate `frame` resolves positions with no elapsed time needed.

- [ ] **Step 3: Verify the preview renders four dots**

A preview that silently renders nothing is worse than none, which is the defect being fixed, so confirm rather than assume. Open `PeerAnnotations.swift` in Xcode and resume the canvas.

Expected: four dots. Mara and Marco offset apart rather than stacked, labelled with widened monograms (not both "M"). Devon in the stopped treatment, Sam ghosted. If the canvas shows an empty map, stop and report rather than shipping the comment above it.

- [ ] **Step 4: Correct GroupMapDots' call-site count**

In `AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift`, lines 3-4 read:

```swift
/// Selects which peers get a dot on the group-ride map — the one home for that rule, since
/// both call sites (`NavigateHUDView` and `RideMapView`) are in the untestable app target.
```

That comment is the stated justification for this type having no view-level test, so the reasoning has to survive the correction, not just the count:

```swift
/// Selects which peers get a dot on the group-ride map — the one home for that rule, since its
/// only call site (`NavigateHUDView`) is in the untestable app target. `RideMapView` was a
/// second call site until ROH-105 removed its dead peer path.
```

- [ ] **Step 5: Point the group-explore aside at the spec**

`Aura/Sources/Ride/RideHUDView.swift:31-33` notes that `GemDiscoveryStore.isSuppressed` exists "for a future group-explore surface". After this change there is no dormant peer path in the Explore HUD, so that reads as a capability that still exists. Replace those three lines with:

```swift
    // Free rides are solo by construction — group rides use NavigateHUDView +
    // GroupRideSession, never this HUD — so gem discovery is never suppressed here.
    // (GemDiscoveryStore.isSuppressed exists for a future group-explore surface. That surface
    // would be a rebuild, not a wiring-up: ROH-105 removed the last dormant peer path here.
    // See docs/superpowers/specs/2026-07-27-roh105-dead-peer-split-deletion-design.md.)
```

- [ ] **Step 6: Build, lint, commit**

Delegate the build to the `apple-platform-build-tools:builder` agent (previews compile into debug builds, so a malformed `#Preview` is a build failure).

```bash
./scripts/lint.sh
git add Aura/Sources/GroupRide/PeerAnnotations.swift \
        AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift \
        Aura/Sources/Ride/RideHUDView.swift
git commit -m "fix(roh-105): rebuild the peer preview so it renders, fix falsified doc comments

The fixture on RideMapView set no lastUpdate, so PeerInterpolators.commit
skipped every peer and it rendered an empty map from the day it was written.
Rebuilt on PeerAnnotations with lastUpdate, a colliding name pair so monogram
widening fires, a dropped peer that keeps its last fix, and a stub projection so
declutter runs at all. Drops the awaiting dot, which cannot reach a map.

GroupMapDots and PeerAnnotations both claimed two call sites; NavigateHUDView is
now the only one."
```

---

### Task 5: Full-gate verification and follow-ups

**Files:**
- No source changes expected. If this task produces a code edit, that edit belongs in whichever of Tasks 1-4 owns the file.

- [ ] **Step 1: Run the full package suite**

```bash
cd AuraCore && swift test --no-parallel 2>&1 | grep -E "Test run with|Executed [0-9]+ tests" | sort -u
```
Expected: `Test run with 689 tests in 141 suites passed` and `Executed 216 tests` (215 after Task 2, plus Task 3's uniqueness test).

- [ ] **Step 2: Run the repo-wide lint**

```bash
./scripts/lint.sh
```
Expected: no output, exit 0.

- [ ] **Step 3: Confirm no stale references survive**

*Revision 2 rewrote this step.* Revision 1 grepped for `selfProgress` repo-wide and expected zero hits. `selfProgress` is a live parameter in `PeerDistance.swift:8,10`, `GroupRosterViewData.swift:23,27,47` and `NavigateHUDView+GroupCrew.swift:22,29`, all shipping group-ride code this change does not touch. An implementer holding a completion gate and told "expected: zero hits" could have deleted the crew roster's distance labels to satisfy it.

```bash
grep -rn "splitAtMeters\|RouteSplit\|isBehind" --include="*.swift" Aura AuraCore
grep -rn "selfProgress" Aura/Sources/Ride/RideMapView.swift
grep -n "RouteSplit" docs/ROADMAP.md
```
Expected: zero hits from all three. Do **not** widen the last grep to `docs/`: `RouteSplit` legitimately survives in `docs/superpowers/plans/2026-06-30-group-rides-sp3-group-ride-ui.md`, `docs/superpowers/plans/2026-07-26-roh98-segmented-model.md` and `docs/superpowers/specs/2026-07-20-group-ride-peer-feel-design.md`, which are shipped historical records and must not be edited.

- [ ] **Step 4: Run the golden-ride E2E before opening the PR**

`Aura/UITests/RideE2EUITests.swift` drives a real Explore ride through `RideMapView` and is the only automated test that executes this view at all. Revision 1 left it to run in PR CI, three commits after the change.

```bash
./scripts/golden-ride.sh
```
Expected: pass. A failure here localizes to this branch instead of to a PR-wide CI run.

- [ ] **Step 5: Build and run the device pass**

Delegate the build to the `apple-platform-build-tools:builder` agent, then verify on the physical iPhone per the project's tunnel recipe. The risk lives in the surviving code's new shape, so check the states that carry it:

1. **First mount with zero segments.** Start an Explore ride; the `if !pieces.isEmpty` path is hit before the first GPS fix on every start.
2. **Pause, resume, watch the ribbon.** The ROH-101 hand-off state. Confirm the track draws with a gap across the pause and no chord, and that the empty segment appended by `resume(at:)` does not break rendering.
3. **The dim rule.** Task 1 Step 4 swapped the ternary's branches. Trigger a gem detour and confirm the **recorded track dims to a quarter opacity** while the detour line stays bright. This is the one rider-visible assertion this branch owes; a polarity inversion here is invisible to every other gate.
4. **Puck follow and recenter.** `Map(viewport: $viewport)` moved out of two wrappers. Ride ~200 m and confirm the camera still follows, then pan away and confirm the recenter control re-enables (`RideHUDView.swift:254` reads `viewport.followPuck != nil`).
5. **Full-bleed layout.** `.ignoresSafeArea()` moved from inside two wrappers to the view root. Confirm no inset band under the notch or home indicator.
6. **Gem pins and the puck still render**, having shared the content builder with the deleted `PeerAnnotations`.

The zoom pill is deliberately not on this list: the type checker guarantees the modifier is attached to a `Map`, and the identical chain already ships in `RoutePreviewView` and `HomeLiveMap`.

- [ ] **Step 6: File the two follow-up issues**

Create in Linear, team `Rohun`, project `Group Rides Tail`:

1. **"Group ride without a destination (group-explore surface)"**, priority Medium, label `Feature`. Body: hosting a crew ride requires picking a destination first. `GroupRideEntry.create` carries a `Route` and is created only from the route preview (`RoutePreviewView.swift:250`); `GroupNavigateContainer` is the sole host of a `GroupRideSession`. (`GroupRideEntry.join` carries a `JoinCode`, so a joiner picks nothing — the constraint is on the host.) So "let's go ride around for an hour" is unsupported. ROH-105 removed the last dormant scaffolding for the alternative, so this is now a rebuild rather than a wiring-up. Link the ROH-105 spec.
2. **"Measure the ribbon's per-frame coordinate copying on long rides"**, priority Low, label `Tech Debt`. Body: `TrackRibbon.pieces(segments:)` copies every coordinate of the ride and `routeRibbon` maps them all again into `CLLocationCoordinate2D` on each body evaluation of a live HUD. ROH-105 retired a phantom figure (ROH-98's 1.3M calls/sec, which described code that never ran) without measuring the real one. Relate to ROH-105 and ROH-98.

- [ ] **Step 7: Hand D5's obligations to the issues that will act on them**

*Revision 2 added this step.* Revision 1 recorded these as a comment on ROH-105, the issue being closed. Pass 4's implementer reads ROH-101.

Add a comment to **ROH-101** carrying the three obligations from spec D5: navigate's paused state needs a positive legibility requirement (a rider paused in a bar mount sees a turn card and route line identical to a live ride, and the pause spec calls the forgotten resume the failure that "corrupts a ride worst"); Pass 4 must reintroduce a pure discriminator in `TrackRibbon` rather than growing the ternary in `RideMapView`, which lives in the untestable app target; and navigate's paused state needs a budgeted device check.

Then update **ROH-103**'s scope: its assertion that "the route draws with a gap rather than a chord" is only assertable on Explore, since Navigate never strokes the recorded track.

- [ ] **Step 8: Open the PR and move ROH-105 to In Review**

```bash
git push -u origin HEAD
gh pr create --title "ROH-105: delete RideMapView's dead peer and split machinery" --body "$(cat <<'BODY'
Deletes the peer-rendering and route-splitting code that `RideMapView` and
`TrackRibbon` carried but never executed.

`RideMapView`'s only production caller never passed peers, which made the driver,
the annotations, the projection helper, the `MapReader` feeding it, the
permanently-paused `TimelineView` and `TrackRibbon`'s entire split branch
unreachable. `RouteSplit` had no other caller.

Spec (revision 2, after a three-reviewer adversarial gate):
`docs/superpowers/specs/2026-07-27-roh105-dead-peer-split-deletion-design.md`

Commits are ordered app-target-first so every one of them builds and can be
reverted independently. Two changes are not deletions and are isolated as their
own commits:

- the ribbon's annotation group now keys on `sourceIndex` rather than the
  enumerated offset, which diverges whenever a segment is too short to stroke
- the peer `#Preview` is rebuilt on `PeerAnnotations`. The fixture it replaces
  set no `lastUpdate`, so the interpolator skipped every peer and it rendered an
  empty map from the day it was written

Gates: 689 tests in 141 suites (Swift Testing) and 216 (XCTest), from 694/142
and 219; `swiftlint --strict` clean; app build; golden-ride E2E; device pass on
ride start, pause/resume ribbon, detour dimming, puck follow and full-bleed.

Closes ROH-105.
BODY
)"
```

Then move ROH-105 to **In Review** in Linear.

- [ ] **Step 9: Whole-branch adversarial review**

Before merging, dispatch a final review of the entire branch diff on the most capable model, per the project's standing pipeline. This is the gate that has repeatedly caught defects green tests and single-pass review missed on this codebase, including three production-dead criticals during Wave 4.

Give the reviewer the spec and the full diff, with a refuting mandate: find any rider-visible behavior change, any deleted symbol that was reachable, any surviving comment or doc the deletion made false, and specifically check the dim-rule polarity in `routeRibbon` and the annotation-key change for identity churn.
