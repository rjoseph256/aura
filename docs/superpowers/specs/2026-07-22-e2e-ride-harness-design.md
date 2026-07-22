# E2E ride harness — design (ROH-92)

**Date:** 2026-07-22 · **Issue:** [ROH-92](https://linear.app/rohun/issue/ROH-92) · **Status:** draft, pending adversarial spec review

## Problem

Aura has no automated end-to-end coverage of its core loop: ride a route, record
the track, land on the summary, persist the ride. The loop is hand-verified on
the simulator every time it changes. The Terrain-RGB lesson (ROADMAP) is the
motivating failure mode: code that compiles clean and silently does nothing.
Proof the gap is real: `SimulatedLocationProvider` (AuraKit) implements the
exact `LocationStreaming` seam the ride pipeline consumes, is unit-tested, and
is wired into **nothing** — the app target never constructs it, and the bundled
`sample-ride-pittsburgh.gpx` is referenced by no runtime code. A whole tested
subsystem sat dark and no test noticed.

## Goals

- A repeatable **golden ride**: simulated location in → recorded track →
  summary screen → persisted ride, asserted automatically.
- Fails when the ride loop regresses (including the silent-flat-elevation
  class of bug: numbers that quietly become zero).
- Runs green locally and in CI on every PR.
- Stays a regression gate, not a slow duplicate of the unit suites.

## Non-goals (v1)

- Navigate-mode and group-ride E2E (see "Ride modes" below).
- Running the seven existing XCUITest suites in CI (separate follow-up).
- Map rendering correctness, HealthKit, Live Activity, widget content
  assertions (each has its own seams/tests; the harness only exercises their
  call sites incidentally).
- Physical-device automation (covered by the existing Appium recipe).

## Design decisions (the ones the workset delegates)

### 1. Layer driven: two layers, one fixture

A single layer can't do the job. Package-level playback alone misses the app
wiring — precisely where the "compiled fine, did nothing" bugs live (the
unwired provider is the proof). XCUITest alone is too slow/flaky to carry the
numeric ground-truth assertions, and would duplicate what pure tests do better.
So:

- **Layer 1 — package golden-ride playback** (`AuraKitTests`, Swift Testing,
  `@Suite(.swiftDataSerialized)`): parse the canonical fixture → play it
  through `SimulatedLocationProvider` at a high `speedMultiplier` → real
  `RideSessionCoordinator` with scripted seams and an **in-memory**
  `RideStore` → `finish()` → assert ground-truth stats and the persisted
  `RideRecord` (denormalized columns, `summaries()` round-trip). This is the
  deterministic numeric gate; runs inside the existing `package-tests` CI job.
- **Layer 2 — XCUITest golden ride** (`RideE2EUITests`, one test method in
  `AuraUITests`): launch the real app with simulated location injected, drive
  Home → Explore → HUD accumulates distance → End ride → summary → History.
  This covers what Layer 1 cannot: the composition root actually injecting the
  provider, HUD auto-start, the end-ride alert, `finish()` → save → path
  collapse → `RideSummaryView`, and real (persistent) SwiftData on the sim.

Division of labor vs existing suites: `RideSessionCoordinatorTests` keeps
testing coordinator *behavior* (lifecycle edges, cancel, save-failure) with
inline scripted points; Layer 1 asserts *loop-level numbers* from a realistic
fixture; Layer 2 asserts *wiring and screens*, never numbers beyond
sanity bands. No layer re-asserts another's details.

### 2. Location injection, and how it stays out of production

- Mechanism: a launch argument on the app target, e.g.
  `-auraSimulatedRide golden [-auraSimulatedRideMultiplier N]`.
  A small pure resolver in AuraKit (`SimulatedRideConfig.parse(arguments:)`,
  unit-tested) maps process arguments to a config; the app's composition root
  uses it to build a `SimulatedLocationProvider` over the canonical fixture
  and exposes it via a custom SwiftUI environment key
  (`\.simulatedRideLocation: (any LocationStreaming)?`, default `nil`).
  `RideHUDView` starts the coordinator with `simulatedRideLocation ?? location`
  (the environment `LocationService` as today). When simulated, the HUD passes
  `.authorized` as the coordinator's `LocationAuthorization` so the ride never
  touches CoreLocation.
- Production gating: the app-side hook (argument read + provider construction
  + environment injection) is compiled under `#if DEBUG`. Release/TestFlight
  builds contain no code path that reads the flag. AuraKit keeps shipping
  `SimulatedLocationProvider` (inert without a call site, and it doubles as
  the desk-demo seam the provider was originally documented as — running the
  app by hand with the flag at multiplier 1 is now a free realistic desk demo).
- Rejected alternatives: `simctl location start` (drives real CoreLocation —
  can't assert deterministic ground truth, teleport/pacing issues, affects the
  whole device, and adds nothing Layer 2 needs since map/arrival aren't
  asserted in v1); `FakeLocationManager` (proven unable to feed ride points:
  `LocationService.points()` bypasses the injected manager and consumes
  `CLLocationUpdate.liveUpdates()` directly).

### 3. The canonical fixture and what the golden ride asserts

- One fixture, `golden-ride.gpx`, lives in **AuraCore package resources**
  (AuraKit target) with a `GoldenRideFixture` loader exposing the parsed
  track and its ground-truth constants. Both layers consume the same file, so
  they can't drift. The existing app-bundled `sample-ride-pittsburgh.gpx`
  (5 points, unreferenced) is removed along with its `project.yml`
  force-include.
- Fixture shape: ~2–3 km, 60–120 points at realistic riding pace and spacing,
  in the Pittsburgh area but **routed away from gem dataset locations** so the
  in-ride gem discovery sink can't pop cards mid-test; elevation designed with
  clean climbs whose positive deltas each exceed the 1 m noise threshold, so
  expected gain is exact by construction.
- Ground-truth assertions (Layer 1): trackpoint count exact; total distance
  within ±5% of the designed nominal; elevation gain within ±20% of nominal
  **and** > 0 (both bounds so silent-flat and silent-double both fail);
  moving time > 0; persisted `RideRecord` denormalized columns equal to the
  computed stats; `summaries()` returns the ride with a thumbnail.
- Layer 2 assertions (sanity, not precision): HUD distance stat becomes
  nonzero and reaches ≥ ~80% of nominal within a timeout; summary screen
  appears after End ride with distance in a wide band and elevation gain
  shown nonzero; Done returns Home; History contains a row for the ride.
  Requires adding stable accessibility identifiers to the HUD distance stat
  and the summary stat values (identifiers only; VoiceOver labels exist and
  stay as-is).

### 4. Ride modes in v1: free ride only

Free ride exercises the entire shared lifecycle — `RideSessionCoordinator.
start/finish`, recorder, stats, save, path collapse, summary — which navigate
and group both reuse (group literally renders `NavigateHUDView` with the same
coordinator). What navigate adds on top (Mapbox guidance session, arrival via
`waypointsArrival`) depends on the Mapbox SDK's own arrival detector, network
Directions calls, and realistic approach movement — high flake, external
dependency, and its pure logic (`GuidanceViewModel`, turn pipeline) already
has unit seams. Group adds Supabase and multi-device. Both are follow-up
issues, not v1.

### 5. CI: yes, a new scoped job

- New `ui-tests` job in `ci.yml` (macos-15, same setup as `app-build`:
  xcodegen, Mapbox secrets): boot an iPhone simulator and run
  `xcodebuild test -scheme Aura -only-testing:AuraUITests/RideE2EUITests`
  with `CODE_SIGNING_ALLOWED=NO`, `timeout-minutes: 30`.
- Scope: **only the golden ride**, not the seven existing suites — this PR
  stands up the deferred UI-test CI lane but gates merges only on the E2E
  regression signal it introduces. Widening the lane to the whole suite is a
  cheap follow-up once the lane proves stable.
- Destination: `iPhone 17` (the sim target used throughout); if the runner
  image's Xcode lacks it, pick the newest available iPhone via `simctl list`
  in the job script rather than hard-failing.

### 6. Flake budget and the GPU question

- Retry policy: `-retry-tests-on-failure -test-iterations 2` (one automatic
  retry). Budget: if the job fails twice in a row on unrelated PRs, it gets
  demoted to non-required and a fix issue is filed — recorded in ROADMAP so
  the policy is explicit.
- GPU: CI runners have no trustworthy Metal GPU for Mapbox. Mitigations: no
  assertion touches map content — everything asserted is SwiftUI chrome
  (stat labels, alert, summary, history rows); the ride stream never uses
  CoreLocation; timeouts are generous (playback is ~15–25 s at the test
  multiplier). Residual risk — Mapbox failing to *render at all* on the CI
  sim and taking the app down — cannot be proven away in advance; this PR's
  own CI run is the experiment. If the app can't run on the CI sim, fallback
  is: keep Layer 1 as the required gate, keep the UI test local-only (like
  the existing seven), and say so honestly in ROADMAP and the PR.
- Known flake sources handled: location permission alert from the app-root
  `LocationService` ambient tier (dismissed via the springboard pattern
  already used in `SavedPlacesUITests`); persistent store accumulating rides
  across local runs (assert "row exists", never counts); gem cards (fixture
  routed away from gems).

## Architecture summary

```
golden-ride.gpx (AuraKit resources)
        │
        ├── Layer 1: GPXParser → SimulatedLocationProvider(×10⁴)
        │            → RideSessionCoordinator (scripted seams)
        │            → in-memory RideStore
        │            → assert stats + RideRecord vs GoldenRideFixture truth
        │
        └── Layer 2: app launch  -auraSimulatedRide golden  (#if DEBUG)
                     → SimulatedRideConfig.parse → environment key
                     → RideHUDView starts coordinator on simulated stream
                     → XCUITest: Home → Explore → HUD → End → Summary → History
```

New/changed pieces:

| Piece | Where | Nature |
|---|---|---|
| `golden-ride.gpx` + `GoldenRideFixture` | AuraKit resources + source | new |
| `SimulatedRideConfig` | AuraKit, pure, tested | new |
| Golden-ride playback suite | `AuraKitTests`, Swift Testing | new |
| Environment key + `#if DEBUG` wiring | `AuraApp` / `RideHUDView` | small edit |
| Accessibility identifiers | `RideHUDView` stats, `RideSummaryView` stats | small edit |
| `RideE2EUITests` + screen objects | `Aura/UITests` | new |
| `ui-tests` CI job | `.github/workflows/ci.yml` | new |
| Remove dead `sample-ride-pittsburgh.gpx` | app resources + `project.yml` | cleanup |
| ROADMAP testing section update | `docs/ROADMAP.md` | edit |

## Error handling

- Fixture fails to parse / missing resource → `GoldenRideFixture` throws;
  Layer 1 fails loudly; the app-side DEBUG hook `assertionFailure`s (debug
  builds only) rather than silently falling back to real location.
- Unknown `-auraSimulatedRide` value → treated as absent (real location),
  config parser unit-tested for this.
- Coordinator save failure already surfaces via `saveFailed`; Layer 1 asserts
  save succeeded; Layer 2's History assertion would catch a silent save drop.

## Verification (definition of done)

- Both layers green locally; CI green on the PR.
- Regression drill: (a) break stats accumulation (e.g. recorder drops points)
  → Layer 1 fails; (b) break the wiring (e.g. summary route never pushed) →
  Layer 2 fails. Reverted after proof, drill results quoted in the PR.
- `swiftlint --strict` clean. ROADMAP testing section updated. ROH-92 → Done
  after merge.
