# ROH-155 — why the share-map prefetch and the summary's 0.8 s sleep stay as they are

Date: 2026-07-31. Branch `claude/post-ride-shareable-redesign-54df82`. **Closed won't-do.**

This is not a design. It is the record of three designs that were wrong, kept because the
reasons are properties of the subsystem and the next person to look at this will otherwise
repeat all three. Every correction below was found by an adversarial reviewer, and most of
them are corrections to numbers I asserted without checking.

## What was being fixed

The ROH-126 whole-branch review recorded that at ride end the share-map pipeline is created by
`ShareMapProviderBox.prefetchShareMap` — a detached `.utility` task that discards its result —
while `RideSummaryView`, the only caller a rider can see, joins as a waiter. So the party with
no stake in the result holds the cancel authority. Both reviewers of the blocker-2 fix reached
this independently and it was recorded rather than fixed.

## Why it is not worth fixing

**The inversion is worth about 200 ms.** `SharePipelineSlot.race` arms a fresh ceiling per
caller, measured from that caller's own join. So the summary stops waiting 20 s after *it*
joined, whoever owns the slot. Whatever the owner does, the summary's outcome is the same and
its timing differs by the arrival skew.

**The priority half of the complaint does not exist.** A reviewer demonstrated that
`await task.value` escalates the pipeline the moment the summary joins — `.low` → `.high` —
and that the three `Task.detached(priority: .utility)` stages inside `runPipeline` escalate
too, because each is immediately awaited. The `.utility` labels are decorative and the window
is the arrival skew, on a main-actor task whose expensive stages run on SDK threads.

**The derivation-drift half is prevention, not a defect.** `ShareCardContent:51` and
`ShareMapRasterProviding:51` are byte-identical today, and `ShareRouteGeometry.prepare`
re-applies `.filter { $0.count > 1 }` itself, so the caller-side filter contributes nothing to
`contentHash`. Real drift needs flattening or regrouping — an edit, not a runtime state.

## The three designs and how each died

### Rev 1 — interest refcount in `SharePipelineSlot`

Count callers waiting on the current pipeline for its key; a ceiling cancels only when the last
withdraws.

- Bought the ~200 ms above.
- Made pipeline lifetime unbounded: with a per-caller ceiling gated on a count, the pipeline
  dies 20 s after the *last* join and each join buys another 20 s. A reviewer transcribed it and
  drove it — ten ceilings, `cancel()` never delivered once.
- Self-sustaining and slot-wide. The trickle keeping a stuck pipeline alive is riders retrying
  *because it looks broken*, and the slot is exclusive, so one wedge takes down every ride's map
  for the session. `task.cancel()` is the subsystem's only recovery lever.
- The count would have measured the wrong thing: `run` has no cancellation point and History is
  a swipe-dismissible sheet, so a dismissed view stays counted for a full ceiling.

One rev-1 rejection reason was itself wrong and is corrected here: I claimed it would blind its
own telemetry. `onCeiling` fires from both arms (`SharePipelineSlot.swift:110` waiter, `:133`
owner) and the documented wedge signature is the *waiter* line, so telemetry would have got
louder.

### Rev 2 — delete the prefetch

Leave `RideSummaryView` as the sole caller.

- **Reversed a recorded product decision in silence.** The normative ROH-126 spec, §Share flow
  step 5: *"a rider who shares within the first seconds… shares the polyline fallback card.
  Prefetch makes this rare on the ride-end path; the residue is accepted rather than blocking
  Share or adding retry UI."* The prefetch is the named mitigation for a stated accepted cost.
- **Costed against a denominator this branch had already corrected.** I wrote "3–7% of a 6–12 s
  pipeline." The whole-branch review records ~8 s as a *cold simulator* number and ~1.5 s on
  device; `RideSummaryView:354` says the same. Against 1.5 s the skew is 13–47%.
- **Lost cache-warming for the fast-dismiss rider.** The prefetch is detached and survives Done;
  the summary's request sits behind a cancellable sleep and a `guard !Task.isCancelled`.

### Rev 3 — delete the prefetch and move the summary's request earlier

Delete the 0.8 s sleep so the summary asks immediately; gate only the upgrade render on an
entrance window. This was the best of the three and it is still wrong.

- **The sleep has a third job nobody had written down.** It debounces committing the exclusive
  pipeline slot. Because `slot.run` has no cancellation point, a cancelled caller neither
  returns nor frees the slot; the sleep plus its guard is the only thing that stops a
  sub-second History glance from committing the slot to a ride nobody is looking at.
  Reproduced against the real slot: with three glanced rides ahead of it, the ride on screen
  resolved at 2.18 s instead of 1.36 s, because the post-release wake-up is a thundering herd
  rather than a queue. This regresses the exact path the change existed to improve.
- **The gate was on the wrong artifact.** Arming the hint ~0.8 s earlier puts "Adding your map…"
  at 0.45–0.9 s against an entrance ending at 0.70 s — mid-entrance on *every* ride end, since
  ride end is always a cache miss. The hint is also not inside the staggered `.opacity` reveal,
  so it is a hard insert that shoves the Done button down. It is the one drawing operation the
  rider actually sees during the entrance, and it was the one left ungated.
- **"The entrance window" is not a constant.** 0.70 s (count-up), 0.65 s (last staggered
  reveal), or **zero** under Reduce Motion. A hardcoded gate makes the rider who asked for no
  animation wait out an animation that does not exist.
- **The warm-hit decode travels with the request, not the render.** `ShareMapSnapshotter:150`
  reads and decodes a 1080×720 PNG synchronously on the main actor inside `raster(for:)` —
  before any gate the view can place — so on History-warm the change moves a main-thread decode
  into the count-up.
- **`fitCamera` cannot be gated from the view**, so "if it hitches, move the gate to the fit"
  resolves to either reinstating the sleep or teaching a process-wide singleton about one
  view's animation. Also: `fitCamera` walks the *decimated* route (600 points per segment), so
  its cost scales with segment count, not ride length — the "long segmented ride" test
  instruction was right for the wrong reason.

## The finding worth keeping

**Ride end and History want opposite policies, and every revision failed by looking for one.**

At ride end there is one ride and one pipeline, and the rider is about to look at it. Asking
early is free, and a request that outlives dismissal is insurance that warms the cache.

In History the slot is exclusive, cancellation is unreachable from the caller, and the number
of glances is unbounded. The same behaviour is a queue of pipelines for rides nobody is
looking at, with the on-screen ride behind them.

Nothing in the slot, the provider, or the view distinguishes the two. Until something does, any
change that treats them alike is wrong in one of them — which is what killed rev 3, and in
retrospect what made rev 1 and rev 2 unsatisfying too.

## What actually landed

A comment on the sleep in `RideSummaryView`, naming all three of its jobs and the reproduction
for the third. That is the whole deliverable, and it is the right size for what was learned.

## What should be built instead

Both reviewers ranked these above ROH-155, and the ROH-126 review already carries them:

1. **ROH-139** — the privacy trim. Still BLOCKING and undecided, irreversible from the rider's
   side once a card is posted, and its sequencing note says it changes route hygiene →
   `contentHash` → every cache key, so it gets more expensive the longer it waits.
2. **Retry and terminal state on the summary upgrade.** The 20 s ceiling is a resource watchdog
   doubling as the rider's timeout. One attempt, no terminal state, no retry — so the two
   commonest causes of a missing map, being offline at ride end and pocketing the phone during
   the window, both end in a spinner that vanishes with nothing else changed on screen. Every
   reject reason is logged, to Console, for a developer.
3. **The device pass** owed since ROH-126, of which swap-while-sheet-open is the top item.
