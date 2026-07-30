# ROH-126 share-card redesign — second whole-branch review

Date: 2026-07-30. Branch `claude/post-ride-shareable-redesign-54df82`, PR #115, reviewed
after `origin/main` was merged in (the merge brought ROH-101 and ROH-107 onto the branch).

Three independent reviewers, refuting stance, distinct lenses, no shared context:
skeptic (claims), product (the rider), architecture (concurrency and failure modes).
This is a second gate — the branch already carried its own whole-branch review, whose
fixes are commit `14385f0a`.

Findings are recorded here rather than only in a PR comment because three of them are
decisions, not patches, and a decision that lives in a comment thread is a decision
nobody can find in six months.

## Fixed on the branch

**The acceptance gate accepted half-blank rasters.** `texturedCellFraction` was 0.5 and
the comparison is `>=`, so a raster blank on any half scored exactly 8/16 and shipped.
That is what a single missing tile column looks like at the fit zoom, which is the most
common partial load there is. The skeptic reproduced the pipeline's downsample against
the shipped fixture and measured it in all four orientations, and further showed that at
`stddevThreshold = 1.0` a cell of flat background plus ONE differing pixel scores ~2.7 and
counts as textured — eight specks out of 4,590 sampled pixels also passed. The 4.0 → 1.0
retune did not move that boundary, it removed it.

The compounding part: an accepted raster is composited and written to the disk cache,
cache hits skip acceptance entirely, and there is deliberately no negative cache. One bad
accept serves that ride a broken card from the fast path permanently.

Raised the fraction to 0.875 (14 of 16) rather than touching the stddev floor, because
raising the floor re-opens the false-reject the tuning existed to fix and there is no data
to re-tune it against. The real capture scores 16/16, so 14/16 keeps two cells of slack for
a legitimately low-texture corner. Added the 8/16 boundary test — the one value the
comparison actually decides, which the suite stepped around by pinning 4/16 and 6/16 and
then jumping to fully textured — plus a test pinning what one stray pixel does, so nobody
re-derives the partial-load defense from the stddev floor again.

**A same-key duplicate pipeline.** The same-key join in `ShareMapSnapshotter.raster(for:)`
was tested once before the wait loop, not on each lap. Two waiters for one key queued
behind an unrelated pipeline both wake when it clears; one claims the slot, the other waits
out that pipeline and then starts a second one for the same key. On success the in-pipeline
cache read absorbs it; on a reject nothing is cached, so it runs the full pipeline again
with the hint still up. The join is now tested every lap.

**The unfinished-note budget (introduced by the merge commit, mine).** Two reviewers found
it independently and both were right. The band's slack was 0.19 pt, and the ceiling it was
computed against was a scaled caption metric with two defects: the note is a `Label`, whose
height is the taller of symbol and text, and the SF Symbol "clock" at 11 pt measures ~14 pt
against a ~13 pt text box — so the glyph set the height, not the text the ceiling came from.
The comment's own stated arithmetic (16.0 × 11/12 + slack = 15.167) also disagreed with the
constant it justified (15.0), by more than the entire margin.

The row's height is now pinned by the view with `.frame(height:)` and the sparkline dropped
to 20 pt, so the budget is a fact the layout enforces instead of a prediction a font can
exceed, and the unfinished variant carries the same slack the finished one ships with. The
test says plainly which rows are measured and which are pinned. The previous version could
not have failed on a real overflow, which is the shape this repo's process notes call out.

One correction to the architecture reviewer, from the skeptic: overflow here does not clip.
`readoutBand` has no `.clipped()` and has 16 pt of bottom padding, so an overrun would push
the stats row and wordmark toward the edge rather than cutting the disclosure off.

## Needs a decision, not a patch

### 1. The card now publishes a labeled map of wherever the rider started. BLOCKING.

Before this branch the card drew a bare polyline on a dark background — a shape with no
coordinate system, genuinely unplaceable. It now draws a real basemap in the rider's chosen
style, which may be the light `.standard` with street names and building footprints. At
`maxZoom = 16` against the ~22 m minimum accepted route span, the frame is roughly a
330 × 220 m window; the route's start and end are stroked with round caps, so both endpoints
are visible markers at the exact coordinate. An out-and-back from home puts the rider's
front door on an image designed to be posted publicly.

Nothing in the spec, the plan, the handoff, the PR body or the diff mentions this. Three
adversarial spec rounds, three plan rounds and a whole-branch review all passed over it.
Aura has no privacy surface at all today. Strava, Ride with GPS and Garmin all ship start/end
hiding and treat it as a headline control.

This is a product decision and it belongs to the PO. It is recorded here because right now
the decision has not been made — it happened. The cheapest honest version is a start/end trim
in `ShareRouteGeometry.prepare`, where it is pure and package-testable and the cache key
already versions on the route content hash so it invalidates for free, plus a one-time
disclosure the first time a map card is produced.

