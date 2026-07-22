# Navigate-mode golden ride — design (ROH-93, bundling ROH-95)

**Date:** 2026-07-22 · **Issues:** [ROH-93](https://linear.app/rohun/issue/ROH-93),
[ROH-95](https://linear.app/rohun/issue/ROH-95) · **Status:** approved by PO; pending
adversarial spec review

## Problem

ROH-92's golden ride gates the free-ride loop only. NavigateHUDView's
finish → summary path-collapse wiring is a separate seam that regressed
independently in ROH-85 (two fixes, one per HUD), and nothing automated
gates it. Navigate also has zero E2E coverage of the plan → preview → Go
entry wiring.

## Goals

- One additional golden-ride path: route preview → NavigateHUDView →
  simulated fixture recording → manual End → summary → History, asserted
  automatically in the existing CI lane.
- Deterministic: no Mapbox Directions call, no Mapbox guidance engine, no
  arrival event, no network in the driven path.
- Near-zero added flake and near-zero CI cost (same app build, same lane).
- Bundled ROH-95: every UI-test launch uses the ephemeral in-memory ride
  store, so the unsigned (`CODE_SIGNING_ALLOWED=NO`) test build stops
  SIGTRAPping in CloudKit-mirrored SwiftData setup during the seven legacy
  suites and manual launches between runs.

## Non-goals

- Arrival-driven ride end (Mapbox guidance owns arrival; unit-tested via
  `GuidanceViewModelTests`). The manual End control is the tested exit.
- Turn-card / guidance UI assertions (the scripted session emits nothing).
- Gating the Mapbox search box (`DestinationSearchView` — third-party SDK UI
  plus network; `SavedPlaceMatcher` is unit-owned).
- Group-ride E2E; route-planning elevation gate (ROH-94).
- New Layer 1 (package) tests: navigate shares the coordinator pipeline the
  ROH-92 playback suite already gates; ROH-93 is app-wiring coverage.

## Coverage honesty

| Regression class | Caught? |
|---|---|
| Navigate finish → summary path collapse (`router.showRideSummary` from `[.preview, .navigate]`) | **Yes** — the ROH-85 class this issue exists for |
| Preview "Start RIDE" → `.navigate` push wiring | Yes |
| Navigate HUD auto-start / coordinator start wiring | Yes (probe distance floor) |
| Deep link `aura://preview` → preview push | Yes (incidental) |
| Route fetch (`MapboxRoutingProvider`), route ranking | No — bypassed by design (ROH-94 adjacent) |
| Guidance engine, turn card, reroute, arrival | No — scripted-empty by design |
| Search box → preview wiring | No — deep-link entry skips it |
| Voice, haptics, Live Activity, widgets, map content | No — unchanged from ROH-92 policy |

## Design decisions

### 1. Entry: deep link, not search

Launch with the ROH-92 sim args plus
`-openURL aura://preview?lat=<fixture-start-lat>&lng=<fixture-start-lng>&name=Golden%20Loop`.
The existing `-openURL` hook (RootView `.task`, production-inert) routes it
through the real `AppRouter.handle(url:)` → path `[.preview]`. Tapping
**Start RIDE** yields `[.preview, .navigate]` — exactly the nested stack
shape whose collapse regressed in ROH-85. The deep-link coordinate is the
fixture's start (Plum Boro area), so the preview map and route polyline are
coherent, but no assertion depends on the coordinate.

### 2. Fixture-backed route (no Directions network)

New `GoldenRideFixture.route()` in AuraKit builds one `AuraCore.Route` from
the parsed fixture track:

- `geometry` = the track's coordinates; `origin`/`destination` = first/last.
- `distanceMeters = expectedDistanceMeters`,
  `elevationGainMeters = expectedElevationGainMeters`,
  `estimatedDurationSeconds = nominalDurationSeconds` (frozen literals — no
  recomputation at runtime).
- `elevationProfile` = the track's elevations (the preview sparkline
  renders it; not asserted).
- `profile = .mostPaths`, `waypoints = []`.

`RoutePreviewView.loadRoutes()` gains a `#if DEBUG` early branch: when
`SimulatedRideConfig.current != nil`, set `routes = [GoldenRideFixture.route()]`,
`selected`, `phase = .loaded`, fit the camera, and return — skipping both
the `MapboxRoutingProvider` call and the `location.current()` one-shot
(which would stall ~3 s with no CoreLocation fix in sim). A `route()` throw
follows the RideHUDView precedent: `assertionFailure` in the branch, fall
through to the real path (Debug-only loudness, no release footprint).

### 3. Guidance: empty scripted session

`NavigateHUDView.init` chooses the `GuidanceViewModel` session under
`#if DEBUG`: `SimulatedRideConfig.current != nil` →
`ScriptedGuidanceSession(script: [])` (public in AuraCore), else the
production `MapboxGuidanceSession()`. Consequences, all intended: no nav
engine or telemetry, no spoken prompts, no reroute, no arrival (so
`onArrive` can never race the manual End), turn card stays in its
`.starting` state. Init-time read of `SimulatedRideConfig.current` is safe:
views are MainActor under the project's default-isolation setting, and the
static is `@MainActor`.

### 4. Shared HUD probe

Extract RideHUDView's DEBUG probe overlay (invisible
`RideTestProbe.line(...)` text tagged `RideTestID.hudProbe`, rendered only
when simulated) into one shared helper in the app target —
`SimulatedRideProbe.swift`, a ViewModifier applied as
`.simulatedRideProbe(distanceMeters:elapsed:elevationGainMeters:)` — and
adopt it in both HUDs. In release builds the modifier body returns the
content unchanged (`#if DEBUG` inside the modifier), so no probe code paths
ship. Behavior of the free-ride probe is unchanged (same identifier, same
line format).

