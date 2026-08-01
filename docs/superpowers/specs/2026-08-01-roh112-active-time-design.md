# Active time on the ride summary (ROH-112) — design

Date: 2026-08-01
Issue: [ROH-112 — Show active time (not moving time) on every surface that reports a ride's duration](https://linear.app/rohun/issue/ROH-112/show-active-time-not-moving-time-on-every-surface-that-reports-a-rides)
Parent spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D5)
Status: revision 3. Revision 2 followed a three-reviewer gate on the spec; revision 3 follows a
two-reviewer gate on the plan.

Revision 1 moved five surfaces to active time. The gate established that this makes the number
worse for a rider who does not press Pause, which is the majority path, and the PO narrowed the
scope on 2026-08-01 to the ride summary alone. Revision 1 also rested on a premise the recorder
contradicts (D2), claimed a formatter that one surface does not use, justified keeping the moving
cell with a test claim that is false, and proposed an XCUITest assertion that could not fail.

Revision 2 then over-corrected D2 into disqualifying every ride carrying a checkpoint marker,
which would have blanked the duration for a rider whose ride failed to save; rewired one of
`RideActiveClock`'s two derivations of active time and left the rendered one; and located D6's
string on a surface that does not carry it. Each correction is marked inline.

Slice A of the pause epic is shipped through Pass 6. The recorder accumulates `pausedSeconds`,
schema V6 persists it, the cockpit shows a paused state, and the Live Activity honors it. No
post-ride surface reads any of it.

## Problem

Parent D5 decided that a finished ride leads with **active** time, `elapsed - paused`, because that
is the number the rider was watching on the HUD when they pressed End. Moving time appears on no
live screen, so leading with it shows the rider a number they never saw.

The ride summary is the surface that decision was about, and it was never built. ROH-101 deferred
it here (`2026-07-29-roh101-pause-control-design.md:404`), so `RideSummaryView.swift:279` still
renders `RideStats.movingTimeSeconds`. A rider can pause for a twenty-minute coffee and no
post-ride screen records that they were out longer than they were pedaling.

### Why the other four surfaces are not in this pass

*(New in revision 2. Revision 1 moved all five.)*

`RideStatsCalculator` gates moving time at 0.5 m/s (`RideStatsCalculator.swift:25`), so moving
time **already** excludes an unpaused café stop, a red light, and a mechanical. Active time
excludes only the stops the rider manually pressed. The parent spec says in its own scope section
(`2026-07-26-segmented-rides-pause-design.md:35-39`) that the stops a rider will not press a
button for are precisely the common ones.

So on the majority path, active time is a worse number than moving time. A twenty-minute coffee
with no pause pressed reads 46 min in History today and would read 68 min after the change, and
every ride already in History would restate upward on upgrade with nothing in the app to explain
why.

The summary is the one surface with room to show active, elapsed and moving together, where the
rider can see all three and compare them. A History row, a widget cell, and a share card each show
one number with no context, so moving out from under moving time there trades a good default for a
worse one. Those four hold until auto-pause (Slice B) makes active time the better number on the
majority path, tracked as a follow-up issue.

This is a deliberate override of parent D5's "all four move to active-with-elapsed"
(`2026-07-26-segmented-rides-pause-design.md:234-238`), taken by the PO on 2026-08-01, not a
reading of its intent.

## Decisions

Numbered D1 onward for this spec. References to the pause epic's numbering are written as
"parent D5".

### D1 — One shared primitive, so "active" cannot drift

*(New in revision 2. Revision 1 promised non-drift and enforced it with a doc comment.)*

Active time is computed in **four** places today, not three. *(Corrected in revision 2's plan
gate: revision 2 listed three and rewired two.)*

| Site | Role |
| -- | -- |
| `RideSessionCoordinator.refreshElapsed` (`:224`) | the number the rider watches on the HUD |
| `RideActiveClock.make` (`:43`) | computed, then **discarded** on the running branch |
| `RideActiveClock.make` (`:54`) | `startedAt + pausedSeconds`, the anchor the Lock Screen and Dynamic Island actually render |
| `RideDuration` (new) | the finished ride, on the summary |

The third is the one that reaches a rider's eyes, and it is a separately-written derivation of the
same quantity rather than a reuse of the second. Since "the rider sees the same clock after the
ride that they saw during it" is the whole justification for this change, that agreement is an
invariant and gets a mechanism rather than a promise:

