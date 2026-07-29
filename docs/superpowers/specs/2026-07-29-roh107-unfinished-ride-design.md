# Unfinished-ride treatment for a recovered pause checkpoint (ROH-107) — design

Date: 2026-07-29
Issue: [ROH-107](https://linear.app/rohun/issue/ROH-107/unfinished-ride-treatment-for-a-recovered-pause-checkpoint)
Status: revision 1, pre-review.

Slice A follow-up to the segmented-rides epic
([ROH-74](https://linear.app/rohun/issue/ROH-74/pause-a-ride)). Blocks Pass 4
([ROH-101](https://linear.app/rohun/issue/ROH-101)).

## Problem

Pass 2 ([ROH-99](https://linear.app/rohun/issue/ROH-99)) made a pause flush the ride so far to
the store, so a jetsam kill during a long stop no longer costs the rider everything they rode
before it. That flush created a row the app has no vocabulary for.

The original spec's D5 assumed a nil `endedAt` would render "the existing statless treatment."
No such treatment exists. Nothing outside the model layer reads `RideSummary.endedAt`, verified
by grep across `Aura/` and `AuraCore/Sources/`: `HistoryView`'s caption is built from
`distanceMeters` / `movingTimeSeconds` / `elevationGainMeters` (`HistoryView.swift:147-155`),
`LastRideCard` degrades on `hasStats` (`LastRideCard.swift:89-92`), which is true for a
checkpoint because `RideMapper` derives it from `statsData != nil`
(`RideMapper.swift:97`), and `WidgetSnapshot.LastRide` carries no such field at all
(`WidgetSnapshot.swift:17-47`). `RideAggregator.weekToDate` counts the row in the weekly ring
(`RideAggregator.swift:45-56`).

Pass 2 therefore stamped the checkpoint's `endedAt` at the pause instant, on the reasoning that
a row claiming "a ride that ended when you stopped" is at least true about what was recorded,
where a nil would assert something no surface could render (`RideRecorder.swift:143-151`).
Pass 3 declined to add a flag column for the same reason, and pointed at this issue
(`RideSchemaV6.swift:22-27`).

Two defects remain, and they are not the same defect:

1. **A recovered ride is unmarked.** After a kill, History shows a normal-looking complete ride
   truncated at the last pause. The rider has no signal it is partial.
2. **The ride in progress leaks into glance surfaces.** `WidgetRefresh.reload` fires on every
   `scenePhase == .active` (`AuraApp.swift:183`), so a rider who backgrounds and foregrounds
   Aura during a pause sees the ride they are currently on presented as their last ride, with
   the weekly ring stepping up to match. It self-corrects at End.

They share a row and a trigger, which is why the issue reads as one problem. They need separate
mechanisms, which is D2.

## D1 — Unfinished means `endedAt == nil`, and nothing else

`RideRecorder.checkpoint(at:)` stops stamping the pause instant and writes nil
(`RideRecorder.swift:152-157`). `RideRecorder.end(at:)` always writes a real date, so the upsert
in `RideSessionCoordinator.finish()` (`RideSessionCoordinator.swift:236-241`) converts the row to
finished with no extra bookkeeping, and `discard()` still deletes it
(`RideSessionCoordinator.swift:272-278`). The state clears itself through paths that already
exist.

`endedAt` is already `Date?` at every layer: `Ride.swift:8`, `RideSchemaV6.swift:41`,
`RideSummary.swift:9`, passed through untouched by `RideMapper.swift:22,42,96`. **No schema
change, no schema version, and no second CloudKit promotion.** This is what unblocks
[ROH-108](https://linear.app/rohun/issue/ROH-108) to promote as written, rather than waiting on
this design.

One derived predicate, in AuraCore beside the model:

```swift
extension RideSummary {
    /// The rider never ended this ride. It is a pause checkpoint that a kill (or a still-running
    /// ride) left behind, so its track stops at the last pause and it has no elapsed time.
    public var isUnfinished: Bool { endedAt == nil }
}
```

### What this costs, accepted

An unfinished row has no elapsed, so it has no active time either: active is
`endedAt - startedAt - pausedSeconds`. It shows distance, climb and **moving** time, all stored
and all truthful about the portion that was recorded.

When [ROH-112](https://linear.app/rohun/issue/ROH-112) moves finished rides to active-with-elapsed,
unfinished rows keep moving time. That is a deliberate asymmetry, not an oversight: active time
is uncomputable for these rows by construction, and showing a zero or a dash where a real
duration exists would be worse than showing the one duration that survived.

### Why not a flag column

Considered and rejected. It would keep `endedAt` stamped and preserve the duration, at the cost
of a schema version, a delayed ROH-108, and a permanent commitment: a CloudKit production field
cannot be removed once promoted. Committing this state's shape to production before anyone has
lived with it buys a duration on a row that, by definition, is missing its ending. If the
duration loss turns out to matter, the column can be added later against evidence.

## D2 — Two mechanisms, not one

| Defect | Mechanism | Scope |
| -- | -- | -- |
| Recovered ride is unmarked | `isUnfinished` (D1) | Labeling, every surface |
| Ride in progress leaks | Active-ride exclusion (D3) | Home, widget, weekly ring |

Conflating them fails a case that occurs in normal use. A rider carrying a recovered unfinished
ride from last week who starts a ride today has two unfinished rows in the store. Only one of
them is the ride they are on, and only that one should disappear from Home. A rule phrased as
"hide unfinished rows while a ride is active" would hide both, silently dropping last week's
distance from the ring for the duration of today's ride.

The exclusion is also correct independently of pause. Showing a rider the ride they are currently
on, labeled as their last ride, is wrong whether or not the row is marked.

## D3 — The exclusion is by ride id, and the parameter is not optional

`WidgetRefresh.reload` reads `rideStore.summaries()` and hands the whole list to
`WidgetSnapshot.make` (`WidgetRefresh.swift:12-17`). It has eight call sites:
`AuraApp.swift:135,178,183`, `SettingsView.swift:122,125`, `NavigateHUDView.swift:243`,
`RideHUDView.swift:199`, `HistoryView.swift:82`.

`reload` and `WidgetSnapshot.make` both take an `activeRideID: UUID?`, and the summary list is
filtered on it before the snapshot is built. Home's `LastRideCard` read is filtered the same way.

**The parameter carries no default.** A defaulted `nil` would compile at a new call site that
should have passed an id and leak in exactly the way this issue exists to fix, silently. Eight
call sites each stating their answer explicitly is churn worth paying once. Two of them can fire
while a ride is running and pass the real id: `AuraApp.swift:183` (the `scenePhase == .active`
edge, which is the leak) and `AuraApp.swift:178` (inside the KVS sync loop, reachable mid-ride
when a settings change arrives from another device). `AuraApp.swift:135` is a launch `.task`, the
two HUD sites fire after `finish()` has already stamped `endedAt`, and the Settings and History
sites are unreachable during a ride. Those six pass `nil` as a claim a reviewer can check.

### Where the id comes from

Nothing currently exposes it. `AppRouter` carries `isRideActive` as a stored `Bool`
(`AppRouter.swift:15`), written by both HUDs at four sites (`RideHUDView.swift:195,203`,
`NavigateHUDView.swift:236,253`). The router is already the app-level authority on "a ride is in
progress" and is in scope at the two `AuraApp` sites that need the id, so it is the right home.

`AppRouter` gains `activeRideID: UUID?`, and **`isRideActive` becomes computed over it**:

```swift
private(set) var activeRideID: UUID?
var isRideActive: Bool { activeRideID != nil }
```

The four HUD writes set the id instead of the Bool, sourced from a new
`RideSessionCoordinator.activeRideID` so the recorder stays private. Every existing reader of
`isRideActive` (the deep-link guard at `AppRouter.swift:35`, `LocationAccuracyMode.desired`,
`SettingsView.swift:30,34`, `HomeView.swift:103`'s true-to-false edge, and the backfill
cancellation at `AuraApp.swift:161-163`) is unchanged.

Storing the id beside the Bool as a second stored property was the smaller diff and is rejected:
two stored properties written from four sites can desync, and a desync here means either the leak
returns or a finished ride vanishes from Home. Computing the Bool makes that unrepresentable.

Rejected alternatives:

* **Return early from `reload` while a ride is active.** One line, but it guards a refresh rather
  than a read, across eight triggers, and leaves Home untouched. A trigger added later is a
  regression nobody sees.
* **Exclude all unfinished rows while `isRideActive`.** Threads a Bool instead of a UUID, which is
  materially cheaper, and fails the two-unfinished-rows case above.

## D4 — Surfaces

| Surface | Treatment |
| -- | -- |
| History row | Renders as today, plus an unfinished marker. Caption keeps distance, moving time, climb |
| Home last-ride card | Same marker. The card still shows the ride |
| Widget last-ride | Same marker, via the snapshot change in D5 |
| Weekly ring | Counts it. `RideAggregator.weekToDate` is not modified; filtering happens on the list feeding it |
| Ride summary screen | Not reachable. A recovered ride never routes there |

The ring counting it is the PO decision of 2026-07-29: the rider covered that distance, and with
no resume and no end-it-now, excluding it under-reports their week permanently for a crash that
was not their fault.

**The marker is not amber.** Amber already carries peer-stopped and `AuraTheme.warning`, which
`GPSSignalChip` uses for weak or lost GPS. That collision is documented on ROH-101 and is not
worth widening here. A neutral secondary-weight treatment is correct on its own terms: an
unfinished ride is a fact about the recording, not a warning about the app.

The marker belongs in the accessibility label, not only in the visual. A VoiceOver user hearing
the same caption as a finished ride has not been told anything.

## D5 — `WidgetSnapshot` gains `endedAt` and `pausedSeconds` together

The widget cannot distinguish the two states: `WidgetSnapshot.LastRide` carries neither field
(`WidgetSnapshot.swift:17-47`). Adding one bumps `currentVersion` to 2
(`WidgetSnapshot.swift:11-13`), and the store's reader rejects an unknown version. That is safe
here because the app and the widget extension ship in one bundle, so the worst case is a widget
that renders empty until the app next writes a snapshot.

Since the bump is being paid, add both fields now. `endedAt == nil` gives this issue its marker,
and the pair is exactly what ROH-112 needs for the widget's active-with-elapsed pair, reducing
its widget work to rendering. One version bump instead of two, and one decode path to get right
instead of two.

## D6 — Out of scope

* **Resume.** PO decision, 2026-07-29: label only. Rehydrating `RideRecorder` from a V6 row is
  feasible, because segments are stored, but it needs a re-entry path into the HUD and an answer
  for a rider who starts a new ride instead. It is not this issue.
* **An explicit end-it-now action.** Same decision.
* **HealthKit for a recovered ride.** `finish()` writes the workout
  (`RideSessionCoordinator.swift:247-249`); a killed ride never reached it, so a recovered ride
  is absent from Health. Not fixed here. Filed separately rather than folded in.
* **Share card marking.** An unfinished ride stays shareable with no marker on the card.
* **`RideAggregator` arithmetic.** Unchanged.

## Risks

| Risk | Mitigation |
| -- | -- |
| A pre-existing row with nil `endedAt` renders as unfinished | `RideRecorder.end` has always stamped it and no other path persists a `Ride`, so I expect zero such rows. If any exist, they are rides with no recorded end, which is what the label says. No backfill |
| Ordering breaks on a nil `endedAt` | Does not apply. Both fetches sort on `startedAt` (`RideStore.swift:105,113`) |
| A new `reload` call site leaks the in-flight ride | D3's non-defaulted parameter makes it a compile error |
| Widget shows stale data after the version bump | Bounded to one snapshot write. App and extension ship together |
| Two flushes then a kill leave two rows | Does not apply. The flush is an upsert on `ride.id` |
| Unfinished row wins "Longest ride yet" | Possible via `RideAggregator.isLongest`, and harmless: a truncated ride is shorter than the ride it would have been |

## Testing

Pure tests in `AuraCoreTests` and `AuraKitTests`. No new XCUITest: the states are reachable
without driving a UI, and Pass 6 ([ROH-103](https://linear.app/rohun/issue/ROH-103)) owns the
end-to-end pause path.

* `checkpoint(at:)` returns a nil `endedAt`; `end(at:)` returns a stamped one.
* `RideMapper` round-trips a nil `endedAt` through the V6 record and back into `RideSummary`.
* Flush then finish leaves one row, with a real `endedAt` and `isUnfinished == false`.
* `weekToDate` counts an unfinished summary.
* The active-ride filter drops exactly the matching id, and keeps a second unfinished row with a
  different id. This is the D2 case, and it is the test that fails if someone later simplifies
  the filter to a Bool.
* `AppRouter.isRideActive` is true exactly when `activeRideID` is set, and the deep-link guard
  (`AppRouter.swift:35`) still drops a link while a ride is active. This is the regression test
  for D3's computed-property change, which touches a guard that Pass 2 audited.
* `WidgetSnapshot` v2 encodes and decodes both new fields; a v1 payload is rejected rather than
  mis-decoded.
* Caption and label strings for both states, including the accessibility label.
