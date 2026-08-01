# A monotonic ride clock (ROH-130) — design

Date: 2026-08-01
Issue: [ROH-130 — Active ride time is computed from a non-monotonic wall clock](https://linear.app/rohun/issue/ROH-130/active-ride-time-is-computed-from-a-non-monotonic-wall-clock)
Parent spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D5, D6)
Status: revision 3. Revision 2 followed a three-reviewer gate on the spec; revision 3 follows a
three-reviewer gate on the plan, which found a defect in revision 2's own D5 and two decisions that
did more than they needed to. Each correction is marked inline.

Revision 1 proposed re-anchoring the recorder's stored wall stamps — rewriting `startedAt` and
`pauseStartedAt` in place whenever a clock step was detected, from inside the duration readers. All
three reviewers landed on that decision from different directions and it does not survive:

- Making a read mutate put correctness at the mercy of argument evaluation order.
  `checkpoint(at:)` reads `startedAt` at argument 3 and calls the re-anchoring reader at argument 7
  (`RideRecorder.swift:170-174`), so the row it writes would pair a pre-step start with a post-step
  end — the step preserved intact, in the ride's only durable copy across a jetsam kill.
- A ride ended while *not* paused calls no reader at all (`closePause` returns early at
  `RideRecorder.swift:154`), so the most common ride shape kept the bug outright.
- Three more wall stamps outlive a re-anchor and were not in the rule:
  `RideSessionCoordinator.startedAt` (`:75`), which is the one the Live Activity anchor is actually
  built from; `PendingCheckpoint.at` (`:87`), which `RideDuration.init` compares against `endedAt`
  and would have blanked a save-failure summary's durations; and `RideActivityAttributes.startedAt`,
  immutable for the activity's lifetime.
- `startedAt` is the value History renders (`HistoryView.swift:219`) and `LastRideCard` buckets into
  Today / Yesterday (`:109-117`). It is the only field in History that is not a measurement — it is
  the rider's index into their own memory — and revision 1 restated it silently and without a cap.

Revision 1's Problem section also had the sign backwards, and its central mitigation was a test that
could not fail. Both are corrected below and marked.

## Problem

Every duration the pause work produces is a difference of two `Date()` readings.

- `RideRecorder.pausedSeconds(asOf:)` (`RideRecorder.swift:133`) measures the stop in progress as
  `now.timeIntervalSince(pauseStartedAt)`.
- `RideSessionCoordinator.refreshElapsed` (`RideSessionCoordinator.swift:222`) measures active time
  as `now - startedAt - pausedSeconds`, with both terms wall-clock.
- `RideActiveClock.make` (`RideActiveClock.swift:39`) anchors the Lock Screen timer at a `Date`.
- `RideDuration.init` (`RideDuration.swift:51`) measures a finished ride as `endedAt - startedAt`.

`Date` is the system's notion of civil time, and iOS moves it. An NTP correction after a long
offline stretch, a NITZ update when the phone reacquires a carrier, a manual date change — each one
steps the clock, and every duration above steps with it.

### What actually goes wrong, per direction

*(Revision 1 had these swapped, and asserted a backward jump that the paused algebra does not
produce. Corrected.)*

`pausedSeconds(asOf:)` measures forward from a stamp in the past, so it is a **backward** step that
drives it negative and trips the `max(0,)` clamp at `RideRecorder.swift:135`.

**Riding, no stop open.** Active time is `now - startedAt`. A step of Δ moves the cockpit's TIME
cell by Δ in the same direction, once. The cell carries `.contentTransition(.numericText())`
(`InstrumentChassis.swift:122`), so it rolls rather than glitches. Recoverable-looking, and the ride
keeps the error to the end.

**Stopped, backward step.** The open stop's `now - pauseStartedAt` goes negative and clamps to zero.
While the clamp binds, the ride stops crediting the stop as paused time — so the active clock
counts the café stop as riding, and keeps counting until the wall clock climbs back past
`pauseStartedAt`. On a stop shorter than the step, the entire stop is lost. That number is not a
flicker: it is banked by `closePause` at `RideRecorder.swift:155`, persisted, and shows up in
History, in the widget, on the share card, and in Apple Health.

**Stopped, forward step.** Both `elapsed` and `pausedSeconds` grow by Δ and the subtraction cancels,
so the live active clock is unharmed. The persisted `elapsed` still carries Δ.

