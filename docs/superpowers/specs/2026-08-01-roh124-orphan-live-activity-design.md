# Orphaned Live Activity sweep (ROH-124) — design

Date: 2026-08-01
Issue: [ROH-124](https://linear.app/rohun/issue/ROH-124/orphaned-live-activity-survives-a-jetsam-kill-and-never-clears)
Status: revision 1, awaiting the adversarial spec gate.

Found by the product-lens reviewer on
[ROH-107](https://linear.app/rohun/issue/ROH-107). Related to Pass 5
([ROH-102](https://linear.app/rohun/issue/ROH-102)), which shipped in PR #117.

## Problem

`RideLiveActivityController` is a `@MainActor` singleton that holds the one
`Activity<RideActivityAttributes>` a ride owns. Every method it exposes is gated on that
stored reference: `update()` opens with `guard let activity` (`RideLiveActivityController.swift:73`)
and so does `end()` (`:120`). The reference lives in memory and nowhere else.

When the process dies mid-ride, whether from jetsam, a crash, or the rider force-quitting,
the activity outlives it. iOS keeps showing it. The next launch builds a fresh singleton whose
`activity` is nil, so every path that could clear the ghost returns immediately. Nothing in the
repo reads `Activity<RideActivityAttributes>.activities`, which is the only API that can reach
an activity this process did not create.

Two defects follow from that.

1. **The ghost never clears.** It sits on the Lock Screen and in the Dynamic Island until iOS
   retires it on its own schedule: up to 8 hours of active lifetime, then up to 4 more hours of
   system-ended presence.
2. **The next ride stacks a second activity beside it.** `start()` calls `end()` defensively
   (`:45`) precisely to prevent this, and against an orphan that call is a no-op. The rider gets
   two Aura activities, one live and one dead, competing for the same Lock Screen.

### Correcting the issue's severity claim

The issue argues that ROH-102 "deliberately pushes `staleDate` forward or clears it while
paused," so a kill during a pause leaves an activity that looks live and un-dimmed for hours.
**That is not what shipped.** `RideActivityPushPolicy` sets one `staleInterval` of 90 seconds
(`RideActivityPushPolicy.swift:27`), applied uniformly at request
(`RideLiveActivityController.swift:54`) and on every enqueued push (`:110`), with a 60 second
heartbeat that is explicitly not gated on paused
(`RideActivityPushPolicy.swift:21-24`). A dead process stops pushing, so the last `staleDate`
expires within 90 seconds and the widget dims: `RideLockScreenView` drops stat opacity to 0.4
(`:25`), the status pill switches to its stale copy (`:88,:131`), and VoiceOver announces all
four paused/stale combinations (`:155,:166`).

So the ghost does confess. It confesses by dimming, which is the mitigation the controller's own
comment claims, and it is still wrong: a dimmed paused ride from three hours ago is not something
the rider can act on, and the stacking defect is untouched by staleness. The fix stands. Its
justification is the two defects above, not an un-dimmed Lock Screen.

## D1 — The sweep ends every activity this process does not own

`RideLiveActivityController` gains `endOrphans()`. It walks
`Activity<RideActivityAttributes>.activities` and ends each activity whose `id` differs from the
`id` of the activity the controller currently holds, passing `nil` final content and
`.immediate` dismissal.

`nil` content is deliberate: this process never held the ghost's payload, so it has nothing
truthful to render, and ActivityKit keeps the last state the dead process pushed. `.immediate`
removes it rather than letting it linger, which is what the PO decision in D3 asks for.

Excluding the owned `id` is the whole safety property. It makes the sweep correct at any call
site and in any order, including one that fires while a ride is genuinely running, so no call
site needs its own ordering argument.

## D2 — Two call sites, both relying on D1's exclusion

**Launch.** The `.task` in `AuraApp.swift:160` already clears orphaned pause nudges for exactly
this failure (`:173-175`). The sweep goes beside it, under the same
`router.activeRideID == nil` guard, for the same reason and with the same idempotence
requirement: that `.task` re-runs on a scene reconnect.

**Ride start.** `start()` calls `endOrphans()` after `Activity.request` succeeds and the new
activity is stored. Placed there, the newly requested activity is the owned `id`, so the sweep
clears the ghost and cannot touch the ride just begun. This covers the rider who launches the
app and starts riding before the launch sweep has run, and it is what closes defect 2
independently of launch timing.

The defensive `end()` at the top of `start()` stays. It handles the same-process case, where
the controller does hold the previous ride's activity, and `endOrphans()` deliberately does not.

Both calls are best-effort. A failure to clear a ghost must never affect the ride, matching how
`start()` already treats a failed `Activity.request`.

## D3 — Ended silently, with no new rider-facing surface

PO decision: the sweep ends the orphan and says nothing. The rider opens the app, the ghost
disappears, and ROH-107's unfinished badge on the last-ride card carries the explanation.

Two alternatives were considered and rejected.

Routing the rider to the recovered ride would need a `widgetURL` on the activity, which it does
not have today, plus a deep-link route, and it would push a screen onto a path whose rules
ROH-85 fixed at some cost.

Ending with a terminal "ride interrupted" state that lingers on the Lock Screen would need a new
`ContentState` variant rendered by all five widget presentations, which is the code ROH-102
rewrote days ago.

Both spend real surface for an explanation the app already gives one screen later.

## D4 — The decision is pure and host-tested; the ActivityKit call is not

No test target in this repo can import ActivityKit, which is why `RideActivityPushPolicy` exists
as a pure enum in AuraCore with the controller as a thin shell over it
(`RideActivityPushPolicy.swift:15-16`). The sweep follows that split.

```swift
/// Which live activity ids a sweep must end: everything except the one this process owns.
/// Pure and host-tested for the same reason `RideActivityPushPolicy` is (spec D4): the
/// controller that consumes it imports ActivityKit and no test target can reach it.
public enum RideActivityOrphanPolicy {
    public static func orphans(among live: [String], owned: String?) -> [String]
}
```

The rule is one line. It is also the line that, inverted, ends the Live Activity of a ride in
progress, and it is the only part of this change a test can reach at all. Cases worth pinning:
an empty list, a list containing only the owned id, a ghost alongside the owned id, several
ghosts, and a nil `owned` (the launch case, where everything is an orphan).

`endOrphans()` itself stays untested and is verified on device.

## Non-goals

**A ride killed while never paused still leaves no History row.** `checkpointedAt` is written at
pause boundaries only (`RideSessionCoordinator.swift:370`), so a rider killed while riding, who
never paused, loses the ride silently and now also loses the ghost that was the single visible
trace of it. This fix does not make that worse, and it does not fix it. It deserves its own
issue.

**No `widgetURL`, no deep link, no new `ContentState`.** Per D3.

**No sweep on foreground.** A process that is alive owns its activity through the singleton, so
`scenePhase == .active` has no orphan to find. Adding it would buy nothing and would put the
sweep on a path that fires mid-ride.

## Verification

Unit tests cover `RideActivityOrphanPolicy` against the cases in D4.

The behavior itself is a device check, since it needs a real process death and a real Lock
Screen:

1. Start a ride, pause it, confirm the Live Activity shows the paused treatment.
2. Kill the app from Xcode, leaving the activity on the Lock Screen.
3. Wait past 90 seconds and confirm the activity dims, which is today's behavior and the
   baseline this change is measured against.
4. Relaunch the app. The activity must clear immediately.
5. Repeat through step 2, then relaunch and start a new ride without waiting. Exactly one Aura
   activity may exist afterwards, showing the new ride.

Step 5 is the one that fails today and the one worth being slow about.
