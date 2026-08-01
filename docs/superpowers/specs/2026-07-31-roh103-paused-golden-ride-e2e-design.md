# Paused golden-ride E2E (ROH-103, Slice A Pass 6) — design

Date: 2026-07-31
Issue: [ROH-103 — Pass 6, E2E coverage through the paused golden fixture](https://linear.app/rohun/issue/ROH-103/pass-6-e2e-coverage-through-the-paused-golden-fixture)
Parent spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D10)
Status: revision 3. Revision 2 followed a three-reviewer gate on the spec; revision 3 follows a
two-reviewer gate on the plan. Revision 1 justified the pass with a claim that was false (three
of its four "uncovered" behaviors have coordinator-level tests), found the segment boundary with
a heuristic that fires early under CI load, and put every expensive assertion inside the one
budget that is scarce. Revision 2 then carried an unfalsifiable max-speed assertion, claimed a
rendered-clock reading it did not make, and understated Pause A's cost. Revision notes are
inline.

This is the last pass of Slice A. Passes 1-5 are shipped: the segmented model, the recorder
state machine, schema V6, the cockpit control, and the Live Activity.

## Problem

*(Revised. Revision 1 claimed nothing verified the frozen clock, the zeroed speed, or the
two-segment save above the recorder. `RideSessionCoordinatorPauseTests` and
`RideRecorderPauseTests` cover all three, and the pass does not need that argument.)*

Four things are genuinely uncovered.

**The button is connected to nothing that a test has ever checked.** No test in `Aura/UITests`
taps `RideTestID.hudPause`. The path from the control at `RideHUDView.swift:294` through
`togglePause()` at `RideHUDView.swift:324` to `coordinator.pause()` exists only by inspection.
There are **two** such paths: `togglePause()` is implemented twice, once in `RideHUDView.swift:322`
and again in `NavigateHUDView+Cockpit.swift:131`. `RideHUDView.swift:299-307` records that the
instrument panel already drew over the pause row once, on an iPhone SE.

**Ending a ride while paused has no end-to-end coverage.** Parent D6's first table row says that
if the `isRecording` reading regressed, "End does nothing while paused and the ride is
discarded". That is the invariant whose violation destroys a rider's ride, and pausing then
ending is an ordinary thing to do — you stop, and then you decide you are done.

**Nothing reads a saved paused ride back.** The summary renders `coordinator.finishedRide`
in memory (`RideSessionCoordinator.swift:378`); the probe reads live recorder state; History is
asserted for row count. `segmentsData` encode and decode is exercised by package tests over
constructed rides, never by a ride this app actually recorded.

**The app cannot play the paused fixture.** `SimulatedRideSupport.rideOverride` ignores
`SimulatedRideConfig.fixture` and always loads `GoldenRideFixture`
(`SimulatedRideSupport.swift:18`).

What the coordinator tests prove about the recorder, this pass proves about the screen. That is
different evidence, not more of the same: `RideSessionCoordinatorPauseTests.swift:113` drives
`c.pause()` directly, and the question here is whether a finger on the control reaches it.

## Two claims in the issue that cannot be delivered as written

**"The summary leads with active time."** That surface change is parent D5, tracked as ROH-112.
It is not built on any of its four surfaces. *(PO decision, 2026-07-31: ROH-112 is promoted out
of Backlog and now blocks ROH-74, so the epic does not close over it. This pass asserts the
moving-time cell, which is a different and weaker signal — see D3.)*

**"The route draws with a gap rather than a chord."** The ride map is a Mapbox GL surface with
nothing in the accessibility tree. *(PO decision, 2026-07-31: proved in the data here, with the
pixels split out as ROH-143, a device pass with a written checklist.)*

## Decisions

### D1 — An unknown fixture name turns the harness off, not half off

*(Revised. Revision 1 had `rideOverride` return `nil` for an unknown name and called that
"degrades to absent". It is not absent — it is a third state.)*