That last line is the one to hold on to: **today's wall-clock elapsed and wall-clock paused cancel
each other for a step taken during a stop.** Making one of them monotonic and not the other would
break a cancellation the code currently gets for free. Persistence has to move as a unit or not at
all — see D3.

All four call sites carry a `max(0,)` clamp today and four comments name this issue
(`RideRecorder.swift:145`, `RideDuration.swift:46`, `RideActiveClock.swift:57`,
`RideSessionCoordinator.swift:35`). A clamp turns a wrong number into a differently wrong number: it
cannot make a duration that spanned a clock step correct, because the information needed to correct
it was never captured.

*(Revision 1 said "two of the four" and called the active clock the largest numeral on the cockpit.
Both wrong: all four clamp, and the speed hero is `speedHero(150)` while the TIME cell is
`metricCockpit(34)` on the free-ride panel only — the navigate cockpit shows TO GO and ARRIVE and no
active-time cell at all (`InstrumentPanel.swift:24-30`). On a navigated ride the rider's only live
view of active time is the Lock Screen, which is why D5 is not a side concern.)*

### What this is not

This is not the GPS-clock rule that D6 rejected. That rule measured a stop against
`TrackPoint.timestamp`, a *third* clock — a replayed fixture carries the stamps it was recorded
with, and a real ride's last accepted fix can be minutes stale through a tunnel. The fix here reads a
clock that is not civil time at all and cannot be read from a track point.

## Approach

Capture two readings at every instant that matters: the wall clock, which is what gets persisted and
displayed, and a monotonic reading, which is what durations are measured with.

```swift
public struct RideInstant: Equatable, Sendable {
    public let date: Date
    public let monotonicSeconds: TimeInterval
}
```

One value rather than two parameters, so a caller cannot pass a mismatched pair.

**Stored wall stamps are written once, at their boundary, and never rewritten.** That is the
correction revision 1 needed. Everything a clock step would otherwise corrupt is either a duration,
which comes from the monotonic reading, or a *derived* value computed at the point of use — never a
stamp mutated in place behind a reader's back.

### D1 — `ContinuousClock`, not `SuspendingClock` and not `systemUptime`

On Darwin `ContinuousClock` is `mach_continuous_time`: it advances while the machine sleeps, it is
unsettable from userspace, and NTP cannot move it. `SuspendingClock` stops during sleep and
`ProcessInfo.systemUptime` is documented as time *awake* since restart. A phone in a jersey pocket
with the screen locked is exactly where the other two under-count, and a ride clock that loses the
sleeping minutes is a worse bug than the one being fixed.

The reading is `origin.duration(to: .now)` against a file-scope `let origin = ContinuousClock.now`,
converted to seconds. Both `ContinuousClock` and `InstantProtocol.duration(to:)` are iOS 16 /
macOS 13, comfortably under this package's `.iOS(.v17), .macOS(.v14)` floor
(`AuraCore/Package.swift:6`), so no availability gate. Not `ContinuousClock.systemEpoch` (SE-0473,
Swift 6.3), which is newer than needed; an arbitrary process-lifetime origin is sufficient because
nothing outside one process run ever subtracts two of these readings.

*(Revision 1 called that API `ContinuousClock.epoch`. It is an instance property named `systemEpoch`.)*

Conversion is explicit — `Double(components.seconds) + Double(components.attoseconds) * 1e-18` —
because `Duration` has no `TimeInterval` bridge. Both components carry the sign, so negative
durations convert correctly.

A reboot needs no handling: it terminates the process, so the origin is re-taken. Background
suspension needs none either — both clocks advance across it.

**Constraint this places on ROH-144.** Two monotonic readings are only comparable within one process
run. ROH-144 (a kill mid-ride with no pause writes nothing at all) will want to resume an
in-progress ride into a fresh process, and it cannot carry a monotonic elapsed across that boundary.
It will have to reconstruct elapsed from persisted wall stamps and accept the wall clock for the
pre-kill portion. Recorded here so that work does not discover it late.

### D2 — The recorder measures durations monotonically; its stamps do not move

`RideRecorder` keeps a monotonic base alongside each wall stamp it already holds: `startMonotonic`
beside `startedAt`, `pauseStartMonotonic` beside `pauseStartedAt`. Each pair is written and cleared
together, in the same statement, at exactly the three boundaries that already write them
(`start`, `pause`, `resume`).

