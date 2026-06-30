# Group Rides — SP2: Live Presence Transport (Design)

**Date:** 2026-06-30
**Status:** Approved design (product+architecture interview). Pending adversarial
review pass, then implementation plan.
**Wave:** 4, feature "Group Rides", sub-project 2 of 3

> SP1 (backend + identity) shipped on `main` at `ae49ac9`: Supabase project `aura`
> (ref `wyofhmufnttiqyjkrbxi`), migrations `0001`–`0009`, the `GroupRideBackend`
> seam, pure AuraCore models, Sign in with Apple. SP2 builds the **live transport**
> on top of that foundation. SP3 (the group-ride UI) consumes what SP2 produces.

---

## 1. What SP2 builds

SP2 is the layer that makes riders appear on each other's maps **live** during a
ride. The product shape was fixed in the Wave 4 interview and is unchanged:

- A **named dot per rider** — position + display name.
- Each rider's **progress along the shared route** ("Alex 0.4 mi ahead").
- A **stopped / dropped** status per rider.
- Live **speed is not shared** between riders.
- Sharing **survives backgrounding and cellular dead zones**; the server holds the
  durable track so reconnects heal.
- Access is **members-only**, reusing SP1's `is_ride_member` as the one authz
  primitive. Crew cap stays at **8**.

SP2 delivers the transport and the pure state model. It does **not** build UI
(SP3) and does not change the product scope. It is strictly **additive** to the
existing solo ride loop: if live sharing fails, the rider's own ride recording and
navigation are unaffected.

---

## 2. Core architecture: one stream, Broadcast-only

**One private Realtime channel per ride**, topic `ride:<ride_id>`, `private: true`.
Everything is carried on a single **position stream**. There is **no Presence** (§4
explains why).

### 2.1 Write path (publish)

The rider's phone calls SP1's `record_track_points(p_ride_id, p_points)` RPC on a
cadence (§6). That function — already `SECURITY DEFINER`, members-only — does two
things in one transaction:

1. Inserts the durable point(s) into `ride_track_points` (the SP1 table, the
   backfill substrate).
2. Calls `realtime.send(payload, 'position', 'ride:'||p_ride_id, true)` to fan the
   **newest** point out to the channel.

One write = durable + live. There is **no database trigger**; the RPC performs the
`realtime.send` itself, giving exact control of the broadcast payload. A backlog
flush (many buffered points) still emits a single broadcast — the newest point —
because peers snap to current (§3).

This is **Broadcast-from-Database**: positions fan out from inside the Postgres
function, not from the client's WebSocket. The deciding reason is the background
requirement — see §5.

### 2.2 Read path (subscribe)

A rider viewing the live map subscribes to `ride:<id>`. On every (re)subscribe it
**first fetches a snapshot** (latest point per member, §3.3) to seed every dot
immediately, then applies live `'position'` deltas on top.

### 2.3 Broadcast payload

Each `'position'` event carries exactly:

```
{ userID, lat, lon, progressMeters, recordedAt, speed }
```

`speed` is the rider's own measured speed (SP1's `InstantaneousSpeed`: Doppler when
present, else position-delta). It is the only signal needed to derive status (§4).
No other fields are broadcast; live speed is **not surfaced to riders** as a UI
value — it is consumed solely to compute riding/stopped status, honoring the
"no shared speed" product rule.

---

## 3. Backfill and reconnection

"Full backfill" decomposes into two independent directions that heal separately.

### 3.1 My gap → the server (durable outbox)

While a rider can't reach the network, points accumulate in a local `PointOutbox`.
When the network returns, the outbox flushes through `record_track_points` (which
already accepts an array). This is independent of WebSocket state, so the durable
trail heals whether or not the live socket is up. SP1's RPC needs no interface
change beyond accepting the optional `speed` field per point.

### 3.2 What peers see of my return: snap to current

