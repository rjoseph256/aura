# Delete RideMapView's dead peer and split machinery (ROH-105) — design

Date: 2026-07-27
Issue: [ROH-105](https://linear.app/rohun/issue/ROH-105/delete-ridemapviews-dead-peersplit-parameters-decided-option-b-before)
Status: approved 2026-07-27. Blocks ROH-101 (Pass 4).

## Problem

`RideMapView` is written as if it serves two surfaces. Its doc comment promises peer dots
with heading cones and a live pulse, plus a route ribbon split into a dimmed "already
ridden" piece and a bright "still ahead" piece. None of that runs.

The view has exactly one production call site, `RideHUDView.swift:68`, the Explore HUD. That
call passes no `peers`, no `selfUserID`, no `nameMap`, and no `selfProgress`. A `#Preview` is
the only code in the repository that supplies them. Three consequences follow.

`TrackRibbon.pieces(segments:splitAtMeters:)` is only ever reached with `splitAtMeters == nil`,
because `ribbonPieces` derives it from `peers.isEmpty`. The entire split branch is unreachable
in production: the per-segment budget walk, the `RouteSplit` call, the three-way dispatch on
the local split index, the one-point overlap that joins behind to ahead, and `Piece.isBehind`
itself.

`TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !peerModel.shouldAnimate(now:)))`
is permanently paused. `shouldAnimate` reports whether any peer is riding, and the peer set is
always empty, so the clock never ticks. The `MapReader` wrapper and `project(_:_:)` exist only
to give the peer driver a screen-space projection for declutter.

A severity figure recorded during ROH-98, roughly 1.3 million `Geo.distance` calls per second
at 30 fps on the group-ride surface, was overstated on both counts for this reason. The caching
fix applied there was correct on its own merits. The number was not real.

Peers are not missing from the product. `NavigateHUDView` renders them on its own map with its
own `PeerAnnotationDriver` (`NavigateHUDView.swift:297,364-368`). The two maps do different
jobs: `RideMapView` strokes the recorded track, `navigateMapView` strokes the planned route.

## Decision

Delete the dead path rather than wire it up. This was settled on 2026-07-27 and recorded on the
issue. Wiring the group HUD through `RideMapView` would mean merging two maps with different
responsibilities on the app's most delicate and most device-verified surface, for no
rider-visible gain, on a screen whose history already includes ROH-7's rejected hoisted map and
three NavigationStack double-mutation traps. If the duplication between the two map views is
worth removing on its own merits, that belongs in its own issue and not in a Pass 4
prerequisite.

**No rider sees any difference.** Every deletion below is of code that cannot execute in a
shipped build.

## D1 — RideMapView loses the whole peer path

Removed: the `peers`, `selfUserID`, `nameMap` and `selfProgress` properties; the `peerModel`
state; `syncPeers()` and the `onAppear`, `onChange(of: peers)` and `onChange(of: reduceMotion)`
hooks that call it; `PeerAnnotations` from the map content; `project(_:_:)`; the `MapReader`
that wrapped the body only to supply a `MapProxy` to that function; the `TimelineView`; and the
`accessibilityReduceMotion` environment read, whose only consumer was `syncPeers()`.

What remains is a `Map` that strokes the recorded track, draws the detour polyline, renders gem
pins, and mirrors the camera into `MapZoomCameraBox`.

Cutting `MapReader` and `TimelineView` changes the view hierarchy around the `Map`, not only its
inputs. One ordering constraint has to survive that unwrap: `.onCameraChanged` must still
precede `.ignoresSafeArea()`, because `.ignoresSafeArea()` type-erases the view and would push
`.onCameraChanged` out of the Map-only modifier chain. ROH-57's zoom pill depends on it, and the
file already documents the requirement in a comment that stays.

The `#Preview` drops its four-peer fixture and keeps the synthetic track.

`PeerAnnotations`, `PeerAnnotationDriver`, `ClusterDeclutter` and `GroupMapDots` are untouched.
`NavigateHUDView` remains their consumer and keeps rendering peers exactly as it does today.

## D2 — TrackRibbon loses splitting

`pieces(segments:splitAtMeters:)` becomes `pieces(segments:)`. The split branch goes, and with
it the `remaining` budget, the `splitting` flag, the `RouteSplit.splitIndex` call, the
three-way dispatch on `local`, the overlap-by-one-point construction, and the private
`length(of:)` helper that no longer has a caller.

`Piece` drops to `(coordinates, sourceIndex)`. `isBehind` was constant false once splitting was
gone, and it was the only reason `routeRibbon` tested `item.element.isBehind || !detourRoute.isEmpty`.
That test collapses to `!detourRoute.isEmpty`.

`sourceIndex` stays. ROH-101 needs it to render the current segment differently while paused,
and it is load-bearing today because short runs are dropped, so output position is not input
position.

The surviving contract is the one that matters: one piece per segment, in ride order, never
spanning a pause, with runs of fewer than two coordinates dropped without shifting the indices
of the runs after them.

This subsumes the micro-optimization the issue suggested for `TrackRibbon.swift:50`, guarding
the `length(of: run)` walk with `if index < segments.count - 1`. That change existed to make the
split branch cheaper. The branch is gone, so the walk is gone with it.

## D3 — RouteSplit is deleted

`TrackRibbon` was its only caller. `RouteSplit.swift` and `RouteSplitTests.swift` are both
removed. Leaving it would leave an unused public API in AuraCore and a test suite exercising
code nothing calls.

## D4 — Tests

`TrackRibbonTests` keeps `test_noSplit_onePiecePerSegment` (renamed to drop the now-meaningless
"noSplit") and `test_segmentsWithFewerThanTwoPoints_areDroppedWithoutShiftingIndices`. Those two
assert the surviving contract, including the chord check that no piece may contain points from
two different segments. The five split tests are deleted along with the behavior they covered.

`PausedGoldenRideFixtureTests.swift:61` drops its `splitAtMeters: nil` argument. Its assertion,
that a paused golden ride yields exactly two pieces, is unchanged and is the fixture-level
guard that the pause gap survives this refactor.

Coverage of reachable behavior does not decrease. Only tests of unreachable code are removed.

## D5 — Recorded consequence for Pass 4 and Pass 6

Paused-segment map styling is an Explore-HUD feature only. Navigate never draws the recorded
track, so there is no chord to break there, and ROH-101's paused treatment on Navigate has to
live in the cockpit and instrument chrome instead. ROH-103 narrows accordingly: "the route draws
with a gap rather than a chord" is assertable on Explore and nowhere else.

## Verification

The package test suites (`AuraCoreTests`, `AuraKitTests`) and a clean app build are the gate.
There is no device verification step, because there is no behavior to observe: the deleted code
could not run on a device before this change.

The risk this carries is a compile-level one, not a behavioral one. The Explore HUD map is the
surface to build and smoke-test, and the specific thing to confirm is that the zoom pill still
tracks the camera after `MapReader` and `TimelineView` are removed from around the `Map`.

## Out of scope

Merging `RideMapView` and `navigateMapView`. The duplication between them is real, and this
issue deliberately does not touch it.
