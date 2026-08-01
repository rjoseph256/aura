# ROH-126 — the slot watchdog cancels instead of abandoning

Date: 2026-07-30. Branch `claude/post-ride-shareable-redesign-54df82`, PR #115.
Answers blocker 2 of [the second whole-branch review](../reviews/2026-07-30-roh126-whole-branch-review.md),
which the reviewer left unpatched on the grounds that the honest fix reverses a decision
the author made on purpose and so wants the author's reasoning. This is that reasoning.

## The defect

`ShareMapSnapshotter.boundedValue`'s ceiling arm did this:

```swift
case .ceiling:
    if inFlight?.id == slotID { inFlight = nil }
    return nil
```

The identity check reads like "don't clobber a successor." What it actually tests is
whether the pipeline's own `defer` has run yet, because that `defer` is the only other
thing that clears the slot. So `inFlight?.id == slotID` is true exactly when the pipeline
is **still alive** — and that is precisely the case in which the arm frees the slot. The
next request finds an empty slot and starts a second `Snapshotter` pipeline beside the
first.

The architecture reviewer reproduced two concurrent pipelines on both different and same
keys. That defeats both invariants the class header calls load-bearing: at most one
pipeline alive, and single-flight per cache key.

The reviewers split on reachability. The skeptic pointed at the 4 s style belt and the 6 s
render belt and called 20 s unlikely. Architecture pointed at what the belts do not cover
— acceptance, composite, encode, cache write and prune all run unbounded at `.utility` —
plus app suspension, which parks both belts and the ceiling together so they fire on the
same resume. I read the suspension argument as decisive. A rider who locks the phone
during the render is not an exotic case; it is the normal way people use a phone after a
ride.

## Why the watchdog was written this way

The watchdog is not gratuitous. `ShareMapSnapshotter` is an app-lifetime singleton, and a
pipeline that never returns would hold the slot forever: every later request parks behind
it, and the share map is dead for the rest of the session. The ceiling exists to make that
unrecoverable state impossible.

The trouble is that it was built out of the one tool left after plan erratum (a) removed
the other. Erratum (a) reads:

> the spec's `withTaskCancellationHandler`/`onCancel` provision is dropped — the pipeline
> task is coordinator-owned and nothing ever cancels it, so boundedness comes solely from
> the timeout arms

With cancellation off the table, a watchdog that wants to stop waiting on a pipeline has
only one move available: forget about it. Abandonment is what is left when you cannot
cancel.

## Why reversing erratum (a) is right

**The erratum was correct about the design it reviewed, and the design then changed under
it.** An earlier draft of this note accused the erratum of circular reasoning — of deleting
the cancellation path and then citing its absence. A review round refuted that, and the
refutation is right. Grep the plan for `ceiling` or `watchdog`: the only hits are
`contextCeiling`, a layout metric, and the erratum sentence itself. The spec has none. The
pinned Step 3 shape in the plan is a bare `while let current = inFlight { _ = await
current.task.value }` with no ceiling and no `cancel()` anywhere. So when the erratum said
"nothing ever cancels it," that was an accurate description of a design in which, in fact,
nothing did. It is also not true that removing `withTaskCancellationHandler` removed a
canceller: that provision is the pipeline's *response* to cancellation, not a caller of
`Task.cancel()`.

What actually happened is narrower and more ordinary. The 20 s slot watchdog was invented
during implementation, after the plan review, and it is the thing that wants to cancel. It
arrived into a pipeline whose ability to respond to cancellation had already been removed
for good reasons that no longer applied — so it reached for the only move left, which was
to forget the pipeline instead of stopping it. The erratum did not cause the defect. It
stopped being true, and nothing rechecked it.

**Its conclusion is what fails.** "Boundedness comes solely from the timeout arms" is false
for the pipeline as built. The 4 s and 6 s belts bound two of the eight steps. Acceptance,
composite, PNG encode, cache write and prune have no belt at all — which is precisely why
the ceiling had to be added. The erratum's conclusion was already failing in the code
written under it.