```swift
extension RideDuration {
    /// The one definition of active time. Every clock in the app routes through it.
    public static func activeSeconds(startedAt: Date, asOf now: Date,
                                     pausedSeconds: TimeInterval) -> TimeInterval
}
```

All three existing sites are rewritten to call it, keeping their behavior identical. The running
anchor becomes `now - activeSeconds`, which is algebraically the same value as
`min(startedAt + pausedSeconds, now)` because the clamp already lives inside the primitive.

**The enforcement is a checked-in guard script, not a one-shot grep.**
*(Revision 3. Revision 2 called a grep run once by the implementer a "mechanism"; it evaporated at
commit time, and it could not have matched the `addingTimeInterval` form anyway, which is the one
that renders.)* `scripts/check-single-active-definition.sh` fails on any subtraction of
`pausedSeconds` outside `RideDuration`, and runs from `.claude/agent-gate.sh` and CI beside the
two guard scripts already there. The repo's precedent is explicit: `.swiftlint.yml`'s
`async_closure_default_argument` rule exists because "do not write X" comments get ignored.

A test covers both branches of `RideActiveClock.make` against the primitive. It cannot fail for a
change to the *definition* once both sides call one function; what it catches is a future author
re-inlining a branch, which is exactly how revision 2 left the rendered anchor behind.
`RideActiveClockTests` pins the definition itself against frozen literals.

`refreshElapsed` gets no equality test. Its `startedAt` is private and stamped from `Date()`
inside `start()`, so a test cannot supply both sides; the guard script and
`RideSessionCoordinatorPauseTests` are what hold it. Said here rather than left implied, because a
test that claims three callers and checks two is the coverage drift ROH-103's review caught twice.

### D2 — `checkpointedAt` is a marker, never a clock; unfinished rides show no duration

*(Rewritten in revision 2. Revision 1 claimed an unfinished ride has no `endedAt` and fell back to
`checkpointedAt`. Both halves were wrong.)*

`RideRecorder.checkpoint(at:)` stamps `endedAt` **and** `checkpointedAt` to the same instant
(`RideRecorder.swift:170-173`), and says so in its own doc comment. The parent spec already
recorded this as a Pass 2 correction (`2026-07-26-segmented-rides-pause-design.md:378-382`). So:

* No row the app can write has `endedAt == nil && checkpointedAt != nil`. Revision 1's fallback
  was unreachable, and the test it proposed for that fallback would have pinned a state nothing
  produces, which is the unfalsifiable-assertion defect this repo keeps catching.
* The state that does occur is **both non-nil**: `RideSessionCoordinator.finish()`'s save-failure
  branch publishes a ride whose `endedAt` is the End tap and whose `checkpointedAt` is an earlier
  flush (`RideSessionCoordinator.swift:376`).

`RideDuration` therefore never reads `checkpointedAt` as a time. It reads it as a disqualifier —
but **not for every ride that carries one**. *(Revision 3. Revision 2 disqualified on
`checkpointedAt != nil`, which is `isUnfinished`, and that is wrong for the second of the two
states below.)*

Two different rides satisfy `checkpointedAt != nil`:

**A checkpoint row.** `endedAt == checkpointedAt`, both the pause instant. A rider who paused at
minute 30, resumed, rode to minute 90, and was then killed has a row saying minute 30. Printing
"30 min active" under a badge reading "No end recorded" is confidently wrong in a way the badge
does not cover: a rider reads that badge as "the last bit is missing", not "two thirds of this ride
is missing". **Disqualified.**

**A ride that failed to save.** `RideSessionCoordinator.finish()`'s catch branch restores the
marker onto a ride whose `endedAt` came from `RideRecorder.end(at:)` — the real End tap, strictly
after the checkpoint (`RideSessionCoordinator.swift:376`). Both durations are exactly known.
This is the summary the rider is looking at *the moment their ride failed to save*, beside a real
distance, a real top speed, and a real route map that the coordinator deliberately keeps live
(`RideSessionCoordinator.swift:365-372`). Blanking the duration alone there reads as "the app lost
my ride". **Reported.** `RideSessionCheckpointFlushTests.swift:238` already asserts this ride is
"still a real duration"; that test would have stayed green through revision 2's rule, because it
never calls `.duration`.

