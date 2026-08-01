# A monotonic ride clock (ROH-130) — design

Date: 2026-08-01
Issue: [ROH-130 — Active ride time is computed from a non-monotonic wall clock](https://linear.app/rohun/issue/ROH-130/active-ride-time-is-computed-from-a-non-monotonic-wall-clock)
Parent spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D5, D6)
Status: revision 1.

## Problem

Every duration the pause work produces is a difference of two `Date()` readings.

- `RideRecorder.pausedSeconds(asOf:)` (`RideRecorder.swift:133`) measures the stop in progress as
  `now.timeIntervalSince(pauseStartedAt)`.
- `RideSessionCoordinator.refreshElapsed` (`RideSessionCoordinator.swift:222`) measures active time
  as `now - startedAt - pausedSeconds`, with both terms wall-clock.
- `RideActiveClock.make` (`RideActiveClock.swift:39`) anchors the Lock Screen timer at a `Date`.
- `RideDuration.init` (`RideDuration.swift:51`) measures a finished ride as `endedAt - startedAt`.

`Date` is the system's notion of civil time, and iOS moves it. An NTP correction after a long
offline stretch, a NITZ update when the phone reacquires a carrier, a manual date change — each
one steps the clock, and every duration above steps with it.

A rider on a two-hour ride through canyon country reacquires signal at the ninety-minute mark and
the carrier's time is 40 seconds behind. The headline active clock on the cockpit — the largest
numeral on the screen — jumps backward 40 seconds. If the step were forward, `pausedSeconds` for a
stop in progress would go negative and the `max(0,)` clamp would pin the paused chip at zero, so
the active clock would count the entire stop as riding.

Two of the four call sites already carry `max(0,)` clamps and a comment naming this issue. A clamp
turns a wrong number into a differently wrong number: it cannot make a duration that spanned a
clock step correct, because the information needed to correct it was never captured.

The parent spec's risk table claims monotonicity is asserted across a pause and a resume. It is
asserted against pause and resume, not against a clock set.

### What this is not

This is not the GPS-clock rule that D6 rejected. That rule measured a stop against
`TrackPoint.timestamp`, which is a *third* clock — a replayed fixture carries the stamps it was
recorded with, and a real ride's last accepted fix can be minutes stale through a tunnel. The fix
here reads a clock that is not civil time at all and cannot be read from a track point.

## Approach

Capture two readings at every instant that matters: the wall clock, which is what has to be
persisted and displayed, and a monotonic reading, which is what durations are measured with.

```swift
public struct RideInstant: Equatable, Sendable {
    public let date: Date
    public let monotonicSeconds: TimeInterval
    public static var now: RideInstant { ... }
}
```

One value rather than two parameters, so a caller cannot pass a mismatched pair.

### D1 — `ContinuousClock`, not `SuspendingClock` and not `systemUptime`

`ContinuousClock` keeps incrementing while the machine is asleep. `SuspendingClock` does not, and
`ProcessInfo.systemUptime` is documented as time *awake* since restart. A phone in a jersey pocket
with the screen locked is exactly the case where the other two under-count, and a ride clock that
loses the sleeping minutes is a worse bug than the one being fixed.

The reading is `origin.duration(to: .now)` against a process-wide `let origin = ContinuousClock.now`,
converted to seconds. Not `ContinuousClock.epoch` (SE-0473): it is a recent stdlib addition and
would need an availability gate, and an arbitrary process-lifetime origin is sufficient because
nothing outside one process run ever subtracts two of these readings.

Conversion is explicit — `Double(components.seconds) + Double(components.attoseconds) * 1e-18` —
because `Duration` has no `TimeInterval` bridge and the obvious `/ 1e18` on a whole `Duration` is
not one.

### D2 — The recorder measures durations monotonically and re-anchors its wall stamps

`RideRecorder` keeps a monotonic base alongside each wall stamp it already holds: one for the
ride's start, one for the stop in progress. Every duration it reports — `closedPausedSeconds`,
`pausedSeconds(asOf:)`, `currentPauseSeconds(asOf:)`, and a new `elapsedSeconds(asOf:)` — is a
difference of monotonic readings.

That alone fixes the live clocks and leaves a second defect: `startedAt` and `endedAt` are wall
stamps taken on either side of the step, so a finished ride's `endedAt - startedAt` still carries
it, and the Live Activity's anchor, which is a wall `Date`, still carries it.

So the recorder also re-anchors. On every reading it compares the wall clock it was handed against
the wall clock its own monotonic elapsed predicts:

```
expected = startedAt + (instant.monotonicSeconds - startMonotonic)
delta    = instant.date - expected
```

