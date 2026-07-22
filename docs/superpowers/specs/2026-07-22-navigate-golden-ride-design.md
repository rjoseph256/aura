# Navigate-mode golden ride — design (ROH-93, bundling ROH-95)

**Date:** 2026-07-22 · **Issues:** [ROH-93](https://linear.app/rohun/issue/ROH-93),
[ROH-95](https://linear.app/rohun/issue/ROH-95) · **Status:** reconciled after
3-reviewer adversarial spec review (technical-skeptic, product/test-value,
architecture/edge-case lenses)

## Problem

ROH-92's golden ride gates the free-ride loop only. NavigateHUDView's
finish → summary wiring is a separate seam that regressed independently in
ROH-85 (two fixes, one per HUD), and nothing automated gates it. Navigate
also has zero E2E coverage of the preview → Go entry wiring.

## Goals

- One additional golden-ride path: route preview → NavigateHUDView →
  simulated fixture recording → manual End → summary → History, asserted
  automatically in the existing CI lane.
- Deterministic: no Mapbox Directions call, no Mapbox guidance engine, no
  arrival event, no network in the driven path.
- Near-zero added flake; one CI budget bump, no new jobs.
- Bundled ROH-95: every UI-test launch uses the ephemeral in-memory ride
  store, so the unsigned (`CODE_SIGNING_ALLOWED=NO`) test build stops
  SIGTRAPping in CloudKit-mirrored SwiftData setup during the seven legacy
  suites and manual launches between runs.

## Non-goals

- Arrival-driven ride end (Mapbox guidance owns arrival; unit-tested via
  `GuidanceViewModelTests`). The manual End control is the tested exit.
- Turn-card / guidance UI assertions (the scripted session emits nothing).
- Gating the plan/search stage. ROH-93's text says "Home → plan → route
  preview → Go"; this gate deliberately delivers preview → Go → summary →
  History (plus Home on exit). The search box is `DestinationSearchView` —
  third-party Mapbox SDK UI plus live network; its matching logic is owned
  by `SavedPlaceMatcher` unit tests and `SavedPlacesUITests`. Stated here
  so nobody reads more coverage than exists.
- Group-ride E2E; route-planning elevation gate (ROH-94).
- New Layer 1 (package) tests: navigate shares the coordinator pipeline the
  ROH-92 playback suite already gates; ROH-93 is app-wiring coverage. This
  also means there is **no package-level backstop for the navigate seam**
  if the E2E can't run — see the CI fallback in §8.

## Coverage honesty

| Regression class | Caught? |
|---|---|
| Navigate finish → summary seam stops presenting the summary (no-op'd `showRideSummary`, broken `finishedRide` onChange, double-mutation blank destination) | **Yes** — steps 6–7 |
| Navigate finish → summary path-collapse **shape** (push-instead-of-collapse leaving stale entries → ROH-85's dismiss flash) | **Partial** — the E2E passes despite it (Done's `popToRoot()` clears any depth; the flash itself is not assertable in XCUITest). The collapse shape stays gated by `RideSummaryRoutingTests`; a call-site regression that stops calling `collapsed(...)` but still presents a summary is the honest residual gap |
| Preview "Start RIDE" → `.navigate` push wiring | Yes |
| Navigate HUD auto-start / simulated `coordinator.start` wiring (incl. stats: distance floor + nonzero gain) | Yes (probe) |
| Deep link `aura://preview` → preview push | Yes (incidental) |
| Route fetch (`MapboxRoutingProvider`), ranking, `.loading→.loaded` phase machine, auto-select from a real fetch | No — bypassed by design (ROH-94 adjacent) |
| Guidance engine, turn card, reroute, arrival | No — scripted-empty by design |
| Search box → preview wiring | No — deep-link entry skips it |
| Voice, haptics, Live Activity, widgets, map content | No — unchanged from ROH-92 policy |

## Design decisions

### 1. Entry: deep link, not search

Launch with the ROH-92 sim args plus
`-openURL aura://preview?lat=…&lng=…&name=Golden%20Loop`. The existing
`-openURL` hook (RootView `.task`, production-inert) routes it through the
real `AppRouter.handle(url:)` → path `[.preview]`. Tapping **Start RIDE**
yields `[.preview, .navigate]` — the nested stack shape whose collapse
regressed in ROH-85. The lat/lng are built **from a new
`GoldenRideFixture.startCoordinate` constant** (exposed alongside the truth
literals), so the link can't silently drift from the fixture; the test
target links AuraKit already.

Accepted residue: a `.preview` deep link calls `remember(place)`, which
persists one "Golden Loop" recents entry to `UserDefaults.standard` on the
test sim. Nothing asserts recents; accepted, not cleaned.

### 2. Fixture-backed route (no Directions network)

New `GoldenRideFixture.route()` in AuraKit builds one `AuraCore.Route` from
the parsed fixture track:

- `geometry` = the track's coordinates (`TrackPoint.coordinate` is already
  `AuraCore.Coordinate`); `origin`/`destination` = first/last.
- `distanceMeters = expectedDistanceMeters`,
  `elevationGainMeters = expectedElevationGainMeters`,
  `estimatedDurationSeconds = nominalDurationSeconds` (frozen literals — no
  recomputation at runtime).
- `elevationProfile` = the track's elevations (compactMap of
  `TrackPoint.elevation`; the preview sparkline renders it; not asserted).
- `profile = .mostPaths`, `waypoints = []`.

`RoutePreviewView.loadRoutes()` gains a `#if DEBUG` early branch: when
`SimulatedRideConfig.current != nil`, set
`routes = [GoldenRideFixture.route()]`, `selected`, `phase = .loaded`, and
return — skipping both the `MapboxRoutingProvider` call and the
`location.current()` one-shot (which stalls ~3 s with no CoreLocation fix
in sim). Setting `selected` fires the existing `.onChange` → `fitCamera`,
so row rendering, selection state, and camera fit stay on production code.
**Deliberate weakening, stated plainly:** the `.loading → .loaded` phase
transition and auto-select-from-a-real-fetch are NOT gated (the branch
replaces them); the early return is chosen over a provider swap because the
`location.current()` stall lives outside the provider. A `route()` throw
follows the RideHUDView precedent: `assertionFailure` in the branch, fall
through to the real path.

### 3. Simulated ride inputs: one shared helper, both HUDs (the load-bearing change)

**This is the change the whole test rides on** (all three reviewers:
without it the navigate coordinator streams from the real `LocationService`,
records zero points, and step 4 times out). New DEBUG-only helper in the
app target, `SimulatedRideSupport.swift`:

```swift
#if DEBUG
/// (provider, .authorized) when the golden-ride harness is active, else nil.
@MainActor static func rideOverride() -> (any LocationStreaming, LocationAuthorization)?
```

It resolves `SimulatedRideConfig.current`, builds
`GoldenRideFixture.simulatedProvider(multiplier:)`, and carries the same
`assertionFailure`-on-throw behavior. **Both** HUDs consume it:
`RideHUDView`'s existing inline block is refactored onto the helper
(behavior unchanged — it keeps its gem-provider swap locally), and
`NavigateHUDView`'s `.task` gains the mirrored block before
`coordinator.start`: swap `location:` to the provider and
`authorization:` to `.authorized` (the guard on `outcome == .started`
then passes without a permission sheet). One code path for the swap means
the two HUDs provably feed identical stats input — which is also what
justifies the navigate test's lean assertion set (§6).

### 4. Guidance: empty scripted session

`NavigateHUDView.init` chooses the `GuidanceViewModel` session: when
simulated, `ScriptedGuidanceSession(script: [])` (public in AuraCore), else
the production `MapboxGuidanceSession()`. The `#if DEBUG` **wraps the
entire selection expression**, so release builds contain no reference to
`ScriptedGuidanceSession` and the release init stays byte-identical to
today (`GuidanceViewModel(session: MapboxGuidanceSession())`). The
property-default → `_guidance = State(initialValue:)` conversion is
init-order-neutral (same pattern as `_coordinator`). Init-time read of
`SimulatedRideConfig.current` is legal: the app target sets
`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` and the static is `@MainActor`.

Consequences, all intended: no nav engine or telemetry, no spoken prompts,
no reroute, no arrival (so `onArrive` can never race the manual End).
The empty stream finishes immediately, so `GuidanceViewModel` sets
`turn = .unavailable` — the HUD renders its "guidance unavailable" card
(NOT `.starting`; corrected per review). `cruisingState` stays `.starting`
(`lastUpdate` remains nil) so the InstrumentPanel is unaffected. None of
this is asserted.

### 5. Shared HUD probe + identifier additions

Extract RideHUDView's DEBUG probe overlay (invisible
`RideTestProbe.line(...)` text tagged `RideTestID.hudProbe`, rendered only
when simulated) into a shared ViewModifier in the app target
(`.simulatedRideProbe(distanceMeters:elapsed:elevationGainMeters:)`), and
adopt it in both HUDs. The modifier adds **`.allowsHitTesting(false)`** so
the transparent text can never intercept a tap near the bottom cluster
(navigate's End button lives in that region). In release builds the
modifier body returns the content unchanged. Free-ride probe behavior is
otherwise unchanged (same identifier, same line format).

Two new `RideTestID` constants (AuraKit shared enum — renames stay
compile-time breaks): `hudEnd` on `ControlCluster`'s End button (both HUDs
and the group path get it for free; label "End ride" unchanged), and
`previewStart` on RoutePreviewView's **Start RIDE** button.