**Abandonment trades a recoverable failure for an unrecoverable one.** A slot held by a
slow pipeline is a delay: the pipeline ends, the slot clears, the feature works again.
Two live `Snapshotter` pipelines are two multi-megabyte renders and two sets of SDK
resources contending at exactly the moment the first one was already too slow — the
condition that triggered the watchdog is the condition abandonment makes worse. The
watchdog was trying to avoid a wedge and bought a stampede.

**The two jobs were conflated.** The ceiling has one legitimate job: stop making *this
caller* wait. Freeing the slot is a different job, and it belongs to whoever can establish
that the pipeline is actually dead. Only the pipeline can establish that. Once you
separate them, the fix falls out and the identity check stops being load-bearing.

## The design

**The slot is occupied exactly while a pipeline is alive.** Nothing but the owning
pipeline's own unwind clears it. The one-pipeline invariant becomes structural rather than
something an identity comparison defends.

**The ceiling cancels and returns.** The owner's ceiling arm calls `task.cancel()` and
hands its caller nil. It does not touch the slot.

**Only the owner cancels.** A waiter's ceiling returns nil to that waiter and nothing
else. A waiter must not kill a pipeline it does not own, and it must not loop — looping
would park it for another full ceiling. The owner arms its ceiling when it creates the
task, so the owner's ceiling always fires before any joiner's; a joiner cancelling would
be redundant at best and a stray kill at worst.

**Cancellation is made real, which is the actual erratum-(a) reversal.** `task.cancel()`
against the pipeline as written did nothing: neither latch await is a cancellation point,
and the detached tail does not inherit cancellation. So:

- `loadStyle` and `renderMapRasterWithChrome` get `withTaskCancellationHandler`. A
  cancelled pipeline resolves its latch immediately instead of waiting out the 4 s or 6 s
  belt. The render's `onCancel` performs the same teardown the 6 s belt already performs,
  in the same cancel-before-resolve order, hopped to the main queue — `Snapshotter.cancel()`
  is main-thread-only, and the hop also guarantees the teardown lands after the
  synchronous store-then-start, which is what keeps an already-cancelled task from
  resolving the latch before there is a continuation to resume.
- `runPipeline` checks `Task.isCancelled` **before** starting an expensive stage and never
  after finishing one. There is exactly one such gate, ahead of the camera fit and the
  render, plus an entry check so a load that has already been given up on is never started.