When `|delta| > 2s` the system clock stepped, and the recorder shifts `startedAt` and
`pauseStartedAt` forward by `delta`. Both stamps then sit on the corrected clock, which is the
better one: the pre-correction `startedAt` was stamped by a clock the system has since disowned.

**Why a threshold and not an unconditional re-derivation.** `Date` is slewed, not only stepped —
NTP corrects small offsets by running the clock slightly fast or slow. An unconditional
`startedAt = endedAt - elapsed` would let that slew move a ride's start time-of-day by a second or
two on every ride, restating history for no benefit and breaking the frozen literals the
golden-ride harness pins. Two seconds is comfortably above any slew NTP will apply over a ride and
far below the smallest step worth correcting.

**Why the shift is idempotent.** After a shift, `expected` is recomputed from the new `startedAt`,
so `delta` is zero until the next step. A step is corrected once, not compounded per tick.

### D3 — No schema change

`pausedSeconds` is already persisted (`RideSchemaV7.swift:42`) and becomes step-free by D2.
`startedAt` and `endedAt` are already persisted and become step-free by re-anchoring. Nothing new
needs a column, which matters: ROH-108 holds the CloudKit production promotion until V7 so one
trip covers all three mirrored fields, and adding a V8 field here would reopen that.

### D4 — Active time keeps exactly one definition

`scripts/check-single-active-definition.sh` is a build gate, so the shared primitive has to absorb
the change rather than be worked around.

`RideDuration.activeSeconds` loses its `startedAt:asOf:` parameters and takes the elapsed seconds
directly:

```swift
public static func activeSeconds(elapsedSeconds: TimeInterval,
                                 pausedSeconds: TimeInterval) -> TimeInterval {
    max(0, elapsedSeconds - pausedSeconds)
}
```

Live callers pass `recorder.elapsedSeconds(asOf:)`, which is monotonic. The finished-ride
initializer passes `max(0, endedAt - startedAt)`, which is wall-clock and correct because both
stamps are re-anchored. One definition, two sources of elapsed, and the guard script keeps
working unchanged.

`RideDuration` also gains `runningAnchor(startedAt:pausedSeconds:now:)`, returning
`min(now, startedAt + pausedSeconds)`. It lives in `RideDuration.swift` because that file is the
guard script's only exemption and the expression it needs is `addingTimeInterval(pausedSeconds)`,
which the script otherwise rejects by design.

### D5 — The Live Activity's two anchors must not jitter

`RideActivityPushPolicy.decide` skips a push when the payload is unchanged
(`RideActivityPushPolicy.swift:41`), which is what keeps a forty-minute café stop down to one
heartbeat push a minute instead of one every four seconds. That dedupe is load-bearing against
ActivityKit's budget, and it compares whole payloads including the clock's associated `Date`s.

Today both anchors are stable by construction: `.running(anchor:)` computes `now - activeSeconds`
where both terms come from the same wall reading, so the wall term cancels exactly, and
`.paused(since:)` carries a stored stamp.

Deriving `activeSeconds` from a *different* clock breaks that cancellation. `wallNow - monotonicActive`
drifts by microseconds every tick, every payload becomes distinct, and the push rate goes up
fifteenfold during precisely the stop the dedupe exists for. This is the trap in the change, and
the fix is to stop deriving the anchors from `now` at all:

- `.running(anchor:)` becomes `RideDuration.runningAnchor(startedAt:pausedSeconds:now:)`, built
  from the re-anchored `startedAt` and the monotonic `pausedSeconds`. Both move only at a pause
  boundary or a clock step, so the anchor is constant between them. The `min(now,)` keeps a future
  anchor — which `Text(_, style: .timer)` would count *down* from — off the Lock Screen.
- `.paused(since:)` carries `recorder.pausedSince`, the re-anchored stop stamp, which is likewise
  constant except at a step.

A real clock step changes both, emits one push, and the Lock Screen corrects itself. That is the
intended behavior, not a regression in the dedupe.

The Live Activity's *rendered* timer still runs on the OS's wall clock inside the widget process,
which no app-side change can reach. A step moves what the Lock Screen shows until the next push
lands. Bounding that to one push interval is the whole of what is achievable here, and it is
stated rather than claimed away.

### D6 — The coordinator's non-decreasing clamp goes

`RideSessionCoordinator.currentPauseSeconds` is currently clamped with
`max(currentPauseSeconds, ...)` (`RideSessionCoordinator.swift:226`) — ROH-101's cheap local guard
against exactly this bug. Its input is now monotonic and cannot decrease, so the clamp can no
longer fire. A guard that cannot fire is a guard nobody can test, and this repo has shipped one
before; it goes, and the test that pinned it is retargeted at the monotonic guarantee instead. The
`start()` and `resume()` resets that exist only to keep the clamp honest go with it.

