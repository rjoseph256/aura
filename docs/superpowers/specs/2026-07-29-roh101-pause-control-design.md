# Cockpit pause control, paused state, haptics, nudge (ROH-101, Pass 4): design

Slice A, Pass 4 of 6 of the segmented-rides epic (ROH-74). The parent design is
[2026-07-26-segmented-rides-pause-design.md](2026-07-26-segmented-rides-pause-design.md);
this document resolves its D9 into something buildable and answers the two layout constraints
D9 named but left open.

Blockers are clear: ROH-100 (schema V6), ROH-105 (dead peer parameters) and ROH-107
(unfinished-ride treatment) are all merged to main.

## What Pass 4 is

Passes 1 to 3 shipped a segmented ride model, a recorder state machine and a CloudKit schema
change without altering one pixel a rider sees. Pass 4 is where the rider gets the feature, and
it is the epic's commitment point: if the work stopped after Pass 3 the app would carry a
migration cost for no benefit at all.

Pass 2 already landed the machinery. `RideSessionCoordinator.pause()` and `resume()`
(`RideSessionCoordinator.swift:191-212`) close and open segments, stop the active clock, release
the wake lock, flush a recovery checkpoint, and notify `pauseObserver` synchronously so a
draining arrival cannot end the ride under a rider who just stopped. `RideRecorder` zeroes the
smoothed speed on pause and resets the smoother on resume
(`RideRecorder.swift:95-119`). None of it has a caller.

So Pass 4 adds no ride logic. It adds a control, a state the rider can read, two haptics, a
notification, VoiceOver, and two test identifiers.

## Scope

- A primary pause/resume control in the bottom cockpit of both HUDs.
- A paused state legible at a glance on a bar-mounted phone in rain.
- Haptic confirmation on both transitions.
- A local notification after a long pause, so a forgotten resume is survivable.
- VoiceOver label plus a state announcement, and `RideTestID` entries for Pass 6.

Not in scope: anything that changes what a pause does to the ride. Pass 2 owns that.

## Decisions

### P1: haptics and the nudge belong to the coordinator, not the views

Both HUDs would otherwise duplicate the same side effects, and a SwiftUI body is the one place
in this codebase that cannot be tested on the macOS CI host. So both move behind seams the
coordinator owns, the way `WorkoutWriting` and `RideActivityControlling` already work
(`RideSessionSeams.swift`).

`RideHapticCue` gains `.pause` and `.resume`, and the coordinator takes the existing
`HapticPlaying` seam (`HapticPlaying.swift:8-13`) and fires inside `pause()`/`resume()`. Two
consequences follow for free. Every entry point confirms, including the Lock Screen App Intent
Slice A defers, and a spy proves the haptic fired without a view in the loop.

The nudge gets a new seam, `RideNudgeScheduling`, with the same shape as its neighbours:

```swift
@MainActor
public protocol RideNudgeScheduling: AnyObject {
    /// Ask for permission if it has not been asked for, then schedule the repeating nudge.
    func scheduleForgottenPauseNudge()
    /// Remove pending and already delivered nudges.
    func cancelForgottenPauseNudge()
}
```

The coordinator schedules on `pause()` and cancels on `resume()`, `finish()`, `cancel()` and
`discard()`. Those five are the complete set of exits from a paused ride, and the coordinator is
the only type that sees all five. A view-level cancel would miss `cancel()`, which fires from
`onDisappear`.

Both seams are optional constructor parameters, so the existing test doubles and every current
call site keep compiling unchanged.

`HapticPlaying.prepare()` warms the feedback generators and is called today only when guidance
starts, so on a free ride with no detour in flight they are cold and the first pause tap pays the
warm-up latency. The coordinator calls `prepare()` at `start()` instead, which costs nothing and
covers both HUDs.

### P2: the control is one cockpit row whose layout changes with state

A new row in `bottomCockpit` on both HUDs, between the control-cluster row and the instrument
panel (`RideHUDView.swift:255-277`, `NavigateHUDView.swift:451-482`). Constant height in both
states. The layout inside it is what changes:

| State | Row contents |
| -- | -- |
| Recording | Full-width capsule, `pause.fill` plus "Pause", outline weight |
| Paused | `PAUSED 4:12` state chip on the leading edge, "Resume" as a mint-filled capsule on the trailing edge, minimum 180 pt wide |

The row is 56 pt tall in both states, so nothing below it moves when the rider taps. 56 pt is
`HUDControlMetrics.ride.resolvedHitTarget`, the tap target ROH-75 settled on for a moving rider,
and reusing the number keeps one definition of "big enough to hit at speed" in the codebase.

Resume ends up at roughly triple the area of the 56 pt cluster targets ROH-75 settled on, which
is what D9 means by sizing the control for resume rather than for pause. Pause is pressed while
stopping. Resume is pressed while clipping in, one-handed and often gloved.