When a rider returns from a dead zone, peers' live dots **snap to the rider's
current position** — the moment the newest buffered point lands and is broadcast.
The live trail is not gap-replayed. The **durable** `ride_track_points` table always
holds the true path, so the **post-ride** summary/replay (an SP3 concern) draws the
accurate trail from durable data. The live view is only ever about "where is
everyone now."

### 3.3 Reconnect / snapshot read

A new `SECURITY DEFINER` RPC seeds and re-seeds the live view:

```
ride_live_snapshot(p_ride_id uuid) -> rows of (userID, displayName, lat, lon,
                                                progressMeters, recordedAt, speed)
```

It returns the **latest** `ride_track_points` row per member, joined to
`display_name`, members-only via in-body `is_ride_member`. It is called on initial
join and on every reconnect to re-seed peers to latest-known position. Because the
live view only needs latest-per-member (§3.2), no gap query is needed live.

---

## 4. Status model: derived from the stream, no Presence

SP1's notes assumed Presence for connect/stopped/dropped. SP2 **deliberately drops
Presence** and derives all status from the position stream.

**Why not Presence.** Presence requires a live WebSocket and the client calling
`track()`. But a backgrounded rider keeps sharing via DB writes while their socket
is **suspended** (§5). Under Presence that rider's socket drop fires a `leave`
event, so peers would see them as **dropped** even though their position is still
flowing every 5–8s through the DB broadcast. That false signal hits exactly the
background case the product cares most about. Presence is also documented as unfit
for high-frequency updates. So SP2 uses **Broadcast only**.

**How status is derived** (all in a pure receiver-side reducer):

- **Roster** (who is in the ride): from SP1's `ride_members`. Unchanged.
- **Live / connected:** the peer has sent a position recently.
- **Stopped:** from the peer's own reported `speed` — near-zero, sustained for
  ~15–20 s → `stopped`. The value is self-reported (the rider's own speed); the
  threshold logic lives receiver-side in a pure function.
- **Dropped / out of signal:** position-stream **staleness** — no new point from
  that peer for more than ~30–45 s. Robust to dead zones and backgrounding alike,
  because it is measured on the stream, which never depends on a live socket.

The tradeoff is that "dropped" is a timeout, not an instant socket-close event. For
a cycling group where dead zones are routine, a timeout is the **correct**
semantics: a peer rounding a hill for five seconds should not flicker to "dropped."

All thresholds (`stoppedSpeed`, `stoppedDuration`, `droppedTimeout`) are config
values (§6), not magic constants.

---

## 5. Background and lifecycle

SP2 reuses the ride's existing background-location stack (the
`CLBackgroundActivitySession` path that solo rides already use). The group session
is layered on top of the existing ride; it does not introduce a second location
stream.

- **Backgrounded:** location fixes keep arriving; `RideSession` keeps publishing via
  `record_track_points` over a **background-capable URLSession** at the background
  cadence tier (§6). Peers keep seeing the rider, because the DB broadcast does not
  need the rider's socket. The rider's own WebSocket suspends, so the rider is not
  *receiving* peer updates while backgrounded — acceptable, since they are not
  looking at the map.
- **Foregrounding / socket drop:** re-establish the channel with **bounded
  exponential backoff**, then immediately call `ride_live_snapshot` to re-seed all
  peers (§3.3). The `PointOutbox` flushes independently.

This is the concrete reason §2.1 chose Broadcast-from-Database over client-direct
broadcast: it is the only path that keeps a backgrounded rider visible to peers.

---

## 6. Cadence and thresholds: one tunable config

A single config type holds every rate and threshold so behavior is tuned by value,
never by editing logic. **Hard requirement: the design must allow dropping the
foreground cadence to ~1 s later without code surgery.**