Every duration the recorder reports is a difference of monotonic readings:

- `closedPausedSeconds`, accumulated by `closePause`
- `pausedSeconds(asOf:)` and `currentPauseSeconds(asOf:)`
- `elapsedSeconds(asOf:)`, new, replacing the coordinator's wall subtraction
- `activeSecondsAtPause`, frozen once inside `pause(at:)` — see D5

These are non-mutating reads. Nothing in this design writes state from a getter, so nothing depends
on where a name appears in an argument list.

`startedAt` and `pauseStartedAt` keep exactly the values they are stamped with. A rider's History
row shows the start time their phone showed them when they tapped Start, on every ride, corrected
clock or not.

The `max(0,)` floors stay. They are unreachable from a monotonic input, but two of them also floor a
*caller's* arithmetic: `RideDuration.init` reads a CloudKit-mirrored `Double`
(`RideSchemaV7.swift:42`) that no local invariant governs. They are not the same kind of guard as
the one D6 removes, and the distinction is the point.

### D3 — A *finished* ride's `endedAt` is derived, so elapsed and paused stay on one clock

The Problem section established that wall-elapsed and wall-paused cancel a step taken during a stop.
Making `pausedSeconds` monotonic without moving elapsed with it would break that cancellation and
make a case that is right today wrong. So `end(at:)` emits

```
endedAt = startedAt + elapsedSeconds(asOf: instant)
```

a pure expression evaluated at the boundary, not a mutation. Both persisted durations are then
monotonic: `endedAt - startedAt` is the monotonic elapsed by construction, and `pausedSeconds` is
monotonic by D2. `RideDuration` needs no change to its inputs, and no schema change is needed —
which matters, because ROH-108 holds the CloudKit production promotion until V7 so one trip covers
all three mirrored fields.

This also makes the summary agree with the HUD *exactly* rather than approximately. Both are
`monotonic elapsed − monotonic paused`, which is what parent D5 asks for.

**Why `endedAt` and not `startedAt`.** Both give a correct duration. `startedAt` is rider-facing —
History renders it, the Last Ride card buckets it into Today / Yesterday — and it is the value a
rider reads as a ride's identity. `endedAt` is rendered nowhere. Its consumers are the duration
itself, `RideWorkoutGate`'s nil check, `WidgetSnapshot`, and `WorkoutData`'s workout end
(`WorkoutData.swift:32`). Shifting the one nobody reads is the cheaper correction.

**Residual, stated rather than hidden.** After a backward step, the derived `endedAt` sits up to Δ
ahead of the current wall clock, and the HealthKit workout's end date shifts by the same Δ — which
is the correct duration, on a ride whose end instant the system's own clock disagrees about. The
plan checks that `WorkoutData` and `RideWorkoutGate` tolerate it.

**`checkpoint(at:)` is deliberately left alone.** *(New in revision 3; revision 2 derived both
boundaries.)* A checkpoint row writes `endedAt` and `checkpointedAt` to the same instant, and
`RideDuration.init` disqualifies it on exactly that equality — so the row reports no duration at
all, and there is nothing there for a monotonic correction to fix. Deriving one of the two stamps
would break the equality and start showing a duration on a row that has no business reporting one.
`checkpointedAt` is also the only one of these stamps that is *rendered*:
`UnfinishedRideCopy.swift:29` puts it in front of the rider as "Recording stops at 2:14 PM", and
`:40` repeats it in the warning before an irreversible all-devices delete. Shifting it by the size
of a clock step to fix a duration nobody reads would be a bad trade. Both of its stamps stay raw.

Deriving only `end(at:)` also makes `RideDuration`'s `checkpointedAt >= endedAt` disqualifier
(`RideDuration.swift:41`) strictly *harder* to trip on the save-failure path, because a backward
step moves the finished ride's `endedAt` later while the restored checkpoint stamp stays where it
was. That failure — a save-failure summary with no durations — is reachable today and stays out of
scope; it is filed as ROH-149.

### D4 — Active time keeps exactly one definition, and the guard learns the new way to break it

`scripts/check-single-active-definition.sh` is a build gate, so the shared primitive absorbs the
change rather than being worked around:

