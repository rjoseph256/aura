# Cockpit pause control, paused state, haptics, nudge (ROH-101, Pass 4): design

Slice A, Pass 4 of 6 of the segmented-rides epic (ROH-74). The parent design is
[2026-07-26-segmented-rides-pause-design.md](2026-07-26-segmented-rides-pause-design.md);
this document resolves its D9 into something buildable and answers the two layout constraints
D9 named but left open. It also picks up three obligations
[ROH-105's D5](2026-07-27-roh105-dead-peer-split-deletion-design.md) assigned to this pass by name.

Blockers are clear: ROH-100 (schema V6), ROH-105 (dead peer parameters) and ROH-107
(unfinished-ride treatment) are all merged to main.

**Revision 2.** Three independent reviewers refuted revision 1. Every correction is folded in
below; the ones that changed a decision rather than a sentence are listed under
"What revision 1 got wrong", so the reasoning is not lost.

## What Pass 4 is

Passes 1 to 3 shipped a segmented ride model, a recorder state machine and a CloudKit schema
change without altering one pixel a rider sees. Pass 4 is where the rider gets the feature, and
it is the epic's commitment point.

Pass 2 already landed the machinery. `RideSessionCoordinator.pause()` and `resume()`
(`RideSessionCoordinator.swift:191-212`) close and open segments, stop the active clock, release
the wake lock, and notify `pauseObserver` synchronously so a draining arrival cannot end the ride
under a rider who just stopped. A pause above the discard floor also flushes a recovery checkpoint
(`RideSessionCoordinator.swift:223-238`, gated at `:228`). `RideRecorder` zeroes the smoothed speed
on pause and resets the smoother on resume (`RideRecorder.swift:95-119`). None of it has a caller.

So Pass 4 adds no ride logic. It adds a control, a state the rider can read on three surfaces,
two haptics, a notification, VoiceOver, and two test identifiers.

## Scope

- A primary pause/resume control in the bottom cockpit of both HUDs.
- A paused state legible at a glance on a bar-mounted phone, on the cockpit, on the map ribbon,
  and on Navigate's turn card.
- Haptic confirmation on both transitions, and silence from the haptics that should not fire
  while stopped.
- A local notification ladder after a long pause, so a forgotten resume is survivable.
- VoiceOver label plus a state announcement, and `RideTestID` entries for Pass 6.

Not in scope: anything that changes what a pause does to the ride. Pass 2 owns that.

## Decisions

### P1: haptics and the nudge belong to the coordinator, not the views

Both HUDs would otherwise duplicate the same side effects, and a SwiftUI body is the one place in
this codebase that cannot be tested on the macOS CI host. Those two reasons carry the decision.
(Revision 1 added a third, that a view-level cancel would miss `cancel()`. That was false:
`cancel()` is invoked from the views' own `onDisappear` closures.)

`RideHapticCue` gains `.pause` and `.resume`, and the coordinator takes the existing
`HapticPlaying` seam (`HapticPlaying.swift:8-13`). Two shipped doc comments become false and are
updated in the same commit: `HapticPlaying.swift:5-7` says the seam is guidance-scoped and
explicitly not the coordinator's, and `RideHapticCue.swift:1-2` scopes cues to a navigated ride.

The nudge seam splits authorization from scheduling, because merging them is what made revision 1
unimplementable:

```swift
@MainActor
public protocol RideNudgeScheduling: AnyObject {
    /// Ask the system once, if it has not been asked. Returns whether nudges may be posted.
    func requestAuthorizationIfNeeded() async -> Bool
    /// Schedule the ladder, replacing any already scheduled.
    func scheduleForgottenPauseNudges(startingAt: Date)
    /// Remove every pending and already delivered nudge.
    func cancelForgottenPauseNudges()
}
```

**Both seams are required constructor parameters, not optional ones.** Revision 1 made them
optional so existing call sites kept compiling. That is precisely the defect: there are four
injection points (two HUDs, two seams), forgetting any one of them compiles clean, passes every
host-side test (they inject their own doubles) and ships the feature dead on one HUD. This repo
has shipped exactly that failure before, which `TrackRibbon.swift:13-14` records. Required
parameters cost fourteen mechanical test-site edits and make the miswiring impossible.

**No `prepare()` at ride start.** Revision 1 proposed warming the feedback generators when the
ride starts. `UIFeedbackGenerator.prepare()` is documented for events that are *imminent*; the
engine drops out of the prepared state within seconds and holding it costs power. A pause forty
minutes later pays the warm-up regardless, so the call would be cost without benefit.

**Turn haptics stop while paused.** `GuidanceViewModel` already suppresses spoken instructions
when paused (`GuidanceViewModel.swift:104-106`) but `applyProgress` fires the turn haptic
unconditionally. A rider at lunch with the phone pocketed gets buzzed about turns they are not
taking, and on an accidental pause the surviving buzz masks the fact that the voice has stopped.
Same gate, same reasoning as the voice.

**Pause and resume haptics are not gated on the turn-haptics setting.** That setting
(`NavigateHUDView.swift:228`) governs guidance cues. These are confirmations of a rider's own tap,
the same class as the ungated mark-spot haptic at `RideHUDView.swift:251`, and a rider who tapped
a control is entitled to know it registered.

### P2: the control is one cockpit row whose layout changes with state

A new row in `bottomCockpit` on both HUDs, between the control-cluster row and the instrument
panel (`RideHUDView.swift:255-277`, `NavigateHUDView.swift:451-482`), 56 pt tall in both states so
nothing below it moves when the rider taps. 56 pt is `HUDControlMetrics.ride.resolvedHitTarget`,
the target ROH-75 settled on for a moving rider.

| State | Row contents |
| -- | -- |
| Recording | A compact capsule on the trailing edge, `pause.fill` plus "Pause" |
| Paused | `PAUSED 4:12` chip on the leading edge, "Resume" as a mint-filled capsule filling the rest of the row |

**Resume is the wider control, and revision 1 had this backwards.** It made Pause full-width and
Resume a 180 pt minimum, which inverts D9's stated reasoning and puts the largest tap target on
the ride screen at the bottom edge, where a rain film and a supporting thumb both land, for an
action taken on a minority of rides. Pause is pressed deliberately while stopping and needs no
more than a comfortable target. Resume is pressed while clipping in, gloved and one-handed, and
gets the rest of the row. The two states then differ in shape across the full width of the
screen, which is a stronger glance signal than a fill colour.

Mint, not amber. `CTAButtonStyle` already fills primary actions with `AuraTheme.accent`
(`CTAButtonStyle.swift:32`), so a mint-filled Resume is the app's existing primary-action
treatment rather than a new swatch. Amber stays where it is, carrying peer-stopped and
`AuraTheme.warning` for weak or lost GPS (`GPSSignalChip.swift:18-21`).

`UnfinishedRideBadge.swift:12-14` says the rider "just learned `pause.circle` in the HUD". This
pass ships `pause.fill` in a labelled transport control, which is the right glyph beside a word,
so that comment is corrected in the same commit rather than left false.

### P3: the roster constraint resolves by construction, and the SE cap gets a guard

The roster is a sibling inside the cluster row's `HStack`, not an overlay
(`NavigateHUDView.swift:451-473`). Siblings in a stack cannot overlap, so a row inserted below
that `HStack` cannot be covered at any roster height. D9's premise that the roster "overlaps the
cockpit" was the thing that was wrong.

The real cost is vertical, and on a group navigate ride the column now stacks a turn card, a
roster capped at 40%, a four-entry cluster, the new pause row, and a panel pinned at 25%. An
over-tall column does not clip: it overflows upward and pushes the cluster, including End, under
the turn card.

So the cap stops being a literal. `NavigateHUDView.swift:456`'s `0.4` becomes a named constant
with a test pinning it, so "reduce the roster cap" is a one-line change with a regression guard
rather than something remembered from a device session. The stack is measured on an iPhone SE
before this ships, and the cap is the lever if it overflows.

### P4: paused is carried on four surfaces, and the map ribbon is one of them

D9 requires an indicator that is not only a recoloured button. ROH-105's D5 goes further and
requires Navigate's paused state to be *positively* signalled rather than signalled by
subtraction. Four signals, then:

1. **The chip** in the cockpit row, with a live count of the current stop. This is the positive
   signal, and it is the one a VoiceOver rider gets.
2. **The control** filled mint, reading Resume.
3. **The map ribbon.** `TrackRibbon.Piece` gains a `style` field (`.recorded` / `.paused`), set by
   a pure function that takes the paused flag, so the trailing segment of a paused ride strokes
   differently and the map itself says recording has stopped. This is the discriminator ROH-105's
   D5 demanded: a unit-tested value in AuraCore rather than another clause in
   `RideMapView.swift:115`'s ternary, which lives in the app target this repo treats as untestable.
   Still one piece per segment, so `sourceIndex` stays unique and
   `TrackRibbonTests.test_sourceIndicesAreUnique` keeps its meaning.
4. **The held cockpit**, at secondary weight. `InstrumentChassis` takes an `isPaused` flag; on
   Navigate the turn card takes the same treatment, so a bar-mounted rider does not read a bright
   live turn instruction during a stop.

Two constraints on how the fourth is written. It must use `AuraTheme.textSecondary`, which
`AuraPaletteContrastTests` guards against the panel, and **not** an opacity multiplier on
`textPrimary`, which no test covers and which would fail contrast silently. And it must not add an
accessible child inside `InstrumentChassis`, whose one-composed-element invariant
(`InstrumentChassis.swift:8-10`) is a comment rather than a test.

Navigate's ARRIVE goes to "–" while paused. `InstrumentPanel.swift:22` already renders
`trip.eta ?? "–"`, so this is a fallback that exists, not new behaviour. Revision 1 called a
dimmed-but-still-counting ETA an acceptable limitation; it is a wrong number in one of only two
secondary readouts, and after a 45-minute lunch it displays an arrival time in the past.

The map is not dimmed by a scrim. Stopping to read the map is one of the commonest reasons to
stop, and a scrim over dark terrain at night costs real legibility. The ribbon carries the signal
instead.

The chip's live count needs one new accessor: `pauseStartedAt` is private and
`pausedSeconds(asOf:)` returns the ride's total across every stop (`RideRecorder.swift:126-129`).
So the recorder exposes `currentPauseSeconds(asOf:)`, the coordinator publishes it from the same
0.5 s ticker that already runs while paused, and it is also written in `pause()` and `resume()` so
the chip is never up to half a second stale at the instant it appears.

**The chip is clamped non-decreasing within a stop.** Both the active clock and this count are
differences of wall-clock `Date()` values. A backward NTP correction mid-stop makes the chip count
down while the headline active clock jumps forward, in the same tick. Clamping the chip is cheap
and pure. The headline clock has the same flaw, it predates this pass, and it gets its own issue
rather than a rushed fix here.

### P5: the nudge is a bounded ladder of one-shot notifications

The forgotten resume is the most predictable way a manual pause corrupts a ride, and the rider it
happens to is not looking at the screen. So the nudge has to leave the app, and the app has no
notification infrastructure today: `UIBackgroundModes` is `location` alone
(`Aura/Resources/Info.plist:35-36`) and nothing calls `UNUserNotificationCenter`.

**A ladder, not a repeating trigger.** Five one-shot requests at 10, 25, 45, 75 and 120 minutes
into the stop, scheduled together and cancelled together by fixed identifiers held in
`PauseNudgePolicy`. Revision 1 used one repeating 600 s trigger, which was wrong three ways. It
nags a legitimate two-hour lunch twelve times; it cannot state a duration, because a repeating
request cannot rewrite its own body; and after a jetsam kill during a pause, which D7 says is the
likely outcome of a long stop, it fires every ten minutes forever at a rider who is not going to
open the app. A ladder backs off as the stop looks more deliberate, says how long it has been,
and self-limits: the worst an orphan can do is five notifications ending two hours after the
pause.

**Foreground presentation is not free.** Without a `UNUserNotificationCenterDelegate` implementing
`willPresent`, iOS shows nothing while the app is active. The rider paused to read the map, with
the HUD on screen, is exactly that case, so the app gains an `AppDelegate` adaptor and the
delegate. Revision 1 missed this and its device list only checked a locked phone, so the device
pass would have gone green over it.

**Authorization is settled before anything is scheduled, and the schedule is generation-guarded.**
`pause()` increments a counter and hands it to a task that awaits `requestAuthorizationIfNeeded()`
and then schedules only if the counter still matches and the recorder is still paused. Without
that guard the first pause on every install is inverted: `pause()` releases the wake lock, the
phone locks, iOS defers the permission alert until the app is active again, and the ladder lands
after the rider has already resumed, nagging them mid-ride.

**Scheduling is gated on the discard floor**, the same `RideBackOutGate` check `flushCheckpoint`
uses. A ride not worth recovering is not worth a notification, and this closes the orphan path
where an edge-swipe discard below the floor leaves nudges behind.

**Cancellation points: `resume()`, `finish()`, `discard()`, `start()`, and launch.** Deliberately
not `cancel()`. Revision 1 called five methods "the complete set of exits", which was wrong twice
over: only `resume()` and `finish()` actually leave the paused state, and `cancel()` is reachable
only from `onDisappear`, which this codebase documents as firing without the rider asking for
anything (`RideHUDView.swift:291-292`, `AuraApp.swift:207-208`). Cancelling there would let a
spurious teardown silently remove the safety net for a still-paused ride, and `pause()`'s
`!isPaused` guard means nothing would ever re-arm it. `start()` is included because it is the one
moment the app knows no ride is paused.

**Launch clears pending and delivered nudges when no ride is recording.** Revision 1 justified
this with "nothing persists an in-flight ride", which Pass 2 falsified: a pause writes a
checkpoint row, and ROH-107 shipped a badge for it. The rule is still right, but the real
invariant is narrower and nothing enforces it: **a persisted checkpoint is never resumable.** The
moment checkpoint restore lands, this clear becomes "destroy the nudges for the ride we just
restored", so it carries that sentence as a comment. The clear must also survive a scene
reconnect re-running `RootView`'s `.task` (`AuraApp.swift:93`), the same hazard the V6 backfill
sweep already had to guard.

**A declined permission is recoverable.** Settings gains a row showing that pause reminders are
off, linking out through the existing `RideSettingsLink.open`. The system prompt appears once per
install, and a rider who dismisses it at a junction should not lose the feature permanently with
no way back.

Tapping a nudge only opens the app. Resuming from the Lock Screen wants an App Intent and is out
of scope for Slice A. Note for whoever builds it: `AppRouter.handle(url:)` is guarded on
`!isRideActive` (`AppRouter.swift:41`) and a paused ride keeps that true, so a deep link cannot be
the mechanism.

### P6: policy and copy stay pure

`PauseNudgePolicy` holds the ladder offsets, the per-rung copy and the request identifiers.
`PauseControlCopy` holds the control's labels and VoiceOver strings. Both are plain values in
AuraCore with no SwiftUI and no UserNotifications import, unit-tested the way `HUDControlMetrics`
and `UnfinishedRideCopy` are.

### P7: the control reads as one button whose label tracks its state

The label is "Pause ride" or "Resume ride", and the transition posts an announcement. A label that
changes is clearer than a static label with a toggle value, where "Pause ride, on" is ambiguous
about whether "on" describes the pause or the ride. The announcement lives in the shared control
view, which both HUDs render, so it is written once without a third seam. The exact API comes from
the `ios-accessibility` skill at implementation time rather than from recall.

Two identifiers: `RideTestID.hudPause` for the control and `RideTestID.hudPausedBanner` for the
chip. ROH-103 needs both, which is why they land now.

### P8: tests, and the one thing tests cannot cover

Pure tests: the ladder offsets and copy, the control copy, `currentPauseSeconds` across a stop, a
resume and a second stop, its non-decreasing clamp under a backward clock step, and
`TrackRibbon`'s new style discriminator.

Coordinator tests with spies: a haptic on both transitions; the ladder scheduled on a pause above
the floor and *not* below it; cancelled on `resume()`, `finish()`, `discard()` and `start()`; not
cancelled on `cancel()`; and the generation guard, by resuming before the authorization task
completes and asserting nothing is scheduled.

What none of that covers is whether the two HUDs actually pass the seams, since the tests inject
their own. Required constructor parameters are the guard, and they are a compile-time one.

No new UI test here. ROH-103 owns the E2E through the paused fixture.

## What revision 1 got wrong

Kept short deliberately, because the corrections above are the substance.

- The nudge seam merged async authorization into a synchronous schedule, breaking the first pause
  on every install.
- Foreground notifications were assumed to present themselves.
- "Five exits" miscounted and mislabelled the lifecycle, and put the cancel on the one method
  reachable from an unreliable callback.
- The launch-clear rested on a premise Pass 2 had already falsified.
- The repeating trigger nagged forever after a jetsam kill and could not state a duration.
- Pause and Resume were sized backwards relative to D9's own reasoning.
- The map ribbon obligation ROH-105's D5 assigned to this pass by name was missed entirely, along
  with Navigate's positive-signal requirement.
- `prepare()` at ride start does not warm anything for a pause an hour later.
- The Live Activity limitation was described wrongly, in the rider's disfavour (below).

## Known limitations carried forward

**The Live Activity actively contradicts the pause, and this is a release gate.** The Lock Screen
clock is `Text(context.attributes.startedAt, style: .timer)` (`RideLiveActivity.swift:49, 94`),
rendered by the OS from an immutable attribute, so it keeps counting through the stop. The
controller re-stamps `staleDate` on every push (`RideLiveActivityController.swift:94`) and the
ticker pushes throughout, so it never dims either. A rider who pauses, pockets the phone and
checks the Lock Screen sees a bright, actively-ticking ride. That is the surface they would use to
answer "did my pause take?", and it answers wrongly in both directions. Pass 5 (ROH-102) is the
fix. **Pass 4 must not reach riders ahead of it**, which makes the ordering a gate rather than a
preference.

**The crew still sees a paused rider as riding.** D7 keeps the coordinate flowing so the rider does
not age into `.dropped` during a stop, and Slice C puts `paused` on the wire. On a group ride the
social meaning of pressing Pause is "I have stopped, do not leave me", and Pass 4 delivers none of
it. Worth restating because P3's fit lever spends roster rows on a button that does not yet do
what a group rider presses it for.

**A HealthKit route drawn across a pause is a straight chord.** `WorkoutData(from:)` flattens
`flattenedPoints` across segments while `distanceMeters` is segment-aware, so a rider who pauses,
drives 20 km and resumes writes a workout whose route and distance disagree. First reachable in
this pass, since this pass is what lets a rider pause. Out of scope here, filed separately.

**A zero-segment ride is newly reachable on Navigate**, whose End is always available: start,
pause before the first fix, End. The row saves with a large elapsed and an active time near zero.

**Guidance may be dead, not merely quiet, after a pause at the destination.**
`GuidanceViewModel.run` drops the arrival event and the Mapbox stream typically ends right after
arrival, so the consuming loop exits and no further progress events arrive even after resuming.
D7 left the behaviour open and assigned the check here; the device finding is likely to be
stronger than "arrival did not re-fire". If a fix follows, it must not be flushed synchronously
from inside `rideDidSetPaused`, which would reenter `resume()` and end a ride mid-method.

## Device verification

This is the epic's device pass, so the list is the deliverable. A dev-signed Xcode build, not
TestFlight: ROH-108 holds CloudKit production-schema promotion, which gates TestFlight.

- iPhone SE cockpit stack, both HUDs, recording and paused.
- Group navigate ride with the roster expanded over the new row.
- Gloved resume while rolling, one-handed.
- Chip, control and paused ribbon legible at arm's length on a bar mount.
- Navigate's paused state legible without the map's help (ROH-105 D5's third obligation).
- Pause and resume haptics distinguishable without looking, and turn haptics silent while paused.
- The ten-minute nudge on a locked phone, the twenty-five-minute one after it, and one arriving
  while the app is foregrounded.
- Resume, End and discard each silencing pending and delivered nudges.
- VoiceOver on both states, including the transition announcement.
- Pause at the destination, then resume, to establish what guidance does next.

## Out of scope, filed separately

Auto-resume when the rider starts moving again; notification actions (Resume, remind later);
holding the wake lock briefly after a pause; a coalescing window so a mis-tap corrected in seconds
leaves no segment; a monotonic clock for the headline active time; the HealthKit route chord;
Navigate's ETA correctness beyond blanking it; auto-pause (Slice B); crew-visible paused state
(Slice C); the Live Activity's paused state (Pass 5, ROH-102); battery throttling for a paused
location stream (ROH-106); active time on the surfaces that still report wall clock (ROH-112).
