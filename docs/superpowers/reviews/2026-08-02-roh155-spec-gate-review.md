# ROH-155 — adversarial spec gate

Date: 2026-08-02. Three independent reviewers (`review-skeptic`, `review-product`,
`review-architecture`), dispatched fresh with no shared context.

**Read this if you are the session driving ROH-155.** This gate ran from a second session that
attached to the same worktree, found the detached spec commit `7265040` unreachable from any
branch, and rescued it onto
`adaws96/roh-155-share-map-prefetch-cancel-authority-follows-arrival-order`. Both spec revisions
are now pushed. That session has stopped rather than implement alongside you; this file is what
it produced.

**The spec changed under the reviewers, which turned out to be useful.** `ef15d9d` landed at
21:26 while they were running. So `review-architecture` and `review-product` reviewed v1
(`f24ed0d`, refcounted interest) and `review-skeptic` reviewed v2 (`ef15d9d`, delete the
prefetch). v2 has otherwise never been through a gate, and the skeptic found two blockers in it.

---

## v1 (refcounted interest) — all three reviewers reject it

This is independent corroboration of what v2's revision note already records, reached without
sight of it. Worth keeping only because two of the reasons are properties of the subsystem that
outlive the proposal.

- **The benefit is the arrival skew, not the summary's map.** `race()` arms a fresh ceiling per
  caller from its own join (`SharePipelineSlot.swift:144-148`), so the summary times out 20 s
  after *it* joined either way. It gets `nil` at ~20.8 s in both designs.
- **`interested` would not have measured interest.** `run` has no cancellation point anywhere:
  `race` parks in a non-throwing `withCheckedContinuation` and both arms are unstructured
  `Task {}`. A rider who leaves the summary cannot withdraw. The counter would count callers
  whose timer had not expired, which is the justification the design rested on.
- **Pipeline lifetime becomes unbounded.** Reproduced: ten ceilings, `cancel()` never delivered
  once. Lifetime grows as `last join + ceiling`, uncapped, with the exclusive slot held throughout.
- **A rider could lose a map they get today.** A different-key waiter benefits incidentally from
  the owner's `task.cancel()` freeing the slot. Remove that and ride B waits out its own ceiling
  and gets nil.

## v2 (delete the prefetch) — two blockers

### BLOCKER 1 — the #1-ranked problem is false; Swift escalates the priority

v2 line 20: *"The pipeline runs at the wrong priority for its whole life."* It does not. The
skeptic reproduced `SharePipelineSlot`'s exact shape — a `Task {}` created inside a `.utility`
detached caller, then joined by a `.userInitiated` caller awaiting `task.value` through an inner
unstructured `Task` inside a `withCheckedContinuation`, which is `race` at
`SharePipelineSlot.swift:149-154`:

```
pipeline start prio: TaskPriority.low     // .utility
pipeline late  prio: TaskPriority.high    // .userInitiated, once the summary joins
```

Escalation reaches even an explicitly `Task.detached(priority: .utility)` task awaited via
`.value`, which is what the three tail stages are (`ShareMapSnapshotter.swift:240`, `:388`,
`:420`).

So the mispriority window is the arrival skew — the same 0.2–0.7 s v2 dismisses four lines later
as the smallest of the three problems. The descending-cost ordering is backwards, and the table
row promising `.userInitiated` after the change describes something the code already does. v2
asserts this as fact while prescribing no measurement of priority; the previous revision had
concluded priority *"wants measurement before a change, not a guess."*

This does not sink the deletion. It removes its headline justification, so the case has to be
made on the two remaining items.

### BLOCKER 2 — "the History path is untouched" is false, and the device plan tests the one case that cannot regress

Today `prefetchShareMap` is a `Task.detached` (`ShareMapRasterProviding.swift:49`) fired from the
HUD, so it outlives the summary view and warms the cache no matter what the rider does next.
After deletion the only request is `RideSummaryView.swift:165`, sitting behind
`try? await Task.sleep(for: .seconds(0.8))` and `guard !Task.isCancelled`
(`RideSummaryView.swift:151-152`).

A rider who taps Done inside that ~1 s window — `onDone` pops the pushed summary and cancels its
`.task` — now issues **no raster request at all**. Same when the fallback render fails (`:145`).
Opening that ride from History later is a cold pipeline where today it is instant. Ending a ride
and immediately dismissing is not an exotic path.

v2's device step is *"History **warm** open. Confirm no change"* — structurally the one History
case that cannot regress. The case that does regress is: end a ride, dismiss inside a second,
then open that ride from History.

Cache warming does survive dismissal *after* the request is issued — the pipeline `Task`
(`SharePipelineSlot.swift:117`) is unstructured and `persist` (`ShareMapSnapshotter.swift:251`)
is not cancellation-gated. The regression is bounded to pre-request dismissal.

### SERIOUS — the 0.8 s sleep quietly becomes the only frame-safety floor

v2 keeps it, justifies it by the warm-cache upgrade render, and invites shortening it on the
device pass. The recorded reason is different and stronger:
`docs/superpowers/specs/2026-07-29-roh126-share-card-redesign-design.md:248-253` and `:305-307`
hold the pipeline out of the push transition because the SDK's compositor pass runs on the main
queue and there are transiently two live `Map`s; ROH-126 required that be device-verified
(`:333`). With the prefetch gone the sleep is the only thing still doing that job. Say so in the
spec, or a later tuning pass shortens it and reintroduces a defect ROH-126 designed against.

