# Unfinished-ride treatment for a recovered pause checkpoint (ROH-107) — design

Date: 2026-07-29
Issue: [ROH-107](https://linear.app/rohun/issue/ROH-107/unfinished-ride-treatment-for-a-recovered-pause-checkpoint)
Status: revision 2, after a three-reviewer adversarial gate.

Slice A follow-up to the segmented-rides epic
([ROH-74](https://linear.app/rohun/issue/ROH-74/pause-a-ride)). Blocks Pass 4
([ROH-101](https://linear.app/rohun/issue/ROH-101)).

**Revision 1 chose a nil `endedAt` as the marker, on the grounds that it needed no schema change.
The gate found two harms that decision causes, and it is reversed in D1.** Revision 1 also
asserted the ride summary screen was unreachable (it is one tap from any History row), specified
a `private(set)` property that cannot compile against its own stated writers, and cited
`discard()` as a live clearing path when it is unreachable in production. Each correction is
marked below rather than silently applied, because two of them change what the design is *for*.

## Problem

Pass 2 ([ROH-99](https://linear.app/rohun/issue/ROH-99)) made a pause flush the ride so far to
the store, so a jetsam kill during a long stop no longer costs the rider everything they rode
before it. That flush created a row the app has no vocabulary for.

The original epic spec's D5 assumed a nil `endedAt` would render "the existing statless
treatment." No such treatment exists. Nothing outside the model layer reads `RideSummary.endedAt`:
`HistoryView`'s caption is `lead · movingTime · ↑ climb` with distance as the trailing hero
numeral (`HistoryView.swift:147-155,199`), `LastRideCard` degrades on `hasStats`
(`LastRideCard.swift:89-92`), which is true for a checkpoint because `RideMapper` derives it from
`statsData != nil` (`RideMapper.swift:97`), and `WidgetSnapshot.LastRide` has no such field
(`WidgetSnapshot.swift:16-47`). `RideAggregator.weekToDate` counts the row in the weekly ring
(`RideAggregator.swift:45-56`).

*Revision 1 described the History caption as containing distance. It does not; distance is the
hero numeral beside the caption. The D4 row is corrected accordingly.*

Three defects, not one:

1. **A recovered ride is unmarked.** After a kill, History shows a normal-looking complete ride
   truncated at the last pause.
2. **The recording may be short, and nothing says so.** A rider who pauses at km 20, resumes,
   rides to km 60 and is killed while riding gets the km-20 checkpoint. Forty kilometres are
   gone. That row is indistinguishable from a ride that was merely never ended.
3. **The ride in progress leaks into glance surfaces.** `WidgetRefresh.reload` fires on every
   `scenePhase == .active` (`AuraApp.swift:183`), so a rider who backgrounds and foregrounds
   during a pause sees the ride they are on presented as their last ride, with the weekly ring
   stepping up. It self-corrects at End.

Defect 2 is not caused by this issue: the data loss exists today and is silent. This issue owns
how the row is presented, so communicating it is in scope even though preventing it is not.

## D1 — The marker is `checkpointedAt: Date?`, and `endedAt` keeps its stamp

*Reversal. Revision 1 dropped the `endedAt` stamp and used nil as the marker, because it cost no
schema change. Two independent reviewers found harms that a stored timestamp fixes and a nil
cannot, recorded under "Why the nil marker was reversed" below.*

`Ride`, `RideRecord` and `RideSummary` gain `checkpointedAt: Date?`.
`RideRecorder.checkpoint(at:)` sets it to the pause instant and **keeps stamping `endedAt` as it
does today** (`RideRecorder.swift:152-157`, unchanged). `RideRecorder.end(at:)` sets it to nil.
Pass 2's behavior is left alone.

```swift
extension RideSummary {
    /// The rider never ended this ride: it is a pause checkpoint that a kill, or a ride still
    /// running on another device, left behind. `checkpointedAt` is when recording stopped, which
    /// is not necessarily when the rider stopped riding.
    public var isUnfinished: Bool { checkpointedAt != nil || endedAt == nil }
}
```

The `endedAt == nil` clause is not redundant. Commits `c356419` and `ac5582c` (PR #90) shipped a
`checkpoint(at:)` that wrote a nil `endedAt`, so any dev build installed during Pass 2 device
verification could have written such rows, and they mirror to CloudKit. No App Store build
carried it. Those rows have no `checkpointedAt` and would otherwise render as finished.

### What this buys over a nil `endedAt`

* Unfinished rows keep elapsed and active time, so there is no duration asymmetry against
  finished rows and [ROH-112](https://linear.app/rohun/issue/ROH-112) needs no special case.
* The copy can say **what the recording covers** ("Recorded until 2:14 pm"), which is the only
  cheap signal that separates defect 1 from defect 2. Recovering that from the last track point
  means faulting the external blob on every History row.
* No consumer has to learn to handle a nil `endedAt`.

### Why the nil marker was reversed

* **Cross-device.** The active-ride exclusion (D3) is process-local. The checkpoint row syncs, so
  a second V6 device shows the rider's in-progress ride marked as one they never ended. Under a
  nil `endedAt` the app could not tell "being recorded right now" from "abandoned" at all. It
  still cannot tell them apart with certainty, but see D2.
* **Truncation is invisible.** Defect 2 above. The rider reads the marker as "I forgot to press
  End" and never learns their distance is short.

### Cost

Schema V7, a lightweight stage adding one optional attribute, and one more CloudKit production
field. **[ROH-108](https://linear.app/rohun/issue/ROH-108)'s production deploy must wait for V7
so it remains a single promotion covering `CD_segmentsData`, `CD_pausedSeconds` and
`CD_checkpointedAt`.** Its steps 1 and 2 are unaffected. A production field cannot be removed
once promoted; that is accepted here on the strength of two independent findings rather than on
anticipation.

## D2 — Three mechanisms

| Defect | Mechanism | Scope |
| -- | -- | -- |
| Recovered ride unmarked | `isUnfinished` | Labeling, every surface in D4 |
| Recording may be short | `checkpointedAt` in the copy | Same surfaces |
| Ride in progress leaks | Active-ride exclusion (D3) | Home, widget, weekly ring, local device only |

Conflating the marker with the exclusion fails a case that occurs in normal use. A rider who
recovered an unfinished ride **on Monday** and starts a ride **on Wednesday of the same week** has
two unfinished rows. Only one is the ride they are on, and only that one should leave Home. A rule
phrased as "hide unfinished rows while a ride is active" hides both, dropping Monday's distance
from the week-to-date ring for the duration of Wednesday's ride.

*Revision 1 illustrated this with a ride from **last** week, which contributes nothing to a
week-to-date ring either way. The decision holds; the example did not.*

### The cross-device boundary, named rather than solved

`AppRouter.activeRideID` exists only on the recording device. A second device cannot filter, so
it counts the in-flight ride in its ring and may show it as the last ride. This is true today and
is not made worse by the marker, **provided the copy is true in both readings** (D4). A staleness
rule on `checkpointedAt` ("younger than N minutes, probably still riding") is available and is
deliberately not adopted: a legitimate two-hour café stop and an abandoned ride are the same
signal, so the rule would trade a known, self-correcting inaccuracy for a heuristic that is wrong
in a new and unpredictable way. Revisit only with evidence from
[ROH-12](https://linear.app/rohun/issue/ROH-12).

## D3 — Active-ride exclusion by id

`WidgetRefresh.reload` reads `rideStore.summaries()` and hands the list to `WidgetSnapshot.make`
(`WidgetRefresh.swift:12-17`), from eight call sites: `AuraApp.swift:135,178,183`,
`SettingsView.swift:122,125`, `NavigateHUDView.swift:243`, `RideHUDView.swift:199`,
`HistoryView.swift:82`.

`reload` and `WidgetSnapshot.make` take an `activeRideID: UUID?` with **no default**, so a new
call site cannot silently leak. Two sites pass a real id: `AuraApp.swift:183` (the
`scenePhase == .active` edge, the leak) and `AuraApp.swift:178` (the KVS sync loop, reachable
mid-ride when a settings change arrives from another device). The other six pass `nil` as a claim
a reviewer can check: `AuraApp.swift:135` is a launch `.task`, both HUD sites fire from
`onChange(of: coordinator.finishedRide)` after `finish()` has stamped, and the Settings and
History sites are unreachable during a ride.

### Home filters at the source, not per-read

*Correction. Revision 1 named only the `LastRideCard` read.* `HomeView` derives three things from
one `summaries` array: `weekStats` and `lastRide` (`HomeView.swift:46-47`), and `lastRide` is
passed on to `WeeklyGlanceView` (`HomeView.swift:169`), whose headline falls back to it when
`week.rideCount == 0`. **The filter is applied once to `summaries`**, and all three derive from
the filtered array. Filtering only `lastRide` would leave Home's ring stepping up mid-ride while
the widget's does not.

### Home must refetch when the exclusion lifts

`HomeView.summaries` is loaded on mount and on `rideStore.syncRevision`
(`HomeView.swift:67,86`), and Home is retained beneath the pushed HUD, so its `.task` does not
re-run after a ride. A checkpoint that synced mid-ride is already in the array; when
`activeRideID` clears at End, the filter lifts and Home re-renders the **stale checkpoint row**
for a ride the rider just finished. `HomeView` therefore reloads on the
`activeRideID` true-to-false edge, alongside the existing `isRideActive` observer at
`HomeView.swift:105`. The widget is unaffected: both HUD sites call `WidgetRefresh.reload`, which
refetches.

### Where the id comes from

`AppRouter` carries `isRideActive` as a stored `Bool` (`AppRouter.swift:15`), written by both HUDs
at four sites (`RideHUDView.swift:195,203`, `NavigateHUDView.swift:236,253`). It gains
`activeRideID: UUID?` with `isRideActive` computed over it, so the two cannot desync:

```swift
var activeRideID: UUID?
var isRideActive: Bool { activeRideID != nil }
```

*Correction. Revision 1 wrote `private(set) var activeRideID`, which does not compile: the four
writers are in other files, and `private(set)` scopes the setter to `AppRouter.swift`. Verified
with `swiftc -typecheck`. The property is settable, and the desync argument stands on the
computed Bool alone.*

The source is a new `RideSessionCoordinator.activeRideID`, which **must** be
`recorder.isRecording ? recorder.rideID : nil`. `recorder.rideID` survives `end()`; it is reset
only in `start(at:)` (`RideRecorder.swift:72`), so a non-optional passthrough re-creates the leak.

Every existing reader is unchanged: the deep-link guard (`AppRouter.swift:35`),
`LocationAccuracyMode.desired` via `AuraApp.swift:215`, `SettingsView.swift:30,34`,
`HomeView.swift:105`, and the two `onChange` observers at `AuraApp.swift:161,187`. Observation
still propagates, because the computed getter reads the tracked stored property.

*Correction. Revision 1 presented the reader list as exhaustive and omitted `AuraApp.swift:187`.*

### Rejected alternatives

* **Return early from `reload` while a ride is active.** Guards a refresh rather than a read,
  across eight triggers, and leaves Home untouched.
* **Exclude all unfinished rows while `isRideActive`.** Cheaper (a Bool, not a UUID) and fails
  D2's same-week case.

## D4 — Surfaces

*Correction. Revision 1's table said the ride summary screen was unreachable. Every History row
taps into it: `HistoryView.swift:62` sets `selected` and `:48` presents
`RideSummaryView`. It is the largest surface and the one a rider opens **because** the row looks
odd, and revision 1 gave it no treatment. That also contradicted revision 1's own D6, since the
only share entry point is inside that screen (`RideSummaryView.swift:80`).*

| Surface | Treatment |
| -- | -- |
| History row | Marker in its **own layout slot**, not appended to the caption |
| Ride summary sheet | Marker plus one explanatory line, replacing the "Nice ride" headline |
| Home last-ride card | Marker |
| Widget last-ride | Marker where the layout allows (D5) |
| Weekly ring | Counts it. `RideAggregator` is not modified; filtering happens on the list feeding it |

The ring counting it is the PO decision of 2026-07-29: the rider covered that distance, and with
no resume and no end-it-now, excluding it under-reports their week permanently for an OS decision.
Where the recording was truncated (defect 2), the ring under-reports instead. That is unavoidable
and is stated rather than implied.

### Copy

The marker describes **the recording**, not the rider. "Unfinished" reads as an accusation on a
Home surface whose job is motivation, and it is wrong in the common case: a rider who rode to the
brewery, got a lift home and never reopened the app did finish their ride. Aura failed to record
its end.

Wording is a Pass 4 design call, but the spec constrains it: it must be true both for a recovered
ride and for a ride still running on another device, and it must carry `checkpointedAt` so a
truncated recording is discoverable. "No end recorded · until 2:14 pm" satisfies both. "You never
finished this ride" satisfies neither.

Duration is labeled with its quantity on unfinished rows, because `checkpointedAt` makes the
number a *recording* duration rather than a ride duration.

**Not amber.** Amber already carries peer-stopped and `AuraTheme.warning`, which `GPSSignalChip`
uses for weak or lost GPS. Neutral secondary weight: this is a fact about the recording, not an
app error. The marker belongs in the accessibility label, not only in the visual.

**Layout.** The History caption is one `.footnote` `Text` with `.lineLimit(1)`
(`HistoryView.swift:189-192`). A marker appended there is the first thing Dynamic Type truncates,
for the users least able to lose it. It gets its own slot.

### Deleting an unfinished ride needs a confirmation

History's delete is `.swipeActions(allowsFullSwipe: true)` with a destructive role
(`HistoryView.swift:67-71`), calling a hard delete that propagates to every device
(`RideStore.swift:125`). Labelling a row as damaged and putting a one-gesture irreversible destroy
on it is a trap: in the common case the row is a complete, correct ride missing only its ending.
Unfinished rows get a confirmation. This is in scope because the label creates the hazard.

## D5 — `WidgetSnapshot` gains optional fields and does **not** bump its version

*Correction. Revision 1 bumped `currentVersion` to 2 and priced the cost as "one snapshot write."
`WidgetSnapshotStore.read()` rejects an unknown version, and the only writer is `WidgetRefresh`,
reached only from in-app triggers. There is no background writer, so the window closes at the
rider's **next app foreground**, not at the next write. For someone who installs a glanceable
widget and rarely opens the app, both widgets render "No rides yet" with the ring at 0% for days.*

`WidgetSnapshot.LastRide` gains `checkpointedAt: Date?`, `endedAt: Date?` and
`pausedSeconds: Double?`, all optional, at the **current version**. Swift's synthesized `Codable`
decodes a missing key for an `Optional` property as nil, so an existing v1 payload decodes with
every new field nil, which is exactly the safe reading: not a checkpoint, no duration pair, no
paused time. No empty window, and no version bump.

`endedAt` and `pausedSeconds` are added now because ROH-112 needs them for the widget's
active-with-elapsed pair, reducing its widget work to rendering.

Where the marker physically goes on `accessoryRectangular` (a 34 pt thumbnail plus three tight
lines, `LastRideWidget.swift:90-114`) and `systemSmall` is a Pass 4 layout call. If a family has
no room, it renders without the marker rather than truncating a stat.

## D6 — Correctness fixes this design depends on

### `finish()` must not drop the deletion handle before the save

`RideSessionCoordinator.swift:238-245` clears the checkpoint handle *before* `try saving?.save`.
(That handle was `checkpointedRideID` when this spec was written; the whole-branch fix wave
collapsed it into `pendingCheckpoint`, which carries the flush stamp alongside the ride id.)
On a throw the checkpoint row survives with nothing able to remove it, and the rider sees
"Couldn't save this ride, it won't appear in History" (`RideSummaryView.swift:135-137`) beside a
History row marked as never ended. The clear moves after a successful save. This is safe: only
`discard()` deletes, and `cancel()` does not.

### `RideStore.save`'s update branch must copy `checkpointedAt`

The update branch is a hand-written field copy (`RideStore.swift:78-102`). Pass 3 hit exactly this
trap with `segmentsData`. A missing copy here means `finish()` never clears the marker and every
paused ride stays unfinished forever.

### `discard()` is unreachable in production, and the spec no longer relies on it

*Correction. Revision 1 cited `discard()` as a live clearing path.* `flushCheckpoint` writes only
above the 25 m discard floor (`RideSessionCoordinator.swift:206`), and `RideHUDView.backTapped`
discards only below it (`RideHUDView.swift:284-294`). Recorded distance is monotonic, so the two
are mutually exclusive by construction, and `NavigateHUDView` has no discard path. **`finish()` is
the only path that clears the marker.** The existing test
(`RideSessionCheckpointFlushTests.swift:74-80`) passes because it calls `discard()` directly in a
state the UI cannot produce; it is kept as a seam test and annotated as such.

## D7 — Out of scope

* **Resume and an explicit end-it-now action.** PO decision, 2026-07-29: label only.
* **The orphaned Live Activity.** After a jetsam kill the Lock Screen keeps an un-dimmed Aura
  activity, because `RideLiveActivityController.end()` guards on an in-process handle
  (`RideLiveActivityController.swift:99`) and nothing sweeps `Activity.activities` on relaunch.
  It is the rider's *first* contact with this failure, before History. Filed separately: it is an
  ActivityKit lifecycle defect that exists independently of this marker, and Pass 5
  ([ROH-102](https://linear.app/rohun/issue/ROH-102)) already owns the Live Activity's paused
  behavior.
* **HealthKit for a recovered ride.** `RideWorkoutGate.shouldWrite` guards `endedAt != nil` and
  `writeWorkout` is called only from `finish()`, so no checkpoint can leak into Health. The
  converse gap stands: a recovered ride is in Aura's History and its weekly ring but absent from
  Health, silently. Filed separately.
* **Share card marking.** An unfinished ride stays shareable with an unmarked card. Truthful
  where the recording is complete; wrong where it was truncated. Revisit with defect 2.
* **`RideAggregator` arithmetic.** Unchanged.

## Risks

| Risk | Mitigation |
| -- | -- |
| `finish()` fails to save and strands a marked row | D6 keeps the deletion handle. The row stays marked, which is truthful: it was not saved as finished |
| `RideStore.save` update branch misses the new field | D6, plus a dedicated test. This is Pass 3's `segmentsData` trap |
| A second device counts the in-flight ride | Named in D2, unchanged from today, and the copy is true in both readings |
| Pre-V7 checkpoint rows render as finished | Only dev builds wrote them. The `endedAt == nil` clause in `isUnfinished` catches the PR #90 subset |
| Ordering breaks on a nil `endedAt` | Does not apply. Both fetches sort on `startedAt` (`RideStore.swift:105,113`) |
| A new `reload` call site leaks the in-flight ride | Non-defaulted parameter makes it a compile error |
| Widget shows an empty state after the update | Does not apply. D5 removes the version bump |
| Two flushes then a kill leave two rows | Does not apply. The flush is an upsert on `ride.id` |
| Unfinished row wins "Longest ride yet" | Possible via `RideAggregator.isLongest` (`RideSummaryView.swift:216`), and harmless: a truncated ride is shorter than the ride it would have been |

## Testing

Pure tests in `AuraCoreTests` and `AuraKitTests`. Pass 6
([ROH-103](https://linear.app/rohun/issue/ROH-103)) owns the end-to-end pause path.

* `checkpoint(at:)` sets `checkpointedAt` and still stamps `endedAt`; `end(at:)` clears it.
* `RideMapper` round-trips `checkpointedAt` through the V7 record into `RideSummary`.
* **`RideStore.save`'s update branch copies `checkpointedAt`**: flush, then finish, leaves one row
  with `isUnfinished == false`. This is the test that would have caught Pass 3's trap.
* A save failure at `finish()` leaves `pendingCheckpoint` non-nil.
* V6 to V7 lightweight migration preserves every existing row, with `checkpointedAt` nil.
* `weekToDate` counts an unfinished summary.
* The active-ride filter drops exactly the matching id and keeps a second unfinished row with a
  different id. This is D2's case, and it fails if anyone simplifies the filter to a Bool.
* `WidgetSnapshot` decodes a payload written without the three new fields, yielding nil for each,
  with no version change.
* Caption, marker and accessibility strings for both states.

**`AppRouter` has no unit-test coverage and cannot get any here.** It lives in the app target,
which has no test bundle (`project.yml` defines `Aura`, `AuraWidgets`, `AuraUITests` only).
Revision 1 claimed a regression test for the computed-property change that could not be written.
The change is covered by the existing `AuraUITests` deep-link cases and by device verification;
if that is judged insufficient, the guard logic moves to AuraCore as its own pass rather than
being asserted here.