Six sites key off `SimulatedRideConfig.current != nil`: the in-memory store
(`AuraApp.swift:51`), the ambient location tier (`AuraApp.swift:235`), the preview route
substitution (`RoutePreviewView.swift:271`), scripted guidance (`NavigateHUDView.swift:90`), the
probe (`SimulatedRideSupport.swift:41`), and the notification-authorization skip
(`PauseNudgeScheduler.swift:38`). Nilling the provider alone leaves five of them engaged while
the ride records real GPS. A typo then reads, ninety seconds later, as "distance never reached
— last probe: d=0".

So the fixture name is validated where the contract lives:

- `SimulatedRideFixture` is added to `AuraKit/Testing/`: a name-keyed lookup from `"golden"` and
  `"paused"` to a provider factory. A dictionary in AuraKit rather than a `switch` in the app
  target, for the reason `PauseNudgePolicy` already documents — the app target has no test
  bundle, so a `switch` there is untestable by construction.
- `SimulatedRideConfig.parse` returns `nil` for a name the lookup does not know. All six sites
  then honor one contract, and an unknown name means real location everywhere.
- `rideOverride` resolves through the lookup and keeps its existing `assertionFailure` for a
  name that is known but fails to load, which is a packaging regression rather than a typo.

`PausedGoldenRideFixture` gains the `simulatedProvider(multiplier:)` factory its sibling has.
`RoutePreviewView` keeps naming `GoldenRideFixture` directly; the preview substitution is the
navigate deep link's route, not the ride stream.

### D2 — Two probe fields, described for what they actually do

`RideTestProbe` renders an invisible line in the accessibility tree during DEBUG simulated
rides. It carries distance, elapsed and gain, and gains two more:

| Field | Source | What it is worth |
| -- | -- | -- |
| `s` | `coordinator.currentSpeedMetersPerSecond`, in **decimetres per second** | The rendered speed is also readable (`InstrumentChassis.swift:90-92` exposes an `accessibilityValue`), but that string is formatted and unit-dependent. The probe carries the raw number; the test asserts both — see D5 |
| `n` | `coordinator.segments.count` | A cheap check that `resume()` ran. **Not** proof of the saved shape: `resume(at:)` appends unconditionally (`RideRecorder.swift:119-127`), so `n == 2` is true before a single post-resume fix, and the saved ride goes through `normalizedSegments`, which drops a trailing empty |

*(Revised. Revision 1 called `n` "the only reading of a gap available to a UI test", which its
own D3 and D5 refute, and justified `s` on a dial and on locales, neither of which exists. The
decimetre choice stands: `pause(at:)` writes exactly `0`, so any nonzero reading is a real
defect, and a partial-decay regression is visible at that resolution.)*

**`d`, `e` and `g` stay required; `s` and `n` parse as optional.** `RideTestProbe.parse` returns
nil on any unknown or missing key. Both CI and `scripts/golden-ride.sh` use
`test-without-building`, so a test bundle from this commit against an app binary from an older
one is an ordinary developer state, and strict parsing turns that skew into
`XCTUnwrap` "expected non-nil value" across all three golden tests, naming nothing. The
compiler already forces both HUD call sites through the `simulatedRideProbe` signature;
strictness in the parser adds no safety and costs attribution.

`RideTestProbeTests` covers the new line format and an old-format line without `s` or `n`.

### D3 — The discriminating assertions are made in raw metres

