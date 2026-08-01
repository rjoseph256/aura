# Active time on the ride summary (ROH-112) — design

Date: 2026-08-01
Issue: [ROH-112 — Show active time (not moving time) on every surface that reports a ride's duration](https://linear.app/rohun/issue/ROH-112/show-active-time-not-moving-time-on-every-surface-that-reports-a-rides)
Parent spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D5)
Status: revision 2, after a three-reviewer gate on revision 1.

Revision 1 moved five surfaces to active time. The gate established that this makes the number
worse for a rider who does not press Pause, which is the majority path, and the PO narrowed the
scope on 2026-08-01 to the ride summary alone. Revision 1 also rested on a premise the recorder
contradicts (D2), claimed a formatter that one surface does not use, justified keeping the moving
cell with a test claim that is false, and proposed an XCUITest assertion that could not fail. Each
is corrected inline below.

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

Active time is computed in three places after this pass, and would have been four:

| Site | Role |
| -- | -- |
| `RideSessionCoordinator.refreshElapsed` (`:224`) | the number the rider watches on the HUD |
| `RideActiveClock.make` (`:43`) | the Live Activity and Dynamic Island clock |
| `RideDuration` (new) | the finished ride, on the summary |

The first two are today the same expression, `max(0, now - startedAt - pausedSeconds)`, written
out twice. Since "the rider sees the same clock after the ride that they saw during it" is the
whole justification for this change, that agreement is an invariant and gets a mechanism rather
than a promise:

```swift
extension RideDuration {
    /// The one definition of active time. Every clock in the app routes through it.
    public static func activeSeconds(startedAt: Date, asOf now: Date,
                                     pausedSeconds: TimeInterval) -> TimeInterval
}
```

`RideActiveClock.make` and `refreshElapsed` are rewritten to call it, keeping their existing
behavior byte-for-byte. A test drives the same inputs through the live path and the finished path
and asserts equality, following `RideSummaryUnfinishedTests.rideAgreesWithItsSummaryProjection`.

Revision 1 proposed clamping paused into `0...elapsed` here, which disagrees with the two existing
implementations on a negative `pausedSeconds`. The shared primitive removes the question.

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

`RideDuration` therefore never reads `checkpointedAt` as a time. It reads it as a disqualifier:

**`RideDuration` is nil for any unfinished ride**, using the existing `isUnfinished` predicate
(`Ride.swift`, `RideSummary.swift:63`). The checkpoint is written at the *pause*, so a rider who
paused at minute 30, resumed, rode to minute 90, and was then killed has a row whose `endedAt` is
minute 30. Printing "30 min active" under a badge reading "No end recorded" is confidently wrong in
a way the badge does not cover, and a rider reads that badge as "the last bit is missing", not "two
thirds of this ride is missing". The moving cell still reports what was actually recorded, and the
badge carries the rest.

This also removes the hazard the architecture review flagged: a future author cannot read this spec
as licence to prefer `checkpointedAt`, because no rule here uses it as a clock.

### D3 — `RideDuration` for a finished ride

`AuraCore/Sources/AuraCore/Ride/RideDuration.swift`, beside `RideActiveClock`:

```swift
public struct RideDuration: Equatable, Sendable {
    public let elapsedSeconds: TimeInterval
    public let activeSeconds: TimeInterval
    public init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?, pausedSeconds: Double)
}
```

with `Ride.duration` and `RideSummary.duration` as call-site conveniences. Rules, each pinned by a
test:

* `nil` when the ride is unfinished, per D2. That is the only unavailable case.
* `elapsedSeconds = max(0, endedAt - startedAt)`.
* `activeSeconds` comes from D1's shared primitive with `now: endedAt`.
* A ride recorded before pause existed has `pausedSeconds == 0`, so active equals elapsed.

