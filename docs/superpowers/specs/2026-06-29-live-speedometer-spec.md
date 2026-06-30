# Live Speedometer Spec

**Status:** draft → self-reviewed
**Date:** 2026-06-29
**Branch:** `claude/live-speedometer`

## Problem

On the first real on-device ride, the HUD speed dial lagged badly: the rider was
surging to 16–22 mph (verified against external video) while the dial stayed pinned
near 14–16 and barely moved. GPS tracking itself was accurate.

Root cause (two compounding defects):

1. **The dial shows the ride *average*, not current speed.** `SpeedRail`'s hero is
   bound to `stats.averageSpeedMetersPerSecond`
   (`Aura/Sources/Ride/SpeedRail.swift:23`), which is defined as cumulative
   `distance / movingTime` over the whole ride so far
   (`AuraCore/Sources/AuraCore/Stats/RideStatsCalculator.swift:43`). A cumulative
   average converges after a few minutes and is unresponsive to short surges — exactly
   the reported symptom. The in-code comment already calls it "the live (slow-moving
   average) value."
2. **Instantaneous speed is never captured.** `LocationService.ingest()` builds each
   `TrackPoint` from coordinate + altitude + timestamp and discards
   `CLLocation.speed` (`AuraCore/Sources/AuraKit/LocationService.swift:31`).
   `TrackPoint` has no speed field. The only speeds in the system are derived after
   the fact by diffing GPS positions.

The Dynamic Island / Live Activity shares defect (1): its `speedMetersPerSecond` is
also fed from `stats.averageSpeedMetersPerSecond`
(`Aura/Sources/LiveActivity/RideLiveActivityController.swift:78`).

## Goal

Make the HUD speed dial — and the Live Activity speed — read the rider's **current
speed**, lightly smoothed so it tracks real surges within a second or two without
digit jitter (Garmin/Wahoo behavior, the user's chosen option).

## Approach

Source current speed from `CLLocation.speed` (Doppler-derived instantaneous velocity,
m/s; `-1` when invalid), with a position-delta fallback so simulated/GPX rides and
fixes without a Doppler speed still animate. Smooth with a time-aware exponential
moving average (EMA). Surface a `currentSpeedMetersPerSecond` off the coordinator and
bind the dial to it.

### Data model — `TrackPoint` gains an optional Doppler speed

Add `public var speedMetersPerSecond: Double?` to `TrackPoint`
(`AuraCore/Sources/AuraCore/Geo/TrackPoint.swift`).

- **Optional on purpose.** GPX playback, the HealthKit route reconstruction
  (`WorkoutRouteLocations`), and any fix lacking a valid Doppler speed leave it nil.
- **Persistence is Codable-safe, no schema migration.** The track persists as a single
  JSON-encoded `[TrackPoint]` blob in `RideRecord.trackData`
  (`RideMapper.swift:13`). Swift's synthesized `Decodable` uses `decodeIfPresent` for
  optionals, so existing rides (encoded without the key) decode with
  `speedMetersPerSecond == nil`. No `RideSchemaV3`, no `RideMigrationPlan` change. New
  rides encode the key going forward.
- `init` gains the parameter with a `nil` default so every existing call site
  (`WorkoutRouteLocations`, GPX decode, tests) compiles unchanged.

### Capture — `LocationService.ingest()`

Set `speedMetersPerSecond` from `location.speed` when valid:

```swift
let doppler = location.speed >= 0 ? location.speed : nil
return TrackPoint(coordinate: ..., elevation: location.altitude,
                  timestamp: location.timestamp, speedMetersPerSecond: doppler)
```

`CLLocation.speed` is `-1` when the platform can't compute it; guard `>= 0`. (We do
not gate on `speedAccuracy`; on bikes the accuracy field is often unreported and
gating would needlessly drop good Doppler readings. Out-of-band values are tamed by
smoothing + the existing GPS-accuracy gate in `GPSFix.isAcceptable`.)

### Smoothing — pure `SpeedSmoother` (AuraCore)

A pure, deterministic, unit-tested value type in AuraCore (so it builds/tests on the
macOS CI host, no CoreLocation):

```swift
public struct SpeedSmoother {
    public init(timeConstant: TimeInterval = 2.5)
    /// Feed one instantaneous sample (m/s, >= 0) at its timestamp; returns the new
    /// smoothed speed. Time-aware EMA: alpha = 1 - exp(-dt / timeConstant), so it is
    /// robust to irregular GPS intervals. First sample seeds the value directly.
    public mutating func add(_ speed: Double, at time: Date) -> Double
    public var value: Double { get }   // current smoothed value, 0 before first sample
    public mutating func reset()
}
```

- `timeConstant` 2.5 s gives "reacts within ~1–2 s, no jitter."
- Negative samples are ignored (caller already guards, but defend anyway).
- Non-monotonic / zero `dt` between samples: treat `dt <= 0` as a direct replace (no
  divide-by-zero, no NaN).

