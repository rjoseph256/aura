# ROH-155 — delete the ride-end share-map prefetch

Date: 2026-07-31. Branch `claude/post-ride-shareable-redesign-54df82`, follow-up to ROH-126.

**Revision note.** The first version of this spec proposed an interest refcount in
`SharePipelineSlot` so cancellation followed interest rather than arrival order. Three
adversarial reviewers — skeptic, architecture, product — independently rejected it, and they
were right. That design is recorded at the end under "What was rejected and why," because the
reasoning is worth more than the proposal was.

## The problem, restated with the numbers checked

`ShareMapProviderBox.prefetchShareMap` fires from both HUDs when a ride finishes, sleeps 0.7 s
in a detached `.utility` task, calls `raster(for:)`, and discards the result.
`RideSummaryView`'s `.task` requests the same key roughly 0.2–0.7 s later. So at ride end the
prefetch creates the pipeline and the summary — the only caller a rider can see — joins it.

Three consequences, in descending order of what they actually cost:

**The pipeline runs at the wrong priority for its whole life.** The pipeline `Task` is created
inside `SharePipelineSlot.run`, so it inherits the priority of whichever caller reached the
creation site. At ride end that is the prefetch's detached `.utility` task, and a foreground
summary then blocks on background-priority work. On the History path, where no prefetch exists,
the same pipeline runs at `.userInitiated` — so the two paths differ in a way nobody chose.

**The route derivation is written twice on the share path.** `ShareCardContent:51` and
`ShareMapRasterProviding:51` both compute
`ride.segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }`, and both feed
`ShareMapRequest.cacheKey`. A comment asks them to stay in lockstep; nothing enforces it. On
divergence the prefetch occupies the single slot under a *different* key, so the summary
becomes a different-key waiter — and if that pipeline outlives the ceiling the summary gets
`nil` and never starts its own, because its `.task` gets exactly one attempt.

The ROH-126 review counted three copies. `RideSummaryView:39` is the third and it is
display-only — it feeds `StaticRouteMap`, never a cache key. And `ShareRouteGeometry.prepare`
re-applies `.filter { $0.count > 1 }` itself, so the caller-side filter contributes nothing to
`contentHash`; real key drift needs flattening or regrouping, not dropping a short run.

**Cancel authority sits with the caller that discards the result.** The prefetch owns the slot,
so its ceiling cancels the pipeline the summary is waiting on. This is the item the ROH-126
review recorded, and it is listed last deliberately: it is the smallest of the three. Each
caller arms its own ceiling from its own join (`SharePipelineSlot.race`), so the summary stops
waiting 20 s after *it* joined either way. The inversion costs the arrival skew — roughly
200 ms — not the summary's map.

## The design

**Delete `prefetchShareMap` and both call sites.**

- Remove `ShareMapProviderBox.prefetchShareMap` entirely.
- Remove `shareMapBox.prefetchShareMap(...)` from `RideHUDView:232` and `NavigateHUDView:263`,
  and the then-unused `@Environment(ShareMapProviderBox.self)` in each.
- `ShareMapProviderBox` stays: `RideSummaryView` reads `shareMap.provider` and `AuraApp` injects
  it.
- `ShareMapRasterProviding`'s `Sendable` refinement is justified in its doc comment by "the
  HUDs' detached prefetch tasks capture the existential." That justification dies with the
  prefetch. Try removing the refinement; if something still needs it, keep it and correct the
  comment. A conformance kept for a reason that no longer holds is the failure mode this branch
  has spent three commits removing.

That is the whole change. It does not manage the three problems — it removes the conditions for
all three:

| | before | after |
|---|---|---|
| pipeline priority at ride end | `.utility`, inherited from a discarded background task | `.userInitiated`, matching History |
| derivations feeding `cacheKey` | 2, kept in step by comment | 1 |
| cancel authority | held by the caller that discards the result | one caller; nothing to contest |
| Mapbox renders per ride end | up to 2 on a key miss | 1 |

**Cost: the map arrives 0.2–0.7 s later at ride end**, 3–7% of a 6–12 s pipeline. The History
path is untouched, because it never had a prefetch.

### The 0.8 s sleep does not change here

`RideSummaryView:140` sleeps 0.8 s before requesting, and its comment attributes the ride-end
half to the prefetch already being in flight. That sentence becomes false and must be corrected.