### 6. The test

A second method in `RideE2EUITests` (same class → the CI lane's
`-only-testing:AuraUITests/RideE2EUITests` and per-method retry cover it
with zero workflow edits): `testNavigateGoldenRideEndsToSummaryAndHistory`.

Flow and assertions:

1. Launch with onboarding-done + sim args + in-memory store + the
   `-openURL` preview link (URL built from
   `GoldenRideFixture.startCoordinate`); tolerant springboard-alert
   dismissal as today.
2. **Poll `PreviewScreen.startRide.isEnabled`** (not bare existence — the
   button exists in every phase and only enables once the fixture route is
   auto-selected one runloop after `.task` runs).
3. Tap Start RIDE → `RideScreen.probe` appears (simulated hook engaged in
   the navigate HUD).
4. `waitForDistance(atLeast: 0.85 × expectedDistanceMeters, timeout: 90)`
   — proves the coordinator records through the navigate path — **plus the
   one-line gain check** (`g ≥ 40`, same threshold as free ride): distance
   alone is a weak proxy if the navigate wiring ever diverges from the
   shared helper. Elapsed-ticker polling is NOT repeated (free-ride owns
   the ticker guarantee; same coordinator).
5. Tap `RideScreen.endButton` (`hudEnd`) → "End ride?" alert (solo alert —
   `groupSession == nil`) → "End ride".
