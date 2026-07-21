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

> **Reconciled after adversarial review.** The interpolator is driven by each fix's
> **`recordedAt`** (the payload timestamp, already stored as `RidePeer.lastUpdate`), **not**
> by view wall-clock arrival time. `recordedAt` is sender-truthful, ~monotonic, and the exact
> basis presence/`droppedTimeout` already use — so snap, duration, and the ROH-66 boundary all
> stay coherent, and out-of-order/duplicate/heartbeat/unchanged fixes are filtered by one
> `recordedAt` guard instead of five ad-hoc ones. Wall-clock is used only to *start* a tween;
> its *size* comes from `recordedAt` spacing.

### 3.1 Model: chase-to-target, linear-normal / ease-late

On each new fix, tween the *rendered* position from where the dot currently is → the new fix,
over a duration equal to the observed fix spacing (§3.4), with **linear** timing — a
constant-speed rider must read as constant glide, not decelerate-into-every-fix (uniform
ease-out manufactures a stop-and-go ripple at the fix cadence). "Ease to a stop on a
late/last packet" is delivered by **clamp-and-hold**: when a segment runs past its duration
with no new fix, the position clamps at the last fix and holds — it never freezes mid-glide
and never extrapolates/overshoots. (If, on device, the hard velocity-drop at a genuinely late
packet reads badly, an overdue ease-out tail is the documented follow-up — see §7 — but the
default is linear, chosen for constant-speed fidelity.)