The value stays at 0.8 s. Shortening it would recover the latency this deletion costs, and it is
tempting — but the sleep also keeps the upgrade render, a main-actor `ImageRenderer` pass at
1080×1350, out of the entrance animation on a warm cache hit, where `raster(for:)` returns
immediately. Which effect dominates is a question about frame timing on real hardware, and this
repo's rule is that UI is verified on a device rather than asserted. Tuning it belongs on the
device pass this branch already owes.

### One derivation, for a smaller reason than before

With the prefetch gone no second caller builds a `ShareMapRequest`, so cache-key drift becomes
structurally impossible and the reason ROH-155 was filed stops existing.

`ShareRouteSegments.from(_ segments: [RideSegment]) -> [[Coordinate]]` in AuraKit is still worth
landing, for a smaller reason that should be stated as the smaller reason it is:
`ShareCardContent` (what the card draws) and `RideSummaryView.routeSegments` (what the on-screen
map draws) should not be able to disagree about which route this ride is. Consistency between
two views of one ride, not cache-key protection.

No test will assert `ShareCardContent.routeSegments == ShareRouteSegments.from(ride.segments)`.
Once `ShareCardContent` calls `from`, that is `f(x) == f(x)`; it cannot fail. The first version
of this spec proposed exactly that test three paragraphs below the sentence "a test that passes
against both behaviours is not testing this change." Existing `ShareCardContent` coverage
exercises the behaviour and the shared function inherits it.

## Testing

This is a deletion, so verification is mostly negative and mostly not unit tests.

- Package suite and app build stay green. `SharePipelineSlotTests` is untouched; the slot does
  not change.
- `ShareCardContent` coverage of `routeSegments` continues to pass through the shared function —
  grouping preserved, runs under two points dropped — on both the plain and paused golden
  fixtures.
- **Device pass, ride end.** End a real ride, confirm the map still upgrades in place, and time
  it. This is the only way to know what the deletion actually cost; the 0.2–0.7 s above is read
  off the code, not measured.
- **Device pass, History warm open.** Confirm no change, since this path never had a prefetch.
- While on device: whether the 0.8 s sleep can shrink without hitching the entrance animation.

## What was rejected and why

The first version added `var interested: Int` to `Slot` so a ceiling cancelled only when the
last same-key caller withdrew. Recorded because the reasons it fails are properties of the
subsystem rather than of the proposal, and the next person to have this idea should find them
here.

- **The benefit is ~200 ms.** `race()` arms a fresh ceiling per caller from its own join, so the
  summary times out 20 s after it joined regardless of who owns the slot. Refcounting moves the
  pipeline's death from `prefetch + 20 s` to `summary + 20 s`; the summary gets `nil` in both.
- **Pipeline lifetime becomes unbounded.** With a per-caller ceiling gated on a count, the
  pipeline dies 20 s after the *last* join and each new join buys another 20 s, with no cap. A
  reviewer transcribed the design and drove it: ten ceilings, `cancel()` never delivered once.
- **The wedge would be self-sustaining and slot-wide.** The trickle of same-key callers keeping
  a stuck pipeline alive is riders retrying *because it looks broken*, and the slot is exclusive,
  so one immortal pipeline takes down every other ride's map for the session. `task.cancel()` is
  the subsystem's only recovery lever, and refcounting withholds it exactly when it is needed.
- **The count would measure the wrong thing.** `run` has no cancellation point, and History
  presents the summary as a swipe-dismissible sheet, so a dismissed view stays counted for a full
  ceiling. The counter would count callers whose timer has not expired, not callers who still
  want the result — which was the justification the whole design rested on.
- **It would blind its own telemetry.** `onCeiling` logs only a cancel that, in the wedge case,
  never happens, so the signal added to make wedges visible goes quiet exactly then.
- **It contradicted itself on priority.** "Refcounting makes ownership stop mattering" cannot
  coexist with "the pipeline inherits `.utility` from the prefetch." Creator identity fixes
  priority for the pipeline's whole life, and refcounting would have *lengthened* the window in
  which a foreground caller blocks on `.utility` work.

Deleting the prefetch resolves all six by removing the second caller.

## Still out of scope

The ride-end path renders the card twice and writes two multi-megabyte PNGs, and
`ShareCardFileStore.sweepOtherRides` cannot collect the current ride's accumulation.

Larger, and raised by the product reviewer as worth more than anything in this spec: the 20 s
ceiling is a resource watchdog doing double duty as the rider's timeout. The summary gets one
upgrade attempt, no terminal state and no retry, so the two commonest causes of a missing map —
being offline at ride end, and pocketing the phone during the window — both end in a spinner
that vanishes with nothing else changed on screen. That wants its own issue and probably
outranks this one.
