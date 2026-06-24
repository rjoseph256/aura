# Aura — Wave 0: Core Ride Correctness · Design Spec

- **Date:** 2026-06-24
- **Status:** Approved for planning
- **Scope:** Roadmap "Wave 0 — Make the core ride actually work", full scope including off-route reroute.
- **Context:** Follows the 2026-06-24 audit in `docs/ROADMAP.md`. Builds on `main` at the
  Live Activity work (`6bba88d`).

---

## 1. Overview and goal

Wave 0 makes the flagship behavior of a cycling app trustworthy: a ride records a
continuous, accurate GPS track, the rider can tell when something is wrong, and the
app recovers gracefully from the common failure modes. Today none of that is wired
end to end. The app forwards every GPS fix regardless of accuracy, never holds a
background session or keeps the screen awake, only ever asks for When-In-Use
authorization, shows no GPS-weak or permission state, and never observes off-route
reroutes (so a rerouted rider sees a stale line).

This is correctness work, not features. It is the foundation the later waves build on.

The work splits into a location-layer rebuild plus three safety states.

---

## 2. Scope

### In scope

1. A consolidated `LocationService` replacing `LiveLocationProvider` and
   `CurrentLocationProvider`, built on the iOS 17 CoreLocation APIs.
2. Background recording under When-In-Use via `CLBackgroundActivitySession`, plus
   keeping the screen awake while recording.
3. GPS fix filtering (bad fixes never reach the recorded track) and a GPS-weak / lost
   indicator in both HUDs.
4. A permission-denied explainer with a Settings deep link, gating ride start while
   keeping the plan screen usable.
5. Off-route reroute: observe the Mapbox reroute signal, show a non-jarring cue, and
   redraw the navigate polyline from the live route shape instead of the frozen one.

### Out of scope (wave boundary)

- No ride-session coordinator (Wave 1). The new lifecycle hooks are called from the
  existing HUD `startRide` / `endRide`, alongside the existing Live Activity calls.
- No entitlements file. Background location and `CLBackgroundActivitySession` need only
  the `location` background mode already in `Info.plist`. An entitlements file arrives
  with HealthKit in Wave 3.
- No ETA, distance-remaining, current street name, or recenter control (Wave 2 cockpit).
- No Always authorization. When-In-Use plus a background activity session covers an
  actively started ride.

---

## 3. Decisions (settled during brainstorming)

- **Authorization and background model:** When-In-Use plus `CLBackgroundActivitySession`.
  Lower friction than Always, App Review safer, sufficient for an actively started ride.
  Recording is not required to survive app termination in this wave.
- **Location-layer scope:** consolidate the two providers into one service now, using the
  modern API, rather than bolting onto the existing two-manager code and rebuilding later.
- **GPS quality:** filter fixes with invalid or poor horizontal accuracy out of the
  recorded track so they cannot corrupt distance, speed, or elevation stats. The same
  signal drives the on-screen indicator, and the last good position is retained.
- **Permission handling:** block ride start on denied/restricted with a full explainer and
  a Settings deep link. Keep the plan/map screen graceful on the existing fallback origin.
  The gate lives only where location is actually required.
- **Reroute:** include it in this wave. Observe the Mapbox reroute publisher, show a
  transient cue, and redraw the polyline from the live route shape.
- **Verification:** simulator plus the package test suite. "Locked screen keeps recording"
  is configured but device-unverified, and will be flagged as such rather than claimed.

---

## 4. Architecture and components

### 4.1 LocationService (AuraKit)

One `@Observable @MainActor final class LocationService`, the single CoreLocation owner,
injected through the SwiftUI environment in `AuraApp` exactly like `router`, `rideStore`,
and `settings`, so every screen observes the same instance. It conforms to the existing
`LocationStreaming` protocol so `RideRecorder` and the desk-demo `SimulatedLocationProvider`
are untouched.

Implementation:
- **Streaming** via `CLLocationUpdate.liveUpdates()` (iOS 17+). No `CLLocationManagerDelegate`
  and no manual continuation bridge, which removes the `MainActor.assumeIsolated` pattern the
  audit flagged in `LiveLocationProvider`.
- **Authorization** via a `CLLocationManager` used only to read status and call
  `requestWhenInUseAuthorization()`. The `CLLocationUpdate` value also reports
  `authorizationDenied` / `locationUnavailable`, which feeds the gate and the indicator.
