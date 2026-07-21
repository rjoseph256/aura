# Group-ride peer "feel" pass — smooth motion + distinct identity

**Issues:** ROH-69 (peer dots jump instead of gliding) + ROH-72 (riders hard to tell
apart; heading invisible). Specced together because they share one rendering path
(`PeerDotView`, the two map hosts, `PeerBearing`) and interact: interpolation stabilises
the bearing that the identity/heading work makes legible.

**Boundary with ROH-66 (heartbeat):** out of scope to build. This pass must only stay
*coherent* with the `.stopped` (18s motion) / `.dropped` (40s silence) states ROH-66
owns — see §6.

**Date:** 2026-07-20. **Branch:** `claude/group-ride-peer-dots-1dd30f` (combined).

---

## 1. Problem & goal

On a real two-rider ride (2026-07-19) tracking was accurate but the *feel* was wrong:

- **ROH-69:** positions arrive as discrete broadcasts (`foregroundInterval` 2s /
  `backgroundInterval` 6s) and are applied straight to `MapViewAnnotation(coordinate:)`,
  so each dot **teleports** once per broadcast. The bearing cone, derived from consecutive
  fixes, steps in the same lurches.
- **ROH-72:** every peer dot is the same shape/size/colour (`AuraTheme.accent` for
  `.riding`), differing only by one initial — two close riders become a muddle, two riders
  who share a first initial are indistinguishable. And the heading cone (10×16pt @55%
  opacity, accent-on-dark, beside a pulse) is effectively invisible.

**Goal:** peer dots **glide** between fixes, and riders are **instantly distinguishable**
with a **legible heading**, without regressing the solo path, the annotation budget, or
Reduce Motion.

**Acceptance (device-first):** a real two-phone ride where (a) dots glide smoothly instead
of hopping, (b) you can tell the two riders apart at a glance even when close and even if
their names share a first letter, and (c) each rider's heading is obvious.

---

## 2. Current architecture (as-built)

```
SupabaseRideLiveSubscription (app)  --TransportEvent-->  RideSession.ingest (AuraKit)
   → LivePresenceState.apply (AuraCore, pure)  → RidePeer{coord,status,motion,lastUpdate}
GroupRideSession (@Observable, @MainActor)  snapshots peers[] on each ingest + a 1 Hz ticker
   → NavigateHUDView / RideMapView  (Map { ForEvery(visiblePeers) { MapViewAnnotation → PeerDotView } })
```

- **No per-frame clock exists** (no `TimelineView`, no `CADisplayLink`). Peers repaint only
  when the `peers` array changes (~every 2s) or on the 1 Hz tick.
- **Bearing** is derived at render time in each view from `@State previousPeerCoordinates`
  (updated in `.onChange(of: peers)`) → `PeerBearing.heading` (pure, AuraCore).
- **`RidePeer`** (AuraCore): `userID, displayName, coordinate?, progressMeters?,
  motionState?, lastUpdate?, status`. No stored bearing.
- **`PeerStatus`** (AuraCore): `.awaiting/.riding/.stopped/.dropped`, derived by
  `PeerStatusReducer` from `motionState` + silence vs `droppedTimeout` (40s).
- **`LiveShareCadence`** (AuraCore): `foregroundInterval` 2s, `backgroundInterval` 6s,
  `stationaryInterval` 15s, `stoppedDuration` 18s, `droppedTimeout` 40s.
- **`GroupMapDots.visiblePeers`** (AuraCore): `peers.filter { !self && coordinate != nil }`.
  **No count cap today** — rides are ≤8 riders server-side, so it's inherently ≤7 dots.
- **`PeerDotView`** (app): 22pt disc (fill = status colour), a `Triangle` cone, an
  RM-aware pulse ring, a leader-only name tag.

**Design principle honoured:** all math/logic lives in **pure AuraCore value types**
(unit-tested); the app target holds only SwiftUI + transport. New interpolation and palette
logic go in AuraCore next to `PeerBearing`/`PeerStatusReducer`.

---

## 3. ROH-69 — smooth interpolation

### 3.1 Model: chase-to-target with eased arrival (not render-delay buffer)