Inherent latency: like *any* interpolation-not-extrapolation model (buffer or chase), the dot
reaches fix N ≈ when fix N+1 arrives, so peer dots trail true position by ~one fix interval
(the rider's own `Puck2D` stays live). Accepted — chase-to-target is chosen for minimal state
and pure-testability, not for latency.

### 3.2 `PeerInterpolator` (new, pure, AuraCore) — one per peer

A value type holding the active tween and the last fix's timestamp. All time is **injected**.

State: `from, to: Coordinate`, `startWall: Date` (tween start, wall-clock), `duration:
TimeInterval` (from `recordedAt` spacing), `fromBearing, toBearing: Double?`,
`lastRecordedAt: Date`, `lastGap: TimeInterval`, `settled: Bool`.

API (all `now` = wall-clock render/commit time; `recordedAt` = fix timestamp):

- `mutating func commit(fix: Coordinate, recordedAt: Date, now: Date)`:
  1. **First fix** (`lastRecordedAt == nil`): `from = to = fix`, `duration = 0`,
     `lastRecordedAt = recordedAt`; appear in place. Return.
  2. **Stale/dup/unchanged guard:** if `recordedAt <= lastRecordedAt`, **return unchanged**
     (drops reordered older fixes and the many `onChange(of: peers)` firings caused by a
     *different* peer moving or by a `status`/`progress`-only change — see §3.6). A heartbeat
     that republishes the same point advances `recordedAt` but has zero distance → step 4
     gives it `duration = 0`, so it never drives the clock.
  3. `gap = recordedAt - lastRecordedAt`; `newFrom = position(at: now)` (freeze current point).
  4. Decide **snap** (§3.3). Snap → `from = to = fix`, `duration = 0`. Coincident
     (`distance(newFrom→fix) ≈ 0`) → `from = to = fix`, `duration = 0` (no idle animation).
     Else → `from = newFrom`, `to = fix`, `duration = clamp(gap)` (§3.4), `startWall = now`,
     `fromBearing = bearing(at: now)`, `toBearing = heading(newFrom→fix)`.
  5. `lastRecordedAt = recordedAt`; `lastGap = gap`.
- `func position(at now: Date) -> Coordinate` — `t = duration>0 ? clamp((now-startWall)/duration,0,1) : 1`;
  `lerp(from, to, curve(t))` where `curve` = **linear** while `t ≤ 1`; the *view* applies
  ease-out decay only when a segment is overdue (no commit past `duration`). Planar lerp on
  lat/lon — correct at the sub-100 m deltas between fixes; the large-gap case is snapped.
- `func bearing(at now: Date) -> Double?` — **shortest-arc** angular lerp `fromBearing→toBearing`
  over `t` (must handle the 0/360 seam: 350→10 yields +20, not −340). Holds last heading when
  `toBearing == nil` (coincident/stopped) so the pointer never spins to a random direction; nil
  only before the first real segment.
- `func isActive(at now: Date) -> Bool` — `duration > 0 && now - startWall < duration`.

### 3.3 Snap (don't glide across a gap) — keyed on `recordedAt`

`commit` snaps instead of tweening when **either**, using the `recordedAt` `gap`:

- **Silence:** `gap > snapSilenceThreshold` (= `droppedTimeout`, 40s). A peer who went silent
  long enough to be `.dropped` and then reappears **jumps**; a dead-zone gap is never glided
  across. Because both this and `.dropped` read `recordedAt`, they trip on the same event (§6).
- **Implausible speed:** `distance(from→fix) / gap > maxPlausibleSpeed` (~25 m/s). Uses the
  *sender-truthful* `gap`, so batched broadcasts arriving 0.1 s apart (arrival-delta ≈ 0)
  **do not** false-snap normal motion — the denominator is the real fix spacing.

Thresholds are defaulted constructor params (tests drive them; app wires from `LiveShareCadence`).

### 3.4 Duration = observed fix spacing (no EWMA lag)

`duration = clamp(gap, minInterval ≈ 0.5s, maxInterval ≈ 8s)` — the **last observed
`recordedAt` gap**, used directly. This adapts *instantly* to a cadence change (6 s→2 s on
foregrounding shortens the very next tween; an EWMA would stay high and make the dot chase at
a fraction of real speed). Floor stops a lunge on a tiny gap; ceiling caps a long gap (beyond
it we snap anyway).

### 3.5 Frame clock

`TimelineView(.animation(minimumInterval: 1/30, paused:))` wraps the `Map { }` content. Each
frame reads interpolated **geographic coordinate** + bearing per visible peer and feeds them to
`MapViewAnnotation(coordinate:)` / `PeerDotView`.

- **Why geographic, not a view-space offset:** the HUD map follows heading, so a point offset
  would skew as the map rotates — interpolated lat/lon is the only correct anchor.
- **`paused`** is false while **any tween is active OR (any peer is `.riding` and not Reduce
  Motion)** — the second clause keeps the liveness **pulse** running for a present-but-stationary
  rider (its pulse must not freeze just because they stopped moving). Under RM the pulse clause
  drops (no pulse), so the clock runs only while a tween is active — RM still glides, just without
  pulse or pointer spin. In practice a peer is `.riding` for most of a ride, so the clock runs
  continuously then and idles only in the lobby / after everyone stops; the `GroupRideSession`
  1 Hz tick re-evaluates the body each second, so `paused` is re-read promptly when the last
  rider settles (bounded ≤1 s of extra ticking, not indefinite).
- **Settle:** linear `position(at:)` clamps to the exact target for `t ≥ 1`, so a completed tween
  already rests on the fix — no separate settle-frame bookkeeping needed.
- **Per-frame cost — hoist everything derived, not just the route split.** All of these are
  computed **once per peer-set change** into `@State`, never inside the 30fps closure:
  `RouteSplit.splitIndex` (memoise on `track`/`selfProgress`), `leaderID` (O(n) max-scan),
  `GroupMapDots.visiblePeers` (filter+cap), `PeerPalette.assign` (order-dependent — must never
  recompute mid-render), disambiguated monograms (§4.5), and `nameTag`/overlap decisions (§4.4).
  The 30fps closure then only rebuilds ≤7 `MapViewAnnotation`s (value types Mapbox diffs
  cheaply). `id: \.userID` keeps annotation identity stable.
- **Gesture/viewport fallback (not just a checkbox).** If re-evaluating `Map { }` at 30fps
  fights the `$viewport` binding or user pan/zoom/rotate on device, fall back to a lighter
  driver: a small `@Observable` display-tick published at 30fps **only while `anyActive`**
  (a `Task` loop with injected sleep), read by the annotations, leaving the rest of the Map
  body out of the per-frame path. Decided during the build from on-device behaviour; the pure
  interpolation math is identical either way.

### 3.6 Where interpolation state lives — and the commit trigger

A **view-local** `@State private var interpolators: PeerInterpolators` (a small struct over
`[UUID: PeerInterpolator]` with `commit(peers:now:)`, `display(at:)`, `anyActive(at:)`,
prune-on-leave). **Not** in `GroupRideSession` (per-frame state there would widen observation
and repaint the whole HUD).

- **Commit is per-peer and coordinate-guarded.** `onChange(of: peers)` fires on *any* field of
  *any* peer (`RidePeer` is whole-struct `Equatable`: a `status`/`progress`/`motion` change on
  peer A re-delivers the whole array). `commit(peers:now:)` therefore calls each peer's
  interpolator, and the §3.2 step-2 `recordedAt` guard makes it a **no-op for any peer whose
  fix hasn't advanced** — so peer A moving never resets peer B's tween/`lastGap`, and the
  `.dropped` status-flip at 40 s (a field change with the *same* `recordedAt`) never resets the
  silence clock. This one guard is what makes snap-on-silence and ROH-66 forward-compat actually
  hold (§6).
- Both hosts share a single extracted `PeerAnnotations` sub-view (TimelineView + interpolators +
  memoised derivations live in one place). Replaces the old `previousPeerCoordinates` bookkeeping
  (the interpolator now owns bearing).

---

## 4. ROH-72 — distinct identity + legible heading

> **Reconciled after adversarial review.** Identity is carried by **three redundant channels**
> (hue **and** a disambiguated monogram **and** — as reinforcement — a pointer), so it survives
> colour-blindness and status changes. Status is carried by **high-area, glanceable** signals
> (opacity + a small glyph badge + pulse-presence), **not** four ~2 pt ring-dash patterns.
> Amber and lime are reserved (they already mean warning/route), never rider hues.

### 4.1 Two independent axes: identity (who) ⟂ status (state)

Today one channel (disc fill) carries status, so per-rider identity has nowhere to go. Separate
them, and critically **do not let a status treatment destroy the identity hue**:

**Identity (constant for a rider all ride, robust to CVD):**
- **Hue** — stable per-rider fill from a curated palette (§4.2). Primary, but never the *only*
  identity cue.
- **Monogram** — a disambiguated 1–2-char label (§4.5) so two riders who share a first initial
  are still distinct *without* relying on colour. This is the direct fix for the literal
  reported case (two close riders, same first letter).

**Status (glanceable, high-area — reads in <1 s while pedalling):**
- `.riding` — full-opacity hue disc, subtle pulse (clock-driven, §4.6), **heading pointer** shown.
- `.stopped` — **full hue kept** (identity preserved), pulse off, a small **pause glyph** badge.
  "Paused at the café."
- `.dropped` — hue at reduced opacity (**ghost**) + a **no-signal glyph** badge, pulse off, no
  pointer. "Lost them."
- `.awaiting` — hollow (hue stroke, no fill). "In the ride, not moving yet."

Status distinctions ride on **opacity + a shape glyph + pulse-presence** (all high-area /
glanceable), not on stroke-dash geometry. The rider's hue and monogram are unchanged across all
four states, so identity never collapses into status. Self is unchanged (Mapbox `Puck2D`).

### 4.2 Stable per-rider colour — `PeerPalette` (new, pure, AuraCore)

`PeerPalette.assign(userIDs: [UUID]) -> [UUID: Int]` returns a **palette index** (not a `Color`;
AuraCore stays UI-free), mapped app-side to `AuraTheme.riderPalette[index]`.

- **Stable across rides:** `index = hash(userID) % paletteCount` (a rider keeps their colour).
- **Distinct within a ride:** deterministic de-collision — iterate userIDs sorted; if a hash
  slot is taken, probe to the next free slot. Common case is hash-stable; only real collisions
  perturb. ≤7 peers with ≥8 entries → always a free slot; > paletteCount wraps gracefully.
- Pure, fully unit-testable (stability, determinism, no within-ride dupes, overflow wrap).

**The palette (`AuraPalette` RGB tokens guarded by the existing `WCAGContrast`/ΔE tests, surfaced
as `AuraTheme.riderPalette`):** a **small** curated set (start at **4–6**, matching the modal
2–4-rider ride) of tones that read as one Aura family on dark terrain. **Hard constraints, in the
spec, not deferred:** (a) **lime/mint and amber are excluded** — lime is the route/accent, amber
is `.warning`/`.stopped`, so reusing either would collide two meanings on one colour; (b) every
pair must clear a **ΔE distinctness bar at 22 pt** *and* remain distinguishable under
**deuteranopia/protanopia** (simulated), since ~8 % of male riders are red-green CVD; (c) hold
contrast on the terrain style incl. Increase-Contrast. Because identity is *also* carried by the
monogram (§4.5), colour can be restrained (Aura-quiet) without being the sole load-bearer. Exact
hues are tuned at build time with `impeccable`, but must pass (a)–(c) as an acceptance gate.

### 4.3 Directional marker — pointing dot with an upright head

The marker is directional (per PO), but the identity head stays **upright and legible** (the
adversarial review showed a whole-marker teardrop that rotates while its monogram counter-
rotates is a fidgety mess at 22 pt). Design: a **round identity head** (hue fill + monogram +
status treatment), **upright, non-rotating**, with an **integrated heading pointer** (a bold,
dark-**outlined**, opaque tail/apex) that rotates around the head to show bearing — echoing the
self-puck's heading arrow. So the *marker* is intrinsically directional, but only the *pointer*
rotates; the monogram never spins.

- **Rotation** = `interpolator.bearing(at:)`, an explicit per-frame value (§3.5), **deadbanded**:
  no re-render under ~10° change and suppressed below a min speed, so a near-stationary or GPS-
  noisy rider's pointer doesn't jitter.
- **Degrade, don't swap:** with no bearing (stopped/awaiting/dropped) the pointer **retracts to a
  plain disc** via a morphing `@Animatable` "pointiness" (0…1) and/or ternary *modifiers* on a
  **single** persistent view — never `if/else` swapping two roots (which resets pulse state).
- Contrast: the pointer's dark outline + full opacity fixes the original "invisible cone" via
  size + contrast, independent of the (dark) map behind it.

### 4.4 Overlap handling — declutter (spread discs) + de-occluded tags

Real group spacing is tight (drafting riders sit ~5–30 m apart), so overlap must be handled
directly, not only worked around by colour. **In scope this pass** (PO pulled geometric
spreading in):

- **Screen-space declutter.** The app projects each visible peer's interpolated coordinate to a
  screen point (Mapbox `point(for:)`), and a **pure** `ClusterDeclutter.resolve(points:radius:)
  -> [UUID: Offset]` helper detects clusters (points within `radius`) and returns a **deterministic
  radial spread offset** per dot (evenly-spaced around the cluster centroid, ordered by `userID`
  so it's stable). The offset is applied as an **animated `.offset`** on the annotation *view*.
  Screen-space is correct here (unlike position, §3.5) because this is a deliberate *visual*
  nudge, not a location claim — the anchor coordinate stays the true fix.
- **No jitter.** Declutter uses **two-radius hysteresis** (a pair links when < `enterRadius`, and a
  previously-clustered pair stays linked until > `leaveRadius ≈ 1.5·enterRadius`); the prior
  membership is passed *in* so the helper stays pure. Offset changes also animate, so dots don't
  pop as riders drift near the threshold. `ClusterDeclutter` is unit-tested (two-dot spread,
  even spacing, no-overlap → zero offset, stable ordering, hysteresis hold). It reads the live
  interpolated points, so it is the one derivation computed per frame — bounded and cheap
  (O(k²), k ≤ 7); everything else is hoisted to the peer-set change (§3.5).
- **Distinct hue + monogram** still carry identity (top disc's colour + label differ even mid-
  spread and for CVD riders), z-order is deterministic `userID` order.
- **Name tags** attach to the *spread* dot positions and use the same cluster result — leader
  always tagged, plus clustered peers. Because each tag rides above its already-spread dot, the
  radial spread de-occludes the tags too; no separate tag-stacking pass is needed.

Coupling to interpolation is bounded: declutter reads the already-projected interpolated points
(no new geographic math) and its hysteresis keeps it stable while dots glide.

### 4.5 Disambiguated monogram — `RiderMonogram` (new, pure, AuraCore)

`RiderMonogram.assign(names: [UUID: String]) -> [UUID: String]`: normally the first grapheme
(today's behaviour), but when two riders in the ride share a first initial it lengthens *only the
colliding ones* to the shortest distinguishing form (first + last initial, else first two
letters), deterministically. Colour-independent, so it disambiguates for CVD riders and when discs
overlap. Pure, unit-tested (unique initials unchanged; collisions widen minimally; stable order).

### 4.6 Reduce Motion — glide, don't snap

Under Reduce Motion the dots **still glide** — a 22 pt dot sliding across the map is not a
vestibular trigger, and a *snap* is a harsher motion event than a smooth translate. RM suppresses
only the **pulse** and continuous **pointer rotation**, keeping a gentle **linear** position tween.
Concretely: the frame clock still runs while a tween is active (§3.5); the pulse is clock-driven so
it simply isn't emitted under RM; and the heading pointer **snaps to the 8-point compass (45°
steps)** rather than rotating continuously — direction stays readable without a spinning element.
This gives RM riders the ROH-69 glide instead of withholding it.

The pulse is driven by the **frame-clock phase** (a function of `context.date`), not `@State` +
`.onAppear` — so it survives status/identity morphs on the persistent marker view (never stranded
by a one-shot `.onAppear`) and is naturally absent when the clock is paused or RM is on.

### 4.7 Annotation budget

`GroupMapDots.visiblePeers` takes `maxDots` (default **7**, matching ≤8-rider rides) and caps
**leader-preserving** (always keep the leader, then fill the remaining slots in the existing
deterministic order), with a doc note + one-line log if exceeded. Bounds the §3.5 per-frame cost
against a runaway roster. (Overflow only occurs for a broken roster > 8; refined "nearest" selection
is unnecessary at that size.)

---

## 5. Files touched

**AuraCore (pure, new — with tests):**
- `PeerInterpolator.swift` — `recordedAt`-keyed tween: commit-guard, snap, duration, linear
  position, shortest-arc bearing (§3.2–3.4).
- `PeerPalette.swift` — stable, de-colliding index assignment (§4.2).
- `RiderMonogram.swift` — collision-widening monogram assignment (§4.5).
- `GroupMapDots.swift` — leader-preserving `maxDots` cap (§4.7).
- `ClusterDeclutter.swift` — pure screen-space cluster detection + radial spread + tag-stacking
  offsets, with hysteresis (§4.4).
- (Reuse `PeerBearing`, `Coordinate`, `LiveShareCadence`.)

**AuraCore tests:** `PeerInterpolatorTests` (first-fix appear-in-place, stale/dup/unchanged
guard no-ops, snap-on-silence via `recordedAt` gap, no false-snap on bunched arrivals, linear
position, 0/360 seam bearing, coincident→no idle activity), `PeerPaletteTests`,
`RiderMonogramTests`, `ClusterDeclutterTests` (spread geometry, hysteresis, stable ordering),
extended `GroupMapDotsTests`.

**App target:**
- New `PeerAnnotations` sub-view — owns the TimelineView clock (+ the display-tick fallback,
  §3.5), `@State` interpolators, screen-space projection → `ClusterDeclutter`, and **all**
  memoised per-set derivations (route split, leader, visible peers, palette, monograms). Shared
  by both hosts.
- `PeerDotView` — identity(hue+monogram)/status(opacity+glyph+pulse) encoding + upright-head
  directional marker with a rotating outlined pointer (§4.1, §4.3); clock-driven pulse (§4.6).
- `AuraTheme` / `AuraPalette` — add rider palette tokens (lime/amber excluded) + `riderPalette`;
  ΔE/CVD-gated.
- `NavigateHUDView`, `RideMapView` — swap the inline peer `ForEvery` for `PeerAnnotations`; drop
  `previousPeerCoordinates`.

**No transport, schema, presence-derivation, or cadence changes.** `LivePresenceState.apply` is
**not** modified (reorder/stale handling lives in the render-only interpolator, keeping presence
semantics — and the ROH-66 boundary — untouched). Solo path unaffected (`peers` empty →
`anyActive` false → clock paused, zero new work).

---

## 6. ROH-66 boundary (explicit)

We **do not** build the heartbeat, change when `.stopped`/`.dropped` fire, or add a keepalive.
Coherence holds because interpolation and presence are now keyed on the **same clock**
(`recordedAt`):

- **Late-packet easing** just holds the dot at its last target (no extrapolation).
- **Snap-on-silence** compares the **`recordedAt` gap** to the *existing* `droppedTimeout` (40s).
  Presence's `.dropped` uses `now − recordedAt` against the same 40s; both trip on the same
  event, so a re-appearing dropped rider both *renders as* dropped and *snaps* rather than
  gliding across the gap. (The earlier arrival-time design broke this — see the reconciliation
  note in §3.)
- **Status treatments** (§4.1) give `.stopped` vs `.dropped` visibly distinct dots using the
  **existing** enum — delivering ROH-66's "keep 'waiting at the café' distinct from 'lost them'"
  value visually, without touching presence semantics.
- **Forward-compatible with heartbeats:** a heartbeat republishes the last point with a *fresh*
  `recordedAt` but the **same coordinate**. The §3.2 commit sees distance ≈ 0 → `duration = 0`
  (no movement, no idle animation), and because `lastRecordedAt` only advances on the guard, the
  dot simply holds. A real move after re-acquire still snaps if the `recordedAt` gap or implied
  speed is implausible. No rework required — and, crucially, the coordinate-guard (§3.6) is what
  makes this true; without it, heartbeats/dropped-flips would reset the silence clock and
  structurally disable snap-on-silence.

---

## 7. Risks & device-verification

- **TimelineView wrapping `Map`** must not recreate the map or drop viewport/gestures — Map view
  identity stays stable, only content updates. **Verify on device**; if it fights pan/zoom/rotate,
  use the §3.5 display-tick fallback (defined, not just a checkbox).
- **30fps body re-eval** — all derived work is hoisted (§3.5), leaving ≤7 annotations per frame;
  **verify no hitching** on a real ride (Release build, Instruments SwiftUI lanes if needed).
- **Directional marker legibility** — the rotating outlined pointer with an upright head +
  deadband is the reconciliation of "directional dot" (PO) with "don't spin a 22 pt marker"
  (review). **On-device is the arbiter**; documented fallback is a bolder static-disc + outlined
  cone if the pointer still reads as fidgety.
- **Palette ΔE + CVD + on-map contrast** is a **blocking acceptance gate** (§4.2), not a nicety —
  simulate deuteranopia/protanopia on the actual terrain style; the monogram (§4.5) is the
  colour-independent backstop.
- **Planar lerp** — correct at sub-100 m deltas; snap covers the large-gap case.
- **Motion feel** — position is linear (constant-speed fidelity). Two watch-items on device:
  the hard velocity-drop when a genuinely *late* packet clamps to a stop (follow-up: an overdue
  ease-out tail); and speed variation from using the raw `recordedAt` gap as duration under
  timestamp jitter (follow-up: light duration smoothing). Neither blocks; both are tunable.
- **Screen projection is required, not optional** — `ClusterDeclutter` is inert without real
  Mapbox `point(for:)` projection, so the build must wire it (via `MapReader`/`MapProxy`); the
  degraded no-projection state is a fallback of last resort, not the acceptance target.
- **Acceptance is a two-phone ride** (§1): dots glide, two riders instantly tell-apart-able even
  when close and sharing a first initial, heading obvious. **Reduce Motion re-verified** — dots
  still *glide* (linear), only pulse + pointer-rotation suppressed.

## 8. Out of scope

ROH-66 heartbeat & presence-semantics changes; ROH-16 peer-focus tap/framing; any wire/schema
change. (Geometric declutter is now **in** scope — §4.4.)