```swift
public struct RideElapsed {
    public let seconds: TimeInterval
    /// A monotonic measurement — `RideRecorder.elapsedSeconds(asOf:)`.
    public static func measured(_ seconds: TimeInterval) -> RideElapsed
    /// The interval between a finished ride's two stamps. Legal for a saved ride and nothing else.
    public static func betweenStamps(startedAt: Date, endedAt: Date) -> RideElapsed
}

public static func activeSeconds(elapsed: RideElapsed,
                                 pausedSeconds: TimeInterval) -> TimeInterval {
    max(0, elapsed.seconds - pausedSeconds)
}
```

Three callers: `RideSessionCoordinator.refreshElapsed`, `RideRecorder.pause(at:)` for the frozen
paused value, and `RideDuration.init`. The first two pass `.measured(recorder.elapsedSeconds(asOf:))`,
the third passes `.betweenStamps(startedAt:endedAt:)` — which by D3 is the same monotonic quantity.

**Why a wrapper and not a bare `TimeInterval`.** *(New in revision 3.)* The old signature forced its
elapsed to come from a `Date` pair. A bare `TimeInterval` lets a future author write
`activeSeconds(elapsedSeconds: now.timeIntervalSince(startedAt), …)` for a *live* clock and
reintroduce ROH-130 while still calling the one definition. Revision 2 answered that with a second
grep detector; the plan gate refuted it by executing it — `detect()` is line-anchored, the offending
call wraps across lines under the repo's 140-column limit, and the detector matched only its own
single-line self-test string. The invariant is "these two numbers came from the same clock", which a
grep is the wrong tool for.

`RideElapsed` does not make the mistake impossible, but it makes it require typing `betweenStamps`
at a live call site — a loud, single-token, reliably greppable act. So the script's second detector
becomes: `betweenStamps` may appear only in `RideDuration.swift`, which the script already excludes.
That is a detector a wrapped line cannot slip past.

`RideDuration` also gains `runningAnchor(startedAt:pausedSeconds:now:)` returning
`min(now, startedAt + pausedSeconds)`. It lives in `RideDuration.swift` because that file is the
script's only exemption and the expression it needs is `addingTimeInterval(pausedSeconds)`, which
the script otherwise rejects by design.

### D5 — The Live Activity's clock must be constant between discrete events

`RideActivityPushPolicy.decide` skips a push when the payload is unchanged
(`RideActivityPushPolicy.swift:41`), which keeps a forty-minute café stop down to one heartbeat push
a minute instead of one every four seconds. That dedupe is load-bearing against ActivityKit's
budget, and it compares whole payloads including the clock's associated `Date`s and `TimeInterval`s.

Today both cases are stable by an accident worth naming. `.running(anchor:)` is `now - activeSeconds`
where both terms come from the same wall reading, so `now` cancels; `.paused`'s `activeSeconds` is
`(now - startedAt) - (closed + (now - pauseStartedAt))`, where `now` cancels again. `Date` values sit
around 7.8e8, which quantizes them to a coarse grid, so the cancellation is exact rather than
approximately exact.

Feeding either expression a monotonic elapsed destroys that. `Date()` and `ContinuousClock.now`
cannot be sampled at the same instant, and the gap between them differs per tick, so every payload
becomes numerically distinct, `next != last` is true on every tick, and the push rate goes up
fifteenfold — during exactly the stop the dedupe exists for. Revision 1 named this trap and then put
its fix only in the `.running` branch, which is not the branch a stop renders. Both branches need it,
and neither is fixed by cancellation any more.

The fix is to stop deriving either value from `now`:

- **Paused.** `RideActiveClock.paused` carries a stop bundled as one value —
  `OpenStop { since: Date, activeSecondsAtPause: TimeInterval }` — both of which are stamped once,
  inside `pause(at:)`, and are literally unchanged for the length of the stop. Two optionals that
  must be non-nil together become one optional that cannot be half-supplied.
- **Running.** The anchor is `RideDuration.runningAnchor(startedAt:pausedSeconds:now:)`, built from
  the start stamp and `closedPausedSeconds`. Both move only at a pause boundary, so the anchor is
  constant between boundaries. The `min(now,)` keeps a future anchor — which `Text(_, style: .timer)`
  counts *down* from — off the Lock Screen; while that clamp binds, the anchor tracks `now` and costs
  a push per coalescing interval, which `RideActiveClock.swift:53-56` already documents as the
  accepted cost of the alternative.

