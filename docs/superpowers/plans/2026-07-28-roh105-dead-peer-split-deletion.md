# ROH-105 dead peer/split deletion — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the peer-rendering and route-splitting code that `RideMapView` and `TrackRibbon` carry but never execute, without changing anything a rider sees.

**Architecture:** Three layers, deleted bottom-up so each task compiles on its own. `TrackRibbon` (pure AuraCore) loses its `splitAtMeters` parameter and the branch it guards, taking `RouteSplit` with it. `RideMapView` (app target) loses the four peer properties and every piece of machinery that existed only to serve them, which unwraps two view containers from around its `Map`. The peer `#Preview` fixture relocates to `PeerAnnotations` rather than dying with the view that hosted it.

**Tech Stack:** Swift 6 language mode, SwiftUI, MapboxMaps v11 (11.26.0), Swift Testing + XCTest, SwiftLint (`--strict`), XcodeGen (`Aura/project.yml`).

Spec: [`docs/superpowers/specs/2026-07-27-roh105-dead-peer-split-deletion-design.md`](../specs/2026-07-27-roh105-dead-peer-split-deletion-design.md) (revision 2, post-gate).

## Global Constraints

- **No rider-visible behavior may change.** Every deletion is of code that cannot execute in a shipped build. Any diff hunk that alters what renders is out of scope and must be raised, not written.
- **Measured baseline: 694 tests in 142 suites pass** via `swift test --no-parallel` in `AuraCore/`. Expected after this change: **685 tests in 141 suites** (nine removed: four split tests, five `RouteSplit` tests; one suite removed). Verify these numbers; a different result means something was deleted that the spec did not sanction.
- **`--no-parallel` is mandatory** for `swift test`. Several suites build SwiftData `ModelContainer`s and abort intermittently under Swift Testing's default parallel execution.
- **Remove parameters, never default them.** `splitAtMeters: Double? = nil` would keep all call sites compiling and silently skip the call-site audit that is the point of this change. It is also a public default argument across a module boundary, the family ROH-110 was burned by.
- **`.onCameraChanged` must precede `.ignoresSafeArea()`** in the modifier chain. Misordering is a compile error (`onCameraChanged` is declared once, on `public extension Map`, returning `Self`), not a silent no-op. Keep the explanatory comment but do not repeat its inaccurate "would be silently dropped" framing.
- **Do not reorder `routeRibbon` / `detourPolyline` / `gemAnnotations`** inside the `Map` content builder. `MapContent` node IDs are positional; removing `PeerAnnotations` already shifts them, which is harmless per-process, but a second reordering makes any regression harder to attribute.
- **`swiftlint lint --strict` must pass on the whole repo** (`scripts/lint.sh`). Lint before pushing; a lint failure after a push has bitten this project before.
- `PeerAnnotations`, `PeerAnnotationDriver`, `ClusterDeclutter`, `GroupMapDots` and `NavigateHUDView` keep their implementations. Only their doc comments change.

---

### Task 1: TrackRibbon loses splitting; RouteSplit is deleted