The `max(0, ...)` on elapsed guards a degenerate recorder state, not a device clock: `startedAt ??
date` in `checkpoint(at:)` collapses to a zero interval when the recorder never started. It is
paired with an `assertionFailure` in DEBUG and a `Logger` line in release, following
`RideMigrationPlan.swift:38`, because a silent clamp is how a future auto-pause accounting bug
would ship as "active time is a bit low" and never get reported.

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

The moving cell is kept because moving time is a real cycling metric that riders arriving from
Strava or Garmin expect, and the summary is the surface with room for it. *(Corrected in revision
2: revision 1 justified this by claiming the paused E2E would otherwise have nothing to read.
That is false. `assertPausedHeroDistanceInBand` (`RideE2EUITests.swift:309-313`) bands the hero
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

### D6 — The Live Activity's running clock is relabeled ACTIVE

*(New in revision 2.)* `RideLiveActivity.swift:107` labels the clock `ELAPSED`, and that clock is
`RideActiveClock`, which is active time. Shipping D4 without this would leave the word "elapsed"
pointing at active time on the Lock Screen and at wall clock on the summary the rider lands on
seconds later, which is a worse version of the inconsistency this issue exists to close.

One string, at that one site. The Dynamic Island's other clock cells already use the neutral `TIME`
(`RideLiveActivity.swift:128`) and are left alone.

## Testing

Package tests, which run on the macOS CI host:

* `RideDurationTests`: nil for an unfinished ride (both the checkpoint case and the legacy nil-end
  case), the elapsed clamp, and a pre-pause ride where active equals elapsed.
* The cross-implementation test from D1: the same inputs through `refreshElapsed`,
  `RideActiveClock.make` and `RideDuration` agree.
* `RideSummaryStats`: a paused ride renders the caption, an unpaused ride does not, a sub-minute
  pause does not, an unfinished ride renders `—` with no caption, and all three accessibility
  label forms.

XCUITest, added to ROH-103's paused golden ride:

* `assertActiveIsNotTheMovingNumber`: parse the number from the active cell and from the moving
  cell on the same summary, and assert they differ.

**Why that is falsifiable, and what it does not prove.** *(Corrected in revision 2. Revision 1
proposed asserting the cell "carries both terms", whose substrings are compile-time constants in
the very format string D5 mandates, so it could only fail if the implementer ignored D5. It also
argued from arithmetic that was wrong.)* On this fixture the two numbers are structurally
different quantities: moving time is frozen at 290 s from the GPX stamps
(`PausedGoldenRideFixture.expectedMovingTimeSeconds`) and reads "4 min", while active time is wall clock over a
~45 s playback at 20x plus the tester's dwell. A surface still handed `movingTimeSeconds` reads 4
in both cells and fails. It does not prove the subtraction of paused time, which the package tests
cover. The assertion holds while playback stretch under CI load stays under about 4x; ROH-103's
notes on stretch apply.

Note for anyone reading a harness screenshot: on this fixture moving time **exceeds** active time,
inverting the production invariant `moving ≤ active ≤ elapsed`, because the two are measured on
different clocks. That is the harness, not a defect.

Device pass, per `CLAUDE.md`'s rule that UI is verified rather than asserted:

* Summary on an iPhone SE at default and AX5 text sizes. D4 adds a third cell and a caption to a
  row that already has a `ViewThatFits` fallback, and `HistoryView.swift:190-197` and
  `LastRideCard.swift:21-24` both carry comments about SE-at-AX5 breakage that only a device found.
* A paused ride end to end: the Lock Screen reading `ACTIVE`, then the summary's pair.
* An unpaused ride, confirming no elapsed caption appears.

## Risks

* `RideActiveClock.make` and `refreshElapsed` are load-bearing live code being rewritten to route
  through a new primitive for no behavior change. Existing tests (`RideActiveClockTests`,
  `RideSessionCoordinatorPauseTests`) are the guard, and the rewrite must not touch the clamping
  comments at `RideActiveClock.swift:44-52`, which document a Live Activity countdown bug.
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
a follow-up issue blocked on Slice B.

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