6. Summary appears (`SummaryScreen.title`), hero distance within the same
   band as the free-ride test — band + floor constants extracted to shared
   helpers used by both methods, with a comment that a fixture re-record
   must update literals AND bands together.
7. Done → Home (`home.exploreButton`), then History shows exactly one row.

New screen object: `PreviewScreen` (startRide). `RideScreen` gains
`endButton`.

### 7. ROH-95: ephemeral store for every UI-test launch

`XCUIApplication.launched()` and `launched(onboarded:)` append
`-auraInMemoryRideStore`, **and the two call sites that construct
`XCUIApplication()` directly — `SavedPlacesUITests` and `HomeUITests`'
`testAX5` — are converted to the helper** (reviewer finding: patching the
helpers alone leaves those launches on the CloudKit-mirrored store, and
`SavedPlacesUITests` opens the store on launch). Plain `launched()`
currently has no callers; it gets the flag anyway so no future caller can
reintroduce the trap.

Verified during review (not just asserted): none of the seven suites
relaunches the app to assert cross-launch persistence, and none asserts
populated History/ride counts; `SettingsStore` (UserDefaults/KVS),
onboarding flag (NSArgumentDomain), and recents are unaffected by the flag.
`SavedPlacesStore` shares the container and works in-memory within a
launch. `RideStore.inMemory()` omits `cloudKitDatabase`, so the SIGTRAPping
CloudKit mirror setup is genuinely never constructed.

**Honest limitation (recorded on ROH-95, not blocking):** after this
change no UI test ever opens the CloudKit-mirrored store, so the harness is
blind to production CloudKit-setup crashes (e.g. signed build, iCloud
signed out). Whether that path is reachable in production is a separate
verification noted on the ROH-95 issue; a signed-store smoke test remains
possible follow-up material.

### 8. CI: one number changes, plus a recorded fallback

- `timeout-minutes: 40 → 50` on `app-build`. Re-derived worst case: cold
  SPM + full Mapbox build (~15–25 min) + boot + **two** E2E methods, each
  up to twice under `-retry-tests-on-failure -test-iterations 2` (~2–3 min
  per method-run incl. launch) → the old 40 could breach as a pure timeout
  flake; 50 holds with margin. Nothing else in the workflow or
  `scripts/golden-ride.sh` changes.
- **Fallback if the full-bleed navigate map can't render on the CI sim**
  (first time this surface runs there; free ride's quarter-panel map
  proving out does not prove full-bleed): demote the navigate method to
  local-only (skip in CI via an env guard), record it in ROADMAP and on
  ROH-93, and note there is no Layer-1 navigate backstop. This PR's CI run
  is the experiment, same policy as ROH-92 §5.

### 9. What does not change

The fixture and its truth literals, Layer 1, `SimulatedRideConfig`, the
free-ride test's assertions, `scripts/golden-ride.sh`. The ROADMAP testing
section gets one line: both HUDs' finish → summary seams are now gated
(free ride and navigate), navigate entering via preview → Go.

## Error handling

- `GoldenRideFixture.route()` / `simulatedProvider` throw → Debug
  `assertionFailure` (packaging regressions fail loudly; release
  unaffected).
- Simulated hook silently no-ops in the navigate HUD → probe never appears
  → step 3 fails loudly (same not-survivable property as ROH-92).
- Summary-seam regression → step 6 (summary never appears / blank pushed
  destination) or step 7 (History wrong) fails.

## Verification (definition of done)

- Full `RideE2EUITests` class (both methods) green locally on the iPhone 17
  sim; CI green on the PR (or the §8 fallback recorded honestly).
- The seven legacy suites green locally under the unsigned build (ROH-95
  effect verified, or residual failures noted honestly on the issue).
- Regression drill (both variants, reverted after proof, output quoted in
  the PR):
  (a) no-op `router.showRideSummary` call in NavigateHUDView's
  `finishedRide` onChange → navigate test fails at step 6 while free-ride
  stays green — proves the new gate covers the seam the old one couldn't;
  (b) swap the collapse for `path.append(.rideSummary(...))` → **document
  that the E2E stays green** — records the coverage boundary from the
  honesty table instead of letting it pass silently.
- `swiftlint --strict` clean. ROADMAP updated. ROH-93 and ROH-95 → In
  Review at PR, Done after merge + verification.