Pure AuraCore, fully unit-testable, and it compiles independently of Task 2. Doing it first means Task 2's app-target change lands against a settled API.

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Geo/TrackRibbon.swift`
- Delete: `AuraCore/Sources/AuraCore/GroupRide/RouteSplit.swift`
- Delete: `AuraCore/Tests/AuraCoreTests/GroupRide/RouteSplitTests.swift`
- Modify: `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`
- Modify: `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift:61`
- Modify: `docs/ROADMAP.md:504`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `TrackRibbon.pieces(segments: [RideSegment]) -> [TrackRibbon.Piece]`, where `Piece` is `public struct Piece: Equatable, Sendable` with exactly two stored properties, `public let coordinates: [Coordinate]` and `public let sourceIndex: Int`, and initializer `public init(coordinates: [Coordinate], sourceIndex: Int)`. Task 2 calls this and reads `.coordinates` and `.sourceIndex`.

- [ ] **Step 1: Confirm the baseline before deleting anything**

Run:
```bash
cd AuraCore && swift test --no-parallel 2>&1 | tail -3
```
Expected: `Test run with 694 tests in 142 suites passed`. If the count differs, stop and report — the plan's arithmetic is calibrated to it.

- [ ] **Step 2: Rewrite the tests first, so the compiler drives the deletion**

This is the TDD cycle inverted for a removal: the tests move to the new API, fail to compile against the old one, and the implementation change is what makes them pass.

Delete four split tests from `AuraCore/Tests/AuraCoreTests/TrackRibbonTests.swift`: `test_split_marksRiddenPortionBehind`, `test_split_isMeasuredPerSegment_notAcrossThePauseChord`, `test_splitBeyondTotalLength_isAllBehind`, `test_splitAtZero_isAllAhead`.

Keep three, edited to the new signature. Replace the file's body (keeping `import XCTest`, `@testable import AuraCore`, and the `pt`/`seg` helpers exactly as they are) so the three survivors read:

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
    /// the runs after them. `RideMapView` keys its annotation group on `sourceIndex`, so a
    /// shift here churns Mapbox annotation identity.
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

Note the rename in the first test: `test_noSplit_onePiecePerSegment` loses its now-meaningless `noSplit` prefix.

- [ ] **Step 3: Update the remaining caller in the test targets**

In `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift:61`, change:

```swift
        #expect(TrackRibbon.pieces(segments: ride.segments, splitAtMeters: nil).count == 2)
```

to:

```swift
        #expect(TrackRibbon.pieces(segments: ride.segments).count == 2)
```

Leave the surrounding comment (`// Live/summary ribbon: no piece spans the gap.`) and every other assertion in that test untouched.

- [ ] **Step 4: Run the tests to verify they fail to compile**

Run:
```bash
cd AuraCore && swift test --no-parallel 2>&1 | grep -E "error:" | head -5
```
Expected: FAIL, with errors of the form `missing argument for parameter 'splitAtMeters' in call`. This confirms the tests are genuinely bound to the new API before the implementation moves.