Mint, not amber. `CTAButtonStyle` already fills primary actions with `AuraTheme.accent` and inks
them with `onAccent` (`CTAButtonStyle.swift:32`), so a mint-filled Resume is the app's existing
primary-action treatment rather than a new swatch. Amber stays exactly where it is, carrying
peer-stopped and `AuraTheme.warning` for weak or lost GPS (`GPSSignalChip.swift:18-21`). A rider
paused under a railway bridge sees one amber element, and it means GPS.

The glyph question is already settled in the codebase: `UnfinishedRideBadge.swift:11-14` reserves
`pause.circle` for "paused and resumable" in the HUD and deliberately uses a clock instead. This
row is the surface that comment was written against.

### P3: the roster constraint resolves by construction, and the cost lands on the iPhone SE

D9 asked what happens when `GroupRosterSheet` expands to 40% of HUD height over the cockpit
(`NavigateHUDView.swift:455-456`). The answer needs no arbitration. The roster lives inside the
cluster *row* and grows upward from its bottom edge, so a row placed below that one cannot be
covered however far the roster expands.

The real cost is vertical. On a group navigate ride the cockpit column now stacks a turn card, a
roster capped at 40%, a four-entry cluster with the zoom pill, the new pause row, and a panel
pinned at 25% (`containerRelativeFrame(.vertical, count: 4, ...)`). That is the tightest this
column has ever been on an iPhone SE.

Two commitments rather than one guess. The stack is measured on hardware at both HUDs before this
ships, and if it overflows, the roster's 40% cap is the lever, not the pause row's height. The
row is the primary action and the reason the pass exists; a crew list that shows five riders
instead of seven is a smaller loss. ROH-57 hit the same wall and resolved it on device by dropping
an always-dead Navigate control, so the precedent is that fit is settled on hardware.

### P4: paused is carried by three signals, and the map is left alone

D9 requires an indicator that is not only a recoloured button. Three, then:

1. The state chip in the cockpit row, with a live count of the current stop.
2. The mint fill on the control, which also reads as an invitation to tap.
3. The instrument panel dropping to secondary weight while paused, so a frozen clock looks
   deliberately frozen instead of broken. `InstrumentChassis` takes an `isPaused` flag; both
   panels pass it through.

The map is not dimmed. Stopping to read the map is one of the commonest reasons to stop at all,
so a scrim would degrade the surface the rider most likely paused to look at, and a scrim over
dark terrain at night costs real legibility.

The chip sits in the cockpit row rather than pinned to the top of the screen. The top zone is
fully occupied: `TurnCardView` on Navigate, and `GemPeekCard`, `MarkSpotToast` and
`DetourOverlay` on Explore (`RideHUDView.swift:97-128`). Putting it in the cockpit also lands it
in the same glance zone as the speed hero, which is where a bar-mounted rider is already looking,
and it costs no extra height.

The live count needs one new accessor. `pauseStartedAt` is private to the recorder, and
`pausedSeconds(asOf:)` returns the ride's total across every stop
(`RideRecorder.swift:126-129`), which is not what the chip should show. So the recorder exposes
`currentPauseSeconds(asOf:)` for the stop in progress, and the coordinator publishes it off the
0.5 s ticker that D6 already keeps running while paused.

### P5: the nudge is a repeating local notification, cancelled on every exit

The forgotten resume is the most predictable way a manual pause corrupts a ride, and the rider it
happens to is by definition not looking at the screen. The phone is pocketed and dark. So the
nudge has to leave the app, and the app has no notification infrastructure at all today:
`UIBackgroundModes` is `location` alone (`Info.plist:35-36`), and nothing anywhere calls
`UNUserNotificationCenter`.

One repeating `UNTimeIntervalNotificationTrigger` at 600 s. First fire at ten minutes paused,
then every ten until the rider resumes or ends. Ten minutes clears a coffee queue, a mechanical
or a photo stop without firing. The repeat is the part that actually rescues anyone, because the
first notification on a locked phone is the one most likely to be missed.

Authorization is requested at the first pause with `[.alert, .sound]`, not at launch. A rider who
never pauses never sees the prompt, and a silent banner on a locked phone is invisible to the
rider who needs it. Repeated requests are harmless; the system shows the prompt once and returns
the stored status afterwards.

Three consequences, named here rather than discovered later:

The copy carries no duration. A repeating trigger cannot rewrite its own body, so "Your ride is
paused and isn't recording" has to be true at minute 10 and at minute 90. Six discrete
notifications would allow accurate durations but would stop nudging after an hour. Unbounded and
true beats bounded and precise.

Tapping the notification only opens the app. Resuming from the Lock Screen wants an App Intent
and is out of scope for Slice A.

