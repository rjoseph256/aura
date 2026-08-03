# ROH-155 — cancellation follows interest, and the route is derived once

Date: 2026-07-31. Branch `claude/post-ride-shareable-redesign-54df82`, follow-up to ROH-126.
Both reviewers of the blocker-2 fix (`4cd429e`) reached these independently; that commit
recorded them rather than fixing them.

## Problem 1 — the party with no stake holds the kill switch

`SharePipelineSlot` lets the caller that created a pipeline cancel it, and nobody else. At
ride end that is structurally the wrong caller.

`ShareMapProviderBox.prefetchShareMap` fires from both HUDs when a ride finishes, sleeps
0.7 s inside a detached task, calls `raster(for:)`, and discards the result —
`_ = await provider.raster(for: request)`. `RideSummaryView`'s `.task` renders the fallback
card, sleeps 0.8 s, and calls `raster(for:)` at roughly +0.9 s. The ordering is fixed by
construction, not by luck: the prefetch always owns the slot, and the summary — the only
caller a rider can see — is always a waiter.

So the prefetch's 20 s ceiling, armed 0.9 s earlier, cancels the pipeline the summary is
waiting on. Nothing in the type expresses which caller wants the result; a waiter cannot
signal that it is still interested; and "owner" means only "arrived first," which is a
timing accident.

Two mitigations already in place keep this from being urgent. The owner's ceiling fires
about 0.1 s before the waiter's, so the summary was nearly out of time anyway, and since
`4cd429e` a cancelled pipeline that has an accepted raster still composites and caches it.
Neither addresses the inversion; they cap its cost.

## Problem 2 — the route derivation can drift, and drift inverts the prefetch

`ride.segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }` appears three
times: `RideSummaryView:39`, `ShareMapRasterProviding:51`, `ShareCardContent:51`. A comment
asks them to stay in lockstep. Nothing enforces it.

They feed `ShareMapRequest.cacheKey`. The ROH-126 review recorded the failure as "the
prefetch is wasted," which is too kind. There is one pipeline slot. On divergence the
prefetch occupies it under a *different* key, so the summary is no longer a joiner — it is
a different-key waiter, and it must wait out a full pipeline it cannot use before starting
its own. The optimization inverts into roughly double the latency, silently, with both
paths individually correct.

## Design

### Interest replaces ownership

`Slot` gains `var interested: Int` — the number of callers waiting on *this* pipeline for
*its* key. The creator starts it at 1. A same-key joiner increments on join. Both paths then
converge on one function, so there is exactly one place a withdrawal can be missed:

```swift
private func waitOnPipeline(task: Task<Value?, Never>, id: UUID, key: String) async -> Value? {
    let outcome = await race(task)
    let remaining = withdrawInterest(from: id)
    switch outcome {
    case .finished(let value):
        return value
    case .ceiling:
        if remaining == 0 { task.cancel() }
        onCeiling?(key, remaining == 0)
        return nil
    }
}
```

Withdrawal happens before the decision, because "am I the last" is a question about the
state *after* this caller leaves.

`withdrawInterest(from:)` is identity-guarded and returns 0 when the slot has already turned
over. Cancelling in that case is safe: turnover only happens after the departing pipeline's
`defer`, which runs when its task completes, so the `cancel()` lands on a finished task and
is a no-op.

**Different-key waiters neither register nor cancel.** This is the substantive line in the
design. They are not waiting for the result — they are waiting for the *slot*. Counting them
would keep alive a pipeline whose value nobody wants, and letting them cancel is the bug
being fixed, one step removed.

`onCeiling`'s second parameter changes from `isOwner` to `isLast`. Ownership stops being
observable because it stops meaning anything; what a log reader needs to know is whether
this ceiling ended the pipeline.

At ride end the sequence becomes: prefetch creates (1), summary joins (2), prefetch ceilings
at 20.7 s and drops to 1 without cancelling, summary ceilings at 20.8 s and drops to 0 and
cancels. A prefetch with no summary behind it still cancels itself.

### One derivation

`ShareRouteSegments.from(_:)` in AuraKit, taking `[RideSegment]` rather than `Ride` so the
prefetch keeps both its deferred whole-track walk and its `Sendable` capture. A
`ShareMapRequest(rideID:rideSegments:style:)` convenience initializer applies it, so a call
site can build a request for a ride without writing the expression at all.

`ShareCardContent.init` and `RideSummaryView.routeSegments` route through the same function.
The summary keeps building its request from `content.routeSegments` — that is literally the
route the card draws, and matching what is drawn is the point — and because content now
derives through the shared function, the two agree by construction.

## Testing

Slot behaviour, in `SharePipelineSlotTests`:

- A same-key waiter keeps the pipeline alive when the first caller's ceiling fires: the work
  body observes no cancellation, and the slot stays occupied.
- The last withdrawal cancels: with both callers ceilinged, the work body observes
  cancellation.
- A different-key waiter neither counts nor keeps a pipeline alive, and its ceiling cancels
  nothing.
- `onCeiling` reports `isLast` correctly for each of the above.

Each is verified the way `4cd429e`'s were: revert to first-caller-cancels and confirm the
new tests fail. A test that passes against both behaviours is not testing this change.

Derivation, in the package:

- `ShareCardContent(ride:units:).routeSegments` equals `ShareRouteSegments.from(ride.segments)`
  on the golden fixture, including the paused fixture, so segment splitting is covered.
- A request built via the convenience initializer has the same `cacheKey` as one built from
  `content.routeSegments`. This is the invariant that actually matters — equal segments are
  the mechanism, an equal key is the requirement.

## What this costs

**Wedge exposure widens.** A stuck pipeline now survives until every same-key caller times
out, rather than until the first does. With a steady trickle of same-key callers it could
stay alive indefinitely. This is judged correct — those callers do still want the result, and
cancelling out from under them is the defect — but it is a trade, and `onCeiling` logging is
what makes it visible.

**A joiner arriving during an unwind still resurrects interest in a doomed pipeline.**
A same-key caller that arrives after the count hit zero but before the cancelled pipeline has
unwound increments to 1 and inherits its nil. Behaviour is unchanged from today and already
pinned by `testSameKeyRetryDuringUnwindJoinsTheDyingPipeline`; refcounting neither fixes nor
worsens it.

**Ride-end ownership is deliberately unchanged.** The prefetch still creates the pipeline.
Making the summary the owner would mean fighting the timings, and ownership is the wrong
lever precisely because it is decided by arrival order. Refcounting makes ownership stop
mattering, which survives a future third caller in a way that a correctly-assigned owner
would not.

## Out of scope

The ride-end path still renders the card twice and writes two multi-megabyte PNGs, and
`ShareCardFileStore.sweepOtherRides` cannot collect the current ride's accumulation. Both are
in the ROH-126 review's smaller-items list and neither is touched here.

Priority is also untouched: the pipeline task inherits `.utility` from the prefetch's detached
task, and the three `Task.detached(priority: .utility)` stages inside `runPipeline` do not
escalate when a foreground caller joins. An architecture reviewer raised this as unverified.
It is a real question and a separate one — it wants measurement before a change, not a guess.
