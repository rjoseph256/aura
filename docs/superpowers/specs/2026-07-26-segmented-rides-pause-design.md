# Segmented rides & pause (ROH-74, Slice A) — design

Date: 2026-07-26
Issue: [ROH-74 — Pause a ride](https://linear.app/rohun/issue/ROH-74/pause-a-ride)
Status: revision 2, after a three-reviewer adversarial gate

Revision 2 reworks D5, D6, D7 and D9 and rebuilds the pass decomposition. Revision 1's
versions of those decisions contained a fabricated failure mode, two claims contradicted
by the code they cited, and a pass split that was not buildable. The architecture — the
segmented model and the dual-write — survived review.

## Problem

A ride has two states: running and ended. A rider who stops for a café, a mechanical, a
photo, or to wait for someone has no way to say so.

**The live clock counts time the rider was not riding.** `RideSessionCoordinator.elapsed`
is wall-clock (`RideSessionCoordinator.swift:122`), while the summary reports
`RideStats.movingTimeSeconds`, which discards every segment slower than 0.5 m/s
(`RideStatsCalculator.swift:28`).

**Parked GPS drift counts as distance.** `RideStatsCalculator.swift:24` sums `segDistance`
unconditionally, outside the speed gate that guards `movingTime`.

**A deliberate stop is indistinguishable from a lost rider.** In a group ride a stationary
rider decays to `.dropped` after 40 s. That is ROH-66, and it is Slice C.

### What Slice A does and does not fix

Manual pause only fires when the rider remembers to press it. Two of the scenarios in the
originating ticket — the forgotten café stop, the long regroup — are precisely the ones a
rider will not press a button for. **Slice A makes the clock honest about deliberate
stops. It does not make it honest generally.** Traffic lights, slow climbs and unpaused
stops still separate active time from moving time.

Auto-pause (Slice B) is what closes that gap. Slice A is sequenced first because auto-pause
needs this state machine to drive, not because it is the larger share of the value.

**Slice A is also asymmetric across the two HUDs.** The navigate cockpit renders TO GO and
ARRIVE and has no clock at all (`InstrumentPanel.swift:20-22`); only the Explore HUD shows
elapsed (`ExploreInstrumentPanel.swift:22-24`). A navigate rider gets the recording gate,
the summary changes and the Live Activity, but no in-ride clock change.

## Scope

| Slice | Content | Status |
| -- | -- | -- |
| A | Local pause: segmented model, pause/resume, honest active clock, no parked drift | This spec |
| B | Auto-pause: speed-threshold detection with hysteresis | Later, own spec |
| C | Crew presence: `paused` on the wire, roster/map rendering, merged with ROH-66 | Later, own spec |

Slice C subsumes ROH-66.

## Decisions

### D1 — The ride model becomes segmented

`Ride.track: [TrackPoint]` becomes `Ride.segments: [RideSegment]`, where `RideSegment`
wraps an ordered `[TrackPoint]`. A pause closes the current segment; a resume opens a new
one. A ride with no pauses is a single segment.

This was chosen over a flat track with per-point discontinuity flags and over pause
intervals stored beside a flat track, because it is the only option in which "these two
points are not adjacent" is unrepresentable-if-wrong rather than a convention every
consumer must remember. FIT files use this model. (HealthKit is **not** an argument for it
in either direction — see D7.)

**`Ride.track` is removed.** A `Ride(kind:…track:…)` convenience **initializer** is
retained, wrapping its argument in one segment, so test files that need only *a* ride are
untouched. Write-side convenience is safe; read-side convenience is the hazard.

`flattenedPoints` exists for consumers that are correct to flatten. The guarantee is not
that no site can flatten — it is that every site is forced to be revisited, and a site that
then flattens says so at the call site.

**Removing `Ride.track` does not reach the live HUD map**, which is the surface a rider
stares at during a pause. `RideHUDView.swift:68` reads `coordinator.track`
(`RideSessionCoordinator.swift:18`), a passthrough to `RideRecorder.track` — a different
property on a different type. **`RideRecorder.track` and `RideSessionCoordinator.track`
must be segmented in the same pass**, or the one surface that matters most keeps drawing
the chord while compiling cleanly.

Sites broken by removing `Ride.track`: `RideSummaryView.swift:33,39`;
`ShareCardContent.swift:35,40`; `ElevationProfileContent.swift:18`;
`WorkoutData.swift:27,32`; `RideMapper.swift:7,13`. Of these, the polyline consumers are
`RideSummaryView:39`, `ShareCardContent:35` and `RideMapper:7`; the rest are encode,
elevation classification, and HealthKit.

The six thumbnail render sites (`HistoryView.swift:166`, `LastRideCard.swift:68`,
`ShareCardView.swift:39`, `LastRideWidget.swift:41,63,94`) consume
`RideSummary.thumbnailCoordinates` and are deliberately **not** reached, per D3.

### D2 — Persistence dual-writes, with a redeclared model and a backfilling migration

Rides sync to a private iCloud database (`RideStore.swift:50`). During rollout a V5 and a
V6 device read the same records.

**V6 redeclares `RideRecord`.** `RideRecord` is a typealias to `RideSchemaV2.RideRecord`
(`RideSchemaV2.swift:48`); V3, V4 and V5 all reuse that same class. Adding a property to
the V2 class would retroactively change the entity hash of V2 through V5, so an on-disk
store stamped V5 would no longer match any schema in the plan. `RideSchemaV6` therefore
declares its own `RideRecord` with all existing attributes plus `segmentsData`, and the
typealias moves — exactly the pattern `RideSchemaV5` used for `SavedPlaceRecord`, with a
comment explaining why (`RideSchemaV5.swift:5-7`).

**The entity name stays `RideRecord`.** A rename produces a new CloudKit record type and
every already-synced ride becomes invisible.

**`segmentsData` carries `@Attribute(.externalStorage)`**, matching `trackData`
(`RideSchemaV2.swift:20`). Without it a ~300 KB blob sits inline in the row, and
`RideStore.summaries()` fetches every row — reintroducing the ROH-64 fault that the
external-storage attribute exists to prevent.

**V5→V6 is a `.custom` stage that backfills `segmentsData`** from each row's existing
`trackData`. It cannot be lightweight: `RideMigrationPlan.swift:5-7` already documents the
rule — a lightweight stage cannot compute a new column from existing rows. Backfill is not
optional, because `RideStore.save` only ever `insert`s (`RideStore.swift:59-63`); there is
no update path, so an un-backfilled row would keep `segmentsData` nil forever and
`trackData` could never be retired.

Read prefers `segmentsData`; when absent, wraps decoded `trackData` in one segment. When
`segmentsData` is present but fails to decode, the read falls back to `trackData` rather
than throwing, and records a diagnostic.

**Storage cost.** A 3-hour ride at ~1 Hz is roughly 10,800 points, about 1.1 MB of JSON
(`RideTrackExternalStorageTests.swift:37-39` puts 3000 points at ~300 KB). Dual-write makes
that ~2.2 MB per ride, on disk and in the rider's iCloud quota. `segmentsData` is a strict
superset of `trackData`, so the second copy is wholly redundant. Retiring `trackData` is a
separate issue, unblocked by the backfill above.

**Release gate: the CloudKit production schema must be promoted before V6 ships.** Adding
an attribute to a mirrored model adds a field to the `CD_RideRecord` record type, and the
production schema is immutable from the client. Shipping V6 without promoting it first
stops sync entirely for every V6 user — strictly worse than the degraded rendering this
decision is designed around.

**Known unverifiable assumption.** That a V5 build silently ignores an unknown
`CD_segmentsData` field, and therefore degrades to a flat track rather than failing, is
asserted from documented `NSPersistentCloudKitContainer` behavior and cannot be tested in
this repo — macOS CI has no CloudKit entitlement
(`SchemaV5MigrationTests.swift:27`). It is verified manually on two devices before V6 ships.

**`SchemaInvariantTests` must be repointed to V6.** It currently pins
`Schema(versionedSchema: RideSchemaV5.self)` (`SchemaInvariantTests.swift:14`) under a
comment reading "always guard the CURRENT schema", so leaving it would let it pass while
testing a stale schema and provide no coverage of `segmentsData` at all.

### D3 — Thumbnails stay flat

`RideMapper.summary` decodes `thumbnailData` with a bare `try?` falling back to an empty
array (`RideMapper.swift:42-48`), so changing its shape blanks every History row on an
older build syncing the same records, with no failure signal.

This is the D2 compatibility argument, not an aesthetic one. **The line is drawn at
blob-shape compatibility, not at rendering size:** every surface that reads `segments`
becomes segment-aware regardless of how small it draws; only the surfaces that read the
pre-baked `thumbnailData` blob stay flat.

### D4 — Statistics are computed per segment, never across

`RideStatsCalculator` gains a segment-aware entry point running the existing pairwise walk
within each segment and combining results:

- `distance` and `movingTime` summed across segments; `maxSpeed` the maximum over segments;
  `averageSpeed` recomputed once as total distance over total moving time, not averaged
  from per-segment averages.
- Every pairwise quantity is computed only between points **inside** a segment.
- **The `count >= 2` guard is duplicated per segment, not moved.** A segment with fewer
  than two points contributes nothing. Moving the guard up would leave the per-segment body
  reaching `points[0]` unguarded, which is an index-out-of-range crash on the main actor
  for an empty segment — and empty segments are reachable (D6).
- The elevation baseline bridges nil samples **within** a segment and resets at each
  boundary.

The flat `stats(from: [TrackPoint])` entry point is retained, so
`RideStatsSnapshotTests`'s frozen reference is unaffected.

**On the elevation change.** Revision 1 attributed a possible "mostly flat" summary to the
boundary reset. That was wrong about the mechanism. The dominant cause is D6 dropping
points while paused: a rider who walks a bike up a hill records nothing for that climb, and
the whole ascent is gone before the calculator sees it. Against
`ElevationProfile.minGainMeters = 10.0`, the single discarded boundary delta is noise by
comparison.

The two cases also deserve different defences. Dropping the walked climb is correct — the
rider did not ride it. Discarding the boundary delta is a **small accepted inaccuracy**,
not a correctness win: it represents real elevation traversed under power on either side of
the pause. It is accepted because tracking it would require interpolating across a gap of
unknown shape.

### D5 — Active time is the headline; the rider sees the number they watched

| Number | Definition | Storage |
| -- | -- | -- |
| Elapsed | `endedAt - startedAt` | Already stored |
| Paused | Accumulated paused duration | **New**, see below |
| Active | `elapsed - paused` | Derived |
| Moving | Existing 0.5 m/s-filtered sum | Unchanged |

`movingTimeSeconds` keeps its current definition. Redefining it would make every saved ride
incomparable in History and the weekly-goal widget.

**The summary leads with active time**, with paused shown as the explanation for the gap to
elapsed. Revision 1 showed moving and elapsed only, which meant the summary looked
identical whether or not the rider had paused — moving time already excluded the café stop
before pause existed, and elapsed is unchanged by pausing. It also meant the number the
rider was watching when they pressed End appeared on no post-ride screen.

**`pausedSeconds` lives on `Ride`, not on `RideStats`.** It is a property of the session,
not of the statistics. `RideStats` is today a pure function of the track, which is what
lets `RideRecorder.record` recompute it wholesale on every point
(`RideRecorder.swift:38`); putting a non-derivable value inside it means every recompute
clobbers it, and `RideRecorderTests.swift:22` asserts
`recorder.stats == RideStatsCalculator.stats(from: points)` — which would fail on an
unpaused ride the moment the two disagree about `0` versus `nil`.

**`RideSummary` gains `pausedSeconds`**, backed by a denormalized column on the V6 record
alongside the existing `movingTimeSeconds`, so History and the weekly widget can use it
without faulting a blob. It defaults to `0`, which is the correct reading for every
pre-pause ride.

`RideSummary.endedAt` is `Date?`. When it is nil, elapsed and active are unavailable and
the summary renders the existing statless treatment rather than a zero.

### D6 — Recorder state machine, and what `isRecording` means

`RideRecorder` moves to `idle` / `recording` / `paused`, with `pause(at:)` and
`resume(at:)`. `record()` drops points while paused.

**`isRecording` remains true while paused.** It is not a recorder-internal flag; it is the
app's notion of "a ride is in progress", and five call sites depend on that reading:

| Site | Why it must stay true |
| -- | -- |
| `RideSessionCoordinator.swift:143` — `finish()` guard | Otherwise **End does nothing while paused** and the ride is discarded. `NavigateHUDView+GroupCrew.swift:154` documents this guard as load-bearing for group-ride end handling |
| `RideSessionCoordinator.swift:121` — ticker guard | It is a `return`, not a `continue`: the ticker would terminate permanently, freezing `elapsed` and killing `pushActivityUpdate()` for the rest of the ride — defeating D5 and D8 |
| `RideSessionCoordinator.swift:82` — `start()` re-entry guard | A re-entrant `start()` calls `recorder.start(at:)`, which wipes `track` and `stats` |
| `RideHUDView.swift:192`, `NavigateHUDView.swift:226` → `router.isRideActive` | See D7 |

A separate `isPaused` carries the paused reading. Nothing outside the recorder and the
cockpit consumes it.

**The ticker keeps running while paused**, and stops advancing `elapsed` because `elapsed`
is now computed as active time, not because the loop exits.

**Clocks.** Segment boundaries land on `point.timestamp` (GPS clock);
`pause(at:)`/`resume(at:)` are called with wall-clock `Date()`. Mixing them makes
`pausedSeconds` irreconcilable with the sum of segment spans and breaks under accelerated
replay — `GoldenRidePlaybackTests` runs at `multiplier: 10_000`, where a wall-clock pause
of milliseconds would span GPS-clock minutes. **`pausedSeconds` accumulates on the same
clock as the points**: `pause(at:)` stamps from the most recent point's timestamp when one
exists within the current segment, falling back to wall-clock only before the first fix.
`RideRecorder.swift:39-41` already documents this rule for the speed smoother.

**`end(at:)` closes any open pause interval into `pausedSeconds`** before producing the
ride. Without this, every ride ended while paused over-reports active time by the length of
the tail. It also drops a trailing empty segment — kept as hygiene, not for the reason
revision 1 gave, which was fabricated: `RideRecorder.end(at:)` always sets `endedAt`, so
`WorkoutData`'s `track.last` fallback is unreachable on that path and no zero-duration
workout was ever possible.

**`resume(at:)` resets `lastPoint` and the speed smoother.** Otherwise the first post-pause
fix position-deltas across the whole gap, spiking `maxSpeedMetersPerSecond` and the HUD
dial. Currently uncovered by tests.

**The speed hero decays to zero on pause.** `currentSpeedMetersPerSecond` is written only
inside `record()`, and `SpeedSmoother` has no time decay, so a rider who pauses at 25 km/h
would otherwise leave 25 on the largest numeral in the cockpit for the whole stop — a worse
lie than the one this feature exists to fix. `pause(at:)` zeroes it explicitly.

**Empty segments are legal and must not crash.** A pause before the first fix, and
pause→resume→pause with no intervening point, both produce empty non-trailing segments. D4
duplicates the count guard for this reason.

### D7 — Coordinator behavior while paused

| Concern | Behavior |
| -- | -- |
| `router.isRideActive` | **Stays true.** A paused ride is an active ride |
| Recording | Gated |
| Location streaming | Continues at a **coarser tier**; full accuracy re-armed on resume |
| Screen wake | Released, re-acquired on resume |
| Persistence | **Closed segments flushed at each pause boundary** |
| Group sink | Coordinate continues; progress and speed handled below |
| Gem discovery sink | Gated |
| Guidance | `onArrive` **suppressed** while paused |

**`isRideActive` must not flip.** It is written from `coordinator.isRecording`
(`RideHUDView.swift:192`, `NavigateHUDView.swift:226`) and gates four things, each of which
misfires if pausing clears it. The worst is `AppRouter.swift:35`: `guard !isRideActive` is
the only thing stopping a deep link replacing `router.path`, which tears down the HUD →
`onDisappear` → `cancel()` — and `cancel()` does not save. **Pausing would let a widget tap
silently destroy the entire ride.** The others are the location accuracy tier
(`AuraApp.swift:184`), the post-ride Home reset on the true→false edge
(`HomeView.swift:105`), and the Settings lockout (`SettingsView.swift:30,34`).

**Location drops to a coarser tier.** Holding `.navigating` — `kCLDistanceFilterNone` with
`pausesLocationUpdatesAutomatically` forced off (`LocationService.swift:101-108`) — wakes
the app for every fix, which `record()` then discards. A two-hour forgotten pause plausibly
costs 20%+ of the battery to record nothing, and the rider still has to get home. The
coarser tier keeps the map roughly live and leaves Slice B's auto-resume viable.

**Closed segments are flushed at each pause boundary.** Nothing persists mid-ride today, so
a jetsam kill already loses everything — but pause deliberately creates the conditions that
make a kill likely: backgrounded, no interaction, screen wake released, for tens of
minutes. Losing that gamble costs the distance ridden *before* the stop. One write at a
moment when nothing else is happening makes a killed paused ride recoverable up to the
pause. Full in-flight persistence for unpaused rides remains out of scope.

**Group progress.** `progressMeters` comes from `recorder.stats.distanceMeters`, which
freezes while paused, but the coordinate keeps flowing. Broadcasting a live coordinate
beside a frozen progress number makes the crew's display contradict itself: `PeerDistance`
reports the rider ever further behind, `GroupRosterViewData` sinks them to the bottom of
the roster, and `GroupMapDots` can never make them leader even when they are physically in
front. **The paused rider stops publishing progress updates entirely**, holding their last
value, rather than publishing a frozen number as if it were current.

**Group speed.** The sink falls back to `recorder.currentSpeedMetersPerSecond` whenever
Doppler speed is nil, which is common when stationary. D6 zeroes that on pause, so the
motion classifier sees `< 0.5 m/s` and the rider reads as `.stopped` rather than being
pinned `.moving` by a frozen pre-pause value. This is the honest interim until Slice C
carries an explicit paused state.

**Guidance `onArrive` is suppressed while paused.** `NavigateHUDView.swift:202` sets
`guidance.onArrive = { endRide() }`, which finishes the ride and pushes the summary with no
confirmation. Riders pause *at* the destination they navigated to, inside the arrival
radius. Left untouched, arrival would end the ride under a paused rider. (Voice guidance
speaking over the rider's music during a pause is a related, lesser issue; suppressing
announcements while paused is folded into the same change.)

### D8 — Live Activity uses a shifted anchor

The widget clock is `Text(context.attributes.startedAt, style: .timer)`
(`RideLiveActivity.swift:49,94`, `RideActivityComponents.swift:54`), anchored to an
immutable attribute, so it cannot be frozen in place.

Pushing an anchor of `startedAt + pausedSeconds` makes the OS-side timer display **active**
time with no per-second updates. While paused, the live timer is replaced by a static
formatted duration.

`ContentState` gains `isPaused` and that anchor, so **all three widget call sites move from
`context.attributes` to `context.state`**. `RideActivityControlling.update(…)` gains a
parameter, so both conformers and the test doubles move together.

**`staleDate` is pushed forward or cleared while paused.** The controller marks content
stale 90 s after the last push (`RideLiveActivityController.swift:26-27`), which would dim
the Lock Screen for the remaining 38 minutes of a 40-minute stop. Paused state genuinely
is not going anywhere.

`ContentState` is `Codable` and re-serialized on every update, so an activity in flight
across an app update sees a shape change. The added fields are optional for that reason.

**Resume from the Lock Screen is out of scope for Slice A** and tracked separately. It
wants an App Intent, and the scenario it serves — phone pocketed, rider walking back to
the bike — is real enough that it should not be silently dropped.

### D9 — The control lives in the bottom cockpit

A primary pause/resume control in the bottom cockpit of both HUDs.

**Honest accounting of the alternative.** The cluster carries at most four entries on
either HUD, not five: Explore renders zoom + recenter + mark-spot + end and omits mute
(`RideHUDView.swift:253-259`), Navigate renders zoom + recenter + mute + end
(`NavigateHUDView.swift:447-459`). And the cockpit is the *same vertical column* as the
cluster (`RideHUDView.swift:249-270`), so a large control there spends the same iPhone SE
clearance one row lower. The cockpit is chosen because pause is a primary action that
should not be one of five equal-weight circles, not because it is free.

**Two layout constraints Pass 4 must resolve rather than discover:**

- On a group navigate ride the `GroupRosterSheet` expands to 40% of HUD height
  (`NavigateHUDView.swift:441-443`), overlapping the cockpit. Pause must have a defined
  position and behavior when the roster is expanded.
- On iPhone SE the instrument panel already owns 25% of the screen
  (`containerRelativeFrame(.vertical, count: 4)`), the cluster owns roughly four 56 pt
  targets, and on Navigate the turn card owns the top.

**Resume is the harder ergonomic case.** Pause is pressed while stopping; resume is pressed
while clipping in or already rolling, one-handed and often gloved. `HUDControlMetrics`
exists for exactly that rider (ROH-75). The control is sized for resume, not for pause.

**Amber is already taken.** `AuraPalette.swift:12`'s amber is in live use as the peer
stopped state and as `AuraTheme.warning`, which `GPSSignalChip` uses for weak or lost GPS
(`GPSSignalChip.swift:12-21`). Pausing under a railway bridge would light two amber
elements meaning different things. The paused treatment resolves this collision rather than
assuming the swatch is free.

**Rider-facing states, all required:**

- Haptic confirmation on pause and resume. The app already uses
  `HapticPlayer.shared.play(.approach)` for saving a map pin (`RideHUDView.swift:245`);
  pause is exactly the eyes-off confirmation haptics exist for.
- A paused indicator legible at a glance on a bar-mounted phone in rain — not only a
  recoloured button.
- A nudge after a long pause. The forgotten resume is the most predictable failure of a
  manual pause, and it is the one that corrupts a ride worst.
- VoiceOver label and state announcement, and a `RideTestID` accessibility identifier —
  the E2E pass needs something to tap, and this repo gates contrast and ships a VoiceOver
  labels spec.

Accidental pause is mitigated by the haptic, the persistent indicator and the nudge rather
than by a confirmation dialog, which would defeat the point of a one-tap control.

### D10 — Testing adds a fixture instead of re-recording one

`GPXParser` ignores `<trkseg>` boundaries (`GPXParser.swift:30-58`). Teaching it to honor
them, and adding `golden-ride-paused.gpx` as a **second** fixture, leaves the existing
fixture's four frozen literals byte-identical — which becomes the regression proof that
segmentation changed nothing for unpaused rides.

This matters because re-recording the existing fixture is a coupled three-file edit:
`GoldenRideFixture.swift:13-24`, `GoldenRidePlaybackTests.swift:36-40`, and the
**non-derived** hero-distance bands hardcoded at `RideE2EUITests.swift:152-157`.

**`GPXTrack.points` is retained as a flattened accessor** beside the new segments, so
`GPXLocationPlayer`, `SimulatedLocationProvider`, `GoldenRideFixture` and roughly eighteen
parser-test assertions are unaffected — including `test_emptyGPX_yieldsNoPoints`, which
parses a document with no `trk` or `trkseg` at all.

**The paused fixture needs its own hero band.** `RideE2EUITests.swift:141-142` states the
existing band is shared by both golden rides; a paused fixture with different distance
cannot reuse it.

Re-record procedure, per `GoldenRideFixture.swift:7`:
`GOLDEN_RECORD=1 swift test --filter recordTruthLiterals`.

## Build order

Revision 1's five passes were not buildable: removing `Ride.track` forces the share-card
and elevation surfaces in the same pass that introduces the model, so pass 1 contained most
of pass 3; and the pause control was scheduled to ship before the schema that persists what
it produces.

| Pass | Content | Device? | Depends on |
| -- | -- | -- | -- |
| 1 | `RideSegment`, `Ride.segments`, segmented `RideRecorder.track`/`coordinator.track`, segment-aware `RideStatsCalculator`, `GPXParser` `trkseg`, paused fixture, **and every read surface forced by removing `Ride.track`** | No — CI | — |
| 2 | Recorder state machine, `isRecording`/`isPaused` semantics and all five call sites, coordinator behaviors, speed decay, pause-boundary flush | No — CI | 1 |
| 3 | Schema V6 (redeclared record, `.externalStorage`, custom backfill stage), `RideSummary.pausedSeconds`, `SchemaInvariantTests` repoint, CloudKit promotion gate | No — CI | 2 |
| 4 | Cockpit control, paused visual state, haptics, VoiceOver, nudge | **Yes** | 3 |
| 5 | Live Activity shifted anchor, stale policy, `ContentState` migration | **Yes** | 4 |
| 6 | E2E through the paused fixture | Sim | 4, 5 |

The paused fixture moves into Pass 1 because it is the only way to construct a
multi-segment ride and look at it; without it, Pass 1's read surfaces merge unverified.

**No build with a user-reachable pause control ships before V6 lands**, which is why Pass 4
depends on Pass 3. Otherwise a rider could pause, watch an honest clock, and have every
segment boundary silently discarded on save.

Passes 4 and 5 are split because they are the two things CI cannot verify, and pairing a
layout problem with a `ContentState` shape change makes a failure hard to attribute.

**Passes 1–3 change no rider-visible behavior** while shipping a CloudKit schema change and
a migration. If the epic stalls after Pass 3 the app carries that cost permanently for no
rider benefit. That is the strongest argument for treating Pass 4 as the commitment point
rather than Pass 1.

## Risks

| Risk | Mitigation |
| -- | -- |
| Pausing lets a deep link destroy the ride | D6/D7: `isRideActive` stays true; all five `isRecording` call sites audited in Pass 2 |
| Mixed-version iCloud fleet loses ride tracks | D2 dual-write with redeclared V6 record; degraded, never empty. Manually verified on two devices |
| CloudKit production schema not promoted before V6 ships | D2 names it a release gate |
| `trackData` can never be retired | D2's custom backfill stage; `save` is insert-only so nothing else would ever revisit a row |
| History regresses to a blob-faulting fetch | D2: `.externalStorage` on `segmentsData` |
| Ride lost to jetsam during a long pause | D7 flushes closed segments at each pause boundary |
| Speed hero pinned at pre-pause speed, and rider pinned `.moving` to the crew | D6 zeroes the smoothed speed on pause |
| Arrival ends the ride under a paused rider | D7 suppresses `onArrive` while paused |
| Crew roster contradicts itself for a forgotten pause | D7 stops publishing progress rather than freezing it |
| Live HUD map keeps drawing the chord | D1: `RideRecorder.track` segmented in the same pass, not just `Ride.track` |
| Phantom max-speed spike on resume | D6; explicitly tested, currently uncovered |
| Epic stalls after Pass 3, cost with no benefit | Build order; Pass 4 is the commitment point |

## Out of scope

- Auto-pause (Slice B) and crew-visible paused state (Slice C, with ROH-66)
- Retiring `trackData` after the dual-write window
- Resume from the Lock Screen via an App Intent — tracked separately
- HealthKit pause events. A ride ended after a long pause is still written to Health with
  wall-clock duration; `HKWorkoutEvent(type: .pause)` exists for this and is deliberately
  deferred. **This is a known inaccuracy, not an oversight** — revision 1 incorrectly
  claimed HealthKit has no concept of a gap
- Full in-flight ride persistence for unpaused rides
- Pause-location annotations on the map or elevation profile
- Segmented `thumbnailData` (D3)

## Deferred defect noticed during review

`RideMigrationPlan.swift:37` decodes the track with a bare `try?` and no `assertionFailure`,
inconsistent with the `statsData` branch four lines above; line 39 has a second swallowed
`try?`. Revision 1 folded this into the persistence pass on the grounds that this work
touches that path. It does not — line 37 lives in the frozen V1→V2 `didMigrate`, which
nothing in Slice A routes through. It is a real inconsistency and gets its own issue.