- **Background delivery** via a `CLBackgroundActivitySession` started when the ride stream
  begins and invalidated when it stops, with `showsBackgroundLocationIndicator = true`.
- **Accuracy mode:** an `idle` vs `navigating` setting. Accuracy is coarse when not
  recording and rises to the cycling tier during a ride (the spec's battery behavior).
- **Filtering:** each incoming fix passes the pure acceptance predicate before being yielded
  as a `TrackPoint`; rejected fixes update `signal` but never reach the recorder.

Observable surface read by the HUDs and plan:
- `authorization: LocationAuthorization` (a small AuraKit enum mirroring the CL states the
  UI cares about: notDetermined, denied, restricted, authorized).
- `signal: SignalQuality` (`good` / `weak` / `lost`).
- `func points() -> AsyncStream<TrackPoint>` (filtered), `func stop()`.
- `func current() async -> Coordinate` (one-shot origin, retains the Pittsburgh fallback for
  the graceful-plan case). This is an additive method on `LocationService`, not part of the
  `LocationStreaming` protocol (which stays `points()` / `stop()`); it folds in what
  `CurrentLocationProvider` does today.
- `func setMode(_:)` for idle vs navigating accuracy.

**Wiring (explicit work):** the HUDs do not read a location provider from the environment
today. `RideHUDView` takes a `makeProvider: () -> LocationStreaming` closure and
`NavigateHUDView` constructs `LiveLocationProvider()` directly. Both must be rewired to read
the injected `LocationService` so they can call `points()` / `setMode(_:)` and observe
`signal` / `authorization` on the one shared instance. `AuraApp` creates and injects it.

### 4.2 Pure helpers (AuraCore)

CI-tested, no CoreLocation import:
- `SignalQuality` enum and a classifier `SignalQuality(horizontalAccuracy:age:)` mapping
  accuracy in meters plus fix age in seconds to `good` / `weak` / `lost`. Thresholds are
  named constants (initial values: good <= 20m, weak <= 50m, lost otherwise or stale beyond
  a few seconds), tuned during implementation.
- A fix-acceptance predicate `isAcceptable(horizontalAccuracy:)` that rejects negative
  accuracy (invalid fix) and accuracy worse than the lost threshold.
- The accuracy-mode to `CLLocationAccuracy` mapping is in the service; the mode enum itself
  is pure.

`LocationService` consumes these so the classification and filtering logic is unit-tested
without a simulator. The service maps a `CLLocation` to `(horizontalAccuracy, age)` and
delegates the decision.

### 4.3 Background session and screen awake

The `CLBackgroundActivitySession` lifecycle lives inside `LocationService` (it is a location
concern). Keeping the screen lit is a display concern, so it stays in the app target: a tiny
`@MainActor` helper wrapping `UIApplication.shared.isIdleTimerDisabled`, called from the
HUD `startRide` / `endRide` next to the existing Live Activity calls, and reset on every
terminal path (end button, arrival, view teardown).

### 4.4 GPS-weak indicator

A small chip in both HUD overlays bound to `service.signal`, using `AuraTheme`. Shown for
`weak` and `lost`, hidden for `good`. It carries a composed accessibility label. Because the
same `signal` gates filtering, the chip is visible exactly when fixes are being dropped.

### 4.5 Permission gate and explainer

A `LocationPermissionView` (app target) presenting the rationale and an "Open Settings"
button using `UIApplication.openSettingsURLString`. The HUD ride-start path checks
`service.authorization`: if denied or restricted, it presents the explainer and does not
start recording. If not determined, it requests When-In-Use and proceeds once authorized.
The plan and preview screens continue to use `current()` with the fallback origin, so
browsing the map is never blocked.

### 4.6 Off-route reroute

- **AuraCore:** `GuidanceEvent` gains `.rerouting` and `.rerouted([Coordinate])`.
- **GuidanceViewModel (AuraKit):** tracks `isRerouting: Bool` and `routeGeometry: [Coordinate]?`.
  `.rerouting` sets `isRerouting = true`; `.rerouted(geometry)` sets `routeGeometry = geometry`
  and clears `isRerouting`; a subsequent `.progress` also clears `isRerouting` defensively.
- **MapboxGuidanceSession (app):** subscribes to the Mapbox Navigation v3 reroute publisher,
  emits the new events, and decodes the new route shape to `[Coordinate]`. The exact publisher
  is confirmed to fire on the simulator during implementation before the cue is wired (per the
  Terrain-RGB lesson that a clean build is not proof of behavior).
- **NavigateHUDView (app):** draws its polyline from `guidance.routeGeometry ?? route.geometry`
  and shows a reduce-motion-aware "Rerouting..." cue while `isRerouting`.
- **Tests:** `ScriptedGuidanceSession` replays the new events, so the view-model reroute
  transitions are unit-tested with no Mapbox dependency.

---

## 5. Data flow

A navigated ride, end to end:

1. The rider taps start. The HUD checks `service.authorization`. If granted (or it requests
   and is granted), `service.setMode(.navigating)`, the screen-awake helper is engaged, and
   `RideLiveActivityController.start` runs as today.
2. `service.points()` begins `CLLocationUpdate.liveUpdates()` and starts a
   `CLBackgroundActivitySession`. Each fix is classified (updating `signal`) and filtered;
   accepted fixes are yielded as `TrackPoint`s into `RideRecorder.record`.
3. `GuidanceViewModel` consumes `GuidanceSession` events. Progress drives the turn card;
   reroute events update `isRerouting` / `routeGeometry`; the HUD redraws the polyline and
   shows the cue.
4. On end (button, arrival, or teardown): the stream stops, the background session is
   invalidated, `setMode(.idle)`, screen-awake is released, the Live Activity ends, the ride
   is saved.

---

## 6. Error and edge handling

- **Poor GPS:** fixes failing the predicate are dropped from the track; `signal` becomes
  `weak` or `lost`; the chip appears; the last good position is retained.
- **Permission denied or restricted:** ride start is blocked with the explainer and Settings
  deep link; the plan screen continues on the fallback origin.
- **Off-route:** the reroute cue shows and the polyline follows the new route shape; if the
  reroute publisher cannot be confirmed on the simulator, the cue is gated off and the gap is
  documented rather than shipped as a silent no-op.
- **Screen lock mid-ride:** the background session keeps updates flowing; this path is
  configured but verified only on a device, and is labeled as such.
- **Backgrounding then returning:** the stream and recorder continue; the HUD reflects the
  accumulated track on return.

---

## 7. Testing approach

- **AuraCore (CI):** `SignalQuality` classification across boundary accuracies and ages; the
  fix-acceptance predicate including negative accuracy; `GuidanceViewModel` reroute and
  unavailable transitions via `ScriptedGuidanceSession`.
- **AuraKit (CI):** `LocationService` logic that does not require a live manager, exercised
  through the existing seams (`SimulatedLocationProvider` for the recorder path).
- **Simulator:** location simulation through a ride, foreground-to-background transition, a
  simulated reroute, the permission-denied explainer, and the GPS-weak chip.
- **Device-only, not claimed here:** locked-screen continuous recording. Flagged as
  configured but unverified.

TDD: pure cores and view-model transitions are written test-first. The CoreLocation and
Mapbox shells are thin and verified on the simulator.

---

## 8. Open items and risks

- **Mapbox v3 reroute publisher:** the exact publisher and its payload shape are confirmed
  during implementation against the installed SDK before the cue and polyline redraw are
  wired. If it does not surface a usable new geometry, the polyline redraw degrades to the
  reroute cue alone, documented.
- **`CLLocationUpdate.liveUpdates()` and the desk-demo path:** `SimulatedLocationProvider`
  (GPX) stays the stream for tests and the desk demo and does not show the chip or gate
  (signal always good, authorization not applicable). Under the new environment-injection
  model the simulated stream is selected by injecting a `LocationService` configured to read
  from the GPX `SimulatedLocationProvider` instead of CoreLocation (the service keeps the
  `LocationStreaming` seam internally), rather than the current `makeProvider` closure. The
  planner specifies this swap; it is an accepted limitation that the simulated path shows no
  chip or gate.
- **Background recording verification:** device-only; treated as unverified until a real ride.

---

## 9. Relationship to the roadmap

On completion, the roadmap's Wave 0 moves to Shipped (with the device-verification caveat
noted), the Wave 1 "consolidate the location layer" item is removed (done here), and the
"request Always" framing in the audit section is corrected to the When-In-Use plus background
session model chosen here.