### 5. Identifier contract additions

Two new `RideTestID` constants (AuraKit, shared enum — renames stay
compile-time breaks):

- `hudEnd` on `ControlCluster`'s End button (both HUDs and the group path
  get it for free; label "End ride" is unchanged).
- `previewStart` on RoutePreviewView's **Start RIDE** button.

### 6. The test

A second method in `RideE2EUITests` (same class → the CI lane's
`-only-testing:AuraUITests/RideE2EUITests` and retry policy cover it with
zero workflow edits): `testNavigateGoldenRideEndsToSummaryAndHistory`.

Flow and assertions:

1. Launch with onboarding-done + sim args + in-memory store + the
   `-openURL` preview link; tolerant springboard-alert dismissal as today.
2. `PreviewScreen.startRide` exists and is enabled (proves the fixture
   route loaded and was auto-selected) → tap.
3. `RideScreen.probe` appears (simulated hook engaged in the navigate HUD).
4. `waitForDistance(atLeast: 0.85 × expectedDistanceMeters, timeout: 90)` —
   proves the coordinator records through the navigate path. No
   elapsed-ticker or elevation re-assertions: the free-ride test owns the
   recorder/stats guarantees; this test gates the navigate seam.
5. Tap `RideScreen.endButton` (`hudEnd`) → "End ride?" alert → "End ride".
6. Summary appears (`SummaryScreen.title`), hero distance within the same
   band as the free-ride test (shared helper for the band check).
7. Done → Home (`home.exploreButton`), then History shows exactly one row.

New screen object: `PreviewScreen` (startRide). `RideScreen` gains
`endButton`. The hero-band + leading-number helpers are shared between the
two test methods rather than duplicated.

### 7. ROH-95: ephemeral store for every UI-test launch

`XCUIApplication.launched()` and `launched(onboarded:)` in `Screens.swift`
append `-auraInMemoryRideStore` unconditionally. Rationale (from ROH-95):
the unsigned test build strips iCloud entitlements, and any launch that
opens the CloudKit-mirrored store SIGTRAPs later on CoreData's background
CloudKit setup — `makeRideStore()`'s catch can't reach it. No legacy suite
asserts cross-launch persistence, so no coverage is lost; the golden-ride
tests already pass the flag explicitly. Expected side effect: the three
suites currently failing locally under the unsigned build go green.

### 8. What does not change

CI workflow, `scripts/golden-ride.sh`, the fixture, its truth literals,
Layer 1, `SimulatedRideConfig`, and the free-ride test's assertions. The
ROADMAP testing section gets one line: both HUDs' finish → summary seams
are now gated (free ride and navigate).

## Error handling

- `GoldenRideFixture.route()` throw → Debug `assertionFailure` at the
  preview call site (packaging regressions fail loudly; release unaffected).
- Simulated hook silently no-ops in the navigate HUD → probe never appears
  → step 3 fails loudly (same not-survivable property as ROH-92).
- Path-collapse regression → summary never appears (step 6) or History
  count wrong (step 7).

## Verification (definition of done)

- Full `RideE2EUITests` class (both methods) green locally on the iPhone 17
  sim; CI green on the PR.
- The seven legacy suites green locally under the unsigned build (ROH-95
  effect verified, or any residual failures noted honestly on the issue).
- Regression drill: stub out `router.showRideSummary` in
  NavigateHUDView's `finishedRide` onChange → navigate test fails at the
  summary step while the free-ride test stays green (proves the new gate
  covers the seam the old one couldn't). Reverted after proof; output
  quoted in the PR.
- `swiftlint --strict` clean. ROADMAP updated. ROH-93 and ROH-95 → In
  Review at PR, Done after merge + verification.