### Per-point instantaneous speed — pure helper

The recorder needs an instantaneous speed for *every* incoming point, including
GPX/sim points with no Doppler value. Compute:

```
instantaneous = point.speedMetersPerSecond            // Doppler when present
             ?? (prev map: Geo.distance(prev, point) / dt, dt > 0)   // position-delta fallback
             ?? 0                                       // first point / zero dt
```

Reuse `Geo.distance`. This keeps the simulated free-ride demo and device fixes without
Doppler animating the dial. Expose as a small pure function so it is unit-tested.

### Live current speed — `RideRecorder` + coordinator

`RideRecorder` (`AuraCore/Sources/AuraKit/RideRecorder.swift`) already processes every
point in `record(_:)` and is `@Observable @MainActor`. Add:

- `public private(set) var currentSpeedMetersPerSecond: Double = 0`
- a private `SpeedSmoother` and a reference to the previous point for the fallback.
- `start(at:)` resets the smoother and `currentSpeedMetersPerSecond = 0`.
- `record(_:)` computes the per-point instantaneous speed, feeds the smoother, and
  publishes `currentSpeedMetersPerSecond`.

`RideSessionCoordinator` exposes a passthrough, mirroring `stats`/`track`:

```swift
public var currentSpeedMetersPerSecond: Double { recorder.currentSpeedMetersPerSecond }
```

### Bind the dial — `SpeedRail`

`SpeedRail` gains `let currentSpeedMetersPerSecond: Double` and its hero uses it:

```swift
SpeedReadout(value: fmt.speedValue(currentSpeedMetersPerSecond), unit: ...)
```

Both call sites pass it:
- `RideHUDView.swift:21` (free ride, `.full`)
- `NavigateHUDView.swift:80` (navigate, `.speedOnly`)

The accessibility value also switches to the current speed (update
`SpeedRailVoice.speedValue` to take a current-speed value, or pass the formatted
string). The `.full` stats trio (distance/time/elevation) is unchanged. Average and
max speed remain the summary's job (`RideSummaryView` "mph top" stays as-is).

### Live Activity parity — seam gains current speed

So the Dynamic Island agrees with the HUD:

- `RideActivityControlling.update(stats:maneuver:)` →
  `update(stats:currentSpeedMetersPerSecond:maneuver:)`
  (`RideSessionSeams.swift:17`).
- `RideSessionCoordinator.pushActivityUpdate()` passes
  `recorder.currentSpeedMetersPerSecond`.
- `RideLiveActivityController.update(...)` maps that to
  `ContentState.speedMetersPerSecond` instead of `stats.averageSpeedMetersPerSecond`
  (`RideLiveActivityController.swift:78`).
- Any test double for `RideActivityControlling` updates to the new signature.

## Out of scope

- Changing `RideStats` (average/max stay correct and are still shown on the summary).
- A new persisted schema version (the optional field needs none).
- Backfilling Doppler speed onto already-recorded rides (they keep nil; summary stats
  are unaffected).
- HealthKit route speed: `WorkoutRouteLocations` may later pass the stored Doppler
  speed instead of `-1`, but that is a separate, optional enhancement.

## Global constraints

- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` on app + extension targets.
- AuraCore and AuraKit must build and test on the macOS CI host — no CoreLocation in
  pure logic; `SpeedSmoother` and the instantaneous-speed helper live in AuraCore.
- Mono-lime `AuraTheme` unchanged; this is a value rebind, not a visual redesign.
- Existing `TrackPoint` call sites compile unchanged (defaulted `nil` parameter).
- `cd AuraCore && swift test` stays green; CI's 3 jobs (AuraCore tests, app build with
  `CODE_SIGNING_ALLOWED=NO`, SwiftLint `--strict`) stay green.

## Acceptance

1. **Unit (macOS CI):**
   - `SpeedSmoother`: first sample seeds; EMA converges toward a step input over its
     time constant; reacts within ~2 samples; `dt <= 0` replaces without NaN; negative
     ignored; `reset()` zeroes.
   - instantaneous-speed helper: Doppler value used when present; position-delta used
     when nil; 0 on first point / zero dt.
   - `TrackPoint` round-trips through `JSONEncoder`/`Decoder`; **a legacy JSON blob
     without the key decodes with `speedMetersPerSecond == nil`** (persistence-safety
     regression test).
   - `LocationService.ingest()`: `location.speed = 8.0` → point carries `8.0`;
     `location.speed = -1` → nil.
   - `RideRecorder`: feeding points with Doppler speeds updates
     `currentSpeedMetersPerSecond`; a stop (speed 0) decays it toward 0; `start()`
     resets it.
2. **Device (the actual fix):** on a real ride, the dial tracks real speed — a surge
   to ~20 mph shows ~18–20 within a second or two and settles back when coasting —
   instead of sitting at the converged average. The Dynamic Island speed matches.