So the disqualifier is `checkpointedAt >= endedAt`, which selects the first and spares the second.

This is deliberately **not** `isUnfinished`, and the doc comment says so at length, in the style of
`WidgetSnapshot.LastRide.isUnfinished` — which is the repo's existing precedent for a predicate
that looks like a copy and must not be collapsed into one.

### D3 — `RideDuration` for a finished ride

`AuraCore/Sources/AuraCore/Ride/RideDuration.swift`, beside `RideActiveClock`:

```swift
public struct RideDuration: Equatable, Sendable {
    public let elapsedSeconds: TimeInterval
    public let activeSeconds: TimeInterval
    public init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?, pausedSeconds: Double)
}
```

with `Ride.duration` as the only call-site convenience. There is no `RideSummary.duration`: its
consumers are History and the Home card, which are out of scope, and API whose only reader is the
test that justifies it is API this issue should not add. ROH-146 adds it.

Rules, each pinned by a test:

* `nil` when `endedAt` is nil, or when `checkpointedAt >= endedAt`, per D2.
* `elapsedSeconds = max(0, endedAt - startedAt)`.
* `pausedSeconds` is floored at zero **here**, before the primitive: `max(0, pausedSeconds)`. The
  two live clocks read `RideRecorder.pausedSeconds(asOf:)`, which is structurally non-negative and
  bounded by the session; this reads a persisted, CloudKit-mirrored `Double` column
  (`RideSchemaV7.swift:42`). Without the floor a negative stored value renders active *above*
  elapsed, with the caption present to make it unmissable. *(Revision 3: revision 2 dropped this
  floor on the grounds that the shared primitive "removes the question". It relocates it — the
  arithmetic is shared, the input domain is not.)* An oversized stored value needs no matching
  upper clamp: the primitive's own `max(0, elapsed - pausedSeconds)` already keeps `activeSeconds`
  from exceeding `elapsedSeconds` for any non-negative `pausedSeconds`, so a second clamp against
  `elapsedSeconds` here would be dead code.
* `activeSeconds` comes from D1's shared primitive with `now: endedAt`.
* A ride recorded before pause existed has `pausedSeconds == 0`, so active equals elapsed.

**The negative-elapsed case clamps silently, with no assertion.** *(Revision 3.)* Revision 2
trapped there, reasoning that only a degenerate recorder state produces it. Tracing both writers
shows neither can: `checkpoint(at:)` and `end(at:)` each collapse to a *zero* interval when the
recorder never started, not a negative one. The real producer is a backward wall-clock step, which
this repo already carries as ROH-130. Unlike `RideMigrationPlan.swift:38`, whose assertion runs
once over local data inside a migration, this runs inside `RideSummaryView.body` over rows CloudKit
mirrored from another device — so a trap there fails the summary screen, the XCUITest suite, and
the device pass, for a clock skew the app knows it does not handle.

### D4 — Summary layout: active with a conditional elapsed caption, moving retained

Three cells, with elapsed as a caption under the first rather than a fourth peer:

```
38 min          31 min        24.3
active          moving        mph top
48 min elapsed
```

**The caption renders only when its string differs from the active string.**
*(New in revision 2.)* On an unpaused ride `pausedSeconds == 0`, so active is elapsed and revision
1's fixed layout printed the same number twice, permanently, on the majority path. Truncation makes
that wider than "no pause": `RideStatsFormatter.minutes` is `Int(seconds / 60)`
(`RideStatsFormatter.swift:39`), so any pause that does not cross a minute boundary also collapses
to identical strings. Comparing the rendered strings, not `pausedSeconds > 0`, is what makes the
rule cover both.

This is a second, smaller override of parent D5, which says "the layout stays fixed rather than
conditional" (`2026-07-26-segmented-rides-pause-design.md:237-238`). Named here so a reader
reconciling the two specs does not hit it unannounced. The parent's reasoning was about pre-V6
rides, where the pair is equal; suppressing the repeat is that reasoning carried through rather
than contradicted.

