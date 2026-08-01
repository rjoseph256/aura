# Orphaned Live Activity sweep (ROH-124) — design

Date: 2026-08-01
Issue: [ROH-124](https://linear.app/rohun/issue/ROH-124/orphaned-live-activity-survives-a-jetsam-kill-and-never-clears)
Status: revision 4, after a three-reviewer spec gate, a two-reviewer plan gate, and a
three-reviewer merge gate.

> **The `file:line` citations below were correct against `main` when written and are now stale by
> a few lines each, because the change this spec describes shifted them. Navigate by symbol name.**

Found by the product-lens reviewer on
[ROH-107](https://linear.app/rohun/issue/ROH-107). Related to Pass 5
([ROH-102](https://linear.app/rohun/issue/ROH-102)), which shipped in PR #117.

**Revision 1 claimed the orphan "confesses by dimming" and used that to argue the issue had
overstated the severity. Two reviewers refuted it from the widget source: the clock is dimmed by
nothing and keeps counting. The correction is reversed in the Problem section.** Revision 1 also
placed the sweep after `Activity.request` (the one ordering that cannot fix a slot-exhausted
request), put it in the `.task` that owns the V6 backfill's check-then-set, guarded it with a
flag that lags the ride it is meant to detect, and specified a pure policy whose signature
invited the single defect that would end a live ride's activity. Each is corrected below and
marked, because three of them change what gets built.

## Problem

`RideLiveActivityController` is a `@MainActor` singleton that holds the one
`Activity<RideActivityAttributes>` a ride owns. `update()` opens with `guard let activity`
(`RideLiveActivityController.swift:73`) and so does `end()` (`:120`). That reference lives in
memory and nowhere else.

When the process dies mid-ride, whether from jetsam, a crash, or a force quit, the activity
outlives it. iOS keeps showing it. The next launch builds a fresh singleton whose `activity` is
nil, so both paths that could clear the ghost return immediately. Nothing in the repo reads
`Activity<RideActivityAttributes>.activities`, which is the only API that can reach an activity
this process did not create. `start()` is not gated on the stored reference, which is exactly
why the second defect below exists.

1. **The ghost never clears.** iOS removes it from the Dynamic Island at the 8 hour cap and
   leaves it on the Lock Screen for up to 4 hours after that.
2. **The next ride stacks a second activity beside it.** `start()` calls `end()` defensively
   (`:45`) to prevent precisely this, and against an orphan that call is a no-op. The rider gets
   two Aura activities, one live and one dead, on the same Lock Screen.

### What the orphan actually shows

*Reversal. Revision 1 argued the ghost dims itself into harmlessness within 90 seconds. It does
not.*

One thing in the issue's account is wrong: there is no paused `staleDate` exception. ROH-102
revision 1 proposed one, withdrew it (`2026-07-30-roh102-live-activity-pause-design.md:190,:383`),
and what shipped is a single 90 second `staleInterval` (`RideActivityPushPolicy.swift:27`)
applied at request (`RideLiveActivityController.swift:54`) and on every enqueued push (`:110`),
with a 60 second heartbeat explicitly not gated on paused
(`RideActivityPushPolicy.swift:21-24`). A dead process stops pushing, so the last `staleDate`
expires within 90 seconds.

What that staleness does to the card is much less than revision 1 assumed:

- **The clock is not dimmed and keeps running.** `RideLockScreenView.swift:23-25` applies
  `statOpacity` to distance and speed only, and says why: "the still-live elapsed timer stays the
  trustworthy value." The clock is `Text(anchor, style: .timer)` in accent mint
  (`RideActivityComponents.swift:70-87`), drawn by the system from an anchor date, which
  `:63-66` notes keeps moving "even when the app is suspended or dead." A ghost from a paused
  ride shows a STOPPED clock climbing without bound.
- **The pill for a non-paused ghost reads "Updating."** `RideActivityComponents.swift:129-133`.
  Only VoiceOver says "not updating" (`RideLockScreenView.swift:158`), so the spoken and drawn
  copy disagree about the same state.
- **The Dynamic Island degrades only when paused.** `RideActivityComponents.swift:178-181`
  swaps the glyph for `pause.circle` when paused and stale, and otherwise leaves the plain
  `bicycle`. An unpaused ghost is a bicycle beside a running mint timer.

So the orphan does not confess. It presents a frozen distance at 40% opacity beside a clock that
is still counting, which is worse than either a clearly dead card or a live one. The issue's
conclusion holds; only its mechanism was wrong.

## D1 — The sweep is a synchronous snapshot, then a sequential end

`RideLiveActivityController` gains `endOrphans()`. It is **synchronous**, and that is the whole
safety argument:

1. Read `Activity<RideActivityAttributes>.activities`.
2. Compute the orphan set: every activity that is not already `.ended` or `.dismissed`, and whose
   `id` is neither `self.activity?.id` nor a member of `endingIDs` (D2).
3. Insert those ids into `endingIDs`, then spawn one `Task { @MainActor }` that awaits `end` on
   each captured activity in turn, removing each id as it completes.

Because steps 1 and 2 contain no suspension point, no ride can start between the snapshot and the
exclusion, and the set handed to step 3 can never contain an activity this process owns. The
correctness does not depend on where `endOrphans()` is called from or on what else is running.

*Reversal. Revision 1 specified a pure `RideActivityOrphanPolicy.orphans(among: [String], owned:
String?)` in AuraCore. All three reviewers rejected it, and they are right: it tests a one-line
filter over data the caller supplies, while every real failure lives in what `owned` is at the
instant of the call and whether it was read across a suspension. Worse, a `String?` parameter
accepts `ride.id.uuidString` as readily as `activity.id`, and that substitution ends the running
ride's activity while the unit test stays green. This repo has already shipped one
UUID-string-mismatch bug. The parameter is deleted; `owned` is read from `self.activity?.id` at
the one site that computes it.*

Each orphan is ended with its own recovered `content.state` and `.immediate` dismissal. A
recovered `Activity` exposes its content, so the payload is reachable, and Apple's guidance for
`end(_:dismissalPolicy:)` is to pass a final content update rather than nil. Under `.immediate`
this is close to invisible, and it costs one line to follow the documented contract.

**Implementation constraint.** The ends run sequentially on the main actor, and must not be
parallelized with a `TaskGroup` or per-activity detached Tasks. *Revision 2 justified this by
claiming the parallel form is a hard compile error. A reviewer compiled it clean on the pinned
6.2.4 toolchain in four configurations, so that is false: region isolation proves the send.* The
real reasons are that there is nothing to gain from ending two dying activities at once, and that
the parallel form multiplies exactly the `sending Activity` pattern ROH-116 was filed about and
ROH-117's canary watches.

## D2 — `endingIDs` is written by both paths that end anything

`end()` nils `self.activity` synchronously (`:121`) and performs the ActivityKit end later,
inside a Task that first drains `pushChain` (`:126-135`). Between those, the previous ride's
activity is still in `Activity.activities` and no longer owned, so a sweep in that window would
end it out from under `end()`, bypassing the drain that `:129` exists to guarantee.

`end()` therefore inserts the activity's `id` into `endingIDs: Set<String>` before spawning its
Task and removes it when that Task finishes, under `defer` so a path that never resumes normally
cannot strand an id and blind every later sweep. The sweep excludes that set.

**The sweep writes to it too.** Revision 2 stated the invariant as "the sweep ends only activities
no live path in this process is already responsible for" and then made the sweep the one live path
that recorded nothing. A cold launch fires both new call sites within milliseconds (D3), and
ActivityKit's list removal is asynchronous, so the second sweep's snapshot still contains the
ghost the first sweep is mid-way through ending. Both reviewers found this. `endOrphans()`
therefore claims its orphan ids in `endingIDs` before spawning, exactly as `end()` does, and
releases each as it completes. One set, two writers, one rule.

Excluding `.ended` and `.dismissed` activities from the snapshot covers the tail of the same
problem: `endingIDs.remove` fires when ActivityKit accepts the end, which is before the entry
leaves `Activity.activities`.

*New in revision 2, corrected in revision 3. Revision 1 asserted a division of labor between
`end()` and `endOrphans()` that the code does not have.*

## D3 — Three call sites, none of them guarded on ride state

**Top of `start()`, before everything.** The sweep runs as the first statement, ahead of the
`areActivitiesEnabled` guard (`:47`) and ahead of `Activity.request`, for one reason: from there
it runs unconditionally. Placed after a successful request, it is skipped when the rider has Live
Activities turned off and skipped again when the request throws, leaving the ghost to outlive the
whole session in both cases. The existing defensive `end()` stays for the same-process case,
which the sweep deliberately leaves to it.

*Revision 2 also claimed this ordering frees the ghost's slot before `Activity.request` runs, and
that a slot-exhausted request was the case the ordering existed for. Both plan reviewers refuted
it independently: `endOrphans()` is synchronous only up to spawning its Task, and `start()` never
suspends, so no end can execute until after `Activity.request` has already returned. The claim is
deleted rather than repaired. Recovering a genuinely slot-exhausted request would mean re-issuing
it once the sweep drains, and with one ghost against Apple's per-app ceiling that case is
speculative enough to leave alone. It is recorded here so a later reader does not rediscover the
ordering and assume it was load-bearing.*

**Launch, in its own `.task`.** Not the `.task` at `AuraApp.swift:160`. That closure is
synchronous end to end, and its `guard backfill == nil` check-then-set is idempotent under scene
reconnect only because nothing between the read and the write can yield. Adding an `await` there
would let two invocations both observe nil and spawn two concurrent 50 row `RideSegmentBackfill`
sweeps on one `ModelContainer`.

**`scenePhase == .active`.** A session that launched before ActivityKit had restored its list, or
whose first `Activity.request` threw, otherwise carries the ghost for the life of the process,
which on iOS is days.

*Reversal. Revision 1 put the launch sweep in the backfill's `.task` and declared a foreground
sweep a non-goal on the grounds that "a process that is alive owns its activity through the
singleton." That is false for any session that began with a ghost it never swept.*

No call site guards on `router.activeRideID == nil`. That flag is written by a SwiftUI
`.onChange(of: coordinator.isRecording)` (`RideHUDView.swift:220-222`,
`NavigateHUDView.swift:245-250`), an update cycle after `start()` has already requested the
activity, so it is nil during a window in which a ride is recording and owns one. It is neither
necessary (D1's exclusion is the safety property) nor sufficient. The adjacent
`cancelForgottenPauseNudges()` keeps its own guard, which is load-bearing for a different reason
and is not being changed.

Every call goes through `RideLiveActivityController.shared` directly, in the app target.
`endOrphans()` does **not** join `RideActivityControlling` (`RideSessionSeams.swift:15-25`): the
coordinator has no correct place to call it from, the package cannot describe an operation
defined over ActivityKit's process-global list, and a protocol requirement would only add a
no-op stub to `SpyRideActivity` that no test asserts on. This follows the precedent of
`PauseNudgeScheduler.shared.cancelForgottenPauseNudges()` at `AuraApp.swift:174`.

## D4 — Ended silently, and the rider who was never paused is told nothing

PO decision: the sweep ends the orphan and says nothing.

Where a checkpoint row exists, ROH-107's unfinished treatment carries the explanation, though
less than revision 1 implied. `LastRideCard` renders the compact badge
(`LastRideCard.swift:26`), which is the four word label "No end recorded."
(`UnfinishedRideBadge.swift:41-46`). The sentence that names the data loss is the `.full` style,
used only on the ride summary (`RideSummaryView.swift:198`), two taps further in.

Where no checkpoint row exists, the app says nothing at all, and this change makes that rider's
situation worse before it makes it better. `flushCheckpoint` is called only from `pause()`
(`RideSessionCoordinator.swift:260`) and is suppressed below 25 m, so a rider killed while moving
who never paused has no row, no badge, and no nudge. Today the ghost's frozen distance is the one
artifact in the system that says the ride happened. The sweep deletes it.

*Revision 3 accepted this on the grounds that the deleted card is "a half-true card the rider
cannot act on, not a record." The merge-gate product reviewer refuted both halves and is right.
`RideActivityPushPolicy.coalesceInterval` is 4 seconds, so the frozen distance is accurate to
within about four seconds of the moment the process died; only the clock beside it lies. And
writing that number down, or entering it in Strava, is exactly what a rider does with it.*

So the honest statement is: this change deletes an accurate distance, and offers nothing in its
place. It ships that way because the alternatives were priced against a wrong description of what
was being lost, which makes this a decision to re-take rather than one to defend. **Three options,
for the record:**

1. **Ship silent, as built.** [ROH-144](https://linear.app/rohun/issue/ROH-144) then owns the
   underlying defect, that nothing persists an unpaused ride.
2. **Write the recovered ride at sweep time.** `endOrphans()` already holds
   `orphan.content.state` (distance, elevation gain, clock anchor) and `orphan.attributes.startedAt`
   at the instant it discards them. That is enough for an interrupted-ride row with a real
   distance and a real elapsed time, with no autosave, no deep link and no new `ContentState`.
   Strictly smaller than either alternative rejected below, and it was not considered when they
   were.
3. **Keep the ghost until something replaces it**, accepting the lying clock.

Option 1 is what merged, and it is the PO's call to keep or reverse. Option 2 is the one worth
looking at first.

Two alternatives were rejected. A `widgetURL` plus deep-link route would push a screen onto a
path whose rules ROH-85 fixed at some cost. A terminal "ride interrupted" `ContentState` would
need rendering across all five widget presentations, which is the code ROH-102 rewrote days ago.

## D5 — Nothing here is host-testable, and the spec says so rather than inventing a seam

*Correction. Revision 1 wrote "no test target in this repo can import ActivityKit." The package
suite runs on a macOS host where ActivityKit is unavailable, which is the real constraint
(`RideActivityPushPolicy.swift:15-16`), but `AuraUITests` is an iOS bundle that links the iOS
SDK. It still cannot verify this change: XCUITest drives the app, not the Lock Screen, and the
sweep's whole observable effect is on the Lock Screen.*

With D1's policy deleted, almost nothing here is unit-testable. The one exception is real and a
reviewer was right to find it: the `-skipOrphanSweep` predicate below has the same shape as
`SimulatedRideConfig.forcesInMemoryStore(arguments:)`
(`AuraKit/Testing/SimulatedRideConfig.swift:35-37`), which is host-tested
(`SimulatedRideConfigTests.swift:36-39`). It goes in the same file, tested the same way, rather
than being buried as a private computed property in a SwiftUI view.

Everything else about this change is invisible to CI, and the spec would rather say that than
pretend otherwise:

- The package suite cannot see any of it. `RideSessionCoordinator`'s tests run against
  `SpyRideActivity` (`RideSessionCoordinatorTests.swift:346`), and no host target links the app
  target, so nothing tests the real `end()`. *Revision 2 listed the package suite as a guard here.
  It is not one.*
- SwiftLint runs `lint`, not `analyze`, so an unreferenced `endOrphans()` would draw no
  complaint. That is why the implementation lands as one commit with its call sites rather than
  as a primitive followed by wiring.
- The toolchain canary (`.github/workflows/ci.yml:117-135`) catches a region-isolation regression
  on 6.3, but it is deliberately outside branch protection, so it reports rather than blocks.
- Everything that matters is the device pass below.

**`RideActivityAttributes`'s decode rule becomes load-bearing for a second reason.** Its comment
already requires every added field to be Optional or defaulted. A ghost written by the previous
binary that this binary cannot decode never appears in `Activity.activities` at all, so it
becomes permanently unsweepable rather than merely misrendered. The comment gets that sentence.

## Non-goals

- **Persisting an unpaused ride.** Separate issue, per D4.
- **No `widgetURL`, no deep link, no new `ContentState`.** Per D4.
- **Clearing the ghost while the app stays closed.** The sweep needs a process. A rider who force
  quits at the trailhead and does not open Aura until evening sees the ghost all afternoon,
  exactly as today. Defect 1 is bounded by this, not closed, and the spec would rather say so
  than let the issue read as fully fixed.

## Verification

The device pass is the gate. Two DEBUG-only launch arguments make the three call sites separable:
`-skipOrphanSweep` suppresses launch and foreground, leaving only the sweep inside `start()`, and
`-skipLaunchOrphanSweep` suppresses launch alone, which is the only way to reach the foreground
site with a ghost still alive. Neither reaches `start()`. Without them the launch sweep fires on
the first frame and every later step passes whether or not the other sites exist.

**Watch the log, not just the card.** Each sweep emits
`Ending N orphaned Live Activity(s)` on subsystem `app.aura.ios`, category `live-activity`. A card
that disappears with no such line was retired by iOS, not by this code, and that is the failure
mode most likely to be reported as a pass. Stream it with:

```bash
xcrun devicectl device console --device <udid> | grep live-activity
```

1. Start a ride, pause it, confirm the paused Live Activity. Kill the app from Xcode. Confirm at
   90 seconds that the stats dim and the clock keeps counting, which is the baseline this change
   is measured against.
2. Relaunch **by tapping the Live Activity itself**, which is how a rider actually gets here. The
   card clears and the log shows one orphan ended. Repeat several times: the launch site sweeps
   twice, immediately and again two seconds later, because ActivityKit may not have restored its
   activity list on the first frame. A run where the first sweep logs nothing and the second logs
   one is a pass, and is the case the delayed pass exists for.
3. Repeat the kill, relaunch with `-skipLaunchOrphanSweep`, and confirm the ghost is **still
   there** with no log line. Background the app, foreground it, and confirm it clears with one.
   This is the only step that proves the foreground site.
4. Repeat the kill, then relaunch with `-skipOrphanSweep` and start a new ride. Exactly one Aura
   activity may exist afterwards, showing the new ride, and it must still be updating a minute
   later. This is the step that proves the `start()` site.
5. Repeat the kill, then turn Live Activities off for Aura in Settings. **First record whether the
   ghost survives that toggle.** If iOS ends it there, this step proves nothing and should be
   struck rather than reported as a pass, and the "runs even when Live Activities are off" half of
   D3's argument goes with it. If it survives, launch with `-skipOrphanSweep`, re-enable Live
   Activities, start a ride, and confirm the ghost is gone.
6. Force quit by swiping up rather than killing from the debugger, then relaunch from the Home
   Screen and confirm step 2. Steps 3 and 4 are not reproducible here: launch arguments come from
   the Xcode scheme at spawn, so a springboard launch carries neither flag. The problem statement
   treats a swipe-up quit and a debugger kill as equivalent and nothing has checked that, which is
   what this step is for.
7. Start a ride, background and foreground the app repeatedly, and confirm the live activity is
   never swept and the log stays silent. This is the negative case for the foreground call site.
8. Ride, End, tap Done, and immediately start a second ride. Exactly one card, still updating a
   minute later. This is the `endingIDs` hand-off between `end()` and the `start()` sweep, the
   most intricate invariant in the change and the one with no automated coverage.
9. Kill during a ride that was never paused, relaunch, and look at Home. Expected: the ghost is
   gone and Home says nothing about the ride. Confirming what D4 accepts, so it is a known outcome
   rather than a surprise found later. Note the distance the card showed before you relaunch: that
   is the number D4 option 2 would preserve.
