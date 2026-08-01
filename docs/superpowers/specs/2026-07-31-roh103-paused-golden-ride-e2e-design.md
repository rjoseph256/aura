# Paused golden-ride E2E (ROH-103, Slice A Pass 6) — design

Date: 2026-07-31
Issue: [ROH-103 — Pass 6, E2E coverage through the paused golden fixture](https://linear.app/rohun/issue/ROH-103/pass-6-e2e-coverage-through-the-paused-golden-fixture)
Parent spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D10)

This is the last pass of Slice A. Passes 1-5 are shipped: the segmented model, the recorder
state machine, schema V6, the cockpit control, and the Live Activity. Every one of them is
covered by unit tests. None of them has ever been driven end to end through the real app by
a test that presses the real button.

## Problem

The pause feature's load-bearing behaviors are the ones a package test cannot reach.

`RideRecorderPauseTests` proves the recorder drops points while paused. It does not prove
that the button in the cockpit is wired to `coordinator.pause()`, that the clock the rider
watches stops, that the speed hero drops to zero, or that a ride paused across a GPS gap
saves as two segments instead of one line drawn straight through the stop.

Slice A's whole premise is that the rider's clock becomes honest. Nothing currently
verifies that claim above the recorder.

### What this pass changes about the E2E harness

The harness (ROH-92, ROH-93) plays `golden-ride.gpx` through the real app and asserts the
summary and History wiring. `golden-ride-paused.gpx` landed in Pass 1 with frozen literals
and package-level coverage, but the app cannot play it: `SimulatedRideSupport.rideOverride`
ignores `SimulatedRideConfig.fixture` and always loads `GoldenRideFixture`
(`SimulatedRideSupport.swift:18`).

## Two claims in the issue that cannot be delivered as written

**"The summary leads with active time."** That surface change is D5, and it is tracked as
ROH-112, which sits in Backlog. The summary shows moving time today
(`RideSummaryView.swift:214`). *(PO decision, 2026-07-31: assert the moving-time cell
instead. See D3.)*

**"The route draws with a gap rather than a chord."** The ride map is a Mapbox GL surface
with nothing in the accessibility tree, so no XCUITest can read it. *(PO decision,
2026-07-31: prove it in the data through the HUD probe, and leave the pixels to a device
eyeball. See D2.)*

## Decisions

### D1 — The launch argument selects a fixture

`SimulatedRideSupport.rideOverride` gains a switch on `SimulatedRideConfig.current.fixture`:
`"golden"` maps to `GoldenRideFixture`, `"paused"` to `PausedGoldenRideFixture`, and any
other value returns `nil`.

Returning `nil` matches the contract `SimulatedRideConfig` already documents — an unknown or
malformed value degrades to "absent" and the app rides on real location rather than
crashing. It also keeps the existing `assertionFailure` for a fixture that is named
correctly but fails to load, which is a packaging regression rather than a typo.

`PausedGoldenRideFixture` gains the `simulatedProvider(multiplier:)` factory its sibling
already has.

