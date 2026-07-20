# Location Usage Lifecycle — Design (ROH-83)

**Date:** 2026-07-20
**Issue:** [ROH-83](https://linear.app/rohun/issue/ROH-83) — Location "in use" indicator persists after a ride ends (and after app close); no low-power home tier
**Branch:** `claude/location-usage-persistence-2aaa00` (off `main` @ e0dd212)
**Status:** revised after adversarial spec review (3 reviewers) + PO decisions.

## Terminology (used precisely throughout)

- **Background pill** — the persistent blue "\<App\> is using your location" capsule iOS shows
  when an app holds an active *background* location session. This is the PO's reported bug.
- **Foreground arrow** — the small status-bar arrow shown while a foregrounded app takes fixes.
  Expected and acceptable while the app is open and actively locating. Not the bug.

The fix's hard guarantee is about the **background pill**. The **foreground arrow** is allowed
whenever the app is open and legitimately locating (in a ride, or ambient-on-Home per PO choice).

## Problem

After a ride ends, the **background pill** stays on, and it sometimes persists after the app is
closed. PO clarifications (2026-07-20):

- The pill persisted **after the ride had already ended** (the pure bug — not mid-ride).
- Seen after **both** backgrounding (swipe to home) **and** force-quit (swipe away).

Location should be released whenever the app is neither in a ride nor searching/exploring. On Home
the PO wants **continuous coarse** updates (weather refreshes as he moves ~500 m), and accepts that
this keeps the foreground arrow visible while Home is open — as long as the background pill is gone.

### Root-cause map (investigation + review reconciliation)

Single shared `LocationService` (`AuraCore/Sources/AuraKit/LocationService.swift`, made once at
`Aura/Sources/AuraApp.swift:13`) runs two decoupled pipelines:

- **Pipeline A — ride stream** (`points()` L55 / `stop()` L92): creates a
  `CLBackgroundActivitySession` (L64) and sets `showsBackgroundLocationIndicator = true` (L51).
  Released only via `RideSessionCoordinator.finish()`/`cancel()`/`stopStreaming()`
  (`RideSessionCoordinator.swift:144/167/175`). Teardown partly relies on
  `continuation.onTermination` re-hopping to the main actor (L84–88) — an **async** hop, not a
  synchronous guarantee.
- **Pipeline B — `current()`** (L106, helper `firstLiveCoordinate()` L130): opens a separate,
  **unmanaged, continuous** `CLLocationUpdate.liveUpdates()` for a one-shot origin, with no stop
  site. Called from `HomeView.swift:142` (weather) and `RoutePreviewView.swift:294` (route origin).

**Which pipeline raises the surviving pill?** The background pill is produced by an active
*background location session*. Two mechanisms can sustain one under `UIBackgroundModes:[location]`:
(1) Pipeline A's `CLBackgroundActivitySession` if not invalidated before the app suspends/terminates;
(2) a Pipeline B `liveUpdates()` iterator left running. Given the PO saw the pill **after the ride
ended** and **even after force-quit**, the leading suspect is **Pipeline A's background session not
being torn down synchronously on ride end** (an orphaned session survives suspension and can even
outlive a force-quit briefly). The exact culprit is a **device-verification** item; therefore this
design **hardens both pipelines** (defense in depth) rather than betting on one.

Additional facts surfaced by review, folded into the design below:

- `CLLocationUpdate.liveUpdates()` is a *static* API with its own configuration; it does **not**
  read `manager.desiredAccuracy`/`distanceFilter`. So ride accuracy is governed by the live-updates
  configuration, not the shared `manager`.
- `HomeView` is the **retained** root of a `NavigationStack` (`AuraApp.swift:74–96`). `onAppear`/
  `onDisappear` are **not** reliable on push/pop or on background→foreground; the tier machine must
  not depend on them.
- `router.isRideActive` already exists as the app's ride-truth flag, set by both HUDs
  (`NavigateHUDView.swift:210`, `RideHUDView.swift:177`). We anchor on it rather than inventing a
  third source of truth.
- The Mapbox map puck (`RideMapView` `Puck2D`) runs its **own** `CLLocationManager` inside
  MapboxMaps, independent of `LocationService`. Out of code scope here, but on the device-verify
  checklist so it isn't assumed innocent.

## Desired end state

1. **Idle = no background session, and no foreground location at all** whenever the app is not in a
   ride and Home is not the visible foreground screen (e.g. Settings, History, backgrounded).
2. **Ride = full accuracy + background session + pill.** Unchanged intent; the pill is correct while
   a ride records. Teardown on ride end must be **synchronous and complete** (no orphaned session).
3. **Home (foreground, top of stack) = continuous coarse ambient.** Weather updates as the rider
   moves ~500 m. Foreground arrow visible (accepted by PO); **never** a background session or pill.

## Design

### A. Three tiers, and `setMode` fully owns the manager per tier

Replace the two-case `LocationAccuracyMode`
(`AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift`) with three: `.idle`, `.ambient`,
`.navigating`. `setMode(_:)` becomes the single place that configures the shared `manager` and must
set **every** relevant knob for **every** tier (no knob may leak across a transition):

| Tier | `desiredAccuracy` | `distanceFilter` | `activityType` | `pausesLocationUpdatesAutomatically` | `showsBackgroundLocationIndicator` | Background session |
|---|---|---|---|---|---|---|
| `.idle` | `kCLLocationAccuracyHundredMeters` | `kCLDistanceFilterNone` | `.other` | true | **false** | none |
| `.ambient` | `kCLLocationAccuracyKilometer` | `500` | `.fitness` | true | **false** | none |
| `.navigating` | `kCLLocationAccuracyBestForNavigation`/`NearestTenMeters` | `kCLDistanceFilterNone` | `.fitness` | **false** | **true** | `CLBackgroundActivitySession` |

Rules:
- **Only `.navigating`** sets `showsBackgroundLocationIndicator = true` and creates a
  `CLBackgroundActivitySession`. All iOS-only knobs stay inside the existing `#if os(iOS)` block; the
  cross-platform `desiredAccuracy`/`distanceFilter` stay outside it (macOS CI builds the package).
- `distanceFilter` is now set for every tier so an ambient 500 m filter can never persist into a ride
  or idle.
- Ride accuracy is set on the `liveUpdates()` configuration (not `manager`); the `manager` accuracy
  in `.navigating` is belt-and-suspenders only. (Documented so the tier table isn't read as fiction.)

### B. Tier ownership — an explicit, single-writer controller (not view lifecycle)

Introduce one place that computes the desired tier from explicit inputs and applies it. Inputs:

- `isRideActive` — from `router.isRideActive` (existing).
- `isHomeForeground` — `router.path.isEmpty && scenePhase == .active`.
- `authorization == .authorized` (When-In-Use granted).

Desired tier:

```
if isRideActive            -> .navigating   (owned by the ride pipeline via points()/stop())
else if isHomeForeground
        && authorized      -> .ambient
else                       -> .idle
```

This controller is driven by **explicit observation** of `router.path`, `router.isRideActive`,
`scenePhase`, and `authorization` — **never** by `onAppear`/`onDisappear`. Concretely it lives as an
observation in `RootView` (which owns `router` and `scenePhase`) that calls into `LocationService`
(`startAmbient()` / `releaseNonRide()`); the ride tier remains owned by the coordinator's existing
`points()`/`stop()` calls. Because the ride pipeline sets `.navigating` and the controller only ever
drives `.ambient`/`.idle` (and is a **no-op while `isRideActive`**), the two writers cannot fight.

Consequences this resolves:
- Going into Settings/History (`path` non-empty) → `.idle`, ambient stops. (Fixes the retained-root
  `onDisappear` leak.)
- Background → `.idle` on `.background` specifically (not `.inactive`, which fires on Control Center /
  banners / permission alerts). Foreground back onto Home → controller recomputes `.ambient`
  (fixes "ambient never re-arms after background").
- Ride starting flips `isRideActive` true → controller yields to the ride; ambient is released before
  `.navigating` engages.

### C. Ambient monitor (continuous coarse, Home-foreground only)

`startAmbient()` / `stopAmbient()` on `LocationService`:
- Uses the shared `manager` with `setMode(.ambient)` + classic `startUpdatingLocation()`. **No**
  `CLBackgroundActivitySession`, indicator off.
- **Gated on `authorization == .authorized`.** It must **never** call `requestWhenInUseAuthorization`
  or `startUpdatingLocation` while `.notDetermined` — the first permission prompt must still originate
  from the **ride path** (`points()`, unchanged), preserving today's prompt timing. (Fixes premature
  first-launch prompt.)
- Publishes each fix to an observable `lastKnown: (coordinate: Coordinate, at: Date)?`.

`HomeView` weather: add `.onChange(of: location.lastKnown)` → `refreshWeather()` (throttled by the
500 m `distanceFilter`), so weather actually updates as the rider moves. Keep the existing `.task` and
`authorization` triggers.

### D. `current()` — a true, isolated one-shot

Rewrite `current()` so it never opens an unmanaged continuous stream and cannot crash under
concurrency:

- **Dedicated one-shot `CLLocationManager`** (separate from the ambient `manager`) with a single-slot
  `CheckedContinuation`. Implement `locationManager(_:didUpdateLocations:)` and
  `locationManager(_:didFailWithError:)`; **demultiplex by manager identity** (`m === oneShotManager`)
  so ambient fixes and one-shot fixes never cross. Resume-once guard (nil the slot) prevents
  double-resume.
- **Coalesce concurrent callers:** if a one-shot is already in flight, new callers await the same
  result rather than starting a second request (protects against `HomeView`'s `.task` +
  `authorization` `onChange` + `RoutePreview` overlapping).
- **Resolution order, accuracy-aware:**
  1. fresh cached fine fix (`manager.location`, age < 30 s) → return;
  2. **for routing origins** (route preview) skip coarse `lastKnown`; **for non-routing** (weather),
     a fresh `lastKnown` (age < 30 s, timestamped) may be returned;
  3. else one-shot `requestLocation()` on the dedicated manager, raced against the existing 3 s
     timeout → Pittsburgh fallback.
- `current()` gains an accuracy/purpose parameter (e.g. `for: .routing` vs `.coarse`) so
  `RoutePreviewView` gets a fine fix and weather can accept coarse. Never returns a `kCLLocationAccuracyKilometer`
  sample as a routing origin.
- Remove `firstLiveCoordinate()` (verified: no other caller, no test depends on it).

### E. Ride pipeline hardening (Pipeline A)

The ride pipeline stays the sole owner of the background session/pill, but its teardown becomes a
**synchronous, complete** guarantee rather than an async best-effort:

- `stop()` must synchronously: cancel `updatesTask`, `invalidate()` + nil the `backgroundSession`,
  finish the continuation, and `setMode(.idle)` — before returning. (Mostly true today at L92–100;
  the risk is the *ordering* vs the async `onTermination` self-stop.)
- Remove the `continuation.onTermination { Task { @MainActor stop() } }` self-teardown **race** (L84–88):
  with teardown now explicitly owned by `stop()` (called by the coordinator and the controller), the
  delayed async re-hop can land *after* a new `.ambient` has been armed and clobber it. Either drop
  the self-stop, or make `setMode(.idle)` in `stop()` a no-op when a newer non-idle tier is already
  requested. Design choice: **drop the self-stop**; teardown is explicit.
- Fix the unconditional pill flag: today `stop()` → `setMode(.idle)` still ran the old unconditional
  `showsBackgroundLocationIndicator = true` (L51). Per §A, `.idle`/`.ambient` set it **false**.

### F. Lifecycle wiring (`RootView` / `AuraApp.swift`)

- Add `@Environment(LocationService.self)` to `RootView` (it currently lacks it).
- **Merge** the tier-driver observation into the existing `scenePhase` handler (`AuraApp.swift:131`,
  which reloads widgets on `.active`) rather than adding a second `.onChange(of: scenePhase)`.
- Observe `router.path` / `router.isRideActive` changes to recompute the tier (§B).
- The ride HUDs and coordinator are **not** modified — they already drive `points()`/`stop()` and set
  `router.isRideActive`. This keeps the change surface off `RideSessionCoordinator`, avoiding conflict
  with the ROH-81 branch.

## Testing

Add a **`CLLocationManager` protocol seam** (a thin wrapper the ambient/one-shot code calls, injectable
in tests) and expose an observable `tier` and a testable `sessionActive: Bool`. Then unit tests
(Swift Testing) can assert on state that is otherwise device-only:

- `setMode(.ambient)`/`.idle` leave `showsBackgroundLocationIndicator == false` and `sessionActive == false`;
  `.navigating` sets both true.
- Every tier sets `distanceFilter` (no leak across transitions).
- `current(for: .routing)` never returns a coarse `lastKnown`; `current(for: .coarse)` may.
- `current()` under two concurrent callers resumes exactly once each (no double-resume), leaves no
  pending continuation, and no running task.
- Controller logic: `(isRideActive, isHomeForeground, authorized)` → expected tier, including the
  no-op-while-navigating property and the `.background` (not `.inactive`) release rule. Prefer testing
  this as a **pure function** `desiredTier(...)` so it needs no CoreLocation.
- `stop()` leaves `backgroundSession`/`sessionActive == false` and `updatesTask == nil` synchronously.
- Ambient is gated on `.authorized` (no `startUpdatingLocation` while `.notDetermined`).

### Device verification (cannot be settled from code — required before closing ROH-83)

- Capture which session is alive when the pill persists (Console/Instruments) — confirm Pipeline A vs
  B vs Mapbox.
- Background pill is **off within seconds** of ending a ride and returning Home.
- Background pill does **not** appear while idle on Home; only the foreground arrow (ambient) shows.
- No background pill survives **force-quit** when no ride is active.
- No background pill while sitting in Settings / History (ambient released).
- In-ride tracking/accuracy/background recording unchanged; pill correct during a live ride.
- Mapbox puck provider is not left running after a ride ends.
- Home weather resolves and updates as the rider moves ~500 m.

## Scope guardrails / non-goals

- **Authorization unchanged** — stays When-In-Use; first prompt still originates from the ride path;
  ambient is gated on `.authorized`. No Always, no significant-change monitoring (needs Always).
- **No `RideSessionCoordinator` internal edits** — ride-truth read via `router.isRideActive`.
- **No new background modes / Info.plist capability changes.**
- **Mapbox puck / free-drive provider** — out of code scope; on the device-verify checklist only.
- `CompassHeadingProvider` out of scope (heading only; no pill; already start/stop paired).
- New ambient/one-shot API is **concrete-`LocationService`-only** — not added to `LocationStreaming`;
  `SimulatedLocationProvider` (GPX playback) is unaffected.

## Acceptance criteria

- [ ] Background pill is off within seconds of ending a ride and returning to Home.
- [ ] Background pill does not appear while idle on Home (a foreground arrow is expected/acceptable).
- [ ] No background pill survives closing the app (background or force-quit) when no ride is active.
- [ ] No background pill (or foreground arrow) while in Settings / History with no ride active.
- [ ] In-ride tracking accuracy and background recording unchanged; pill correct during a live ride.
- [ ] Home weather resolves and updates as the rider moves ~500 m (coarse ambient source).
- [ ] Route-preview origin uses a fine fix, never a coarse ambient sample.
- [ ] First location-permission prompt still appears at ride start, not on first Home load.
- [ ] New unit tests pass; existing suite green; SwiftLint clean; app builds.