On each new fix, tween the *rendered* position from where the dot currently is → the new
fix, over an interval-aware duration, easing out so a late packet **arrives and holds**
(ease to a stop), never extrapolating past the last fix. This matches the issue's stated
direction ("interpolate over roughly the expected inter-update interval so the dot arrives
just as the next fix lands"), is the simplest thing to make **pure and deterministic**, and
adds no render latency. (A render-delay/buffer model is smoother under jitter but renders
~1 interval in the past and carries more state — rejected as over-engineered for ≤7 dots at
bike speed.)

### 3.2 `PeerInterpolator` (new, pure, AuraCore) — one per peer

A value type holding the active tween and the arrival-cadence estimate. Time is **injected**
(`now: Date`), never read internally — same discipline as `RideSession`.

State: `from: Coordinate`, `to: Coordinate`, `startTime: Date`, `duration: TimeInterval`,
`fromBearing: Double?`, `toBearing: Double?`, `lastArrival: Date`, `arrivalEWMA:
TimeInterval`, `snapped: Bool`.

API:

- `mutating func commit(fix: Coordinate, at now: Date)` — called when a new fix arrives:
  1. `elapsedSinceArrival = now - lastArrival`; update `arrivalEWMA` (EWMA, α≈0.4),
     clamp to `[minInterval, maxInterval]` (see §3.4).
  2. `newFrom = position(at: now)` (freeze the current rendered point as the tween origin).
  3. Decide **snap** (§3.3). If snap: `from = to = fix`, `duration = 0`, `snapped = true`,
     bearings jump. Else: `from = newFrom`, `to = fix`, `startTime = now`,
     `duration = arrivalEWMA`, `fromBearing = current bearing`,
     `toBearing = heading(newFrom → fix)` (nil if coincident → hold last).
  4. `lastArrival = now`.
- `func position(at now: Date) -> Coordinate` — `t = clamp((now-startTime)/duration, 0, 1)`
  (t=1 when duration 0); `lerp(from, to, easeOut(t))`. Lerp is planar on lat/lon
  (fine at the sub-100m deltas between fixes; documented). Clamped → never overshoots.
- `func bearing(at now: Date) -> Double?` — shortest-arc angular lerp from `fromBearing`
  → `toBearing` over the same `t`; holds last known when `toBearing == nil` (stopped) so the
  pointer never spins to a random direction. nil only until the first real segment exists.
- `func isActive(at now: Date) -> Bool` — `now - startTime < duration` (a tween is running).
  Drives the frame-clock pause (§3.5).

`easeOut`: `1 - pow(1 - t, 2)` (quadratic) — decelerates into the target so an on-time fix
reads as continuous motion and a late fix reads as slowing to a stop.

### 3.3 Snap (don't glide across a gap)

`commit` snaps instead of tweening when **either**:

- **Silence:** `elapsedSinceArrival > snapSilenceThreshold` — aligned to `droppedTimeout`
  (40s). A peer who went `.dropped` and reappears jumps to their new position rather than
  sliding across the dead interval. (§6 explains why this stays coherent with ROH-66.)
- **Implausible speed:** `distance(from→fix) / elapsedSinceArrival > maxPlausibleSpeed`
  (~25 m/s ≈ 90 km/h, generous for cycling + GPS noise). Catches a big jump inside a short
  window (GPS teleport / re-acquire).

Both thresholds are constructor parameters (defaulted), so tests drive them and the app wires
them from `LiveShareCadence`.

### 3.4 Interval-aware duration

Duration = EWMA of observed inter-arrival Δt, **not** a hardcoded 2s — so it self-adapts when
a rider backgrounds (6s) or goes stationary (15s cadence) without the receiver needing to
know the sender's lifecycle. Clamped to `[minInterval ≈ 0.5s, maxInterval ≈ 8s]`: the floor
stops a burst of near-simultaneous fixes from making the dot lunge; the ceiling stops one
long gap from making the dot crawl for minutes (the 246s desk-gap case) — beyond the ceiling
we're in snap territory anyway. Seeded to `foregroundInterval` (2s) for a peer's first tween.

### 3.5 Frame clock

`TimelineView(.animation(minimumInterval: 1/30, paused:))` wraps the `Map { }` content.
Each frame reads `interpolator.position(at: context.date)` / `.bearing(at:)` for every
visible peer and feeds the interpolated **geographic coordinate** to
`MapViewAnnotation(coordinate:)` and the interpolated bearing to `PeerDotView`.

- **Why geographic, not a view-space offset:** the HUD map follows heading
  (`.followPuck(bearing: .heading)`), so a point offset would skew as the map rotates. The
  interpolated lat/lon is the only correct anchor.
- **`paused` = `reduceMotion || noPeerActive`** where
  `noPeerActive = !peers.contains { interp[$0].isActive(at: now) }`. When the last tween
  settles the clock stops; a new fix mutates `@State` via `.onChange(of: peers)`, re-evaluates
  the body, flips `paused` false, and TimelineView resumes. Zero idle cost when nobody moves
  and zero added cost under Reduce Motion.
- **Per-frame cost:** the only heavy non-peer MapContent is `RouteSplit.splitIndex` (a scan
  over the growing track). **Memoise** it into `@State` updated in
  `.onChange(of: track)`/`.onChange(of: selfProgress)` so a 30fps body re-eval only rebuilds
  the ≤7 peer annotations (value types Mapbox diffs cheaply), not the split. `id: \.userID`
  keeps annotation identity stable across frames.

### 3.6 Where interpolation state lives

A **view-local** `@State private var interpolators: PeerInterpolators` (a small struct
wrapping `[UUID: PeerInterpolator]` with `commit(peers:at:)`, `positions(at:)`,
`anyActive(at:)`, and prune-on-leave). **Not** in `GroupRideSession` — putting per-frame
state in the heavy `@Observable` session would widen its observation scope and repaint the
whole HUD. Both hosts (`NavigateHUDView`, `RideMapView`) get the same wiring; extract a
shared `PeerAnnotations` sub-view so the TimelineView + interpolation lives in one place, not
copy-pasted. This replaces the existing `previousPeerCoordinates` bearing bookkeeping (the
interpolator now owns bearing).

---

## 4. ROH-72 — distinct identity + legible heading

### 4.1 Two-channel encoding (identity ⟂ status)

Today one channel (disc fill) carries status, which is why per-rider colour has nowhere to
go. Split them:

| Channel | Carries | Encoding |
|---|---|---|
| **Disc fill (hue)** | **rider identity** | stable per-rider colour from a curated *muted-terrain* palette |
| **Ring + saturation + pulse + pointer** | **status** | see below |

Status treatments (all keep the rider's hue so identity survives):

- `.riding` — full-strength hue fill, **pulsing** ring in-hue, **heading pointer** shown.
- `.stopped` — hue fill **dimmed/desaturated**, **static** ring (no pulse), no pointer.
  Visibly "paused at the café," distinct from dropped.
- `.dropped` — hue drained toward grey at low opacity ("ghost"), **dashed static** ring, no
  pulse, no pointer. Reads as "lost signal."
- `.awaiting` — **hollow** (hue stroke, no fill), dotted ring. "In the ride, not yet moving."

Self is unchanged (drawn as the Mapbox `Puck2D`, never a peer dot).

### 4.2 Stable per-rider colour — `PeerPalette` (new, pure, AuraCore)

`PeerPalette.assign(userIDs: [UUID]) -> [UUID: Int]` returns a **palette index** (not a
`Color` — AuraCore stays UI-free), consumed by the app which maps index →
`AuraTheme.riderPalette[index]`.

- **Stable across rides:** primary assignment hashes `userID` → `index = hash % paletteCount`
  (deterministic; a rider keeps their colour ride to ride).
- **Distinct within a ride:** a deterministic de-collision pass — iterate userIDs in sorted
  order; if a hash index is already taken, probe to the next free slot. So the common
  (no-collision) case is hash-stable, and only genuine collisions perturb, deterministically.
  With ≤7 peers and ≥8 palette entries there is always a free slot.
- Pure and fully unit-testable (stability, determinism, no within-ride dupes, > paletteCount
  peers degrade gracefully by wrapping).

**The palette itself** (muted terrain hues, added as pure `AuraPalette` RGB tokens so the
existing `WCAGContrast` tests guard them, then surfaced as `AuraTheme.riderPalette: [Color]`):
lime/mint stays reserved for the route line & accent to avoid confusion; rider hues are a
curated set of desaturated, earthy tones that read as one Aura family against dark terrain
(e.g. amber, teal, clay/terracotta, slate-violet, moss, dusty-blue, rust). **Exact hues +
the pointer geometry are a design task for the build**, driven by `impeccable` + Aura design
judgment and checked for mutual distinguishability and on-map contrast (incl. Increase
Contrast). Count ≈ 8–10.

### 4.3 Directional-dot marker (heading intrinsic to the shape)

Replace the separate faint cone: the marker itself points. A rounded "nav teardrop / kite" —
a circular body (per-rider hue fill + centered initial + status ring) with a pointed apex in
the heading direction, echoing the self-puck's heading arrow so the visual language is
consistent.

- **Rotation** = `interpolator.bearing(at:)`, applied as an explicit per-frame
  `.rotationEffect` value (driven by the §3.5 clock, angular-lerped) — smooth, and testable,
  rather than relying on SwiftUI implicit animation. The **initial/text counter-rotates** so
  it stays upright while the silhouette points.
- **Degradation without identity loss:** when there's no bearing (stopped/awaiting/dropped),
  the point **retracts to a plain disc**. This is one marker view whose "pointiness"
  (0…1) and rotation are driven values — a morphing `@Animatable` shape and/or ternary
  *modifiers* on a **single** view, never `if/else` swapping two root views (which would
  reset the pulse `@State` and restart the animation every status change — an identity trap
  the SwiftUI-performance skill flags).
- Contrast: the pointer/silhouette carries a thin dark outline so it reads on any terrain,
  fixing the original "invisible cone" complaint via size + contrast + opacity.

### 4.4 Overlap handling — colour + name tags (geometric spreading deferred)

Scope decision (confirmed with PO): distinct colours + initials + a proximity-aware name tag
+ stable z-order. **No geometric spider/cluster spreading this pass** — that needs live
screen-space projection each frame and interacts poorly with interpolation; it becomes its
own follow-up ticket, and we log-note the deferral.

- **Name tags:** extend `GroupMapDots` with
  `nameTagIDs(peers:leaderID:proximityMeters:) -> Set<UUID>` (pure) — leader always tagged,
  **plus** any peer within `proximityMeters` (≈60m) of another peer, so a clump gets labelled
  and spread-out riders stay clean. `showsNameTag` becomes membership in that set.
- **Z-order:** render `visiblePeers` in the existing deterministic `userID` order so the same
  dot is consistently on top (no flicker-fighting between overlapping dots).

### 4.5 Annotation budget

Add a defensive cap: `GroupMapDots.visiblePeers` takes `maxDots` (default **7**, matching
≤8-rider rides) and `.prefix`es after the filter, with a doc note + a one-line log if ever
exceeded. Bounds the per-frame cost of §3.5 regardless of a runaway roster.

---

## 5. Files touched

**AuraCore (pure, new — with tests):**
- `PeerInterpolator.swift` — the tween + cadence estimator (§3.2–3.4).
- `PeerPalette.swift` — stable, de-colliding index assignment (§4.2).
- `GroupMapDots.swift` — add `nameTagIDs(...)` + `maxDots` cap (§4.4–4.5).
- (Reuse `PeerBearing`, `Coordinate`, `LiveShareCadence`.)

**AuraCore tests:** `PeerInterpolatorTests`, `PeerPaletteTests`, extend `GroupMapDotsTests`.

**App target:**
- New `PeerAnnotations` sub-view — owns the TimelineView clock + `@State` interpolators +
  memoised route split, shared by both hosts.
- `PeerDotView` — two-channel identity/status encoding + directional morphing marker (§4.1,
  §4.3).
- `AuraTheme` / `AuraPalette` — add the rider palette tokens + `riderPalette` array.
- `NavigateHUDView`, `RideMapView` — swap the inline peer `ForEvery` for `PeerAnnotations`;
  drop `previousPeerCoordinates`.

**No transport, schema, presence-derivation, or cadence changes.** Solo path unaffected
(`peers` empty → TimelineView paused, zero new work).

---

## 6. ROH-66 boundary (explicit)

We **do not** build the heartbeat, change when `.stopped`/`.dropped` fire, or add a keepalive.
Coherence is maintained purely on the render side:

- **Late-packet easing** just holds the dot at its last target (no extrapolation) — nothing to
  do with presence firing.
- **Snap-on-silence** reads the *existing* `droppedTimeout` (40s) numeric boundary as its
  threshold. It does not change that boundary; it just refuses to glide across it.
- **Status treatments** (§4.1) give `.stopped` vs `.dropped` visibly distinct dots using the
  **existing** enum — delivering ROH-66's "keep 'waiting at the café' distinct from 'lost
  them'" value on the *visual* side without touching presence semantics.
- **Forward-compatible:** when ROH-66 later republishes the last point as a heartbeat, those
  carry the **same** coordinate → zero movement → no snap, the dot simply holds; a real move
  after re-acquire still snaps if implausible. No rework required.

---

## 7. Risks & device-verification

- **TimelineView wrapping `Map`** must not recreate the map or drop viewport/gestures — Map
  view identity stays stable (same call site), only content updates. **Verify on device.**
- **30fps body re-eval** over Mapbox content — memoised route split keeps it to ≤7 dots;
  **verify no hitching** on a real ride (Release build).
- **Planar lerp** between fixes — correct at sub-100m deltas; snap covers the large-gap case.
- **Palette distinguishability + on-map contrast** (incl. Increase Contrast) — design-review
  the hues on the actual terrain style before shipping.
- **Acceptance is a two-phone ride** (§1): glide + tell-apart + heading obvious. Reduce Motion
  path re-verified (snaps, no clock).

## 8. Out of scope

Geometric collision spreading (spider/cluster); ROH-66 heartbeat & presence-semantics
changes; ROH-16 peer-focus tap; peer-focus framing; any wire/schema change.