- [ ] **Step 5: Rewrite TrackRibbon**

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
/// these indices, which churns Mapbox annotation identity in `RideMapView` and breaks any
/// "current segment" rule keyed on them.
public enum TrackRibbon {
    public struct Piece: Equatable, Sendable {
        public let coordinates: [Coordinate]
        /// Index into the original `segments` array. Preserved because runs too short to
        /// stroke are dropped, so output position is not input position. `RideMapView` keys
        /// its annotation group on this, and Pass 4 (ROH-101) renders the current segment
        /// differently while paused.
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

- [ ] **Step 6: Delete RouteSplit and its tests**

```bash
git rm AuraCore/Sources/AuraCore/GroupRide/RouteSplit.swift \
       AuraCore/Tests/AuraCoreTests/GroupRide/RouteSplitTests.swift
```

`AuraCore` is a local path package (`Aura/project.yml`: `packages.AuraCore.path: ../AuraCore`) with no external consumer, and both files are picked up by directory globbing, so no manifest edit is needed.

- [ ] **Step 7: Run the tests to verify they pass**

Run:
```bash
cd AuraCore && swift test --no-parallel 2>&1 | tail -3
```
Expected: `Test run with 685 tests in 141 suites passed`. If the number is not exactly 685/141, stop and reconcile against the Global Constraints before continuing.

- [ ] **Step 8: Update the ROADMAP entry that lists RouteSplit**

In `docs/ROADMAP.md:504`, change:

```
    helpers (PeerBearing, PeerDistance, DisplayName, GroupRosterViewData, RouteSplit); an
```

to:

```
    helpers (PeerBearing, PeerDistance, DisplayName, GroupRosterViewData); an
```

This is a historical Wave 4 record, so do not rewrite the surrounding narrative — only drop the name of the helper that no longer exists.

- [ ] **Step 9: Lint and commit**

```bash
./scripts/lint.sh
git add -A
git commit -m "refactor(roh-105): drop TrackRibbon's unreachable split branch and RouteSplit

pieces(segments:splitAtMeters:) was only ever called with nil, so the budget
walk, the RouteSplit call, the overlap fix, length(of:) and Piece.isBehind were
all unreachable. RouteSplit had no other caller.

Keeps the three tests that cover reachable behavior, including the empty-input
case hit on every ride start. Preserves the per-segment-progress trap and the
sourceIndex stability rule as doc comments, since both outlived the code that
taught them.

685 tests in 141 suites pass, down from 694/142."
```

---

### Task 2: RideMapView loses the whole peer path

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift`

**Interfaces:**
- Consumes: `TrackRibbon.pieces(segments:)` and `TrackRibbon.Piece` (`.coordinates`, `.sourceIndex`) from Task 1.
- Produces: `RideMapView`'s call signature, unchanged from the caller's point of view. `RideHUDView.swift:68-74` already passes exactly the surviving set (`segments`, `gems`, `seenGemIDs`, `onSelectGem`, `detourRoute`, `cameraBox`, `viewport`) and **must not be edited**. If this task requires touching `RideHUDView`, something has gone wrong.

- [ ] **Step 1: Replace the file's declarations and body**

Replace `Aura/Sources/Ride/RideMapView.swift` from the top of the file through the closing brace of `var body` (that is, lines 1 through 75 of the current file) with:

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
        TrackRibbon.pieces(segments: segments)
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

Deleted here: the `peers` / `selfUserID` / `nameMap` / `selfProgress` properties, the `peerModel` state, the `accessibilityReduceMotion` environment read, the `MapReader` wrapper, the `TimelineView`, and `PeerAnnotations` from the content builder. `Puck2D`, `.mapStyle` and `.onCameraChanged` all survive unchanged.

- [ ] **Step 2: Delete syncPeers() and project()**

Delete these two methods outright (currently lines 77-88):

```swift
    private func syncPeers() { ... }
    private func project(_ c: Coordinate, _ proxy: MapProxy) -> ClusterDeclutter.Point2D? { ... }
```

`project` existed only to give the peer driver a screen-space projection, and it was the only reason the body was wrapped in `MapReader`.

- [ ] **Step 3: Update routeRibbon for the collapsed dim rule and the new annotation key**

Replace the `routeRibbon` property (currently lines 101-121) with:

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
            PolylineAnnotationGroup(pieces, id: \.sourceIndex) { piece in
                PolylineAnnotation(lineCoordinates: piece.coordinates.map {
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

Two changes beyond the deletion. The dim test drops its `item.element.isBehind ||` term, which was constant-false, and the branches are swapped so the common case reads first. The annotation group now keys on `\.sourceIndex` rather than the enumerated `\.offset`; keying by output position is stable today only by accident of a `RideRecorder` invariant, and `sourceIndex` is the identity the ribbon actually means.

Leave `detourPolyline` and `gemAnnotations` exactly as they are.

- [ ] **Step 4: Strip the peers from the preview**

Replace the `#Preview` block (currently lines 137-160) with:

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

The four-peer fixture is **not** discarded — Task 3 rehomes it on `PeerAnnotations`. Do not delete it until Task 3 has landed it, or run the two tasks as one commit.

- [ ] **Step 5: Build the app target to verify**

The app target has no unit tests (`Aura/project.yml:123-124` — the only test target is `UITests`), so compilation is the check, and it is a real one: every deleted symbol is either still referenced or it is not.

Delegate this to the `apple-platform-build-tools:builder` agent to keep build logs out of context. Ask it to build the `Aura` scheme for an iPhone simulator and report only pass/fail plus any errors.

Expected: build succeeds. A `MapReader`/`MapProxy` unresolved-symbol error means Step 2 removed `project` but left a caller; a `value of type 'some View' has no member 'onCameraChanged'` error means the modifier order in Step 1 was not preserved.

- [ ] **Step 6: Lint and commit**

```bash
./scripts/lint.sh
git add Aura/Sources/Ride/RideMapView.swift
git commit -m "refactor(roh-105): delete RideMapView's dead peer path

The sole production caller (RideHUDView) never passed peers, so the driver, the
annotations, the projection helper, the MapReader that existed to feed it and the
permanently-paused TimelineView were all unreachable. Removing them unwraps two
containers from around the Map; the same chain already ships in RoutePreviewView
and HomeLiveMap.

Also keys the polyline group on sourceIndex rather than the enumerated offset,
which was stable only by accident of a RideRecorder invariant."
```

---

### Task 3: Rehome the peer preview and correct the doc comments the deletion falsified

The four-peer fixture is the only artifact in the app sources rendering the awaiting dot, the dropped dot, monogram disambiguation and declutter offsets together over a real map. `GroupNavigateContainer`'s preview supplies one `.moving` peer; `PeerDotView` has none. Group-ride UI is the designated flagship surface, so this fixture survives the view that happened to host it.

**Files:**
- Modify: `Aura/Sources/GroupRide/PeerAnnotations.swift`
- Modify: `AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift:3-4`
- Modify: `Aura/Sources/Ride/RideHUDView.swift:31-33`

**Interfaces:**
- Consumes: `PeerAnnotations`, `PeerAnnotationDriver` and `PeerFrame` as they already exist; this task adds a preview and edits comments, and changes no type.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Correct the "shared by both hosts" claim**

In `Aura/Sources/GroupRide/PeerAnnotations.swift`, the type doc currently ends line 7 with `Shared by both hosts.` That is now false — `NavigateHUDView` is the only host. Change the sentence to:

```swift
/// `frame` by `PeerAnnotationDriver`, so this only rebuilds ≤7 annotations. `NavigateHUDView`
/// is the only host; `RideMapView` carried a second, dead copy until ROH-105.
```

- [ ] **Step 2: Add the relocated preview**

Append to the end of `Aura/Sources/GroupRide/PeerAnnotations.swift`:

```swift
/// The four peer states over a real map: riding, stopped, awaiting a first fix, and dropped.
/// Relocated from `RideMapView` in ROH-105, where it was previewing a code path that never ran
/// in production. It is the only fixture in the app sources that exercises the hollow awaiting
/// dot, the ghosted dropped dot, monogram disambiguation and declutter offsets together.
#Preview {
    @Previewable @State var viewport: Viewport = .camera(
        center: CLLocationCoordinate2D(latitude: 37.7742, longitude: -122.4182), zoom: 15)
    let driver = PeerAnnotationDriver()
    let peers: [RidePeer] = [
        RidePeer(userID: UUID(), displayName: "Mara",
                coordinate: Coordinate(latitude: 37.7752, longitude: -122.4192),
                progressMeters: 900, motionState: .moving, status: .riding),
        RidePeer(userID: UUID(), displayName: "Devon",
                coordinate: Coordinate(latitude: 37.7742, longitude: -122.4182),
                progressMeters: 450, motionState: .stopped, status: .stopped),
        RidePeer(userID: UUID(), displayName: "Priya",
                coordinate: Coordinate(latitude: 37.7732, longitude: -122.4172),
                progressMeters: 200, status: .awaiting),
        RidePeer(userID: UUID(), displayName: "Sam",
                coordinate: nil, progressMeters: nil, status: .dropped)
    ]
    driver.updateSet(peers: peers, selfUserID: nil, nameMap: [:],
                     reduceMotion: false, now: Date())
    return Map(viewport: $viewport) {
        PeerAnnotations(frame: driver.frame(now: Date(), project: { _ in nil }))
    }
    .ignoresSafeArea()
}
```

`project: { _ in nil }` is deliberate: declutter falls back to unresolved projection off a live `MapProxy`, which is what a preview can offer, and the dots still render at their coordinates.

- [ ] **Step 3: Correct GroupMapDots' call-site count**

In `AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift`, lines 3-4 currently read:

```swift
/// Selects which peers get a dot on the group-ride map — the one home for that rule, since
/// both call sites (`NavigateHUDView` and `RideMapView`) are in the untestable app target.
```

That comment is the stated justification for this type having no view-level test, so the reasoning has to survive the correction, not just the count. Change to:

```swift
/// Selects which peers get a dot on the group-ride map — the one home for that rule, since its
/// only call site (`NavigateHUDView`) is in the untestable app target. `RideMapView` was a
/// second call site until ROH-105 removed its dead peer path.
```

- [ ] **Step 4: Point the group-explore aside at the spec**

`Aura/Sources/Ride/RideHUDView.swift:31-33` notes that `GemDiscoveryStore.isSuppressed` exists "for a future group-explore surface". After this change there is no dormant peer path anywhere in the Explore HUD, so that note reads as a capability that still exists. Change lines 31-33 to:

```swift
    // Free rides are solo by construction — group rides use NavigateHUDView +
    // GroupRideSession, never this HUD — so gem discovery is never suppressed here.
    // (GemDiscoveryStore.isSuppressed exists for a future group-explore surface. That surface
    // would be a rebuild, not a wiring-up: ROH-105 removed the last dormant peer path here.
    // See docs/superpowers/specs/2026-07-27-roh105-dead-peer-split-deletion-design.md.)
```

- [ ] **Step 5: Build to verify the preview compiles**

Previews are compiled into debug builds, so a malformed `#Preview` is a build failure, not a silent no-op.

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator, report pass/fail and errors only.

Expected: build succeeds. An `unresolved identifier 'Viewport'` or `'Map'` error means `PeerAnnotations.swift` needs no new import (it already imports `SwiftUI`, `MapboxMaps` and `AuraCore`) and something else is wrong — report rather than adding imports speculatively.

- [ ] **Step 6: Lint and commit**

```bash
./scripts/lint.sh
git add Aura/Sources/GroupRide/PeerAnnotations.swift \
        AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift \
        Aura/Sources/Ride/RideHUDView.swift
git commit -m "refactor(roh-105): rehome the peer preview, fix the doc comments the deletion falsified

The four-state peer fixture moves from RideMapView (where it previewed a dead
path) to PeerAnnotations. It is the only place in the app sources that renders
the awaiting dot, dropped dot, monograms and declutter offsets at once.

GroupMapDots and PeerAnnotations both claimed two call sites; NavigateHUDView is
now the only one. RideHUDView's group-explore aside now says that surface would
be a rebuild rather than a wiring-up."
```

---

### Task 4: Full-gate verification and follow-ups

**Files:**
- No source changes expected. If this task produces a code edit, that edit belongs in whichever of Tasks 1-3 owns the file, and the plan should be updated to say why.

**Interfaces:**
- Consumes: the complete state after Tasks 1-3.
- Produces: a verified branch and two filed Linear issues.

- [ ] **Step 1: Run the full package suite**

```bash
cd AuraCore && swift test --no-parallel 2>&1 | tail -3
```
Expected: `Test run with 685 tests in 141 suites passed`.

- [ ] **Step 2: Run the repo-wide lint**

```bash
./scripts/lint.sh
```
Expected: no output, exit 0. `--strict` treats warnings as errors.

- [ ] **Step 3: Confirm no stale references survive**

```bash
grep -rn "splitAtMeters\|RouteSplit\|isBehind\|selfProgress" --include="*.swift" Aura AuraCore
grep -rn "RouteSplit" docs/
```
Expected: zero hits from both. A hit in `docs/` other than the ROH-105 spec and this plan means a historical record still names the deleted helper.

- [ ] **Step 4: Build the app and run the device pass**

Delegate the build to the `apple-platform-build-tools:builder` agent, then verify on the physical iPhone per the project's usual tunnel recipe.

The spec is explicit that the risk lives in the surviving code's new shape, not in the deleted code, so check the states that carry it:

1. **First mount with zero segments.** Start an Explore ride. The `if !pieces.isEmpty` path is hit before the first GPS fix lands, on every ride start.
2. **Pause, then resume, then watch the ribbon.** This is the ROH-101 hand-off state. Confirm the track draws with a gap across the pause and no chord, and that the fresh empty segment appended by `resume(at:)` does not break rendering.
3. **Full-bleed layout.** `.ignoresSafeArea()` moved from inside two wrappers to the view root. Confirm the map still runs under the notch and home indicator with no inset band.
4. **A glance at the shared content builder.** Gem pins, the detour polyline and the puck shared the `Map` content builder with the deleted `PeerAnnotations`; confirm all three still render.

The zoom pill is deliberately **not** on this list. The type checker guarantees it (see Global Constraints), and the same chain already ships in `RoutePreviewView` and `HomeLiveMap`.

- [ ] **Step 5: File the two follow-up issues**

Both come out of the spec's Follow-ups section and are prerequisites for closing ROH-105 honestly, because this change deletes the last scaffolding for the first one.

Create in Linear, team `Rohun`, project `Group Rides Tail`:

1. **"Group ride without a destination (group-explore surface)"**, priority Medium, label `Feature`. Body: `GroupRideEntry`'s two cases both carry a `Route` (`AppRoute.swift:47-50`), created only from the route preview (`RoutePreviewView.swift:250`), and only `GroupNavigateContainer` hosts a `GroupRideSession`. So riding with a crew requires picking a destination first, and "let's go ride around for an hour" is unsupported. ROH-105 removed the last dormant scaffolding for the alternative, so this would now be a rebuild. Link the ROH-105 spec.

2. **"Measure the ribbon's per-frame coordinate copying on long rides"**, priority Low, label `Tech Debt`. Body: `TrackRibbon.pieces(segments:)` copies every coordinate of the ride and `routeRibbon` maps them all again into `CLLocationCoordinate2D` (`RideMapView.swift`) on each body evaluation of a live HUD. ROH-105 retired a phantom figure (the ROH-98 1.3M calls/sec number, which described code that never ran) without measuring the real one. Relate it to ROH-105 and ROH-98.

- [ ] **Step 6: Move ROH-105 to In Review and open the PR**

```bash
git push -u origin HEAD
gh pr create --title "ROH-105: delete RideMapView's dead peer and split machinery" --body "$(cat <<'BODY'
Deletes the peer-rendering and route-splitting code that `RideMapView` and
`TrackRibbon` carried but never executed. No rider-visible change.

`RideMapView`'s only production caller never passed peers, which made the
driver, the annotations, the projection helper, the `MapReader` feeding it, the
permanently-paused `TimelineView` and `TrackRibbon`'s entire split branch
unreachable. `RouteSplit` had no other caller.

Spec (revision 2, after a three-reviewer adversarial gate):
`docs/superpowers/specs/2026-07-27-roh105-dead-peer-split-deletion-design.md`

Beyond the deletion, three changes the gate asked for:

- the polyline group keys on `sourceIndex` rather than the enumerated offset,
  which was stable only by accident of a `RideRecorder` invariant
- the four-state peer `#Preview` moves to `PeerAnnotations` rather than dying
  with the view that hosted it
- the doc comments that claimed two call sites are corrected

Gates: 685 tests in 141 suites (down from 694/142 — nine deleted tests, all of
unreachable code), `swiftlint --strict` clean, app build, device pass on ride
start, pause/resume ribbon, and full-bleed layout.

Closes ROH-105.
BODY
)"
```

Then move ROH-105 to **In Review** in Linear, and add a comment recording the three obligations D5 places on ROH-101: navigate's paused state needs a positive legibility requirement, Pass 4 must reintroduce a pure discriminator rather than grow the ternary in `RideMapView`, and navigate's paused state needs a budgeted device check since ROH-103's assertion is now Explore-only.

- [ ] **Step 7: Whole-branch adversarial review**

Before merging, dispatch a final review of the entire branch diff on the most capable model, per the project's standing pipeline. This is the gate that has repeatedly caught defects green tests and single-pass review missed on this codebase, including three production-dead criticals during Wave 4.

Give the reviewer the spec and the full diff, and a refuting mandate: find any rider-visible behavior change, any deleted symbol that was reachable, and any surviving comment or doc that the deletion made false.