The moving cell is kept because moving time is a real cycling metric that riders arriving from
Strava or Garmin expect, and the summary is the surface with room for it. *(Corrected in revision
2: revision 1 justified this by claiming the paused E2E would otherwise have nothing to read.
That is false. `assertPausedHeroDistanceInBand` (`RideE2EUITests.swift:316-331`) bands the hero
distance specifically to exclude a flattened read, and the in-ride probe checks segment count and
the gain band. The moving cell is one of four discriminators, not the only one.)* Its identifier,
label and value expression stay unchanged regardless, so `assertMovingTimeIsSegmented` is
untouched.

An unfinished ride renders `—` in the active cell with no caption. That sits beside a moving cell
reading a real number, which is a new mixed treatment in one row and is accepted: the duration is
genuinely not computable while the stats are, and the row already carries the unfinished badge.

### D5 — The stat row is a projection of a pure type built from scalars

`RideSummaryStats` in `AuraKit/Formatting`, following `ExploreInstrumentState`, resolves the three
cells to display strings plus the active cell's spoken label.

**It takes scalars, not a `Ride`.** *(New in revision 2.)* `RideSummaryView.swift:52-54` records
this project's rule about not reading track-derived properties inside `body`, and `ShareCardContent`
is built in a `.task` precisely because it walks `flattenedPoints`. A type taking a whole `Ride`
and constructed in `body` invites the next author to add one track-derived field and hand the
summary an O(n) walk per evaluation.

The active cell sets an explicit accessibility label rather than relying on `children: .combine`
to order a value, a label and a caption:

* with caption: "Active time, 38 min. Elapsed, 48 min."
* without: "Active time, 38 min."
* unavailable: "Active time, unavailable."

### D6 — The Dynamic Island's running clock is relabeled ACTIVE

*(New in revision 2; **its surface corrected in revision 3**.)* `RideLiveActivity.swift:107` labels
the clock `ELAPSED`, and that clock is a `RideActiveClock`, which is active time. Shipping D4
without this would leave the word "elapsed" pointing at active time on one screen and at wall clock
on the summary the rider lands on seconds later.

**Where the string actually appears.** Line 107 sits inside
`expandedTrailing(_:nav:imminent:clock:)`, a `DynamicIslandExpandedRegion(.trailing)`, on the
non-navigate branch. So it is the **expanded Dynamic Island of a running free ride**, and nowhere
else. Revision 2 called it the Lock Screen; the Lock Screen is `RideLockScreenView`, which labels
its clock `TIME` at `:49` and `:93` and always has. A paused clock renders `PAUSED` through
`rideActivityClockLabel`, so the running label never appears on a paused ride either. Getting this
wrong in a spec is how a device pass gets signed off against the wrong surface.

The other clock cells already use the neutral `TIME` and are left alone.

**One accepted lie, in a narrow window.** `ContentState.activeClock(startedAt:)` falls back to
`.running(anchor: startedAt)` for an activity started by a pre-ROH-102 binary
(`RideActivityAttributes.swift:92-94`), which is raw elapsed with pauses included. Labeled
`ELAPSED` that was honest; labeled `ACTIVE` it is not. It requires a Live Activity started before
ROH-102 and still in flight across an app update, it ends when that ride ends, and the alternative
is keeping a permanently wrong label to protect a transient one.

## Testing

Package tests, which run on the macOS CI host:

* `RideDurationTests`: nil for a checkpoint row and for the legacy nil-end row, a **save-failure
  ride keeping its real duration**, active bounded by elapsed for a negative and an oversized
  stored `pausedSeconds`, and a pre-pause ride where active equals elapsed.
* The agreement test from D1, covering **both** branches of `RideActiveClock.make` including the
  rendered anchor, plus the guard script in the gate and CI.
* `RideSummaryStats`: a paused ride renders the caption, an unpaused ride does not, a sub-minute
  pause does not, an unfinished ride renders `—` with no caption, and all three accessibility
  label forms.

XCUITest, added to ROH-103's paused golden ride:

* `assertActiveIsNotTheMovingNumber`: parse the number from the active cell and from the moving
  cell on the same summary, and assert they differ.

**Why that is falsifiable, and what it does not prove.** *(Corrected in revision 2. Revision 1
proposed asserting the cell "carries both terms", whose substrings are compile-time constants in
the very format string D5 mandates, so it could only fail if the implementer ignored D5.)* On this
fixture the two numbers are structurally different quantities: moving time is frozen at 290 s from
the GPX stamps (`PausedGoldenRideFixture.expectedMovingTimeSeconds`) and reads "4 min", while
active time is real wall clock — only the *location* stream replays at 20x — so the ~890 s fixture
plays in roughly 45 s, **less** the three pause dwells. A surface still handed `movingTimeSeconds`
reads 4 in both cells and fails.