**The wall-clock offset.** Anchors built from raw wall stamps are stable, but they never recover from
a step: the OS renders `now - anchor` on its own wall clock, so after a step the Lock Screen is off
by Δ for the rest of the ride while the cockpit is right. So the recorder maintains one
`wallOffset`, applied to `startedAt` and `pauseStartedAt` *for these two derived values only*:

```
expected = startedAt + wallOffset + elapsedSeconds(asOf: instant)
delta    = instant.date - expected
if |delta| > 2s { wallOffset += delta }
```

Updated in one explicit method, `align(at:)`, called once per ticker tick from `refreshElapsed` and
at each pause boundary. Never from a getter. Idempotent: after an update, `expected` recomputes to
the new offset and `delta` is zero.

**An offset is only valid for a stamp taken before it.** *(New in revision 3. Revision 2 added
`wallOffset` to both stamps unconditionally, which all three plan reviewers refuted independently,
and it is the worst defect either gate found.)* `wallOffset` converts a stamp taken on the *old*
clock onto the current one. `startedAt` always qualifies — `start()` zeroes the offset. `pauseStartedAt`
does not: it is stamped whenever the rider taps, which may be long after a step has already been
absorbed, in which case it is *already* on the corrected clock and adding the offset applies the
step twice. A rider who pauses after a backward step would see the Lock Screen's stop timer open at
0:40 instead of 0:00, and after a forward step it would open 40 s in the future and count *down* —
the failure the running branch's `min(now,)` clamp exists to prevent, reintroduced on the branch
that has no clamp. It is also a regression: today's raw `pausedSince` gets this case right.

So each stamp is stored with the offset in force when it was taken, and the anchor is the
difference:

```
anchorStartedAt   = startedAt      + (wallOffset - 0)
anchorPausedSince = pauseStartedAt + (wallOffset - wallOffsetWhenStopOpened)
```

which is the general rule; `startedAt`'s stamp-time offset is zero by construction. Because
`pause(at:)` aligns before it stamps, a stop opened after a step starts with its anchor equal to its
stamp and only moves on a *later* step.

`make` additionally clamps the paused case's `since` to `min(now, since)`, symmetric with the running
anchor's clamp. With the rule above it cannot bind, so it costs nothing; it is there because
`RideInstant.now` reads its two clocks a few instructions apart and a descheduled sample can
fabricate a small offset out of nothing, and a Lock Screen counting down is worse than a push.

The threshold keeps the offset discrete, which is what keeps the dedupe alive, and its only
consequence is Lock Screen anchor precision. `ContinuousClock` is not NTP-disciplined, so `delta`
accumulates the whole wall-vs-monotonic divergence since the ride started, and a long enough ride
will cross 2 s on slew alone — which costs one push and a 2 s anchor shift on a surface that renders
whole seconds. Revision 1 spent this threshold on a rider-facing timestamp and had to argue slew
could never reach it; here it buys a bounded imprecision on one derived value.

Nothing persisted and nothing in History depends on `wallOffset`.

### D6 — The push policy's own clock

`decide` compares `now.timeIntervalSince(lastPushedAt)` against the coalesce and heartbeat intervals
(`RideActivityPushPolicy.swift:35`), and both are wall-clock. A backward step of Δ drives
`sinceLastPush` negative, so *every* time-gated branch fails until the wall clock climbs back —
which stalls not only the clock correction but distance, speed and elevation on the Lock Screen, for
up to Δ + 4 seconds, with no stale dimming because the pushed `staleDate` moved out by the same Δ.

Fixing the anchors and leaving this in place would make "the Lock Screen self-heals in one push"
false by up to a minute on the spec's own opening example. So `decide` takes
`secondsSinceLastPush: TimeInterval?` instead of `lastPushedAt: Date` and `now: Date`, and
`RideLiveActivityController` tracks the last push on the monotonic reading. The policy is pure and
host-tested; the controller change is four lines in a type that imports ActivityKit and is verified
on device.

### D7 — The coordinator's clock is a seam, not a shim

Revision 1 proposed a test-only `Date` overload forwarding to
`RideInstant(date: date, monotonicSeconds: date.timeIntervalSinceReferenceDate)` and claimed every
existing test would keep asserting what it asserted. That is false in a way worth spelling out,
because it is the failure mode the shim was supposed to avoid.