| Field | Default | Notes |
|---|---|---|
| `foregroundInterval` | ~2–3 s | live-riding publish cadence; must be lowerable to ~1 s |
| `backgroundInterval` | ~5–8 s | battery-kinder tier while backgrounded |
| `stationaryInterval` | longer | when the rider is stopped (reduce redundant writes) |
| `stoppedSpeed` | near-zero | speed threshold for "stopped" |
| `stoppedDuration` | ~15–20 s | sustained low speed before flipping to `stopped` |
| `droppedTimeout` | ~30–45 s | stream silence before a peer is `dropped` |

Defaults are starting values to tune on-device; the exact numbers are not load-
bearing for correctness. The reducer and session read them from the config.

---

## 7. Swift layering (SP1's three-layer rule holds)

The load-bearing invariant from SP1 is unchanged: **`supabase-swift` lives only in
the app target**, never in `AuraCore/Package.swift`, so the hermetic `swift test` CI
job stays Supabase-free. All *logic* lives in the pure package; Supabase is confined
to the app target.

### 7.1 AuraCore (pure, in the SwiftPM package)

- `LivePositionPayload` — Codable wire model (the broadcast/snapshot row).
- `RidePeer` — render state: `userID, displayName, coordinate, progressMeters,
  speed, lastUpdate, status`.
- `PeerStatus` — enum `riding | stopped | dropped`.
- `PeerStatusReducer` — **pure function**: `(speed history, last-seen age,
  thresholds) → PeerStatus`. The whole status model, unit-tested in isolation.
- `LivePresenceState` — aggregate `[UUID: RidePeer]` with pure ops `apply(_
  payload:)` (upsert one peer from a delta) and `tick(now:)` (recompute
  staleness/dropped). Seeded from a snapshot array.
- `LiveShareCadence` — the tunable config from §6.
- `PointOutbox` — buffers unsent points for backlog flush (§3.1).

### 7.2 AuraKit (the seam, beside SP1's `GroupRideBackend`)

- `RideSessionTransport` protocol:
  - `snapshot(rideID:) async throws -> [LivePositionPayload]`
  - `publish(rideID:points:) async throws`
  - `subscribe(rideID:) -> AsyncStream<LivePositionPayload>`
  - `unsubscribe(rideID:)`
- `InMemoryRideSessionTransport` — fake for tests.
- `RideSession` — `@MainActor` coordinator owning a `LivePresenceState`: drives
  publish off the location stream at the cadence, applies incoming payloads through
  the reducer, runs the staleness `tick` on an injected clock, manages
  reconnect/backfill. Injected with the transport, a clock, and the location source,
  so it is fully testable with the fake + a virtual clock and no network. It stays
  thin — all logic delegates to the pure AuraCore pieces.

### 7.3 App target — `AuraSync` (where `supabase-swift` is allowed)

- `SupabaseRideSessionTransport` conforming to the seam: manages the
  `RealtimeChannelV2` lifecycle (subscribe/unsubscribe, `private: true`), maps
  `'position'` events into `LivePositionPayload`, calls `record_track_points` for
  publish, calls `ride_live_snapshot` for snapshot. `nonisolated` per SP1's Swift-6
  default-MainActor rules (a Decodable wire struct used from `nonisolated` methods
  is itself `nonisolated`).

---

## 8. Database changes (one migration set, pgTAP-tested)

Migrations continue the `00NN_*.sql` sequence (`0010`+) on project `aura`, applied
live via MCP and gated by the `db-tests` pgTAP CI job, exactly as SP1.

**a. `record_track_points` gains the broadcast (§2.1).** After the insert, compute
the newest point per writer in the batch and `realtime.send(jsonb_build_object(...),
'position', 'ride:'||p_ride_id, true)`. Still `SECURITY DEFINER set search_path =
''`, still members-only (authz unchanged). Accepts an optional `speed` field per
point.