`RoutePreviewView.swift:269` also names `GoldenRideFixture` directly, for the navigate
deep-link preview. It stays as it is. The paused fixture is exercised through the free-ride
path only, because that is the only HUD with a clock (parent spec, Scope: "the navigate
cockpit renders TO GO and ARRIVE and has no clock at all"), and a paused fixture behind the
navigate preview would assert nothing the free-ride path does not.

### D2 — Two new probe fields carry what the screen cannot say

`RideTestProbe` renders an invisible line in the accessibility tree during DEBUG simulated
rides so tests read raw numbers instead of parsing localized display strings. It carries
distance, elapsed and elevation gain. It gains two more:

| Field | Source | Why it has to be here |
| -- | -- | -- |
| `s` | `coordinator.currentSpeedMetersPerSecond` | The speed hero is a dial with a formatted label; there is no numeric readout a test can trust across locales. D6 zeroes this on pause, and that behavior is otherwise unobservable above the recorder |
| `n` | `coordinator.segments.count` | The only reading of "the track has a gap in it" available to a UI test |

`s` is reported in **decimetres per second** (`Int(speed * 10)`), not truncated metres per
second. The assertion is that a paused ride reads exactly zero; under metre truncation a
residual 0.4 m/s also reads zero, so the test would pass on the bug it exists to catch.
Distance, elapsed and gain keep their existing metre and second truncation — their
assertions are bands, not equalities.

Both HUDs already attach the probe (`RideHUDView.swift:94`, `NavigateHUDView.swift:154`) and
both pass the new values, so the navigate path keeps a probe that parses.

### D3 — The summary is asserted on moving time, and the assertion is a band

The E2E asserts that the summary's moving-time cell falls in a 3-6 minute band.

The paused fixture's segment-aware moving time is 290 s, which the formatter renders as
"4 min" (`RideStatsFormatter.swift:39` truncates). Flattened, the same points produce 890 s,
which renders as "14 min". A band rather than an equality absorbs a dropped boundary point
without absorbing the bug: the two readings are three times apart.

This is the same regression signal ROH-112's active-time assertion would carry, available a
release earlier. When ROH-112 lands it owns the active-time assertion, and this one either
moves or stays beside it — that is ROH-112's call, not this pass's.

The moving cell needs an identifier. `RideTestID.summaryMoving` is added beside
`summaryDistance`, so a rename breaks the compile in both places rather than failing CI
silently.

### D4 — The test pauses on a stall, not on a distance threshold

At a 20x multiplier the fixture replays as 7 s of riding, a 30 s silence, then 7 s of
riding. `GPXLocationPlayer.schedule` derives playback offsets from the trackpoint stamps
(`GPXLocationPlayer.swift:16`), and the fixture's two `trkseg`s are 600 s apart, so the stop
the rider took becomes dead air in the stream.

The test rides segment 1, then polls the probe until the distance reading stops changing.
A stall means the replay is inside that silence with every segment-1 point already
recorded. Only then does it tap pause.

The alternative — pausing once distance crosses some fraction of the segment-1 literal —
pauses early and drops the tail of the segment, which loosens every downstream band by an
unknown amount. Waiting for the stall costs about a second of a 30 s window and makes the
recorded distance land on the frozen literal instead of near it.

Knowing where segment 1 ends needs a frozen number, so `PausedGoldenRideFixture` gains
`expectedSegmentDistanceMeters: [Double]`, recorded through the procedure the file already
documents (`GOLDEN_RECORD=1 swift test --filter recordPausedTruthLiterals`) and pasted, never
recomputed at test time.

**20x rather than the harness default of 30x.** At 30x the silence is 20 s, and the pause,
the four assertions taken during it, and the resume all have to fit inside it. At 20x the
window is 30 s and the whole ride costs 45 s instead of 30. Fifteen seconds of CI buys the
margin.

Missing the window is not a silent failure. A resume that lands after segment 2 has started
records short, and the closing distance band fails loudly.

### D5 — What the test asserts, in order

`RideE2EUITests.testPausedGoldenRideSegmentsAndSummary`, launched onboarded with
`-auraSimulatedRide paused -auraSimulatedRideMultiplier 20 -auraInMemoryRideStore`, entering
through Explore:

1. Segment 1 records, then the distance reading stalls at the segment-1 literal.
2. Tapping `ride.hud.pause` shows `ride.hud.paused.banner`.
3. While paused: the elapsed reading does not advance across several polls, and speed reads
   exactly zero.
4. Tapping the control again clears the banner, elapsed advances again, and it never read
   lower than it did before the pause.
5. Segment 2 records out. Segment count is 2, and distance falls in a band holding the
   segmented literal (1883 m) and excluding the flattened one (2391 m).
6. Ending the ride gives a summary whose hero distance is in the paused fixture's own band
   and whose moving cell is in the 3-6 minute band.
7. Done returns Home, and History holds exactly one row.

Steps 3 and 4 are the pass's reason to exist. Everything else is the wiring that has to hold
for them to mean anything.

**The paused fixture gets its own hero band.** `RideE2EUITests.swift:141-142` documents the
existing band as shared by both golden rides; 1883 m is a different distance and cannot
reuse it. The parent spec's D10 called this out.

### D6 — Nothing in CI changes

The workflow (`ci.yml:113`) and `scripts/golden-ride.sh:32` both run
`-only-testing:AuraUITests/RideE2EUITests`, so a new method in that class is picked up with
no edit to either.

## Out of scope

- The rendered gap on the map. Pixels, and a device eyeball; the data-level proof is D2.
- Active time as the summary headline. ROH-112.
- The Live Activity's paused rendering. ROH-102 owns it, on device.
- The navigate HUD through the paused fixture. D1.
- Auto-pause and crew-visible paused state. Slices B and C.

## Risks

| Risk | Mitigation |
| -- | -- |
| The pause and resume miss the 30 s replay silence | D4's 20x multiplier; a miss fails the closing distance band rather than passing quietly |
| A boundary point is dropped and the bands drift | D4 pauses on a stall, so segment 1 is whole; the bands are sized against the flattened reading, which is 27% larger in distance and 3x in moving time |
| Probe parsing breaks the existing golden rides | `RideTestProbe.parse` is round-tripped in its own package tests and both HUDs pass the new fields; a partial line fails to parse and the existing tests fail loudly |
| A notification prompt hijacks the run | Already handled at the source: `PauseNudgeScheduler.prepareAuthorization` is a no-op under the simulated harness (`PauseNudgeScheduler.swift:38`) |
| The paused fixture drifts from its literals | The literals are frozen and recorded, never recomputed at test time — the rule the fixture file already carries |