**Nothing past the render is gated, including persist.** Two review rounds killed an
earlier version that checked after the render and after acceptance, and the argument that
killed it is worth keeping: the ceiling is 20 s and the belts are 4 s and 6 s, so a
pipeline still alive when the ceiling fires has cleared both by definition and can only be
in the tail. A late check therefore fires *exactly* when the raster is already in hand. It
would have saved a 90×60 downsample and one draw and thrown away ten seconds of style load
and SDK render — and, with no negative cache and the write skipped, made the next request
pay all of it again. The spec pins this directly (§step 7: the write is "not guarded on
cancellation — an accepted raster is worth keeping"). The old abandoning watchdog got this
right by accident: it let the pipeline finish and warm the cache, so a rider who lost the
map at ride end got it instantly on the next History open.

So cancellation here means *stop waiting*, not *discard work*. Its whole value is cutting
the 4 s and 6 s waits short; past the render the pipeline holds no `Snapshotter` and
finishing costs the slot a few hundred milliseconds of bounded CPU and disk.

## What this costs

**A wedged pipeline now holds the slot until it unwinds rather than being forgotten at
20 s, and that failure does not recover.** Being plain about the shape: `ShareMapSnapshotter.shared`
is an app-lifetime singleton with no reset, so a pipeline that ignores cancellation means
every later request on a cache miss blocks a full ceiling and returns nil, for the rest of
the process. The old code did recover from this — by starting a second pipeline, which is
the defect. This is a deliberate trade of a rare unrecoverable failure against a common
invariant violation, not a free win, and an earlier draft of this note undersold it as
"holding the slot makes it visible." It does not make it visible. `onCeiling` does, which
is why it exists: a run of ceiling log lines across different keys is that failure, and
without them it reads from outside as the share map quietly stopping.

Both reviewers walked all five stages and neither could construct a pipeline that never
terminates: each detached stage is bounded CPU or a bounded directory walk, and both latch
stages now resolve on cancellation. So the wedge needs an SDK callback stranded or a main
thread hung, and the latter kills the app anyway. That is the basis for accepting the
trade — not a claim that every stage is belted, which is false: the three detached tail
stages have neither a belt nor a check, because a check in front of a stage does nothing
once the stage is entered.

## Known and not addressed here

**The slot's owner is structurally the caller that discards the result.** `prefetchShareMap`
fires at ride end + 0.7 s from a detached task that throws its result away; the summary
requests at ~0.8 s and joins. So the prefetch always owns the slot and the summary — the
only caller a rider can see — is always a waiter, which means the prefetch's ceiling is the
one that cancels. Removing the late gates defuses most of the harm (an accepted raster is
now composited and cached regardless), and the owner's ceiling fires ~0.1 s before the
waiter's anyway, so the summary was about to give up regardless. But the type has no notion
of a joiner keeping a pipeline alive, and "only the owner cancels" is justified in terms of
who is entitled rather than who is interested. Recorded rather than fixed: reversing it is
a design change to the prefetch, not to the slot.

Also still open from the review: a ceiling returns nil indistinguishably from "no
acceptable map", `raster(for:)` has no cancellation point of its own, and
`RideSummaryView`'s `.task` gets exactly one attempt. Those are the retry story, not the
invariant, and they want the device pass from blocker 3 first.

## Where it lives

The slot machine moves out of `ShareMapSnapshotter` into `SharePipelineSlot` in AuraKit —
generic over the result, with an injectable ceiling timer, no MapboxMaps and no UIKit.
That is what closes blocker 4 for this region: the app target has no unit-test target at
all, so the confirmed defect lived somewhere no test could reach it. It is now package
code with `SharePipelineSlotTests` covering the same-key join, the never-two-pipelines
invariant, the ceiling-then-new-request sequence that reproduced the defect, and the
cancellation itself.

`ResolveOnceLatch` comes along for the ride. The pipeline had hand-rolled the same
resolve-once shape three times; the cancellation path needs a fourth property — tolerating
a resolution that arrives before the continuation does — and that is worth writing once
with the reason attached. Two of the three sites now use it; `SnapshotBox` still hand-rolls
it because it also owns a non-Sendable `Snapshotter` under the same lock.

Its first version kept "resolved" and "the value" in separate fields and had `attach`
consult only the second, which left a representable state where a waiter parked on a latch
that could never fire again. Both reviewers reproduced it. The outcome is now written once
and never cleared, so it is both the flag and the value and the permanent-suspend state is
unrepresentable rather than merely unreached. `ResolveOnceLatchTests` pins the orderings.

## Two invariants that nothing can enforce

Written down because both reviewers independently named them, and neither is checkable by
a test:

1. **`renderMapRasterWithChrome` must stay `@MainActor` and must not suspend before
   `box.store`.** The cancellation arm's safety is a three-link chain — an already-cancelled
   `onCancel` runs synchronously on the cancelling thread, that thread is main because the
   method is main-actor, and the main-queue hop therefore cannot be dequeued until the
   synchronous store-then-start has finished. Make the method `nonisolated` and the chain
   breaks silently into a permanent suspend. It now carries a `MainActor.assertIsolated()`
   and a comment at the line that depends on it; that is the most enforcement available.
2. **The pipeline must observe cancellation promptly, or the singleton is dead for the
   session.** The enforcement cannot live in AuraKit, which is where the tests are.