Sequencing note: a trim changes route hygiene, which changes the content hash, which changes
cache keys. Doing it after the remaining fixes means redoing them.

### 2. The slot watchdog abandons rather than cancels.

`ShareMapSnapshotter.boundedValue`'s ceiling arm clears the slot without cancelling or
observing the pipeline that owns it, and the identity check that reads as "don't clobber a
successor" in fact confirms the pipeline being abandoned is still alive. The architecture
reviewer reproduced two concurrent pipelines by executing a faithful transcription of the
state machine, on both different keys and the same key — defeating both invariants the class
header states as load-bearing.

The reviewers disagree on reachability. The skeptic called it unlikely given the 4 s style
and 6 s render belts; architecture argued from what those belts do not cover — acceptance,
composite, encode, write and prune all run unbounded at `.utility` — plus app suspension,
which parks both the belts and the ceiling so they fire together on resume.

Not fixed here. Plan erratum (a) deliberately dropped `withTaskCancellationHandler`, so the
honest fix reverses a decision the author made on purpose, and rewriting another engineer's
concurrency machine without their reasoning is how a review finding becomes a worse bug. It
needs its own design round with the author.

Related and unfixed: `raster(for:)` has no cancellation point, `RideSummaryView`'s `.task` is
guarded by `shareImage == nil` and gets exactly one attempt, and a ceiling returns nil
indistinguishably from "no acceptable map" — so a rider who locks the phone during the
window loses the map for that whole presentation with no retry.

### 3. Swap-while-sheet-open is still unverified.

The spec named this a risk requiring device verification AND designed the mitigation (a swap
latch) for if it failed. Verification was deferred; the latch was not built. The ride-end path
is engineered to land the swap ~8 s after the summary appears, squarely inside the window
where a rider may already have tapped Share.

Deliberately not patched. There is no clean way to observe a `ShareLink`'s presentation state,
so any latch written now guesses at UI state that the device pass was supposed to establish.
Guessing here risks pinning the fallback card permanently for a rider who taps Share once.
This is the top item on the device pass, and if the sheet does misbehave the latch design is
already in the spec.

### 4. Coverage stops exactly where the risk starts.

`ShareMapRasterProviding` has one implementation, no stub, and zero test files. The 780 green
package tests cover six pure functions on either side of the seam. Untested by construction:
the entire slot state machine (where the confirmed defect above lives), the style-load belt,
the disk cache read/write/prune interleavings, `ShareCardFileStore`'s sweep, `RideCardRenderer`'s
three failure exits, and `RideSummaryView`'s fallback-then-upgrade state machine. `fitCamera`'s
"mutate, never rebuild" rule — the sole enforcement of the route-clear-of-attribution ToS
invariant — is enforced by a comment.

## Smaller, recorded, not fixed

- The plan required real fixture crops of all three styles before the thresholds could be
  called tuned; one shipped, and there is no fixture of a degraded real capture at all. Not
  in the five recorded errata.
- The cache key omits `cameraPaddingTop/Sides/Bottom`, `maxZoom` and `mapChromeStripHeight`.
  Changing the bottom padding — e.g. because an SDK update grew the attribution chip — leaves
  every warm entry serving cards drawn under the old padding, with no invalidation.
- "The Share button enables as fast as it does now (the same synchronous fallback render)" is
  false: `RideCardRenderer.make` is now async with two actor hops, and the write target moved
  to a path requiring `createDirectory`, a new failure mode whose consequence is Share disabled.
- "Instant warm" History reopen pays an unconditional 0.8 s sleep before the cache probe, then
  renders the card twice and writes two multi-MB PNGs where the pre-branch code did one.
- `ShareCardFileStore.sweepOtherRides` skips the current ride's subtree unconditionally and
  nothing else collects it, so repeated reopens of one ride accumulate ~2 MB per presentation
  that no sweep can reach.
- Route decimation caps 600 points per segment with no total cap, and segment count became
  rider-controlled when pause/segmented rides shipped. A 40-stop commute hands ~24,000
  coordinates to a synchronous main-actor camera fit and a per-point projection inside the
  render window.
- The prefetch's route expression is hand-copied in three files with a comment requiring it to
  stay in lockstep with `ShareCardContent.routeSegments` and nothing enforcing it. Drift is
  silent: the prefetch renders one key, the summary requests another.
- On a reject the "Adding your map…" hint disappears with nothing changed on screen. Every
  reject reason is logged — to Console, for the developer. The rider gets silence.
- At the ~130 pt feed thumbnail the handoff verified, the unfinished note renders at ~4 pt
  while the hero distance renders at 17.3 pt. On that surface the distance is legible and its
  qualifier is not, which is the outcome the note exists to prevent. Whether the note belongs
  on this card at all is a product question the merge did not settle.

## Verification of this pass

780 package tests and all XCTest suites pass, SwiftLint `--strict` clean, app builds for
iPhone 17, and CI is green on all five jobs including the toolchain canary. None of that
touches the four items above, which is the point of recording them.
