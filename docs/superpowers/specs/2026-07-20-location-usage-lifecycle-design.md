# Location Usage Lifecycle — Design (ROH-83)

**Date:** 2026-07-20
**Issue:** [ROH-83](https://linear.app/rohun/issue/ROH-83) — Location "in use" indicator persists after a ride ends (and after app close); no low-power home tier
**Branch:** `claude/location-usage-persistence-2aaa00` (off `main` @ e0dd212)

## Problem

After a ride ends, iOS's blue "using location" indicator stays on, and it sometimes
persists even after the app is closed. Location should be released whenever the app is
not in a ride and not actively searching/exploring. On Home only occasional, low-power
fixes are wanted.

### Root-cause map (investigation, systematic-debugging Phase 1)

A single shared `LocationService` (`AuraCore/Sources/AuraKit/LocationService.swift`,
instantiated once at `Aura/Sources/AuraApp.swift:13`) runs **two decoupled pipelines**:

- **Pipeline A — ride stream** (`points()` L55 / `stop()` L92): creates a
  `CLBackgroundActivitySession` (L64) and sets `showsBackgroundLocationIndicator = true`
  (L51). Released only through `RideSessionCoordinator.finish()`/`cancel()`/`stopStreaming()`.
- **Pipeline B — `current()`** (L106, helper `firstLiveCoordinate()` L130): for a logically
  one-shot origin it opens a **separate, unmanaged, continuous** `CLLocationUpdate.liveUpdates()`
  stream with **no stop site** — teardown relies solely on async-sequence deallocation inside a
  3s-timeout race. Called from `HomeView.swift:142` (weather, re-fired on every authorization
  change) and `RoutePreviewView.swift:294` (route preview origin).

`setMode()` (L45) sets the iOS indicator/no-auto-pause knobs unconditionally for both
`.idle` and `.navigating`. `Info.plist` declares `UIBackgroundModes = [location]`. There is
no `scenePhase`/background-transition handler that releases location anywhere.

**Leading explanation:** returning to Home after a ride re-runs the weather fetch → `current()`,
re-arming a continuous `liveUpdates()` stream that is never explicitly cancelled; with the
location background mode declared, this raises the indicator and can survive app close. The
persist-after-close signal is the fingerprint of a location session that is not invalidated
while no ride is active.

## Desired end state

1. **Idle = fully released.** Not riding, not on Home, or app backgrounded → no location
   updates, no session, no indicator.
2. **Ride = full accuracy + background.** Unchanged behavior during an active ride: continuous
   high-accuracy updates, background activity session, persistent indicator (correct for a live
   ride that must record in the background).
3. **Home = coarse ambient, foreground only.** While Home is visible and the app is foreground,
   a low-power monitor updates weather as the rider moves (~500 m). No background session; it
   releases the moment the app backgrounds or Home disappears.

## Design

### Three explicit accuracy/activity tiers

Replace today's two-case `LocationAccuracyMode` (`AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift`)
with three tiers:

| Tier | Trigger | `desiredAccuracy` | `distanceFilter` | Background session | `showsBackgroundLocationIndicator` |
|---|---|---|---|---|---|
| `.idle` | not riding, not on Home, or backgrounded | — (updates stopped) | — | none | false |
| `.ambient` | Home visible **and** app foreground | `kCLLocationAccuracyKilometer` | ~500 m | **none** | **false** |
| `.navigating` | active ride only | `kCLLocationAccuracyNearestTenMeters` | none/default | `CLBackgroundActivitySession` | true |

Route-preview / "searching" resolves its origin through the one-shot `current()` (below) and
does **not** enter `.navigating` — a single fix needs no background session or indicator.

Key rule: **only `.navigating` ever creates a background session or sets the background
indicator.** `setMode` must stop setting `showsBackgroundLocationIndicator = true` for any
tier other than `.navigating`.

### LocationService changes (`AuraKit/LocationService.swift`)

- **New ambient monitor.** A coarse, foreground-only monitor driven by the classic
  `CLLocationManager` delegate (`startUpdatingLocation()` with coarse `desiredAccuracy` +
  `distanceFilter ≈ 500`). It publishes the latest fix to an observable
  `lastKnown: Coordinate?`. It creates **no** `CLBackgroundActivitySession`. Started/stopped
  via `startAmbient()` / `stopAmbient()` (names finalized in the plan).
- **Rewrite `current()` to a true one-shot.** Order of resolution:
  1. fresh cached `manager.location` (age < 30 s) → return it (already the fast path today);
  2. else, if the ambient monitor has a recent `lastKnown` → return it;
  3. else a single one-shot fix (`requestLocation()`), raced against the existing timeout →
     fall back to the Pittsburgh default.
  It must **never** open an unmanaged continuous `CLLocationUpdate.liveUpdates()` and must leave
  no running task behind. The `firstLiveCoordinate()` continuous helper is removed.
- **Expose ride state for the safety net.** A `var isNavigating: Bool` (or equivalent) derived
  from the current tier, so the app-level safety net can decide whether it is safe to release
  location **without** reaching into `RideSessionCoordinator`.
- **`releaseNonRide()`** — stops the ambient monitor and any one-shot work, but leaves the
  `.navigating` ride pipeline untouched. No-op when navigating.
- Ride pipeline (`points()`/`stop()`) is otherwise unchanged: it remains the sole owner of the
  background session and indicator, and `stop()` continues to invalidate the session.

### Lifecycle wiring

- **HomeView** (`Aura/Sources/Home/HomeView.swift`): start `.ambient` when the view appears and
  the app is foreground; stop it on disappear. Weather refresh reads from the ambient monitor's
  latest fix instead of firing a fresh continuous locate. The `onChange(of: authorization)`
  re-fire is kept but now routes through the safe one-shot/ambient path.
- **RoutePreviewView** (`Aura/Sources/Plan/RoutePreviewView.swift`): unchanged call site — it keeps
  using `current()` for its origin, which is now a safe one-shot.
- **AuraApp** (`Aura/Sources/AuraApp.swift`): a `scenePhase` observer calls
  `location.releaseNonRide()` whenever the app leaves `.active`. Because `releaseNonRide()` is a
  no-op while navigating, an active ride keeps recording in the background; everything else is
  released. On return to `.active`, Home re-arms ambient through its normal appear path.

### Why the safety net reads `LocationService`, not the coordinator

Anchoring "am I in a ride?" in `LocationService`'s own tier state keeps the change surface to
`LocationService` + `HomeView` + `AuraApp`. The ROH-81 branch
(`claude/cleanup-roh-81-feedback-0412af`) edits `RideSessionCoordinator`'s end/leave *feedback*;
avoiding coordinator edits here minimizes merge conflict. This spec does **not** modify the
coordinator's finish/cancel logic.

## Testing

`LocationService` is `@MainActor @Observable` with an existing pure `ingest` seam and unit tests.
Add tests (Swift Testing) for:

- `.ambient` never creates a background session; `.navigating` does.
- `setMode` sets `showsBackgroundLocationIndicator = true` **only** for `.navigating`.
- `current()` returns cached/ambient/fallback and leaves **no** running task or continuation.
- `releaseNonRide()` stops ambient but is a no-op while navigating (ride pipeline survives).
- Tier transitions: idle → ambient → navigating → idle release the previous tier's resources.

Where OS behavior can't be asserted in a unit test, assert on `LocationService`'s observable
state (current tier, session presence via an injected/guarded seam, `updatesTask == nil`).

### Device verification (cannot be unit-tested)

- Indicator turns **off** within seconds of ending a ride and returning to Home.
- Indicator does **not** reappear while idle on Home; ambient shows only the foreground arrow.
- No indicator survives closing the app when no ride is active.
- In-ride tracking/accuracy/background recording unchanged.
- Home weather still resolves and updates as the rider moves ~500 m.

## Scope guardrails / non-goals

- **Authorization unchanged** — stays When-In-Use. No Always, and therefore no
  `startMonitoringSignificantLocationChanges` (which requires Always).
- **No coordinator restructuring** — end/leave feedback is ROH-81's territory.
- **No new background modes or Info.plist capability changes** beyond what already exists.
- `CompassHeadingProvider` is out of scope (heading only; does not raise the indicator; already
  start/stop-paired).

## Acceptance criteria

- [ ] Indicator turns off within seconds of ending a ride and returning Home.
- [ ] Indicator does not reappear while idle on Home.
- [ ] No location indicator survives closing the app when no ride is active.
- [ ] In-ride tracking accuracy/background behavior unchanged.
- [ ] Home weather origin still resolves and updates as the rider moves (~500 m), from the
      coarse ambient source.
- [ ] New unit tests pass; existing suite stays green; SwiftLint clean; app builds.