*(Revision 3 corrects the arithmetic: revision 2 said active was the playback "plus the tester's
dwell", which is elapsed, not active. The dwell is exactly what active subtracts.)* The practical
consequence is that **the active cell renders "0 min" or "1 min" on this run**, and the elapsed
caption is absent, since active and elapsed differ by seconds and both truncate to the same
minute.

So the assertion proves the cell is not wired to moving time, and nothing more: it cannot tell
active from elapsed here, which the package tests cover instead. It fails spuriously only if
playback stretches roughly fivefold under CI load, and its failure message names that possibility
so a reader does not misread a scheduling problem as a wiring bug.

Note for anyone reading a harness screenshot: on this fixture moving time **exceeds** active time,
inverting the production invariant `moving ≤ active ≤ elapsed`, because the two are measured on
different clocks. That is the harness, not a defect.

Device pass, per `CLAUDE.md`'s rule that UI is verified rather than asserted:

* **A paused ride** on an iPhone SE at default, at one intermediate text size, and at AX5. The
  caption widens the first cell's ideal width, so a paused ride flips `ViewThatFits` to its
  vertical fallback at a *smaller* size than an unpaused one; the intermediate size is where that
  lands, and the flip pushes the moving cell — which a CI gate reads — further down the scroll.
  `HistoryView.swift:190-197` and `LastRideCard.swift:21-24` both carry comments about SE-at-AX5
  breakage that only a device found.
* The same ride unpaused, confirming no elapsed caption and a row that stays horizontal longer.
* The **expanded Dynamic Island of a running free ride**, reading `ACTIVE`. Not the Lock Screen,
  which reads `TIME`, and not while paused, which reads `PAUSED`.

## Risks

* `RideActiveClock.make` and `refreshElapsed` are load-bearing live code being rewritten to route
  through a new primitive for no behavior change. Existing tests (`RideActiveClockTests`,
  `RideSessionCoordinatorPauseTests`) are the guard. The clamp reasoning at
  `RideActiveClock.swift:47-53` documents a Live Activity countdown bug and must survive the
  rewrite; because the anchor changes from an addition to a subtraction, that comment is amended
  to describe the form actually present rather than left stale.
* The summary's stat row is the cell ROH-103's CI gate reads. That gate runs with
  `-retry-tests-on-failure -test-iterations 2`, so a layout change that makes the cell
  intermittently unreachable reports as flake rather than as a break.

## Ship precondition

The CloudKit **production** schema promotion covering `CD_pausedSeconds` is still owed (ROH-108).
Until it lands, a two-device account's synced rows carry no paused time, so a ride paused on one
phone renders active equal to elapsed on the other. That is silent, and it is the same reading a
pre-pause ride gives.

## Out of scope

**The other four duration surfaces** (History caption, Home last-ride card, widget last-ride card,
share card) stay on moving time, per the Problem section, and move when auto-pause ships. Filed as
ROH-146.

One of them is reachable in a single tap from the screen this pass changes: the share card is
generated *from* the summary (`RideSummaryView.swift:136`) and renders "31 min moving"
(`ShareCardView.swift:207`) while the summary above it reads "38 min active". Accepted rather than
overlooked — the Problem section's argument is that a card other people see is the worst place to
put the number that inflates for a rider who did not press Pause.

**HealthKit.** `WorkoutData.init(from:)` writes `start = startedAt`, `end = endedAt` with no
`HKWorkoutEvent(.pause)`, so a rider with the Health toggle on sees a 68-minute cycling workout in
Fitness beside a 48-minute active time in Aura. Named here rather than left silent; writing pause
events is its own issue.

**Weekly aggregates.** `RideAggregator.movingTimeSeconds` is summed but rendered by nothing outside
tests, so there is no rider-visible inconsistency to fix.

**`RideStatsFormatter.minutes` keeps its truncating whole-minute output.** The HUD's last frame
reads `59:58` and the summary then reads `59 min`, so the continuity D1 buys at the definition
layer is still imperfect at the layer the rider perceives. Changing the formatter touches every
caller and wants its own review.