The coordinator takes its own instants internally — `start()` at `:170`, `pause()` at `:236`,
`resume()` at `:277`, `finish()` at `:344` — while tests inject `Date`s into `refreshElapsed(now:)`
and `pushActivityUpdate(now:)`. Under the shim those two sources have monotonic origins about 8.07e8
seconds apart, so a test that calls `c.pause()` and then `c.refreshElapsed(now: someDate)` computes
a stop of roughly 780 million seconds. `RideSessionCoordinatorNudgeTests.swift:200` asserts
`currentPauseSeconds >= 599` and would pass on that; `:201` asserts `< 120` and would fail. Green
tests asserting nonsense are worse than red ones.

So the coordinator gets a real seam:

```swift
public protocol RideClocking { func now() -> RideInstant }
```

injected at construction, defaulting to `SystemRideClock()`. Not `Sendable`-constrained *(revision 3;
revision 2 wrote `: Sendable`)*: every consumer is `@MainActor`, so global-actor isolation already
covers the stored existential, and requiring `Sendable` would push the test fake — which is a
mutable box a test drives by hand — into `@unchecked Sendable` for nothing. Every internal `.now` read goes through
it. Tests inject `FakeRideClock`, which produces coherent pairs from a settable base — one origin
per test, no mixing possible. The four coordinator test factories
(`RideSessionCoordinatorTests.swift:20`, `RideSessionCoordinatorPauseTests.swift:18`,
`RideSessionCoordinatorNudgeTests.swift:27`, `RideSessionCheckpointFlushTests.swift:37`) each gain
one argument; the ~33 `Date`-injecting call sites keep working through `Date`-taking overloads that
share `FakeRideClock`'s convention.

`RideRecorder` reads no clock at all — every instant is injected — so a recorder-only test cannot
mix origins by construction. Its existing `Date`-taking call sites keep working through the same
convention, declared in `AuraCore/Tests/AuraKitTests/Support/`.

`RideDuration` and `RideActiveClock` live in AuraCore, whose test target does not import AuraKit, so
no shim reaches them. `ActiveTimeAgreementTests` (5 call sites) and `RideDurationTests` (2) are
edited directly to the new signatures. This is stated because revision 1 claimed those suites
compiled unchanged, and they do not.

`scripts/check-monotonic-instants.sh` fails the build if `RideInstant(date:` appears under
`Sources/` outside `RideInstant.swift` itself — the file that has to construct one. A filename
exemption is the same mechanism the sibling guard uses, and the same blind spot; it is a tripwire
against drift, not a proof.

## Surfaces that change

| Surface | Before | After |
|---|---|---|
| Cockpit TIME cell (free ride) | steps with the system clock | monotonic |
| Cockpit paused chip | clamped non-decreasing, can freeze | monotonic |
| Lock Screen / Dynamic Island | anchored on a stepping wall clock, pushes stall after a backward step | offset-corrected, one push behind |
| Ride summary active + elapsed | spans the step | monotonic, exactly equal to what the HUD showed |
| History start time | — | **unchanged, deliberately** |
| History rows, widgets, share card | read the persisted ride | inherit the fix, no code change |

## Out of scope

Each of these was raised at the gate and is being left, not overlooked.

- **Track-point timestamps.** `RideStatsCalculator` computes `dt` between point timestamps
  (`:72`), so moving time and average speed still ride the wall clock, and a leg spanning a step is
  dropped from moving time while its distance is still counted. On the summary that means active is
  step-free and the moving cell beside it is not. `WorkoutWriter` has a sharper version: a backward
  step makes the route locations non-monotonic, `insertRouteData` rejects them, and the `catch` at
  `WorkoutWriter.swift:101` swallows it — a Health workout with no map and no in-app signal. Filed
  as a follow-up.
- **Local peer aging.** `PeerStatus` ages peers with `now.timeIntervalSince(lastUpdate)` on the
  *local* wall clock (`:38-41`), no wire involved. A forward step larger than `droppedTimeout` greys
  out the whole crew at once. The group-ride carve-out below is about wire timestamps and does not
  cover this; filed as a follow-up.
- **Group-ride wire timestamps.** Peers exchange wall-clock instants across devices, where a shared
  monotonic base does not exist. Separate problem, separate clock discipline.
- **`checkpointedAt >= endedAt` on the save-failure path.** Reachable today; D3 makes it harder to
  reach, not impossible. Filed as a follow-up.