**b. RLS on `realtime.messages` (§2, channel authz).** A policy granting
authenticated clients SELECT (subscribe/receive) on a topic only when
`is_ride_member()` holds for the ride UUID parsed out of `realtime.topic()` (topic
format `ride:<uuid>` → `split_part` + cast). The single gate for channel access,
reusing SP1's `is_ride_member`. **Ops step:** the project's Realtime "Allow public
access" setting must be turned **off** so private channels are enforced — recorded
as a deployment step, not a migration.

**c. `ride_live_snapshot` (§3.3).** New `SECURITY DEFINER set search_path = ''` RPC
returning latest `ride_track_points` row per member joined to `display_name`,
members-only via in-body `is_ride_member`. `revoke execute from public` + `grant to
authenticated`, like every SP1 write API.

**d. `join_ride` TOCTOU fix (carried from SP1).** Replace the check-then-insert with
an atomic guard so the cap is enforced inside the single insert statement (e.g.
`insert into ride_members (...) select ... where (select count(*) from
ride_members where ride_id = v_ride) < 8`), preserving the generic `joinFailed`
oracle. The 8-cap is a soft comfort limit, not a security boundary, but the race is
a real correctness gap and this is the natural moment to close it.

No SP1 tables change beyond the optional `speed` field flowing through
`record_track_points`.

---

## 9. Error handling

Group sharing is **additive** to the solo ride; failures degrade gracefully and
never break the rider's own ride.

- **Publish failure (offline):** points stay in the `PointOutbox`, retried on the
  next flush. Never blocks the ride loop.
- **Subscribe / auth failure** (removed from ride, expired JWT, public-access
  misconfig): surface a non-fatal "live sharing unavailable" state. Solo recording
  and navigation continue.
- **Stale peers:** crossing the `droppedTimeout` is handled by the `tick`, not an
  error — peers grey out, they do not vanish from the roster.
- **Non-member access:** rejected at the `realtime.messages` RLS gate (subscribe)
  and by in-body `is_ride_member` (RPCs).

---

## 10. Testing

- **AuraCore (hermetic `swift test`):** `PeerStatusReducer` transitions
  (riding↔stopped, →dropped on staleness), `LivePresenceState.apply`/`tick`,
  `LiveShareCadence`, `PointOutbox` buffering/flush. Pure, fast, the bulk of
  coverage.
- **AuraKit:** `RideSession` against `InMemoryRideSessionTransport` + a virtual
  clock — publish cadence selection, applying deltas, reconnect re-seed, outbox
  flush on reconnect.
- **pgTAP (`db-tests` CI job):** `record_track_points` inserts a `realtime.messages`
  row under a member identity and **not** for a non-member; `ride_live_snapshot`
  returns latest-per-member and is members-only; atomic join cap holds at 8 with a
  9th rejected. Validated via the `pg_temp` `SECURITY DEFINER` helper pattern (SP1
  learning: pooled connections mishandle interleaved claims-switching).
- **App target:** the Supabase conformer is **built** (not unit-tested) by the
  `app-build` CI job, per SP1.

---

## 11. Out of scope (SP2)

- All UI: the live map, the roster, dot rendering, "Alex 0.4 mi ahead" labels, the
  create/join-by-code flow — these are **SP3**.
- Post-ride accurate-trail replay (reads durable data; an SP3/summary concern).
- Voice / push-to-talk, friends graph, Strava export — later phases.

---

## 12. Open questions for the reviewers

1. **`realtime.topic()` UUID parse** — confirm the topic→uuid extraction and the
   `realtime.messages` policy form against the current Supabase Realtime authz docs
   (cast safety, `to authenticated`, `(select is_ride_member(...))` initplan form).
2. **`record_track_points` calling `realtime.send`** — confirm `realtime.send` is
   callable from a `SECURITY DEFINER set search_path = ''` function (schema-qualified
   `realtime.send`) and that the batch→newest reduction is correct.
3. **Background URLSession + `supabase-swift`** — confirm the publish path can use a
   background-capable session, or that foreground-only publish is an acceptable
   first cut with the durable outbox covering gaps.
