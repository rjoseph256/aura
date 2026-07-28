# Delete RideMapView's dead peer and split machinery (ROH-105) — design

Date: 2026-07-27
Issue: [ROH-105](https://linear.app/rohun/issue/ROH-105/delete-ridemapviews-dead-peersplit-parameters-decided-option-b-before)
Status: revision 2, after a three-reviewer adversarial gate (skeptic, architecture, product).
Sequenced before ROH-101 (Pass 4).

Revision 1 contained four errors the gate caught. Its test accounting was arithmetically wrong
and would have deleted a test of reachable behavior. It claimed `sourceIndex` was "load-bearing
today" when nothing in production reads it. It described the `.onCameraChanged` ordering rule as
a silent-drop risk when the compiler enforces it. And it gated the change on a device check of
the one thing the type checker already guarantees, while skipping the states that actually carry
risk. Each correction is marked inline.

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

A severity figure recorded during ROH-98 (commit `fe6d3a2`), roughly 1.3 million `Geo.distance`
calls per second at 30 fps on the group-ride surface, described code that never ran. *Revision 2
corrects how this is stated.* The arithmetic behind it was sound for the counterfactual, and both
of its premises, the split walk and the 30 fps clock, follow from the single fact that `peers` is
always empty rather than from two independent errors. Had the peer path been live, the 30 fps
premise would have been correct. So the figure was not inflated; it was inapplicable, and
`TrackRibbon`'s true production contribution was zero. The caching fix shipped there was correct
on its own merits.

Peers are not missing from any surface a rider can reach today. `NavigateHUDView` renders them on
its own map with its own `PeerAnnotationDriver` (`NavigateHUDView.swift:297,364-368`). The two
maps do different jobs: `RideMapView` strokes the recorded track, `navigateMapView` strokes the
planned route.

*Revision 2 narrows that sentence.* The reason the dead path is unreachable is itself a product
gap: `GroupRideEntry` has two cases and both carry a `Route` (`AppRoute.swift:47-50`), created
only from the route preview (`RoutePreviewView.swift:250`), and only `GroupNavigateContainer`
hosts a `GroupRideSession` (`GroupNavigateContainer.swift:14-21`). **You cannot ride with a crew
without first picking a destination.** "Let's go ride around for an hour" is not supported. That
gap is recorded nowhere except an inline aside at `RideHUDView.swift:33`. This change deletes the
other artifact of that intent, so the gap needs its own issue before merge (see Follow-ups).

**The dead code was never a regression.** Reviewers walked all fifteen revisions that touched
`RideMapView.swift`: `376e3f8` (2026-07-01, Wave 4 SP3) added the peer path speculatively, and
`bfe0302` moved peer dots into `NavigateHUDView` the same day. No production call site ever
passed peers. It was orphaned on arrival and deliberately superseded.

The reusable lesson, which is why this cost real money while dead: the type doc at
`RideMapView.swift:6-9` promised peer dots and a split ribbon on a solo-only view, and two later
issues believed it. ROH-69/ROH-72 re-plumbed the path as if live, and ROH-98 shipped a perf fix
justified by a figure measured against code that never ran.

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

*Revision 2 corrects the sequencing claim.* Revision 1 said this "blocks ROH-101." Strictly it
does not: Pass 4 needs `Piece.sourceIndex`, which already exists and survives. What the deletion
buys is that Pass 4's paused styling never has to reason about a behind/ahead axis while adding a
paused axis. That is blast-radius reduction, not a hard prerequisite. The distinction matters
because "blocks Pass 4" is what would justify doing a zero-rider-value change ahead of the pause
control itself.

## D1 — RideMapView loses the whole peer path

Removed: the `peers`, `selfUserID`, `nameMap` and `selfProgress` properties; the `peerModel`
state; `syncPeers()` and the `onAppear`, `onChange(of: peers)` and `onChange(of: reduceMotion)`
hooks that call it; `PeerAnnotations` from the map content; `project(_:_:)`; the `MapReader`
that wrapped the body only to supply a `MapProxy` to that function; the `TimelineView`; and the
`accessibilityReduceMotion` environment read, whose only consumer was `syncPeers()`.

What remains is a `Map` that renders `Puck2D(bearing: .heading)`, strokes the recorded track,
draws the detour polyline, renders gem pins, applies `.mapStyle(settings.mapStyle.mapboxStyle)`,
and mirrors the camera into `MapZoomCameraBox`. *Revision 2 adds the puck and the map style to
this list;* revision 1 omitted both, and an implementer rewriting the body from that list would
have dropped the most rider-visible element on the surface.

*Revision 2 corrects the ordering rule.* `.onCameraChanged` must still precede
`.ignoresSafeArea()`, but getting it wrong is a compile error, not a silent no-op.
`onCameraChanged` is declared exactly once in the SDK, on `public extension Map`, returning
`Self` (`mapbox-maps-ios/Sources/MapboxMaps/SwiftUI/Map+Events.swift:71`). There is no
`View`-level overload, so calling it after `.ignoresSafeArea()` fails to typecheck. Revision 1
described this as a risk of the callback being silently dropped, which cannot happen. That
phrasing was inherited verbatim from existing comments at `RoutePreviewView.swift:342-343` and
`HomeLiveMap.swift:90-92`, so it is a repo-wide inaccuracy rather than a new one.

The unwrap is further de-risked by precedent: the exact post-refactor chain
(`Map` → `.mapStyle` → `.onCameraChanged` → `.ignoresSafeArea()`, with no `MapReader` and no
`TimelineView`) already ships in `RoutePreviewView.swift:326-349` and `HomeLiveMap.swift:63-101`.

Removing `MapReader` is inert. Its only effect on the `Map` is publishing `\.mapViewProvider`
into the environment (`MapReader.swift:28`), read at one line in the SDK (`Map.swift:141`) to
hand the `MapView` back to the proxy; absent, that write is a no-op. Removing the `TimelineView`
is inert for the same reason it was dead: nothing non-peer consumes `context.date`, and ribbon
liveness comes from `@Observable` invalidation on `RideSessionCoordinator`/`RideRecorder`, not
from the timeline clock.

**The peer `#Preview` fixture moves rather than dies.** `grep -rn "RidePeer(" Aura/Sources`
returns four lines, all inside this preview. It is the only artifact in the app sources that
renders the hollow awaiting dot, the ghosted dropped dot, monogram disambiguation and declutter
offsets together over a real map. `GroupNavigateContainer`'s preview supplies one `.moving` peer;
`PeerDotView` has none. Group-ride UI is the designated flagship surface, so this fixture
relocates to a `#Preview` on `PeerAnnotations`. `RideMapView`'s own preview keeps the synthetic
track and drops the peers.

`PeerAnnotations`, `PeerAnnotationDriver`, `ClusterDeclutter` and `GroupMapDots` keep their
implementations. `NavigateHUDView` remains their consumer and renders peers exactly as today.

Two doc comments become false and are corrected in this change, because they are what the next
author reads: `GroupMapDots.swift:4` names `RideMapView` as one of two call sites (it is now the
justification for that type having no view-level test, so the reasoning has to survive the edit),
and `PeerAnnotations.swift:7` says "Shared by both hosts." `RideMapView`'s own type doc
(`:6-9`) and its `routeRibbon` doc (`:101-104`) both describe the deleted behavior and are
rewritten.

## D2 — TrackRibbon loses splitting

`pieces(segments:splitAtMeters:)` becomes `pieces(segments:)`. The split branch goes, and with
it the `remaining` budget, the `splitting` flag, the `RouteSplit.splitIndex` call, the
three-way dispatch on `local`, the overlap-by-one-point construction, and the private
`length(of:)` helper that no longer has a caller.

`Piece` drops to `(coordinates, sourceIndex)`. `isBehind` was constant false once splitting was
gone, and it was the only reason `routeRibbon` tested `item.element.isBehind || !detourRoute.isEmpty`.
That test collapses to `!detourRoute.isEmpty`.

`pieces` takes `segments` and nothing else. The parameter is **removed, not defaulted to nil**.
`splitAtMeters: Double? = nil` would keep all four call sites compiling and silently skip the
call-site audit that is the point of this change.

`sourceIndex` stays, for ROH-101. *Revision 2 retracts revision 1's claim that it is
"load-bearing today"*. Nothing in production reads it. `RideMapView.swift:111` keys the
annotation group by `\.offset`, the enumerated output position, not `sourceIndex`. Its only
readers are `TrackRibbonTests`.

That is worth fixing rather than documenting. This change also switches
`PolylineAnnotationGroup(Array(pieces.enumerated()), id: \.offset)` to key on
`\.element.sourceIndex`. Keying by output position is stable today only by accident of a recorder
invariant three files away: `RideRecorder.record` appends only to the last segment
(`RideRecorder.swift:82-83`) and only while recording, so a dropped run stays dropped and offsets
never shift. It is not a live bug. But it hands ROH-101's author the wrong index in the closure,
and the fix makes the retained field load-bearing instead of test-only.

**What `sourceIndex` does and does not give ROH-101.** "Render the current segment differently
while paused" needs three things, and this spec supplies one:

1. Identify the segment. `sourceIndex` does this.
2. Know the view is paused. `RideMapView` has no `isPaused` input and `RideHUDView.swift:68-74`
   passes none. `coordinator.isPaused` exists (`RideSessionCoordinator.swift:25`) but is not
   plumbed to the map. ROH-101 must add that parameter.
3. Survive the current segment having no piece at all. `RideRecorder.resume(at:)` appends an
   empty segment (`RideRecorder.swift:116`) and `TrackRibbon.swift:42` drops runs of fewer than
   two points. So immediately after a resume, `segments.count - 1` names a segment that produces
   no `Piece`. A rule keyed on `sourceIndex == segments.count - 1` renders nothing in that
   window; the correct target is the last *rendered* piece.

`isBehind` would not have helped with any of these, since it is progress-based rather than
pause-based. Deleting it is still right. Revision 1 simply overstated what remained.

The surviving contract is the one that matters: one piece per segment, in ride order, never
spanning a pause, with runs of fewer than two coordinates dropped without shifting the indices
of the runs after them.

Two pieces of hard-won knowledge leave with the deleted code and are preserved as doc comments on
`pieces`, because the next feature that renders progress along a segmented track will otherwise
rediscover them. First, a progress budget must be spent per segment and must never walk the
straight-line chord across a pause, or the ribbon freezes for the chord's length after every
resume (`TrackRibbonTests.swift:56-60` called this "THE discriminating test"). Second, the index
contract holds only because the recorder appends solely to the last segment; any future path that
backfills an interior segment (checkpoint restore, GPX import, a replay harness) breaks both the
annotation identity and ROH-101's current-segment rule, silently.

This subsumes the micro-optimization the issue suggested for `TrackRibbon.swift:50`, guarding
the `length(of: run)` walk with `if index < segments.count - 1`. That change existed to make the
split branch cheaper. The branch is gone, so the walk is gone with it.

## D3 — RouteSplit is deleted

`TrackRibbon` was its only caller. `RouteSplit.swift` and its 5-test `RouteSplitTests.swift` are
both removed. Leaving it would leave an unused public API in AuraCore and a suite exercising code
nothing calls.

`AuraCore` is a local path package (`Aura/project.yml`: `packages.AuraCore.path: ../AuraCore`),
so there is no external consumer and no semver contract. `docs/ROADMAP.md:504` lists `RouteSplit`
among the shipped Wave 4 helpers and is updated in this change.

## D4 — Tests

*Revision 2 corrects this section's arithmetic, which was wrong in a way that would have deleted
a test of reachable behavior.* `TrackRibbonTests` has **seven** tests, of which **four** are split
tests. Revision 1 said "keeps two, deletes five," and 2 + 5 = 7 forced `test_noSegments_isEmpty`
into the delete bucket. It is not a split test.

Keep three:

- `test_noSplit_onePiecePerSegment`, renamed to drop the now-meaningless "noSplit". Carries the
  chord check that no piece may contain points from two different segments.
- `test_segmentsWithFewerThanTwoPoints_areDroppedWithoutShiftingIndices`.
- `test_noSegments_isEmpty`, reduced to its one surviving call. This is the only assertion that
  empty input yields empty output, and that state is reached on **every** Explore ride:
  `RideHUDView.swift:161` starts the ride in `.task`, which runs after the first body evaluation,
  so `coordinator.segments` is empty on the first render of every mount. It is the upstream guard
  for the `if !pieces.isEmpty` check at `RideMapView.swift:110`, which exists to avoid creating a
  Mapbox annotation manager (a style source plus a layer) per map mount.

Delete four: `test_split_marksRiddenPortionBehind`,
`test_split_isMeasuredPerSegment_notAcrossThePauseChord`, `test_splitBeyondTotalLength_isAllBehind`,
`test_splitAtZero_isAllAhead`.

`PausedGoldenRideFixtureTests.swift:61` drops its `splitAtMeters: nil` argument. Its assertion,
that a paused golden ride yields exactly two pieces, is unchanged and is the fixture-level guard
that the pause gap survives this refactor.

Expected suite total afterwards: **685 tests in 141 suites**, down from a measured baseline of 694
in 142. Nine tests removed (four split, five `RouteSplit`), one suite removed. The implementer
verifies these numbers rather than assuming them; a different result means something was deleted
that this spec did not sanction.

Coverage of reachable behavior does not decrease.

## D5 — Recorded consequence for Pass 4 and Pass 6

Paused-segment map styling is an Explore-HUD feature only. Navigate never draws the recorded
track (`NavigateHUDView.swift:281-291` strokes the planned route), so there is no chord to break
there, and ROH-101's paused treatment on Navigate has to live in the cockpit and instrument
chrome instead. ROH-103 narrows accordingly: "the route draws with a gap rather than a chord" is
assertable on Explore and nowhere else.

*Revision 2 adds three obligations, because recording the constraint without them hands ROH-101 a
harder problem while appearing to simplify one.*

**Navigate's paused state needs a positive requirement, not a subtraction.** A rider navigating
to a trailhead who pauses for coffee, phone in the bar mount, sees a turn card and a bright route
line that are byte-identical to a live ride, with guidance still running. The pause spec already
names the forgotten resume as the failure that "corrupts a ride worst"
(`2026-07-26-segmented-rides-pause-design.md:494-496`). ROH-101 must make the navigate paused
state legible from a bar mount without the map's help, which plausibly means the turn card itself
changes.

**ROH-101 must reintroduce a pure discriminator rather than grow the ternary.** Today the
dim/bright decision is split between a unit-tested AuraCore computation (`isBehind`) and a
view-side term. After D2 the whole expression collapses into `RideMapView.swift:115`, in the app
target, which this codebase treats as untestable (`GroupMapDots.swift:4`). ROH-101's headline
visual would then land in the one layer with no test target, on the one surface whose E2E
assertion D5 just narrowed. Pass 4 should add a `TrackRibbon` styling enum or a `Piece` field, not
another clause in that ternary.

**ROH-103's narrowed assertion leaves navigate's paused state with no automated coverage.**
Combined with the above, budget a device check for it in Pass 4 rather than inheriting this
spec's precedent of skipping one.

## Verification

The package suites (`AuraCoreTests`, `AuraKitTests`) plus a clean build of the Aura app scheme are
the gate. The app target has no unit test coverage (`Aura/project.yml:123-124`; the only test
target is `UITests`), so compilation is genuinely the primary check on D1, and it is a real one:
every deleted symbol is referenced or it is not.

*Revision 2 replaces revision 1's verification plan, which was wrong twice over.* It claimed no
device step was needed "because there is no behavior to observe", but that is a statement about
the deleted code, and the risk lives in the surviving code's new shape. Then it spent the one
check it did name on the zoom pill, which the type checker already guarantees (see D1) and which
two shipping files already demonstrate. Both halves were backwards.

A short device pass on the Explore HUD is warranted, aimed at the states that carry actual risk:

- **Pause, then resume, then confirm the ribbon.** This is the ROH-101 hand-off state and the one
  place where the empty-trailing-segment behavior described in D2 is observable.
- **First mount with zero segments.** The `if !pieces.isEmpty` path, hit on every ride start.
- **Full-bleed layout**, since `.ignoresSafeArea()` moves from inside two wrappers to the view
  root. Behavior under the notch and home indicator is a device-only observation.

Gem pins, the detour polyline and the puck share the map content builder with the deleted
`PeerAnnotations`, so they get a glance in the same pass.

## Out of scope

Merging `RideMapView` and `navigateMapView`. The duplication between them is real, and this issue
deliberately does not touch it.

The surviving ribbon path's cost is unmeasured: `pieces(segments:)` copies every coordinate of the
ride and `routeRibbon` maps them all again into `CLLocationCoordinate2D` (`RideMapView.swift:111-114`)
on each body evaluation of a live HUD. Retiring a phantom performance figure is a natural moment
to ask about the real one, but measuring it is not this change. See Follow-ups.

## Follow-ups to file before merge

1. **Group-explore surface.** Riding with a crew requires picking a destination first. This change
   deletes the last scaffolding for the alternative, so the gap needs an issue of its own rather
   than living in an inline comment at `RideHUDView.swift:33`. That comment gets a pointer to this
   spec, so it does not read as a capability that still exists.
2. **Ribbon cost on long rides.** Measure the per-body-evaluation coordinate copying above on a
   multi-hour ride before assuming it is free.
