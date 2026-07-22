# E2E ride harness — design (ROH-92)

**Date:** 2026-07-22 · **Issue:** [ROH-92](https://linear.app/rohun/issue/ROH-92) ·
**Status:** reconciled after 3-reviewer adversarial spec review

## Problem

Aura has no automated end-to-end coverage of its core loop: ride a route,
record the track, land on the summary, persist the ride. The loop is
hand-verified on the simulator every time it changes. Proof the gap is real:
`SimulatedLocationProvider` (AuraKit) implements the exact `LocationStreaming`
seam the ride pipeline consumes, is unit-tested, and is wired into **nothing**
— the app target never constructs it, and the bundled
`sample-ride-pittsburgh.gpx` is referenced by no runtime code. A whole tested
subsystem sat dark and no test noticed.

The ROADMAP's Terrain-RGB lesson (compiled fine, silently returned flat
elevation) is the motivating *class* of bug — code that builds clean and does
nothing. To be explicit about what this harness does and does not do about it:
the golden ride guards the **recording/stats/persist** path
(`RideStatsCalculator` and the assembled ride pipeline). The Terrain-RGB bug
itself lived in the **route-planning** path (`MapboxTerrainRGBElevationProvider`
→ `RouteMetrics` → ranking), which this harness does not touch; that path
remains ungated and is filed as
[ROH-94](https://linear.app/rohun/issue/ROH-94).

## Goals

- A repeatable **golden ride**: simulated location in → recorded track →
  summary screen → persisted ride, asserted automatically.
- Fails when the free-ride loop regresses at the assembly/wiring level —
  including the "numbers quietly become zero" class within the recorded path.
- Runs green locally and in CI on every PR.
- Stays a regression gate, not a slow duplicate of the unit suites.

## Non-goals (v1)

- Navigate-mode E2E — filed as [ROH-93](https://linear.app/rohun/issue/ROH-93)
  (the NavigateHUDView summary seam regressed independently in ROH-85, so one
  mode's E2E does *not* gate the other; free ride first, navigate next).
- Group-ride E2E (Supabase + multi-device).
- Route-planning elevation gate — [ROH-94](https://linear.app/rohun/issue/ROH-94).
- Running the seven existing XCUITest suites in CI (cheap follow-up once the
  lane proves stable).
- Map rendering, HealthKit, Live Activity, widget content assertions.
- Physical-device automation (existing Appium recipe covers it).

## Coverage honesty — what this gate would and would not have caught

| Regression class | Caught by |
|---|---|
| Ride pipeline assembled wrong / provider unwired (the current dark-subsystem state) | Layer 1 + Layer 2 |
| Recorder/stats/persist chain breaks (points dropped, stats zeroed, mapper columns wrong, save dropped) | Layer 1 (numeric), Layer 2 (row exists) |
| Free-ride HUD wiring breaks (auto-start, End alert, finish → summary collapse, History) | Layer 2 |
| Fixture/parse regressions (GPX parsing, playback scheduling) | Layer 1 |
| Terrain-RGB class in route planning | **Not caught** — ROH-94 (decode/placement/sampling gated since ROH-94, see 2026-07-22-route-elevation-gate-design.md; token guard, fetch, cache, and call-site wiring remain not caught) |
| Live CoreLocation ingestion (`LocationService.points()`, signal classification, fix filter — where ROH-83/ROH-88 actually lived) | **Not caught** — both layers bypass `LocationService` by design; this stays covered by its unit seams + device verification |
| Navigate/group summary seams (ROH-85 class) | **Not caught** in v1 — ROH-93 |
| Summary dismiss *flash* (transient animation artifacts) | **Not caught** (not assertable in XCUITest cheaply) |
| WidgetRefresh call-site dropped, saveFailed banner branch, back-out discard path, Live Activity start, HealthKit write, speed dial | **Not caught** — explicitly out; see Layer 2 assertion list |

The harness gates the *next* assembly break, not every historical bug. The
rows marked "not caught" are the honest boundary.

## Design decisions

### 1. Layer driven: two layers, one fixture

- **Layer 1 — package golden-ride playback** (`AuraKitTests`, Swift Testing,
  `@Suite(.swiftDataSerialized)`): parse the canonical fixture → play it
  through the real `SimulatedLocationProvider` at a high `speedMultiplier` →
  real `RideSessionCoordinator` with scripted seams and an in-memory
  `RideStore` → await `coordinator.streamTask?.value` (the drain signal; the
  established pattern in `RideSessionCoordinatorTests`) → `finish()` → assert
  against `GoldenRideFixture` truth constants.

  *What is genuinely new here* (vs `RideSessionCoordinatorTests`,
  `RideStatsCalculatorTests`, `RideStatsSnapshotTests`, `RideMapperTests`,
  `RideStoreSummaryTests`, which keep their duties): the real
  `GPXLocationPlayer` → `SimulatedLocationProvider` timing path feeding the
  coordinator end-to-end, on a realistic-length track, with frozen numeric
  literals. The numeric duty stays with the unit/snapshot suites; Layer 1's
  literals exist to catch assembled-chain breaks and fixture drift (e.g. a
  fixture that silently loses `<ele>` and records flat).

  Determinism note: `speedMultiplier` compresses only wall-clock sleeps;
  `TrackPoint.timestamp`s stay original, so distance/moving-time/speed are
  multiplier-independent. Only `elapsed` (wall clock) compresses.

- **Layer 2 — XCUITest golden ride** (`RideE2EUITests`, one test method in
  `AuraUITests`): launch the real app with simulated location injected, drive
  Home → Explore → HUD accumulates → End ride → summary → Done → History.
  Covers what Layer 1 cannot: the composition root actually injecting the
  provider, HUD auto-start, the End alert, `finish()` → save → path collapse
  → `RideSummaryView`, History rendering. It asserts *wiring and screens*,
  never numbers beyond sanity bands.

### 2. Location injection, and how it stays out of production

- Mechanism: launch arguments on the app target —
  `-auraSimulatedRide golden` (fixture selector),
  `-auraSimulatedRideMultiplier N` (default chosen so playback ≈ 15–25 s),
  `-auraInMemoryRideStore` (deterministic store; see §5-CI).
  A pure resolver in AuraKit (`SimulatedRideConfig.parse(arguments:)`,
  unit-tested, treats unknown values as absent) maps arguments to a config.
- Injection point: **no environment key** (an `EnvironmentKey` conformance
  would fight `SWIFT_DEFAULT_ACTOR_ISOLATION MainActor` — its nonisolated
  `defaultValue` requirement — for no benefit). Instead, the existing
  precedent: `RideHUDView`'s auto-start `.task` already constructs the ride's
  collaborators; under `#if DEBUG` it resolves `SimulatedRideConfig` from
  `ProcessInfo` (same pattern as the `-openURL` hook in `AuraApp`) and, when
  present, starts the coordinator with the `SimulatedLocationProvider` over
  the fixture and `authorization: .authorized`. Navigate's HUD gets the same
  treatment in ROH-93.
- While simulated, the app also (all under `#if DEBUG`, keyed off the same
  config):
  - builds the gem discovery sink with the **curated-only** provider (no
    `LiveGemProvider`) — the live Overpass fetch is an unmocked network call
    with a 1500 m radius that would pop peek cards nondeterministically;
  - skips the app-root **ambient location tier** (`syncLocationActivity`), so
    the WhenInUse prompt never fires mid-test;
  - forces `RideStore.inMemory()` when `-auraInMemoryRideStore` is set.
- Production gating: every app-side hook is compiled under `#if DEBUG`.
  Release/TestFlight builds contain no code that reads the flags. This is
  load-bearing on the scheme's test action using the Debug configuration
  (XcodeGen default; CI pins `-configuration Debug` explicitly). If the gate
  ever silently no-ops, Layer 2 fails loudly: with no simulated stream the
  sim gets no location fixes, distance stays zero, and the first assertion
  times out — the no-op is not survivable.
- Known cosmetic consequences (accepted, never asserted): the GPS signal chip
  reads the real `LocationService` and will show lost/stale; the Mapbox puck
  follows CoreLocation, not the injected stream, so the puck won't track the
  route (the recorded polyline will). Mapbox's own location engine may raise
  a prompt; the CI script pre-grants location via
  `simctl privacy … grant location`, and the test keeps a tolerant
  springboard-alert dismissal.
- Rejected alternatives: `simctl location start` (nondeterministic ground
  truth, device-global, adds nothing asserted); `FakeLocationManager`
  (`LocationService.points()` bypasses the injected manager —
  `CLLocationUpdate.liveUpdates()` direct); SwiftUI environment key (above).
- The desk-demo idea (multiplier 1 by hand) is real but **not claimed as a
  deliverable**: the fixture is a single gem-avoiding loop chosen for test
  determinism, which is roughly the opposite of a good demo route. A
  route-selectable demo mode is possible follow-up material, nothing more.

### 3. The canonical fixture and what the golden ride asserts

- One fixture, `golden-ride.gpx`, in **AuraCore package resources** (AuraKit
  target; requires adding a `.process` entry in `Package.swift`, where
  `gems.json` already proves the `Bundle.module` path works for both the
  package tests and the app). A `GoldenRideFixture` loader (AuraKit) exposes
  the parsed track plus frozen truth constants. Both layers consume the same
  file. The dead app-bundled `sample-ride-pittsburgh.gpx` and both of its
  `project.yml` entries are removed.
- Fixture shape: ~2–3 km, 60–120 points at realistic riding pace/spacing,
  Pittsburgh area, routed away from curated gem locations. Elevation is
  authored so every climbing step clears the 1 m
  `elevationNoiseThreshold` (gentle grades at this spacing would be dropped
  as noise and record zero — authored climbs are deliberately ≥ 1 m per
  sample); flats/descents grouped separately.
- Truth constants: frozen numeric literals in `GoldenRideFixture`
  (point count, total distance, elevation gain, moving time), derived at
  authoring time by running `RideStatsCalculator` over the parsed fixture,
  with a documented re-record procedure (run the derivation helper, paste the
  literals — same deliberate-refresh policy as the snapshot tests). Because
  they are frozen literals, a later calculator regression fails against them;
  they are not recomputed at test time.
- Layer 1 assertions: point count exact; distance, elevation gain, and moving
  time within a small epsilon of the frozen literals (cross-arch double
  drift, per the snapshot-test precedent) plus gain > 0 as a hard floor;
  `saveFailed == false`; persisted `RideRecord` denormalized columns equal
  the computed stats; `summaries()` returns the ride with a thumbnail.
- Layer 2 assertions (sanity, not precision): a DEBUG-only hidden HUD probe
  (machine-readable `d=…;e=…;g=…` line, present only in simulated rides)
  reports distance reaching ≥ ~85% of nominal within a generous timeout,
  elapsed advancing between polls (catches a frozen ticker), and elevation
  gain nonzero — the gain commitment lives at the probe because
  `RideSummaryView` has no numeric gain readout (gain renders only inside
  the profile chart, which stays unasserted); End ride → summary appears
  with the hero distance in a wide band; Done returns Home; History shows
  the ride row (exactly one, since the store is fresh in-memory per launch;
  the row is combined into one accessibility element) and tolerates the
  ephemeral-store banner. Explicitly **not** asserted: WidgetRefresh, saveFailed branch,
  back-out discard, Live Activity, HealthKit, speed dial, map content.
- Identifier contract: accessibility identifiers for the HUD stats and
  summary stats live in one shared constants enum in AuraKit, referenced by
  the views *and* the screen objects (the `AuraUITests` target gains an
  AuraKit package dependency in `project.yml`), so renames are compile-time
  breaks, not silent CI failures.

### 4. Ride modes in v1: free ride only

Free ride exercises the shared lifecycle (coordinator start/finish, recorder,
stats, save, path collapse, summary). Navigate adds Mapbox guidance, network
Directions, and its own summary seam — deferred to
[ROH-93](https://linear.app/rohun/issue/ROH-93) with a concrete no-arrival
scope (end via the manual End control). Group adds Supabase and multi-device;
not scheduled. Per the coverage table, v1 claims "the **free-ride** loop is
gated", nothing broader.

### 5. CI: extend `app-build`, don't duplicate it

- The existing `app-build` job becomes build **and** E2E: after xcodegen +
  Mapbox secrets (unchanged), it selects a simulator (script: `simctl list
  -j devices available` → newest available iPhone → boot + `bootstatus -b` →
  `-destination "id=$UDID"`), pre-grants location for the app bundle id,
  runs `xcodebuild build-for-testing -scheme Aura -configuration Debug`
  (still the compile gate it is today, now with a concrete destination),
  then `xcodebuild test-without-building -only-testing:AuraUITests/RideE2EUITests
  -retry-tests-on-failure -test-iterations 2`. One Mapbox compile, no second
  job. `timeout-minutes: 40` on the job (cold SPM resolve + full build +
  boot + test; no caching exists in this workflow today — SPM caching is a
  follow-up, not a prerequisite).
- Fork/Dependabot PRs get no secrets and already cannot build the app; the
  test steps are guarded with
  `if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository`
  so the harness makes that latent situation no worse.
- Locally: `scripts/golden-ride.sh` — checks the token file, runs xcodegen,
  picks/boots the sim (iPhone 17 by default), pre-grants location, runs the
  same two xcodebuild steps. One command, documented in ROADMAP.
- The GPU question: no assertion touches map content, but `RideHUDView`
  mounts a live Mapbox map, so "Mapbox can't render at all on the CI sim"
  remains a real, untestable-in-advance risk. This PR's CI run is the
  experiment. Fallback if it fails there: Layer 1 stays the required gate,
  the UI test stays local-only (like the existing seven), ROADMAP and the PR
  say so plainly.

### 6. Flake budget and retry policy

- One automatic retry (`-retry-tests-on-failure -test-iterations 2`).
- Budget: if the E2E step fails twice in a row on unrelated PRs, it is
  demoted to non-required and a fix issue is filed — recorded in ROADMAP so
  the policy is explicit rather than a quiet rot.
- Flake sources handled by design: permission prompts (ambient tier skipped +
  pre-grant + tolerant dismissal), gem cards (curated-only provider + fixture
  routing), store state across runs (fresh in-memory store per launch),
  network (no live gem fetch; Mapbox tiles may load or not — never asserted),
  timing (playback duration fixed by fixture ÷ multiplier; generous waits).

## Architecture summary

```
golden-ride.gpx + GoldenRideFixture truth literals (AuraKit resources/source)
        │
        ├── Layer 1: GPXParser → SimulatedLocationProvider(×10⁴)
        │            → RideSessionCoordinator (scripted seams)
        │            → await streamTask → finish()
        │            → in-memory RideStore
        │            → assert vs frozen literals + RideRecord columns
        │
        └── Layer 2: app launch: -auraSimulatedRide golden
        │            -auraSimulatedRideMultiplier N  -auraInMemoryRideStore
        │            (#if DEBUG, resolved in RideHUDView's start .task)
        └──────────→ XCUITest: Home → Explore → HUD (distance, elapsed)
                     → End alert → Summary (bands) → Done → History (1 row)
```

New/changed pieces:

| Piece | Where | Nature |
|---|---|---|
| `golden-ride.gpx` + `Package.swift` resource entry | AuraCore | new |
| `GoldenRideFixture` (loader + frozen truth + re-record helper) | AuraKit | new |
| `SimulatedRideConfig` (pure arg parser) | AuraKit, tested | new |
| Golden-ride playback suite | `AuraKitTests`, Swift Testing | new |
| `#if DEBUG` wiring: simulated start, curated-only gems, ambient skip, in-memory store | `RideHUDView` / `AuraApp` | small edits |
| Shared a11y identifier constants | AuraKit enum | new |
| Identifiers applied to HUD + summary stats | `RideHUDView`, `RideSummaryView` | small edits |
| `RideE2EUITests` + screen objects; AuraKit dep for `AuraUITests` | `Aura/UITests`, `project.yml` | new |
| `app-build` job gains destination script + build-for-testing + guarded test step | `.github/workflows/ci.yml` | edit |
| `scripts/golden-ride.sh` | `scripts/` | new |
| Remove dead `sample-ride-pittsburgh.gpx` (file + both `project.yml` entries) | app resources | cleanup |
| ROADMAP testing section update | `docs/ROADMAP.md` | edit |

## Error handling

- Fixture missing/unparseable → `GoldenRideFixture` throws; Layer 1 fails
  loudly; the DEBUG app hook `assertionFailure`s rather than silently falling
  back to real location.
- Unknown flag values → treated as absent (real location); parser unit-tested.
- Save failure → Layer 1 asserts `saveFailed == false`; a silent save drop
  also empties Layer 2's History assertion.

## Verification (definition of done)

- Both layers green locally; CI green on the PR (or the honest fallback of §5
  recorded if the CI sim can't run the app).
- Regression drill: (a) break the recorder/stats chain → Layer 1 fails;
  (b) break the finish → summary wiring → Layer 2 fails. Reverted after
  proof; drill output quoted in the PR.
- `swiftlint --strict` clean. ROADMAP testing section updated. ROH-92 → Done
  after merge; ROH-93/ROH-94 filed (done).