- **Time zone and DST.** `Date` is an absolute instant; neither affects a duration. Worth one note
  for triage: History renders `startedAt` in the *current* zone, so a rider who flew home already
  sees a start time that does not match their memory. That is a display convention, not this bug.
- **The widget process's rendered timer.** Runs on the OS wall clock inside the widget process. No
  app-side change reaches it; D5 bounds the correction to one push instead.
- **Auto-pause (Slice B).** Unchanged in either direction.

## Testing

Host-testable in the package, which is where every collaborator here already lives.

**A clock step is applied and observed.** Each fixture drives a `FakeRideClock` whose wall and
monotonic readings diverge by a stated amount.

1. Backward step of 40 s mid-stop: the paused chip does not fall and the active clock does not jump.
2. Backward step longer than the stop: the whole stop is still credited as paused. This is the case
   that is durably wrong today.
3. Forward step of 40 s mid-stop: neither number jumps.
4. A step spanning a pause and a resume: `pausedSeconds` equals the real stop length.
5. **A step mid-ride on a ride with no pause at all**, then `end()`: the persisted `elapsedSeconds`
   and `activeSeconds` match the monotonic truth, `startedAt` is byte-identical to the value passed
   to `start()`, and `endedAt` has moved. This is the shape revision 1 missed entirely.
6. `checkpoint(at:)` after a step: same, and the row's `startedAt` still matches.

7. **A step, and then a pause** — the case revision 2's D5 got wrong. The Lock Screen's stop timer
   opens at zero and the cockpit chip agrees with it.
8. A step, a pause, and then a *second* step: both anchors move by the second step only.

**Negative controls**, per the ROH-103 lesson that a test which cannot fail proves nothing.

*(Revision 3 corrects revision 2's claim here. Revision 2 said every step fixture asserts its own
step is present. That is not achievable for the duration fixtures and the plan gate proved it: a
stepped instant puts the whole divergence in its wall half, and no duration reads the wall half, so
substituting a coherent instant leaves those fixtures green. They still catch a production
regression back to wall subtraction, which is what they are for. What they cannot do is police the
fixture generator, so the controls below carry that instead.)*

9. One test computes the *old* wall-clock expression over fixture 2's readings and asserts it differs
   from the new result, pinning that the fixture exercises the defect.
10. One test asserts directly that a stepped instant's wall and monotonic halves disagree by the
    stated amount, so a generator that quietly made them coherent fails here.
11. The anchor fixtures (7, 8) *are* wall-sensitive by construction and need no separate control.

**Live Activity stability.** This is where both gates found unfalsifiable tests, from opposite
directions, so the rule is explicit: **these fixtures run through the coordinator, not through
`RideActiveClock.make`.** After D5, `make`'s paused branch is a field copy — a pure-function test
over it asserts that a constant equals itself and cannot fail for any implementation. The place
stability can actually break is the wiring: whether `activeSecondsAtPause` and `anchorPausedSince`
hold still while `align` runs and the ticker turns.

12. Forty coordinator ticks across a stop, each running `refreshElapsed` *and* `pushActivityUpdate`,
    produce one distinct pushed clock. Driven at production magnitude with tick intervals that are
    not exact binary fractions, because `Date`-magnitude readings on exact half-seconds are the
    condition under which the old arithmetic cancelled exactly and the old version of this test
    could not fail.
13. The same forty ticks with a sub-threshold divergence of 1.9 s still produce one distinct clock,
    so slew alone cannot make `align` flap and turn a café stop into a push every four seconds.
14. A tick carrying a real step produces exactly one distinct new clock and a `.push`, and the ticks
    after it are identical again.
15. `decide` returns `.push` within one coalesce interval after a backward step (D6), driven on
    `secondsSinceLastPush`.

The four `RideActiveClock` tests that today pin the paused branch's arithmetic
(`RideActiveClockTests.swift:45,58,68,81`) lose their subject when that arithmetic moves into
`RideRecorder.pause(at:)`. They move with it, as recorder-level tests in `AuraKitTests` — including
the "second stop freezes active time net of the first stop" case and the clamp-at-zero case, which
`RideOpenStop` does not enforce and the recorder now must.

