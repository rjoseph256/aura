# ROH-155 — one caller, asking early: delete the prefetch and move the summary's request

Date: 2026-07-31. Branch `claude/post-ride-shareable-redesign-54df82`, follow-up to ROH-126.

**Revision history.** Rev 1 proposed an interest refcount in `SharePipelineSlot`; three
reviewers killed it (recorded at the end). Rev 2 proposed deleting the prefetch alone; two
reviewers killed that too, and were right — on the branch's own device numbers it was a
13–47% latency regression that silently reversed a recorded product decision. This is rev 3.
The corrections that got us here are kept, because most of them are corrections to my own
asserted numbers.

## What the prefetch is actually for

The normative ROH-126 spec, §Share flow step 5, records it explicitly:

> **Accepted cost, stated**: a rider who shares within the first seconds (or in dead
> coverage) shares the polyline fallback card. Prefetch makes this rare on the ride-end
> path; the residue is accepted rather than blocking Share or adding retry UI.

So the prefetch is the named mitigation for a stated accepted cost. Its job is **to start the
pipeline early**. Everything else about it — that it owns the slot, that it discards its
result, that it duplicates the route derivation — is incidental to that job, and is where the
problems live.

That reframes the fix. The question is not "should there be a prefetch," it is "who should
ask early." Today it is a detached background task that throws the answer away. It should be
the summary, which is the only caller that wants it.

## What is actually wrong

**The summary asks late for no reason that survives.** `RideSummaryView.swift:151` sleeps
0.8 s before requesting. Its comment gives two reasons and both fail:

- *"the HUD prefetch fired at +0.7 s is already in flight and this request dedups onto it"* —
  circular. The summary waits because the prefetch already asked; the prefetch exists because
  the summary waits.
- *"History: this is the entrance-animation courtesy delay"* — protects the entrance from the
  1080×1350 main-actor upgrade render on a warm hit. Real, but it guards the wrong thing. At
  ride end a warm hit is **impossible**: `cacheKey` includes `rideID.uuidString`
  (`ShareMapRequest.swift:60-71`) and the ride has never been rendered. So on the one path
  this delay costs anything, the hazard it exists for cannot occur.

The sleep is a delay on *asking*, justified by a hazard in *drawing*. Separating those is the
whole design.

**The caller that discards the result owns the ceiling.** The prefetch creates the pipeline,
so its ceiling can cancel one the summary is waiting on. Worth ~200 ms — each caller arms its
own ceiling from its own join (`SharePipelineSlot.race`), so the summary times out 20 s after
*it* joined either way. Real, smallest of the three.

**Two derivations feed `cacheKey`.** `ShareCardContent:51` and `ShareMapRasterProviding:51`.
On divergence the prefetch occupies the single slot under a different key and the summary
waits out a pipeline it cannot use. Byte-identical today, so this is prevention.

## The design

**One caller, asking as early as it can, drawing as late as it should.**

1. **Delete `ShareMapProviderBox.prefetchShareMap`** and its two call sites
   (`RideHUDView:232`, `NavigateHUDView:263`), plus the then-unused
   `@Environment(ShareMapProviderBox.self)` at `RideHUDView:17` and `NavigateHUDView:32`.
2. **Move the summary's request earlier.** Delete the 0.8 s sleep at `RideSummaryView:151`.
   The request now fires as soon as the fallback card is written — earlier than the prefetch
   managed (~0.1–0.6 s vs 0.7 s), from the caller that wants the answer.
3. **Gate the upgrade render, not the request.** Before the second `RideCardRenderer.make`,
   wait out whatever remains of an entrance window measured from the start of `.task`. On a
   ride-end miss the raster arrives well after the window and the gate is a no-op; on a
   History warm hit it does exactly what the 0.8 s sleep did, without taxing the request.

Ordering inside `.task` becomes: build content → render fallback → build request → arm hint →
**request** → cancel hint → **wait out the entrance window if any remains** → render upgrade →
`applyOrDeferUpgrade`.

`ShareMapProviderBox` stays — `RideSummaryView` reads `shareMap.provider`, `AuraApp` injects
it.

### Why this is not a regression anywhere

| path | today | after |
|---|---|---|
| ride end, cold (always a miss) | pipeline starts 0.7 s (prefetch); map ~1.5 s | pipeline starts ~0.1–0.6 s; map same or earlier |
| History, warm | 0.8 s sleep, then instant | instant, gated only by the entrance window |
| History, cold | request at T+0.8 s | request at T |
| rider dismisses fast | prefetch is detached, survives, warms cache | request fires *before* the dismissal window; `slot.run`'s task is unstructured and also survives |
| renders per ride end | 1 (summary dedups onto prefetch) | 1 |

The fast-dismiss row is the one rev 2 got wrong and this fixes by construction: the insurance
was never the prefetch's detachment, it was that *something asked before the rider left*.

### Dead justifications to remove with it

Not optional cleanup — a comment kept for a reason that stopped being true is the exact
failure this branch has spent four commits removing.

- `AuraApp.swift:17` — "the ride-end prefetch and the summary's own request must share it" is
  the recorded reason the provider is a singleton. After this it is false. The single-instance
  requirement survives on different grounds (History reopen dedup, one slot), and must be
  restated on those grounds.
- `ShareMapRasterProviding.swift:11` — enumerates "ride-end prefetch, summary upgrade, History
  reopen" as call sites.
- `ShareMapRasterProviding.swift:12-14` — the `Sendable` refinement, justified by "the HUDs'
  detached prefetch tasks capture the existential." Try removing it; the box is `@MainActor`
  and so implicitly `Sendable`, and after the deletion the sole consumer is main-actor. If
  something still needs it, keep it and restate why.