The substitute rationale also undercuts itself: an identical 1080×1350 `ImageRenderer` pass — the
fallback card — already runs on the main actor before the sleep, inside the entrance window
(`RideSummaryView.swift:141`).

### SERIOUS — the whole-track walk moves back onto the main actor, inside the entrance window

`ShareMapRasterProviding.swift:36-41` records the detached prefetch's second purpose: the segment
flattening plus `ShareRouteGeometry.prepare` runs off-frame. After deletion the only
`ShareMapRequest` construction is `RideSummaryView.swift:146`, synchronous on `@MainActor`, and
`prepare` walks every point of every segment four times (`ShareRouteGeometry.swift:20-36`,
`:76-92`). The ROH-126 review sized a 40-stop commute at ~24,000 coordinates. v2's cost section
inventories latency only and never mentions this.

### SERIOUS — the numbers do not hold together

The same quantity is 0.2–0.7 s when it is a cost (line 15, line 71) and "~200 ms" when it is a
benefit (lines 43-44, line 125) — up to 3.5× apart, and "the benefit is ~200 ms" is the
first-listed reason v1 was rejected. "3–7% of a 6–12 s pipeline" does not follow from its own
inputs (0.7 ÷ 6 = 11.7%, 0.2 ÷ 12 = 1.7%; the honest range is ~2–12%), and "6–12 s" appears
nowhere in the code — `ShareMapSnapshotter.swift:105` documents "the ≤10 s pipeline."

### SERIOUS — the claimed test coverage does not exist as described

v2 lines 109-111 claim `ShareCardContent` `routeSegments` coverage "on both the plain and paused
golden fixtures." Only `PausedGoldenRideFixtureTests.swift:58` touches a golden fixture, and it
asserts `routeSegments.count == 2` and nothing else. There is no plain-golden assertion on
`routeSegments`; the "runs under two points dropped" case lives in `ShareCardContentTests.swift:110-116`
on a hand-built `Ride`. Since v2 declines to write a new test for `ShareRouteSegments.from` — and
the argument for declining is correct, it would be `f(x) == f(x)` — this inherited coverage is
the whole verification story for that change. The inheritance needs to be real.

### MINOR

- Stale line refs: `RideSummaryView:39` is `:45-47`; `RideSummaryView:140` is `:151`. The
  `ShareCardContent:51`, `ShareMapRasterProviding:51`, `RideHUDView:232` and
  `NavigateHUDView:263` refs are correct.
- The `Sendable` bullet defers the outcome to the compiler and the Testing section has no step
  for it. `Ride` is already `Sendable` (`AuraCore/Sources/AuraCore/Models/Ride.swift:3`), so the
  Sendable-capture half of the `[RideSegment]` rationale is wrong wherever it survives; the
  deferred-walk half stands on its own.
- `ShareRouteSegments` next to the existing `ShareRouteGeometry`, both deriving routes, with
  `from(_:)` feeding `prepare(segments:)`. `ShareRouteGeometry.segments(from:)` keeps one
  namespace for one pipeline.
- The "three reviewers rejected it" and "ten ceilings" evidence lives nowhere a later reader can
  check. This file is partly an attempt to fix that.

## What survived every attack

- The one-pipeline-alive and single-flight-per-key invariants hold under both designs.
- `ShareRouteGeometry.prepare` re-applies `.filter { $0.count > 1 }` (`ShareRouteGeometry.swift:21-23`),
  so the caller-side filter contributes nothing to `contentHash`. v2 is right to downgrade the
  drift problem, and right that real key drift needs regrouping rather than dropping a short run.
- `RideSummaryView.routeSegments` is display-only — it feeds `StaticRouteMap` and never a cache
  key. v2 is right that there are two key-feeding copies, not three.
- Each caller arms its own ceiling from its own join. Both specs turn on this and it is true.
- v2's deletion inventory is exact: `ShareMapRequest(` has two production call sites,
  `shareMapBox` is referenced only at `RideHUDView.swift:17,232` and `NavigateHUDView.swift:32,263`.
- With the prefetch gone, cache-key drift is structurally impossible. That claim holds.

## Prioritisation

The product reviewer's verdict, independent of v2 and agreeing with the note v2 already carries:
the 20 s ceiling is a resource watchdog doing double duty as the rider's timeout. The summary
gets one upgrade attempt, no terminal state, no retry, so being offline at ride end or pocketing
the phone during the window both end in a spinner that vanishes with nothing else changed on
screen (`RideSummaryView.swift:107-114`, `:167`, `:174-175`). The ROH-126 whole-branch review
already recorded it as "the rider gets silence"
(`docs/superpowers/reviews/2026-07-30-roh126-whole-branch-review.md:183-184`). It wants its own
issue and it outranks this one.

Also flagged as more likely to be felt than anything in this spec: the main-actor track walk on
the summary entrance, which degrades with ride length and is on the same screen.

## On device verification

For v1 the honest answer was that a device pass could not distinguish a correct implementation
from a broken one — the ceiling only fires on a starved main queue, and `ShareMapSnapshotter`
constructs the slot with the default ceiling and no injected timer (`:129`). Worth saying in the
Linear issue rather than letting the requirement collect a checkbox that proves nothing.

v2's deletion is different: it is meaningfully device-verifiable, because it changes a latency a
person can watch. Time the ride-end upgrade, and add the cold-History case from BLOCKER 2 —
end a ride, dismiss within a second, then open it from History.

---

*`humanizer` is not installed on this machine at user or repo scope, so this document did not go
through it, contrary to the repo's prose rule.*