Launch clears any pending nudge when no ride is recording. Without that, a jetsam kill during a
pause leaves a repeating notification nagging about a ride that no longer exists, which is
ROH-124's failure shape in a new place. Nothing persists an in-flight ride, so at launch there is
never a legitimate pending nudge to protect.

A declined permission degrades to the in-app chip alone. That is weak, and it is the honest
outcome: without the notification there is no way to reach a pocketed phone.

### P6: policy and copy stay pure

`PauseNudgePolicy` in AuraCore holds the interval and the notification copy. `PauseControlCopy`
holds the control's labels and the VoiceOver strings. Both are plain values with no SwiftUI and no
UserNotifications import, so they are unit-tested the way `HUDControlMetrics` and
`UnfinishedRideCopy` already are, and the app target holds nothing but the wiring.

### P7: the control reads as one button whose label tracks its state

The label is "Pause ride" or "Resume ride", and the transition posts an announcement so a
VoiceOver rider learns the state changed without re-reading the control. D9 asks for both the
label and the announcement.

A label that changes is clearer here than a static label with a toggle value. "Pause ride, on"
is ambiguous about whether "on" describes the pause or the ride. The exact announcement API is
taken from the `ios-accessibility` skill at implementation time rather than from recall.

Two identifiers, because Pass 6 needs both something to tap and something to assert:
`RideTestID.hudPause` for the control and `RideTestID.hudPausedBanner` for the state chip.

### P8: tests are host-side, and the E2E stays in Pass 6

Pure tests cover the nudge policy values, the control copy, and `currentPauseSeconds` across a
stop, a resume and a second stop. Coordinator tests use spies to prove a haptic fires on both
transitions, a nudge is scheduled on pause, and it is cancelled on all five exits, including the
`onDisappear` path through `cancel()`.

No new UI test here. ROH-103 owns the E2E through the paused fixture, and it needs the two
identifiers this pass adds, which is why they land now rather than with the test that uses them.

## Known limitations carried forward

The crew still sees a paused rider's dot alive with frozen progress. D7 keeps the coordinate
flowing so the rider does not age into `.dropped` during a café stop, and Slice C is what puts
`paused` on the wire. Pass 4 adds nothing to the wire.

The Live Activity does not know about the pause. The ticker keeps pushing updates while paused,
so the Lock Screen shows a ride whose numbers have stopped moving with nothing saying why, and
`staleDate` will dim it 90 s into the stop. That is Pass 5's whole content (ROH-102), and it is
the reason a rider who reads the Lock Screen during a long pause is the strongest argument for
not letting Pass 5 slip far behind this one.

Navigate's ETA is not paused. It is dimmed with the rest of the column, but guidance keeps
running and the number keeps moving. Suppressing arrival while paused is D7's job and is already
done; correcting ETA is neither, and pretending otherwise in this pass would mean touching
guidance for a cosmetic gain.

A suppressed arrival is still not re-emitted. D7 left this open and assigned the check to Pass 4,
so it is on the device list below rather than in the code. If a rider who pauses at their
destination never sees arrival after resuming, they end the ride by hand, and the finding gets its
own issue.

## Device verification

This is the epic's device pass, so the list is the deliverable, not a formality.

- iPhone SE cockpit stack, both HUDs, recording and paused.
- Group navigate ride with the roster expanded over the new row.
- Gloved resume while rolling, one-handed.
- Chip and control legible at arm's length on a bar mount.
- Pause and resume haptics distinguishable without looking.
- The ten-minute nudge arriving on a locked phone, and a second one at twenty.
- Resume and End both silencing pending and delivered nudges.
- VoiceOver on both states, including the transition announcement.
- Pause at the destination, then resume, to see whether arrival ever re-fires.

## Out of scope

- Auto-pause (Slice B) and crew-visible paused state (Slice C).
- Resume from the Lock Screen, which wants an App Intent.
- The Live Activity's paused state, shifted anchor and stale policy, which are Pass 5 (ROH-102).
- Battery throttling for a paused location stream (ROH-106).
- Active time on the surfaces that still report wall clock (ROH-112).

## Approaches considered and rejected

The nudge could have stayed in-app, or waited for Pass 5's Live Activity to carry it on the Lock
Screen. Both were rejected for the same reason: they leave the epic's device pass shipping the
weakest version of its own stated requirement, and neither reaches a pocketed phone.

The control could have gone inside `InstrumentChassis`, which would have added no row. Rejected
because the panel is a pure readout surface today, with one composed VoiceOver element per
cluster, and mixing a tap target into it puts an action where the rider's eye goes for numbers.

The control could have sat left of the cluster, bottom-aligned opposite End, costing no new row on
solo rides. Rejected because that is exactly where the roster sits on a group navigate ride, so
the group case would need a second layout, and two layouts is two things to verify.

Dimming the map while paused was rejected in P4. A minimal treatment with no state chip was
rejected against D9's explicit requirement.