**Regression.** Recorder, coordinator, duration, active-clock, mapper, store and golden-ride suites
run through the D7 seam. Two suites are edited, not shimmed: `ActiveTimeAgreementTests` and
`RideDurationTests`. `RideSessionCoordinatorNudgeTests.startingAFreshRideZeroesTheStopClock`
(`:224-238`) asserts `currentPauseSeconds == 0` synchronously after `start()`, before any tick — so
`start()`'s reset at `:176` stays. Revision 1 proposed deleting it as clamp scaffolding; it is the
only synchronous zeroing on the reused-coordinator path.

## Device verification

The bug needs a clock change, so the pass is scripted rather than impressionistic.

**It gets its own Linear issue, and the merge does not close it.** *(New in revision 3.)* Nothing
in the package suite can see the Lock Screen, which is where this change's worst failure mode lives
and where a navigated ride's only active-time reading is. This repo has also watched a merged PR
auto-complete a verification issue in Linear that nobody performed, so the device pass is tracked
separately from ROH-130 rather than as a line in its description.

1. **No-step control first.** Ride two minutes, pause for two minutes, resume, End. With
   `log stream --predicate 'subsystem == "app.aura"'` counting activity updates, confirm the stop
   produced heartbeat-rate pushes, not coalesce-rate. This is the only signal for the regression with
   the widest blast radius, and it needs no clock change at all.
2. **Backward step.** Start a ride, ride 3 minutes, note the TIME cell. Set the date back one minute
   in Settings. Expect: TIME unchanged; Lock Screen corrects within about four seconds and distance
   keeps moving throughout.
3. **Forward step during a stop.** Pause, note the chip, set the date forward one minute. Expect: the
   chip keeps counting from where it was, and the TIME cell stays frozen.
4. **Step, then pause** — the case revision 2 got wrong, in both directions. While riding, change
   the date by a minute, wait for the Lock Screen to settle, then pause. Expect: the Lock Screen's
   stop timer starts at 0:00 and counts *up*. A timer that opens at 0:60, or one that counts down,
   is the double-correction defect.
5. **End and read the summary**, then open History. Expect: active equals the last TIME cell reading;
   elapsed equals active plus the stop; and the History row's start time is the one shown at Start.
   Step 5 is where D3 is observable at all, and revision 1's device pass never opened either screen.

iOS's Date & Time picker zeroes the seconds, so the applied step is one minute minus the current
seconds. Read it off the clock before changing it rather than assuming 60.

## Risks

| Risk | Mitigation |
|---|---|
| The 2 s threshold is a fudge factor | It is. Its only consumer is the Live Activity anchor (D5), where 2 s is below what the surface renders. It no longer governs anything persisted or rider-facing. |
| `endedAt` lands ahead of the wall clock after a backward step | Nothing renders it. The plan checks `WorkoutData` and `RideWorkoutGate` tolerate it, and it makes `RideDuration`'s checkpoint disqualifier harder to trip, not easier. |
| The Live Activity push rate regresses on rides with no step | Fixtures 12–14, driven through the coordinator at production magnitude, plus device step 1. Both earlier versions of this test could not fail — revision 1's because the arithmetic cancelled exactly at `Date` magnitude, revision 2's because it tested a field copy against itself. |
| An anchor is corrected twice, or not at all | Each stamp carries the offset in force when it was taken (D5), and fixtures 7 and 8 cover step-then-pause in both directions. This is the defect the plan gate found in revision 2 and it had no test at any level. |
| `align` flaps and pushes every coalescing interval | It is idempotent, so a correction leaves `delta` at zero and the next one has to re-accumulate the whole threshold. Fixture 13 pins that a sub-threshold divergence changes nothing. |
| The Health workout write silently produces nothing for a backward-stepped ride | `WorkoutWriter`'s `catch` swallows failures, so the plan reads the builder call itself rather than only the two pure types that feed it. If `HKWorkoutBuilder` rejects a future end date, that is a stop-and-report, not a clamp. |
| `RideInstant` threading misses a call site | Required at every boundary, so a miss is a compile error. The one escape hatch is a build script (D7). |
| `RideInstant.now` samples two clocks non-atomically | With no stamp mutation and no persisted threshold, a descheduled sample perturbs one reading's pair and nothing else. The only consumer of wall-vs-monotonic agreement is `wallOffset`, which self-corrects on the next tick. |
| The summary's moving cell still rides the wall clock | Named in scope-out, filed as a follow-up. The summary shows active, elapsed and moving together, so a step makes them disagree until that lands. |