*(Revised. Revision 1 put the segmentation proof on the summary's display strings.)*

Segmented and flattened are 1883 m against 2391 m, which the formatter renders as 1.2 mi
against 1.5 mi — three display steps, with rounding eating one on each side. The probe carries
raw metres, so that is where the proof goes:

- **While paused at the boundary, probe distance equals the segment-1 literal exactly** (941 m).
  `record()` is a no-op while paused, so segment 1 is final at that moment. This one equality
  catches a tap that lands early (reads low) and one that lands late (reads 1449, the chord
  included), which is the whole failure family in a single assertion.
- **Probe elevation gain in a 55-70 band at the end.** Segmented is 58, flattened is 100. A tap
  that lands early enough for the +42 m step across the stop to fall inside segment 2 reads 98,
  and one that lands two points early reads 54, so the band brackets the correct answer from
  both sides. *(Revision 2 claimed it caught a one-point-early tap; that reads 56, which is
  inside the band. The exact-941 equality is what catches that case.)* The unpaused golden test
  already carries a silent-flat guard; this is its counterpart.
- **Final probe distance in a band holding 1883 and excluding 2391.**

The summary's display bands stay loose wiring checks, as the existing hero band is. They must
still exclude the flattened reading (1.5 mi / 2.4 km) rather than merely contain the segmented
one — a lazy band of 1.0-1.6 mi would admit both.

**The moving-time cell in a 3-6 minute band.** Segmented moving time is 290 s, rendering as
"4 min"; flattened is 890 s, rendering as "14 min". This is the design's most robust assertion
and the only one that is fully independent of when the tap lands: `movingTimeSeconds` is
computed from the fixture's own timestamps, so any run that recorded the 600 s chord inside a
segment reports at least ten minutes.

**It is not, however, the signal ROH-112's active-time assertion would carry.** Moving time is
`RideStatsCalculator` walking segments behind a 0.5 m/s gate. Active time is
`elapsed - pausedSeconds`, a wall-clock ledger in `RideRecorder` that shares no code with it.
Bugs only the active-time path can have — `end(at:)` failing to bank an open stop,
`pausedSeconds` lost through `RideMapper` and `RideStore` — are invisible here. Worse, they may
not be assertable in this harness at all: `GPXLocationPlayer.schedule` yields points with their
original fixture stamps while `startedAt` and `endedAt` are wall-clock, so a saved harness ride
has 290 s of moving time and roughly 45 s of active time. ROH-112 inherits a problem nobody has
yet shown is solvable as a frozen band. Said here so it is not discovered there.

The moving cell needs `RideTestID.summaryMoving`. The cockpit's speed readout and its stats
column need `RideTestID.hudSpeed` and `RideTestID.hudStats`, rather than being matched on their
display labels — a raw `"Speed"` string in a query is the failure mode the shared enum exists to
prevent, and a rename would leave both new tests dead with no compile break. Identifiers in the
shared enum, applied beside the existing accessibility labels.

### D4 — The boundary is found by distance, not by a stall

*(Revised. Revision 1 polled until the distance reading stopped changing. That is unsound.)*

`SimulatedLocationProvider.points()` sleeps the nominal inter-point delta and advances `last`
by the *scheduled* offset, never the real clock (`SimulatedLocationProvider.swift:19-27`), so
playback stretches under load and never catches up. The suite already budgets about six times
nominal for a replay (`RideE2EUITests.swift:33-35`). Once effective spacing exceeds the one-second
poll interval that `Screens.swift:75-84` documents as necessary, two equal reads mean nothing,
and the detector declares the boundary mid-segment-1. A stall reading is also indistinguishable
from `d=0` before the first fix.

The replacement is deterministic. Segment 1 is exactly 941.5986 m, `record()` accepts every
point unconditionally, and the simulated stream is unfiltered, so 941 m is reachable only at the
30th point and the next increment is +507 m thirty seconds later. `waitForDistance(atLeast: 941)`
— the helper the suite already has — fires *at* the boundary instead of two or three polls after
it, and is correct under arbitrary playback stretch.

**The multiplier is 20x for this method**, so the fixture's 600 s stop replays as a 30 s
silence and the whole ride costs about 45 s. *(Revision 3. Revision 2 put it back to the
harness default of 30x on the grounds that moving the clock assertions out of the window
removed the reason for the margin. The plan review priced Pause A honestly: six XCUITest
round-trips, each paying the idle-wait penalty on a HUD that is never idle — a live Mapbox
surface, a half-second ticker, and a second-resolution numeric transition on the chip's own
clock. Fifteen seconds of CI is the cheaper side of that trade, and it makes the "+507 m
thirty seconds later" reasoning above literally true rather than approximately.)*

Knowing where segment 1 ends needs a frozen number, so `PausedGoldenRideFixture` gains
`expectedSegmentDistanceMeters: [Double]`. The recorder that emits the fixture's literals does
not currently print a per-segment array (`PausedGoldenRideFixtureTests.swift:70-86`), so
`recordPausedTruthLiterals` is extended in this pass to emit it, and a test asserts the array
sums to `expectedDistanceMeters`. Three literals that must agree with nothing checking that they
do is how they drift.

### D5 — Two pauses, because only one of them needs to be inside the window

*(Revised. Revision 1 put every clock assertion inside the 30 s replay silence, which is the one
budget that is scarce.)*

Only the taps need to land in the silence. The clock and speed assertions do not care where
playback is, and they are the expensive part. So the free-ride test
(`testPausedGoldenRideSegmentsAndSummary`, launched onboarded with
`-auraSimulatedRide paused -auraSimulatedRideMultiplier 30 -auraInMemoryRideStore`, entering
through Explore) uses two:

**Pause A — inside the silence, three operations.**

1. Ride until probe distance reaches 941 m. Assert probe speed is above zero, which is the
   positive control: `s == 0` alone passes for a probe wired to a literal, and a dial reading
   zero while riding is itself a shipping bug.
2. Tap `ride.hud.pause`; `ride.hud.paused.banner` appears.
3. Assert probe distance equals 941 exactly (D3).
4. Tap again; the banner clears. Two taps and two reads, well inside twenty seconds.

**Segment 2 records out**, to at least the segmented literal. Assert `n == 2` and the distance
and gain bands.

**Pause B — after the last point, where no window exists.**

5. Tap pause. The banner appears, elapsed does not advance across several polls, probe speed
   reads exactly zero, and the rendered speed value reads zero too. The rendered read is the one
   that matters to a rider; the probe read is the one that is exact.

   *(Revision 3: the rendered **clock** is read here too. Revision 2 asserted the clock only
   through the probe while claiming the freeze was proved "at the rendered surface". The
   cockpit's stats column composes distance, time and gain into one accessibility label at
   second resolution, so holding that label across the pause and watching it change after the
   resume is the rider-visible statement. Both readings are kept: the probe attributes a
   failure to the coordinator, the label attributes it to the view.)*
6. Tap resume. Elapsed advances again and never read lower than it did before the pause.
7. Tap pause once more, then **End the ride from the paused state** — the parent D6 invariant.
   `normalizedSegments` drops the trailing empty segment, so every band is unchanged.

**Then the summary and the round trip.**

8. Summary hero distance and moving cell in their bands (D3).

   *(Revision 3 removed a max-speed band here. Revision 2 sold it as covering parent D6's
   phantom resume spike; both plan reviewers showed it cannot. `RideStatsCalculator.walk`
   computes max speed strictly inside a segment, and the chord across the stop is 507 m over
   600 s — 0.85 m/s, slower than every real leg — so segmented and flattened produce the same
   14.5 mph and the assertion passes under total segmentation failure. The phantom lives on
   `currentSpeedMetersPerSecond`, which never reaches `RideStats`. The band, its identifier and
   its accessor are all dropped rather than left looking like coverage.)*
9. Done returns Home. History holds exactly one row — the pause-boundary flush upserts on
   `ride.id`, so this is the proof that a pause does not duplicate the ride — and that row does
   not carry `UnfinishedRideCopy.label`. `checkpointedAt` is copied by hand at
   `RideStore.swift:93`; if that line were dropped, every paused ride would wear the
   abandoned-ride treatment across History, the last-ride card, the share card and the summary.
10. Tap the row. `HistoryView.swift:75` re-reads through `store.ride(id:)` and presents
    `RideSummaryView`, so the same distance and moving bands asserted on that sheet are the
    **persisted** ride, decoded from `segmentsData`. This is the only step in the pass that
    proves the save kept its segments.

### D6 — The navigate pause control gets its own short test

*(New. PO decision, 2026-07-31.)*

`togglePause()` has two implementations, `isPaused` feeds two different instrument panels, and
ROH-101 line 317 explicitly handed this coverage here. Revision 1 declined it on the grounds
that the navigate cockpit has no clock — true, and it leaves the other six assertions applying.

`testNavigatePauseControlEndsWhilePaused` enters navigate through the preview deep link on the
**ordinary** golden fixture, since it needs no replay silence: ride, pause, assert the banner
and zero speed, end from the paused state, and assert the summary appears. About twenty seconds,
and it covers the second toggle path and the occlusion risk that has already bitten once.

### D7 — The harness stops scheduling nudges

`PauseNudgeScheduler.swift:35` reads: "The pause nudges themselves are left wired: the harness
never pauses, and adding requests prompts nobody." This pass makes the harness pause, so
`scheduleForgottenPauseNudges` runs in CI for the first time and adds five
`UNTimeIntervalNotificationTrigger` requests per run.

It will not prompt, and the first rung is 600 s out. The residual is that a run aborting between
pause and resume leaves those requests alive in that simulator, to fire ten to a hundred and
twenty minutes later over whatever is running then. The scheduling is suppressed under the
harness beside the existing authorization skip, and the stale comment is corrected in the same
pass rather than left to contradict the code.

### D8 — CI runs the same command, on a longer budget

`ci.yml:113` and `scripts/golden-ride.sh:32` both run
`-only-testing:AuraUITests/RideE2EUITests`, so new methods are picked up with no edit. What does
change is the reasoning behind the fifty-minute ceiling: `ci.yml:56` documents it as "TWO
golden-ride methods, each retried once". There are now four. The comment is updated with the
count and the added replay time.

`-retry-tests-on-failure -test-iterations 2` (`ci.yml:114`) means a first-run failure retries and
the job still goes green. With the stall detector gone the only timing-coupled step is Pause A's
two taps inside a twenty-second silence, but the retry is recorded in the risks table so that
nobody reads green as "never flaked".

## What a green run proves

**Proven:** the Explore and navigate pause controls are both wired to `coordinator.pause()`; the
control is reachable and not occluded on the test device; the live active clock freezes, resumes
and never runs backwards at the rendered surface; the speed readout falls to exactly zero; a ride
paused across a GPS gap records and **saves** segmented distance, moving time and elevation gain
rather than flattened; ending from the paused state saves the ride; the pause checkpoint neither
duplicates the History row nor marks it unfinished.

**Not proven here, and worth writing on the test method so nobody over-reads it:** active time on
any post-ride surface, because it does not exist yet (ROH-112); `pausedSeconds` surviving
persistence (D3); the rendered map gap (ROH-143); drift gating during a stop, because the
fixture's stop is dead air and a regression that split the segment but stopped gating `record()`
would pass — that rests on `RideRecorderPauseTests` alone; the forgotten-pause nudge ladder;
haptics; and deep-link protection while paused.

## Out of scope

- Active time as the summary headline. ROH-112, which now blocks ROH-74.
- The rendered gap on the map. ROH-143.
- The Live Activity's paused rendering. ROH-102, on device.
- Auto-pause and crew-visible paused state. Slices B and C.

## Risks

| Risk | Mitigation |
| -- | -- |
| Pause A's taps miss the twenty-second replay silence | D4's deterministic boundary fires at the last segment-1 point rather than two polls later; a miss fails D3's exact-941 equality with a distance in the message, not a vague band |
| CI's retry flag hides a first-run flake | D8 records it. The alternative — excluding these methods from the retry — trades a hidden flake for a red gate on unrelated PRs, which is the trade the flag was added to make |
| A stale app binary meets a new test bundle | D2 parses `s` and `n` as optional, so the two shipped golden tests are unaffected by this pass. **The reverse skew is not covered**: a new app binary against a pre-ROH-103 test bundle hits the old parser's `default: return nil` and fails all three golden tests unattributably. Both CI and `scripts/golden-ride.sh` build before they test, so it takes a hand-run `test-without-building` to reach |
| A test asserts what the code does rather than what the rider needs | Revision 3 deleted the max-speed band for exactly this. Every remaining assertion was checked against a deliberately broken variant: the negative control in the plan neuters `togglePause()` and confirms the suite goes red |
| A typo'd fixture name produces a silently real ride | D1 validates at parse, so all six harness sites turn off together |
| The three fixture literals drift apart | D4's sum assertion, and the array is emitted by the recorder rather than hand-computed |
| Orphaned notification requests outlive an aborted run | D7 suppresses scheduling under the harness |
| An interior empty segment reaches the summary or share card for the first time | D3's exact-941 equality makes a pause before the first fix unreachable; parent D6 declares interior empties legal and `normalizedSegments` preserves them, but only package tests have ever built one |
