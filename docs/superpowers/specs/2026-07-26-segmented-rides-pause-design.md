# Segmented rides & pause (ROH-74, Slice A) — design

Date: 2026-07-26
Issue: [ROH-74 — Pause a ride](https://linear.app/rohun/issue/ROH-74/pause-a-ride)
Status: approved (design), pending adversarial review

## Problem

A ride has two states: running and ended. A rider who stops for a café, a mechanical,
a photo, or to wait for someone has no way to say so. Three things go wrong.

**The live clock lies.** `RideSessionCoordinator.elapsed` is wall-clock
(`Date().timeIntervalSince(startedAt)`, recomputed on a 500 ms ticker,
`RideSessionCoordinator.swift:122`). The summary reports
`RideStats.movingTimeSeconds`, which `RideStatsCalculator` builds by discarding every
segment slower than 0.5 m/s (`RideStatsCalculator.swift:28`). The HUD and the summary
therefore already disagree, and the gap grows with every stop.

**Parked GPS drift counts as distance.** `RideStatsCalculator.swift:24` sums
`segDistance` unconditionally, outside the speed gate that guards `movingTime`. A phone
sitting on a café table accrues real distance.

**A deliberate stop is indistinguishable from a lost rider.** In a group ride a
stationary rider decays to `.dropped` after 40 s (`LiveShareCadence.droppedTimeout`) and
reads as "No Signal" to the crew. This is ROH-66, and it is out of scope here — see
Slice C below.

## Scope

ROH-74 decomposes into three slices. **This spec covers Slice A only.**

| Slice | Content | Status |
| -- | -- | -- |
| A | Local pause: segmented ride model, pause/resume, honest clock, no drift | This spec |
| B | Auto-pause: speed-threshold detection with hysteresis | Later, own spec |
| C | Crew presence: `paused` on the wire, roster/map rendering, merged with ROH-66 | Later, own spec |

Slice C subsumes ROH-66. The two tickets describe one problem — what a stationary rider
looks like to the crew — and are specced together when Slice C starts.

## Decisions

### D1 — The ride model becomes segmented

`Ride.track: [TrackPoint]` becomes `Ride.segments: [RideSegment]`, where `RideSegment`
wraps an ordered `[TrackPoint]`. A pause closes the current segment; a resume opens a new
one. A ride with no pauses is a single segment, so the common case stays trivial.

This is the model FIT files and HealthKit use. It was chosen over a flat track with a
per-point discontinuity flag, and over storing pause intervals beside a flat track,
because it is the only one of the three in which "these two points are not adjacent" is
unrepresentable-if-wrong rather than a convention every consumer must remember.

**`Ride.track` is removed rather than kept as a convenience.** Roughly eight rendering
sites currently assume one array maps to one path. If they keep compiling, they keep
drawing a straight chord across every pause, silently.

A flattening accessor still exists, spelled `flattenedPoints`, because some consumers are
genuinely correct to flatten — the HealthKit route has no concept of a gap. To be precise
about what this buys: the guarantee is **not** that no site can flatten. It is that
removing `track` forces every one of the eight to break at compile time and be revisited
deliberately, and that a site which then flattens says so at the call site. That is a
review-surface improvement, not an enforcement mechanism.

**A `Ride(kind:…track:…)` convenience initializer is retained**, wrapping its argument in
a single segment. Thirty-eight test files construct rides and nearly all need only *a*
ride; the convenience keeps about twenty-five of them untouched. Write-side convenience
is safe. Read-side convenience was the hazard.

### D2 — Persistence dual-writes for CloudKit forward compatibility

Rides sync to a private iCloud database
(`RideStore.swift:50`, `ModelConfiguration(cloudKitDatabase: .private(…))`). During
rollout a V5 device and a V6 device will read the same records. Renaming or repurposing
`trackData` would make every existing ride decode as an empty track on the older build —
silent, total, and it would propagate through sync.

Schema **V6 adds `segmentsData: Data?` alongside the existing `trackData`**, which keeps
receiving the flattened points.

- **Write:** both columns, every save.
- **Read:** prefer `segmentsData`; when absent, wrap the decoded `trackData` in one
  segment.
- **Old build reading a V6 record:** sees a flat track and renders today's straight-line
  chord across pauses. Degraded, not broken, and not lossy.

`segmentsData` is optional, so `SchemaInvariantTests` (every attribute optional or
defaulted, no `.unique`, no relationships, fixed entity set) continues to pass, and
V5→V6 is a lightweight migration.

Retiring `trackData` is **not in scope for this epic** and gets its own issue once the
fleet has moved.

### D3 — Thumbnails stay flat

`RideMapper.summary` decodes `thumbnailData` with a bare `try?` that falls back to an
empty array (`RideMapper.swift:43-48`). Changing that blob's shape would blank every
History row on an older build syncing the same records, with no failure signal — the same
trap as D2, but without even a degraded rendering.

A pause chord inside a 40 pt thumbnail is close to invisible. Blank History rows are not.
`thumbnailData` keeps its `[Coordinate]` shape and is built from flattened points.

### D4 — Statistics are computed per segment, never across

`RideStatsCalculator` gains a segment-aware entry point that runs the existing pairwise
walk within each segment and combines the results. Concretely:

- `distance` and `movingTime` are summed across segments; `maxSpeed` is the maximum over
  segments; `averageSpeed` is recomputed once at the end as total distance over total
  moving time, **not** averaged from per-segment averages.
- Every pairwise quantity — `segDistance`, `dt`, the speed gate — is computed only
  between points **inside** a segment.
- The `guard points.count >= 2 else { return .zero }` guard moves up a level, so a
  two-segment ride of one point each does not collapse to zero.
- The elevation baseline (`lastElevation`, seeded from `points[0].elevation`) still
  bridges nil-elevation samples **within** a segment, and **resets at each boundary**.

The elevation reset has a visible consequence. `ElevationProfile.classify` decides
`.profile` vs `.flat` from `stats.elevationGainMeters` against a 10 m floor, deliberately
so the label and the number cannot contradict each other
(`ElevationProfile.swift:4-6, 22`). A ride whose climb happened mostly across a pause can
now fall under that floor and read "mostly flat". That is the correct number — you did
not ride the hill you walked up — but it is a behavior change, and it is expected rather
than a defect.

### D5 — Three clocks, one new stored number

| Number | Definition | Storage |
| -- | -- | -- |
| Elapsed | `endedAt - startedAt` | Already stored; `RideSummary` carries both |
| Paused | Accumulated paused duration | **New:** `RideStats.pausedSeconds: Double?` |
| Active | `elapsed - paused` | Derived, never stored |
| Moving | Existing 0.5 m/s-filtered sum | Unchanged |

`pausedSeconds` is optional and `statsData` is a JSON blob, so legacy rows decode with it
nil and **no schema migration is required for this field** — the same mechanism already
documented on `TrackPoint.speedMetersPerSecond`.

`movingTimeSeconds` keeps its current definition. Redefining it would make every
already-saved ride incomparable with new ones in History and the weekly-goal widget.

**Rider-facing:** the HUD clock shows **active** time, which is what stops it lying. The
summary shows **moving** as it does today, plus **elapsed**. Rides saved before this
change show no paused figure and their elapsed remains derivable from stored dates.

### D6 — Recorder state machine

`RideRecorder.isRecording: Bool` becomes a three-case state: `idle`, `recording`,
`paused`, with `pause(at:)` and `resume(at:)`. `record()` drops points outright while
paused, which is what stops drift.

Two failure modes must be handled explicitly because both are silent:

**Resume resets `lastPoint` and the speed smoother.** `RideRecorder` chains `lastPoint`
into `InstantaneousSpeed.between(previous:current:)` (`RideRecorder.swift:21, 42-44`).
Resuming 200 m from the pause point would compute a position delta across the whole gap,
feeding a phantom speed into `SpeedSmoother` and spiking both
`maxSpeedMetersPerSecond` and the HUD dial. `start(at:)` already nils both;
`resume(at:)` performs the same subset.

**`end(at:)` drops a trailing empty segment.** Ending while paused would otherwise leave
an empty final segment, and `WorkoutData` falls back to `track.last?.timestamp` for its
end time (`WorkoutData.swift:27`), which would find nothing and write a zero-duration
HealthKit workout.

### D7 — Coordinator behavior while paused

| Concern | Behavior | Why |
| -- | -- | -- |
| Location streaming | **Continues** | Keeps the map live at a stop, leaves the ROH-83 three-tier `LocationService` lifecycle untouched, and supplies the data Slice B's auto-resume needs |
| Recording | Gated | The point of the feature |
| Screen wake | **Released**, re-acquired on resume | A 40-minute café stop should not hold the display on |
| Group sink | **Keeps receiving positions** | Gating it would silence a paused rider into `.dropped` after 40 s, reproducing the ROH-66 bug. Feeding it reads as `.stopped`, which is honest until Slice C |
| Gem discovery sink | Gated | A ride that is not recording should not generate ride events |
| Guidance | Untouched | Out of scope; a stationary rider generates no maneuvers |

### D8 — Live Activity uses a shifted anchor

The Lock Screen and Dynamic Island render their clock with `Text(timerInterval:)`
anchored to `attributes.startedAt`, which is immutable for the activity's lifetime
(`RideActivityAttributes.swift:20-21, 57`), so it cannot simply be frozen.

It does not need to be. Pushing an anchor of `startedAt + pausedSeconds` makes the
OS-side timer display **active** time on its own, with no per-second updates from the
app. While paused, the live timer is replaced by a static formatted duration.

`ContentState` gains `isPaused: Bool` and that anchor.
`RideActivityControlling.update(stats:currentSpeedMetersPerSecond:maneuver:)` gains a
parameter, so both conformers and the test doubles move together.

### D9 — The control lives in the bottom cockpit

A primary pause/resume control in the bottom cockpit of both HUDs, not in the right-hand
cluster. The cluster already carries five controls and both `ControlCluster.swift:25` and
`HUDControlMetrics.swift:31` document iPhone SE clearance above the instrument panel;
ROH-57 had to drop a dead button to fit the zoom pill, and ROH-75 just enlarged every hit
target to 56 pt. A sixth entry is not free.

A rider presses pause as they come to a stop, so the control wants to be large and
unmissable rather than thumb-reachable at speed.

`AuraPalette` already carries an amber swatch commented "stopped/paused"
(`AuraPalette.swift:12`), so the visual vocabulary exists. The paused treatment is
designed against the SwiftUI and design skills during Pass 4 rather than specified here.

### D10 — Testing adds a fixture instead of re-recording one

`GPXParser` ignores `<trkseg>` boundaries entirely (`GPXParser.swift:30-58`), and the
existing `golden-ride.gpx` is a single `<trkseg>` with no pause.

Teaching the parser to honor `trkseg` — which is what the tag means — and adding
`golden-ride-paused.gpx` as a **second** fixture avoids re-recording the first. Its four
frozen literals stay byte-identical, and that becomes the regression proof that
segmentation changed nothing for unpaused rides.

This matters because a re-record is a coupled three-file edit: `GoldenRideFixture.swift:13-24`,
`GoldenRidePlaybackTests.swift:36-40`, and the **non-derived** hero-distance bands at
`RideE2EUITests.swift:152-157`, which are hardcoded and would silently pass or fail on
their own.

The paused fixture gets its own frozen literals recorded through the existing
`GOLDEN_RECORD=1 swift test --filter GoldenRideFixtureTests` procedure.

### D11 — Fix the swallowed decode in the migration plan

`RideMigrationPlan.swift:37` decodes the track with a bare `try?` and no
`assertionFailure`, inconsistent with the `statsData` branch four lines above it, which
does assert. A track that fails to decode leaves `thumbnailData` nil with no diagnostic
in either configuration. This work makes that decode path more interesting, so the
inconsistency is corrected as part of it.

## Build order

Five passes, each a mergeable PR. Passes 2 and 3 are disjoint and may run in parallel.

| Pass | Content | Device? | Depends on |
| -- | -- | -- | -- |
| 1 | `RideSegment`, segment-aware `RideStatsCalculator`, recorder state machine, coordinator behaviors | No — CI | — |
| 2 | Schema V6, dual-write, migration, invariant tests, D11 | No — CI | 1 |
| 3 | Segment-aware read surfaces: `RideMapView`, `StaticRouteMap`, `RouteThumbnail`/share card, summary elapsed cell | No | 1 |
| 4 | Cockpit pause control, Live Activity shifted anchor | **Yes** | 1, 3 |
| 5 | `GPXParser` `trkseg`, paused fixture, E2E coverage | Sim | 1, 4 |

Pass 1 keeps `RideMapper` compiling by flattening to a single segment provisionally;
Pass 2 replaces that with the dual-write.

Pass 4 follows Pass 3 rather than running beside it: both touch `RideHUDView` and
`NavigateHUDView`, Pass 3 at the map call site and Pass 4 in the bottom cockpit.

## Risks

| Risk | Mitigation |
| -- | -- |
| Mixed-version iCloud fleet loses ride tracks | D2 dual-write; old builds degrade to a straight chord, never an empty ride |
| A render site silently keeps drawing the pause chord | D1 removes `Ride.track`, so all eight sites break at compile time and are revisited; a site that legitimately flattens says so at the call site |
| Phantom max-speed spike on resume | D6; explicitly tested, currently uncovered |
| Zero-duration HealthKit workout when ending while paused | D6 drops the trailing empty segment |
| A hilly ride reads "mostly flat" after D4 | Expected and documented; the number is correct |
| Golden-ride re-record churn | D10 adds a fixture instead of changing one |

## Out of scope

- Auto-pause (Slice B) and crew-visible paused state (Slice C, with ROH-66)
- Retiring `trackData` after the dual-write window
- Pause-location annotations on the map or elevation profile
- Pause state surviving app termination
- Segmented `thumbnailData` (D3)