- `ShareMapRasterProviding.swift:4` — `import AuraCore`, whose only use is `Ride`.
- `2026-07-29-roh126-share-card-redesign-design.md` §Share flow step 1 and step 5 — the
  normative spec. Step 5's accepted cost must be restated: the mitigation is now "the summary
  asks immediately," not "prefetch."
- `2026-07-29-roh126-share-card-redesign.md:16`, plan erratum (e) — records the `Sendable`
  refinement as compile-verified *because of the detached prefetch*.

### Cut from this change: `ShareRouteSegments`

Rev 2 kept a shared route derivation. Cutting it, reversing my earlier call, because the
justification did not survive: with one caller, cache-key drift is structurally impossible;
the two remaining expressions are display-vs-card and already byte-identical; no test can
assert the invariant without being `f(x) == f(x)`; and it would not fix the real duplication,
which is that the full-track walk runs **twice per summary** — once in `body` and once inside
`ShareCardContent.init`. Naming a `StaticRouteMap` helper `ShareRouteSegments` under
`Sharing/` would also bake in a wrong home. If card-vs-display consistency is worth chasing,
the fix is for the view to read `content.routeSegments`, and it wants its own issue.

## Testing

- Package suite and app build green. `SharePipelineSlotTests` untouched; the slot does not
  change.
- The `.task` reordering has no package-testable seam — `RideSummaryView` is in the app
  target, which has no unit-test target. Stating that plainly rather than inventing a test
  that would not run.
- **Device pass is the acceptance criterion, not a follow-up.** This change ships only after:
  - **Ride end, cold.** Map upgrades in place; time it and compare against the ~1.5 s the
    whole-branch review recorded on device. Must not regress.
  - **Ride end, fast dismiss.** End a ride, tap Done inside ~1 s, then open that ride from
    History. The card must be instant — proving the request outran the dismissal and warmed
    the cache.
  - **History, warm.** Must be visibly instant, no 0.8 s stall. This is a recorded ROH-126
    review complaint that this change should fix.
  - **The entrance animation.** The open question: with the request firing ~0.8 s earlier,
    `fitCamera` — a synchronous main-actor walk of every coordinate — can land inside the
    0.7 s count-up when the style loads fast. Watch the hero number on a long segmented ride.
    If it hitches, the gate moves from the render to the fit.
  - **The hint.** It now arms ~0.8 s earlier. Confirm a warm hit still cancels it before the
    0.3 s show-delay, and that it does not flash during the entrance.

## What was rejected, and the corrections that got us here

**Rev 1, the interest refcount.** Cancel only when the last same-key caller withdraws.

- Benefit ~200 ms: `race()` arms a ceiling per caller from its own join, so the summary times
  out 20 s after it joined regardless of owner.
- Pipeline lifetime becomes unbounded — dies 20 s after the *last* join, each join buys
  another 20 s, no cap. A reviewer transcribed it and drove it in-session: ten ceilings,
  `cancel()` never delivered once. (No committed artifact; the run was in the review thread.)
- Self-sustaining and slot-wide: the trickle keeping a stuck pipeline alive is riders retrying
  because it looks broken, and the slot is exclusive, so one wedge takes down every ride's map
  for the session.
- The count would measure the wrong thing — `run` has no cancellation point and History is a
  swipe-dismissible sheet, so a dismissed view stays counted for a full ceiling.
- ~~It would blind its own telemetry.~~ **This bullet was wrong.** `onCeiling` fires from both
  arms (`SharePipelineSlot.swift:110` waiter, `:133` owner), and the wedge signature the sink
  documents is the *waiter* line. Under refcounting the retriers are waiters, so telemetry
  would have got louder, not quieter. Corrected here rather than deleted, since a record kept
  for its reasoning should not contain a reason that is false.

**Rev 2, deleting the prefetch alone.** Killed by its own numbers, all of which were mine:

- "3–7% of a 6–12 s pipeline" — the denominator contradicts this branch's own device
  measurement. The whole-branch review records ~8 s as a *cold simulator* figure and ~1.5 s on
  device; `RideSummaryView:354` says the same. Against 1.5 s the skew is **13–47%**.
- "The pipeline runs at the wrong priority for its whole life" — false. A reviewer
  demonstrated that `await task.value` escalates the pipeline the moment the summary joins
  (`.low` → `.high`), and the three `Task.detached(priority: .utility)` stages escalate too
  because each is immediately awaited. The `.utility` window is the arrival skew, on a
  main-actor task.
- "Mapbox renders per ride end: up to 2 → 1" — claimed credit for a case the same spec argued
  cannot occur. The single-flight join means it is 1 today.
- It never mentioned that the prefetch is the ROH-126 spec's named mitigation for the
  mapless-share window, so it reversed a recorded product decision in silence.
- Stale citations: `RideSummaryView:39` should be 45–47; `:140` should be 151.

## Still out of scope

The ride-end path renders the card twice and writes two multi-megabyte PNGs;
`ShareCardFileStore.sweepOtherRides` cannot collect the current ride's accumulation; the
full-track walk runs twice per summary.

Larger, and ranked above this by both reviewers: the 20 s ceiling is a resource watchdog
doubling as the rider's timeout. One upgrade attempt, no terminal state, no retry — so the two
commonest causes of a missing map, being offline at ride end and pocketing the phone during
the window, both end in a spinner that vanishes with nothing changed on screen. Its own issue,
and it probably outranks this one.