The `max(0,)` floors inside the recorder stay. They are now structurally unreachable from a
monotonic input, but they also floor a caller's arithmetic and cost nothing.

### D7 — Existing tests keep their `Date` API through a test-only shim

`RideRecorder`'s time-injected methods are called 130-odd times across the suite with a bare
`Date`. Rewriting all of them would be a large mechanical diff that reviews as noise and hides the
handful of call sites where the change is real.

Instead, a `Date`-taking overload for each boundary lives in `AuraCore/Tests/AuraKitTests/Support/`,
forwarding to `RideInstant(date: date, monotonicSeconds: date.timeIntervalSinceReferenceDate)` — a
coherent pair, no step. Every existing test compiles unchanged and keeps asserting what it
asserted. New tests that need a step build the pair explicitly.

The shim is in the test target, so production code cannot reach it and cannot accidentally
fabricate a monotonic reading from a wall clock. `scripts/check-monotonic-instants.sh` additionally
fails the build if `RideInstant(date:` appears anywhere under `Sources/`, because "production
cannot reach it" is a property of a directory layout that a future author can change without
noticing.

## Surfaces that change

| Surface | Before | After |
|---|---|---|
| Cockpit headline active clock | steps with the system clock | monotonic |
| Cockpit paused chip | clamped non-decreasing, can freeze | monotonic |
| Lock Screen / Dynamic Island | anchored on a stepping wall clock | re-anchored, self-heals in one push |
| Ride summary active + elapsed | spans the step | step-free via re-anchored stamps |
| History rows, widgets, share card | read the persisted ride | inherit the fix, no code change |

## Out of scope

- **Group-ride wire timestamps.** Peers exchange wall-clock instants across devices, where a
  shared monotonic base does not exist. Separate problem, separate clock discipline.
- **Time zone and DST.** `Date` is an absolute instant; neither affects a duration.
- **Auto-pause (Slice B).** Unchanged by this work in either direction.
- **The widget process's rendered timer.** Covered in D5. Not reachable from the app.

## Testing

Host-testable in the package, which is where every collaborator in this design already lives.

**New suite — a clock step is applied and observed.**

1. Backward step of 40 s mid-stop: the paused chip does not fall and the active clock does not
   jump forward.
2. Forward step of 40 s mid-stop: the paused chip does not jump and the active clock does not
   stall at zero.
3. A step spanning a pause and a resume: `pausedSeconds` equals the real stop length.
4. A step mid-ride, then `end()`: the persisted ride's `elapsedSeconds` and `activeSeconds` match
   the monotonic truth, and `startedAt` has moved by the step while `endedAt` has not.
5. A sub-threshold discrepancy (0.5 s): `startedAt` is untouched.

**Negative controls**, per the ROH-103 lesson that a test which cannot fail proves nothing:

6. Each step fixture asserts the step is actually present — that the wall delta and the monotonic
   delta disagree by the expected amount — so a shim that quietly made them coherent would fail
   the test rather than pass it vacuously.
7. A test that computes the *old* wall-clock expression over fixture 1's readings and asserts it
   differs from the new result, pinning that the fixture exercises the defect.

**Live Activity dedupe.**

8. Twenty ticks across a stop with no step produce one distinct payload, so
   `RideActivityPushPolicy.decide` returns `.skip` for all but the first — the D5 jitter trap,
   pinned.
9. A tick carrying a step produces a distinct payload and a `.push`.

**Regression.** The existing recorder, coordinator, duration, active-clock, mapper and
golden-ride suites all run unchanged through the D7 shim. Any that fail are a real behavior
change and get read, not silenced.

## Device verification

The bug needs a system clock change to reproduce, so the device pass is: start a ride, ride for a
few minutes, pause, change the date manually in Settings by a minute in each direction, and watch
the cockpit clock and the Lock Screen. Both should be undisturbed apart from the Lock Screen's
one-push correction. Recorded on the issue as the ROH-130 device pass.

## Risks

| Risk | Mitigation |
|---|---|
| The 2 s threshold is a fudge factor | Stated as one. Below it nothing is corrected and nothing is wrong enough to matter; above it a real step is corrected once. Fixture 5 pins the lower side. |
| Re-anchoring `startedAt` restates a ride's start time-of-day | Only above the threshold, only when the system itself has disowned the old clock, and the direction is toward truth. |
| `RideInstant` threading misses a call site | The type is required at every boundary, so a missed site is a compile error, not a silent wall-clock read. The one escape hatch is guarded by a build script (D7). |
| The Live Activity push rate regresses | D5's dedupe is a named trap with a test (fixture 8), not a hope. |
