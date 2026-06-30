# Group Rides — SP2: Live Presence Transport (Design)

**Date:** 2026-06-30
**Status:** Approved design, revised after a 3-reviewer adversarial pass
(backend/Realtime/SQL — verified against the live `aura` project; iOS
architecture/Swift-6 concurrency — grounded in the real codebase; product/privacy/
scope). Ready for implementation plan.
**Wave:** 4, feature "Group Rides", sub-project 2 of 3

> **Revision note (2026-06-30):** Three independent reviewers audited the first
> draft. Their blocking findings — broadcasting raw speed (a data-sharing
> regression against SP1's "speed not shared" rule), a transport seam that could
> not express reconnect, a leak-prone subscribe/unsubscribe lifecycle, an undefined
> clock abstraction, and a `join_ride` TOCTOU "fix" that did not actually close the
> race — are resolved in the sections below. §13 records the resolved findings for
> traceability. This spec also **supersedes two SP1 assumptions**: SP1 named
> Realtime *Presence* for connect/stopped status (SP2 derives status from the
> position stream instead, §4), and SP1 shipped a racy `join_ride` cap that SP2
> repairs as a carried bugfix (§8d).

---

## 1. What SP2 builds

SP2 is the layer that makes riders appear on each other's maps **live** during a
ride. The product shape was fixed in the Wave 4 interview and is unchanged:

- A **named dot per rider** — position + display name.
- Each rider's **progress along the shared route** ("Alex 0.4 mi ahead").
- A **stopped / dropped** status per rider.
- Live **speed is not shared** between riders — and SP2 honors this **at the
  transport**, not just in the UI: a rider's raw speed never leaves their device
  (§2.3, §4).
- Sharing **survives backgrounding and cellular dead zones** to the extent iOS
  allows (§5 states the precise, honest guarantee); the server holds the durable
  track so reconnects heal.
- Access is **members-only**, reusing SP1's `is_ride_member` as the one authz
  primitive. Crew cap stays at **8**.

SP2 delivers the transport and the pure state model. It does **not** build UI
(SP3). It is strictly **additive** to the existing solo ride loop: if live sharing
fails, the rider's own ride recording and navigation are unaffected.

---

## 2. Core architecture: one stream, Broadcast-only

**One private Realtime channel per ride**, topic `ride:<ride_id>`, `private: true`.
Everything is carried on a single **position stream**. There is **no Presence** (§4
explains why).

### 2.1 Write path (publish)

The rider's phone calls SP1's `record_track_points(p_ride_id, p_points)` RPC on a
cadence (§6). That function — already `SECURITY DEFINER set search_path = ''`,
members-only, owned by `postgres` — does two things in one transaction:

1. Inserts the durable point(s) into `ride_track_points` (the SP1 table, the
   backfill substrate).
2. Calls `realtime.send(payload, 'position', 'ride:'||p_ride_id, true)` to fan the
   **newest point in the batch** out to the channel.

One write = durable + live. There is **no database trigger**; the RPC performs the
`realtime.send` itself, giving exact control of the payload. A batch is always
**single-writer** (the authenticated caller — `record_track_points` hardcodes
`user_id => auth.uid()`), so "newest" is unambiguous: the point with `max
recorded_at` in the array. A backlog flush (many buffered points) still emits a
single broadcast — the newest — because peers snap to current (§3).

This is **Broadcast-from-Database**: positions fan out from inside the Postgres
function, not from the client's WebSocket. The deciding reason is the background
requirement — see §5. (Verified against the live project: `record_track_points` is
owned by `postgres`, which has `rolbypassrls`, so its `INSERT INTO
realtime.messages` via `realtime.send` succeeds; `realtime.send` is schema-qualified
and safe under an empty search_path.)

**Broadcast is best-effort and silent on failure.** `realtime.send` swallows its own
errors (it raises only a Postgres `WARNING` if the send fails — e.g. no subscribers,
or the daily `realtime.messages` partition is missing). A failed broadcast does
**not** fail the RPC. This is good for "additive, never breaks the ride," but it
means **correctness of the live view rests on the snapshot RPC (§3.3), not on
broadcast delivery** (§3.4). Live deltas are an optimization on top of a
snapshot-anchored picture.

### 2.2 Read path (subscribe)

A rider viewing the live map opens **one owned subscription object** for the ride
(§7.2). On every (re)connect it **first fetches a snapshot** (latest point per
member, §3.3) to seed every dot immediately, then applies live `'position'` deltas
on top.

### 2.3 Broadcast payload — no raw speed

Each `'position'` event carries exactly:

```
{ userID, lat, lon, progressMeters, recordedAt, motionState }
```

`motionState` is a **sender-derived** enum (`moving | stopped`), computed on the
publishing device by a pure `MotionClassifier` (§7.1) from the rider's own speed and
the `stopped` thresholds. **Raw speed never crosses the wire and is never stored
server-side.** This is the literal form of the "speed is not shared" rule: peers
receive a one-bit motion state (which backs the deliberate "Alex stopped" product
feature), not the rider's instantaneous speed. `displayName` is **not** on the delta
(it would repeat on every point); it is carried from the roster/snapshot (§3.3, §4).

---

## 3. Backfill and reconnection

"Full backfill" decomposes into two independent directions that heal separately.

### 3.1 My gap → the server (durable outbox)

While a rider can't reach the network, points accumulate in a local `PointOutbox`.
When the network returns, the outbox flushes through `record_track_points` (which
accepts an array). This is independent of WebSocket state, so the durable trail
heals whether or not the live socket is up. SP1's RPC needs **no schema change** —
no new column (the `stopped` decision is sender-side, §2.3), only the durable points
it already stores.

### 3.2 What peers see of my return: snap to current

When a rider returns from a dead zone, peers' live dots **snap to the rider's
current position** the moment the newest buffered point's broadcast (or the next
snapshot re-seed) lands. The live trail is not gap-replayed. The **durable**
`ride_track_points` table always holds the true path, so the **post-ride**
summary/replay (an SP3 concern) draws the accurate trail from durable data. The live
view is only ever about "where is everyone now."

### 3.3 Reconnect / snapshot read — the correctness anchor

A new RPC seeds and re-seeds the live view:

```
ride_live_snapshot(p_ride_id uuid)
  -> rows of (user_id, display_name, lat, lon, progress_meters,
              recorded_at, motion_state)
```

- `SECURITY DEFINER set search_path = ''`, `revoke execute from public` + `grant to
  authenticated`, members-only via in-body `is_ride_member` — same pattern as every
  SP1 write API.
- Returns the **latest** `ride_track_points` row per member via `distinct on
  (user_id) ... order by user_id, recorded_at desc, ctid desc` (the `ctid`
  tiebreaker makes "latest" deterministic when two rows share a `recorded_at`).
- Joins `display_name` from the roster so one round-trip seeds names too.
- `motion_state` is derived from the stored point (or defaults to `moving` if a
  durable point predates the field) — it does **not** expose raw speed.

Called on initial join and on every reconnect to re-seed peers to latest-known
position. Because the live view only needs latest-per-member (§3.2), no gap query is
needed live.

### 3.4 Why the snapshot is load-bearing

Realtime's "Broadcast from Database" only delivers messages inserted **after** a
client has subscribed; a `realtime.send` while a viewer's socket is suspended
(backgrounded) or before anyone has joined is dropped silently. The snapshot re-seed
on every (re)connect is exactly what closes that gap. Therefore: **live deltas are
best-effort; the snapshot RPC is the source of truth for "where is everyone."** The
plan must treat broadcast delivery as an optimization, never a guarantee.

---

## 4. Status model: derived from the stream, no Presence

SP1's notes assumed Presence for connect/stopped/dropped. SP2 **deliberately drops
Presence** and derives all status from the position stream. (Supersession note: SP1
§1 listed Presence as a chosen Realtime need; this section overrides that.)

**Why not Presence.** Presence requires a live WebSocket and the client calling
`track()`. A backgrounded rider keeps sharing via DB writes while their socket is
**suspended** (§5); under Presence that socket drop fires a `leave`, so peers would
see them as **dropped** even though their position is still flowing every 5–8 s. That
false signal hits exactly the background case the product cares most about. Presence
is also documented as unfit for high-frequency updates. So SP2 uses **Broadcast
only**.

**How status is derived.** The receiver holds a `LivePresenceState` keyed by
`userID`, **seeded from the `ride_members` roster** so every member has a dot from
the start (status `awaiting` until their first point), not only riders who have
already moved:

- **Roster** (who is in the ride): SP1's `ride_members`. Display names come from the
  roster/snapshot and are carried forward; deltas (§2.3) do not repeat the name.
- **awaiting:** in the roster, no position yet.
- **riding / stopped:** from the peer's `motionState` (sender-derived, §2.3). The
  receiver does **not** re-threshold speed — it trusts the one-bit flag.
- **dropped / out of signal:** position-stream **staleness** — no new point from
  that peer for more than `droppedTimeout` (§6). Computed by `LivePresenceState.tick
  (now:)`, which must be driven on a clock cadence **independent of payload arrival**
  (so an all-silent ride still flips everyone to `dropped`).

The "dropped" tradeoff is a timeout, not an instant socket event — the **correct**
semantics for cycling, where a peer rounding a hill for five seconds should not
flicker to dropped.

**A rider who truly left vs. one in a dead zone.** `dropped` is intentionally
ambiguous ("no signal recently — dead zone, dead battery, or quietly gone"); SP3 copy
will hedge accordingly. But a rider who **explicitly** leaves or ends must not linger
as a `dropped` dot: SP1's `leave_ride` / `end_ride` already mutate `ride_members`, so
SP2 adds a **`member_left` broadcast** on the same channel from those RPCs (a tiny
`realtime.send(..., 'member_left', 'ride:'||id, true)` carrying the departed
`user_id`). Receivers remove that peer from `LivePresenceState` immediately; the next
snapshot re-seed is the backstop. This keeps the live roster honest without polling.

---

## 5. Background and lifecycle — the honest guarantee

SP2 reuses the ride's existing background-location stack (the
`CLBackgroundActivitySession` path that solo rides already use) and the **single**
existing location stream. It does **not** open a second location stream (§7.4).

**What is actually true** (the first draft over-promised a "background-capable
URLSession" that supabase-swift's RPC client does not expose; this is the corrected
statement):

- **While the app retains background execution** — which `CLBackgroundActivitySession`
  sustains for the duration of an active ride — location fixes keep arriving and
  `RideSession` keeps publishing via ordinary `record_track_points` RPCs at the
  background cadence tier (§6). Peers keep seeing the rider, because the DB broadcast
  does not need the rider's own socket. The rider's WebSocket suspends, so the rider
  is not *receiving* peer updates while backgrounded — acceptable, they are not
  looking at the map.
- **If iOS fully suspends the process** (background execution revoked), publishing
  pauses; points accumulate in `PointOutbox` and flush on resume. The rider's
  **durable trail still heals** (so the post-ride picture is complete and peers
  re-seed to the rider's true position on the rider's return), but during the
  suspension the rider's **live dot goes stale** to peers (they see `dropped` after
  `droppedTimeout`). This is the real boundary of "background sharing," and it is
  acceptable: an active ride with an active location session is the normal case, and
  the durable + snapshot path guarantees no *data* is lost.

**Foregrounding / socket drop:** the transport re-establishes the channel with
**bounded exponential backoff** internally (§7.2), and on each successful
(re)connect the session calls `ride_live_snapshot` to re-seed all peers. The
`PointOutbox` flushes independently of socket state.

---

## 6. Cadence and thresholds: one tunable config

A single `LiveShareCadence` config holds every rate and threshold so behavior is
tuned by value, never by editing logic. **Hard requirement: the design must allow
dropping the foreground cadence to ~1 s later without code surgery.**

| Field | Default | Notes |
|---|---|---|
| `foregroundInterval` | ~2–3 s | live-riding publish cadence; must be lowerable to ~1 s |
| `backgroundInterval` | ~5–8 s | battery-kinder tier while backgrounded |
| `stationaryInterval` | longer | when the rider's `motionState` is `stopped` |
| `stoppedSpeed` | near-zero | sender-side speed threshold for `stopped` |
| `stoppedDuration` | ~15–20 s | sustained low speed before flipping to `stopped` |
| `droppedTimeout` | ~30–45 s | stream silence before a peer is `dropped` |

**Cadence-tier selection is a pure function** — `LiveShareCadence.interval(for:
motionState, lifecycle:) -> Duration` — unit-tested directly, not buried in the
session's imperative code.

**Config invariant (must hold):** `droppedTimeout >= ~4–5 × backgroundInterval`, so a
backgrounded rider publishing on the slow tier never trips a false `dropped`. The
`stoppedSpeed`/`stoppedDuration` thresholds live on the **sender** (the
`MotionClassifier`); `droppedTimeout` lives on the **receiver** (`tick`). Defaults
are starting values to tune on-device; the exact numbers are not load-bearing for
correctness.

---

## 7. Swift layering (SP1's three-layer rule holds)

The load-bearing invariant from SP1 is unchanged: **`supabase-swift` lives only in
the app target**, never in `AuraCore/Package.swift`, so the hermetic `swift test` CI
job stays Supabase-free. All *logic* lives in the pure package; Supabase is confined
to the app target. Every type that crosses the `@MainActor` ↔ `nonisolated` boundary
is **`Sendable`** (§7.1/§7.2 mark them).

### 7.1 AuraCore (pure, in the SwiftPM package)

- `LivePositionPayload: Codable, Sendable` — the broadcast/snapshot wire row
  (carries `motionState`, never raw speed).
- `MotionState: Sendable` — enum `moving | stopped`.
- `MotionClassifier` — **pure, sender-side**: `(speed history, thresholds) ->
  MotionState`, applying the `stoppedSpeed`/`stoppedDuration` hysteresis on the
  publisher's continuous speed. This is where "stopped" is decided, so raw speed
  stays on-device.
- `RidePeer` — render state: `userID, displayName, coordinate, progressMeters,
  motionState, lastUpdate, status`.
- `PeerStatus` — enum `awaiting | riding | stopped | dropped`.
- `PeerStatusReducer` — **pure, receiver-side**: `(motionState, lastSeenAge,
  droppedTimeout) -> PeerStatus`. No speed scalar involved.
- `LivePresenceState` — aggregate `[UUID: RidePeer]`, **seeded from the roster**, with
  pure ops `apply(_ payload:)` (upsert one peer from a delta, name carried forward),
  `remove(userID:)` (for `member_left`), and `tick(now:)` (recompute
  staleness/dropped).
- `LiveShareCadence: Sendable` — the tunable config + the pure `interval(for:
  lifecycle:)` selector (§6).
- `PointOutbox` — buffers unsent points for backlog flush (§3.1).

### 7.2 AuraKit (the seam, beside SP1's `GroupRideBackend`)

- `TransportEvent: Sendable` — enum `.position(LivePositionPayload)`,
  `.memberLeft(UUID)`, `.connected`, `.disconnected(Error?)`. The event arm is what
  lets the session tell "peer quiet" (a `tick`/staleness condition) from "my socket
  dropped" (handled inside the transport).
- `RideLiveSubscription` — **one owned object per ride** (reference type, mirrors the
  existing `LocationStreaming` `points()`/`stop()` ownership): exposes `events:
  AsyncStream<TransportEvent>` and tears the channel down in `deinit` and via the
  stream's `onTermination` / an explicit `cancel()`. No separate `rideID`-keyed
  `unsubscribe` to leak.
- `RideSessionTransport` protocol:
  - `func liveSubscription(rideID:) -> RideLiveSubscription`
  - `func snapshot(rideID:) async throws -> [LivePositionPayload]`
  - `func publish(rideID:points:) async throws`
  - `InMemoryRideSessionTransport` fake drives `TransportEvent`s deterministically in
    tests (including injected `.disconnected`/`.connected` to exercise reconnect).
- `RideSession` — `@MainActor` coordinator, kept **thin**: it consumes the
  subscription's `events`, mutates `LivePresenceState`, on `.connected` calls
  `snapshot` to re-seed, on `.memberLeft` removes the peer, and on the **injected
  clock's** cadence both publishes (point from the coordinator handoff, §7.4) and
  calls `tick(now:)`. Reconnect/backoff lives **in the transport**, not here.
  Cadence-tier choice and status derivation are the pure AuraCore functions. The
  session owns no business logic beyond wiring.

### 7.3 Clock seam (new; none exists in the codebase today)

`RideSession` takes an injected `any Clock` (Swift's `Clock` protocol). Cadence is
driven by `clock.sleep(until:tolerance:)`; `tick(now:)` is fed `clock.now`. Tests
inject a manually-advanced test clock. **`Date()` and `Task.sleep` are forbidden
inside `RideSession`** — this is the explicit rule that makes §10's "publish cadence
selection" and "no-payloads → dropped after `droppedTimeout`" tests deterministic and
fast. (The existing `RideSessionCoordinator` hardcodes `Date()`/`Task.sleep`; SP2
does not follow that, and may optionally adopt the same clock there later — out of
scope.)

### 7.4 Location handoff (no second stream)

The existing `RideSessionCoordinator` is the **sole owner** of the single
`LocationStreaming.points()` stream (it already consumes it to feed the recorder).
`AsyncStream` is single-consumer, so `RideSession` must **not** call `points()`
itself. Instead the coordinator **pushes** each recorded point into
`RideSession.locationDidUpdate(_ point:)`, attaching the `progressMeters` and the
speed the recorder already computes (the session feeds that speed to the
`MotionClassifier`; it never recomputes speed). This is stated explicitly so the
implementer does not introduce a duplicate-stream bug that silently starves the
recorder or the publisher.

### 7.5 App target — `AuraSync` (where `supabase-swift` is allowed)

- `SupabaseRideSessionTransport` conforming to the seam: builds
  `RealtimeChannelV2` (`private: true`), maps `broadcastStream(event: "position" /
  "member_left")` into `TransportEvent`s, owns the **reconnect/backoff loop** and
  re-emits `.connected`/`.disconnected`, calls `record_track_points` for publish and
  `ride_live_snapshot` for snapshot. `nonisolated` per SP1's Swift-6
  default-MainActor rules; the Decodable wire struct is itself `nonisolated`.

---

## 8. Database changes (one migration set, pgTAP-tested)

Migrations continue the `00NN_*.sql` sequence (`0010`+) on project `aura`, applied
live via MCP and gated by the `db-tests` pgTAP CI job, exactly as SP1.

**a. `record_track_points` gains the broadcast (§2.1).** After the insert, select the
single newest point in the batch (`order by (e->>'recorded_at')::timestamptz desc
limit 1`) and `realtime.send(jsonb_build_object('userID', auth.uid(), 'lat', …,
'lon', …, 'progressMeters', …, 'recordedAt', …, 'motionState', …), 'position',
'ride:'||p_ride_id, true)`. Still `SECURITY DEFINER set search_path = ''`, still
members-only (authz unchanged). Accepts an optional `motion_state` per point; **no
`speed` column is added**. (Verified: callable from the existing DEFINER/empty-
search_path context because `postgres` bypasses RLS and `realtime.send` is
schema-qualified.)

**b. RLS on `realtime.messages` (channel authz).** A **SELECT** policy (receiving
broadcasts), `to authenticated`, with a crash-safe topic guard:

```sql
create policy "ride members read broadcast" on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and realtime.topic() like 'ride:%'
    and (select public.is_ride_member(public.ride_id_from_topic(realtime.topic())))
  );
```

`ride_id_from_topic(text) -> uuid` is a small `SECURITY DEFINER`/`immutable` helper
that returns the parsed uuid or `null` on malformed input (so a bad/foreign topic
**denies cleanly** instead of throwing `::uuid` and failing the whole channel join).
The `extension = 'broadcast'` filter scopes the policy to broadcast (not presence/
other), and the `(select …)` wrapper is the initplan-cached form. **Ops step
(non-migration):** the project's Realtime "Allow public access" must be turned
**off** so private channels are enforced; recorded on the deployment checklist with a
manual verification (subscribe as a non-member → denied).

**c. `ride_live_snapshot` (§3.3).** New `SECURITY DEFINER set search_path = ''` RPC,
`revoke execute from public` + `grant to authenticated`, members-only via in-body
`is_ride_member`, returning deterministic latest-per-member (`distinct on` + `ctid`
tiebreaker) joined to `display_name`, `motion_state` not raw speed.

**d. `join_ride` TOCTOU fix — advisory lock (carried SP1 bugfix).** The first draft's
`insert … select … where (count) < 8` does **not** close the race: at READ COMMITTED
two concurrent joiners each read `count = 7` against their own snapshot, neither sees
the other's uncommitted insert, both insert → 9 members. The fix takes a
**per-ride transaction advisory lock** before the count, serializing concurrent joins
for that ride:

```sql
perform pg_advisory_xact_lock(hashtextextended(v_ride_id::text, 0));
-- now the count-then-insert is race-free for this ride
```

The generic `joinFailed` oracle and idempotent re-join are preserved. pgTAP must test
this with **two genuinely interleaved transactions**, not a single-session "9th
rejected" (which passes against the broken version and gives false confidence). The
8-cap is a soft comfort limit, but SP1 called it "a hard, server-enforced invariant,"
so the lock makes that true.

**e. `member_left` broadcast (§4).** `leave_ride` and `end_ride` emit
`realtime.send(jsonb_build_object('userID', <departed/all>), 'member_left',
'ride:'||id, true)` so live peers prune immediately.

No SP1 tables change (no new columns).

---

## 9. Retention — closing the `realtime.messages` gap

SP1 promises server-side ride tracks are deleted within ~48 h of the ride ending,
reaped by the `pg_cron` sweep over `rides`/`ride_members`/`ride_track_points`/
`join_attempts`. **`realtime.send` writes a second copy of each broadcast — including
coordinates — into `realtime.messages`,** which Supabase partitions by day and
retains on its own schedule, **outside** the SP1 cron and **outside**
`delete_account`'s FK cascade. Left unaddressed, a parallel copy of riders'
coordinates could outlive the 48 h promise.

SP2 closes this explicitly:
- Pin the project's **Realtime message retention** to **≤ the 48 h ride-track bound**
  (Realtime settings; recorded on the deployment checklist). Supabase's built-in
  daily-partition trimming then bounds `realtime.messages` within the promise.
- The broadcast payload already minimizes exposure: `motionState`, not raw speed
  (§2.3); the durable, account-linked record of record remains `ride_track_points`,
  which the cron and cascade do cover.
- Documented limitation: `delete_account` does **not** retroactively purge already-
  broadcast rows from `realtime.messages`; the short retention window is what bounds
  them. This is acceptable given the ≤48 h cap and the coordinate-only/motion-bit
  payload, and is recorded so it is a known, bounded property rather than a surprise.

This is verified as a real mechanism: §8b's own RLS policy targets the
`realtime.messages` table because that is where `realtime.send` inserts.

---

## 10. Error handling

Group sharing is **additive** to the solo ride; failures degrade gracefully and never
break the rider's own ride.

- **Publish failure (offline / suspended):** points stay in `PointOutbox`, retried on
  the next flush. Never blocks the ride loop.
- **Broadcast send failure:** silent by design (`realtime.send` swallows it, §2.1);
  the snapshot re-seed (§3.4) is the recovery path. Never surfaced as an error.
- **Subscribe / auth failure** (removed from ride, expired JWT, public-access
  misconfig): the transport emits `.disconnected(error)`; the session surfaces a
  non-fatal "live sharing unavailable" state. Solo recording and navigation continue.
- **Stale peers:** crossing `droppedTimeout` is handled by `tick`, not an error —
  peers grey out, they do not vanish from the roster (a true leave prunes them via
  `member_left`, §4).
- **Non-member access:** rejected at the `realtime.messages` RLS gate (subscribe) and
  by in-body `is_ride_member` (RPCs).

---

## 11. Testing

- **AuraCore (hermetic `swift test`):** `MotionClassifier` hysteresis (moving↔stopped
  on the sender's speed history); `PeerStatusReducer`; `LivePresenceState` roster
  seeding, `apply` (name carried forward), `remove`, `tick` (→dropped on staleness);
  `LiveShareCadence.interval(for:lifecycle:)`; `PointOutbox` buffering/flush. Pure,
  fast, the bulk of coverage.
- **AuraKit:** `RideSession` against `InMemoryRideSessionTransport` + a **test
  clock** — publish-cadence-tier selection, applying deltas, `member_left` pruning,
  **reconnect re-seed** (fake emits `.disconnected` then `.connected`, assert a
  `snapshot` call + re-seed), outbox flush on reconnect, and **no-payloads → all peers
  `dropped` after `droppedTimeout`** by advancing the clock alone (no real time).
- **pgTAP (`db-tests` CI job):**
  - `record_track_points` inserts a `realtime.messages` row under a **member**
    identity and **not** for a non-member — asserted by selecting from
    `realtime.messages` after the call (not by trapping an error, since
    `realtime.send` swallows errors). **Test setup must ensure the current day's
    `realtime.messages` partition exists** or the insert is dropped for infra
    reasons, not logic.
  - `ride_id_from_topic` returns the uuid for `ride:<uuid>` and `null` for a
    malformed topic (proving the RLS policy denies rather than errors).
  - `ride_live_snapshot` returns deterministic latest-per-member and is members-only.
  - **Atomic join cap under concurrency:** two interleaved transactions cannot push
    membership to 9 (advisory-lock fix), plus the serial "9th rejected" and idempotent
    re-join.
  - All identity-dependent assertions use the `pg_temp` `SECURITY DEFINER`
    claims-switching helper (SP1 learning: pooled connections mishandle interleaved
    claims-switching).
- **App target:** `SupabaseRideSessionTransport` is **built** (not unit-tested) by the
  `app-build` CI job, per SP1.

---

## 12. Out of scope (SP2)

- All UI: the live map, the roster, dot rendering, "Alex 0.4 mi ahead" labels, the
  create/join-by-code flow — **SP3**.
- Post-ride accurate-trail replay (reads durable data; an SP3/summary concern).
- A true background-upload publish path (a background `URLSession` upload task to an
  Edge Function) — a larger change; §5 documents the accepted durable-outbox fallback
  instead.
- Voice / push-to-talk, friends graph, Strava export — later phases.

---

## 13. Resolved review findings (traceability)

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | Broadcasting raw `speed` breaks "speed not shared" at the transport | Sender-side `MotionClassifier`; wire carries `motionState` bit only; no speed column (§2.3, §4, §7.1) |
| 2 | Critical | `AsyncStream<payload>` seam cannot express reconnect | `TransportEvent` enum + reconnect-in-transport (§7.2) |
| 3 | Critical | `subscribe`/`unsubscribe(rideID:)` leaks under cancellation | One owned `RideLiveSubscription`, `deinit`/`onTermination` teardown (§7.2) |
| 4 | Critical | Virtual-clock testability unsupported; no Clock seam exists | Injected `any Clock`; `Date()`/`Task.sleep` forbidden in `RideSession` (§7.3) |
| 5 | Critical | `join_ride` `where count < 8` still races at READ COMMITTED | `pg_advisory_xact_lock` per ride + concurrent pgTAP (§8d, §11) |
| 6 | Important | `realtime.messages` retention outside the 48 h cron | Pin Realtime retention ≤48 h; document `delete_account` limitation (§9) |
| 7 | Important | RLS policy under-specified; raw `::uuid` parse can crash channel joins | Full policy with `extension='broadcast'` + `ride_id_from_topic` safe parse (§8b) |
| 8 | Important | Reconnect correctness implied to rest on broadcast delivery | Stated: snapshot is the anchor; deltas best-effort (§3.4) |
| 9 | Important | `displayName` only on snapshot, not deltas → nameless late peers | Roster-seeded state, name carried forward; deltas omit name by design (§2.3, §4) |
| 10 | Important | `RideSession` over-scoped; Sendable unstated | Reconnect→transport, cadence-tier pure fn, thin session, explicit `Sendable` (§7) |
| 11 | Important | Background-publish over-promised ("background URLSession") | Honest §5: publish while app has bg execution; outbox + snapshot otherwise |
| 12 | Important | Coordinator/location handoff ambiguous (single-consumer stream) | Coordinator pushes points into `RideSession.locationDidUpdate` (§7.4) |
| 13 | Important | A truly-left rider lingers as `dropped` | `member_left` broadcast from `leave_ride`/`end_ride` (§4, §8e) |
| 14 | Minor | "newest per writer" mis-framed; `realtime.send` swallows errors | Single-writer batch, `max recorded_at`; silent-send caveat (§2.1) |
| 15 | Minor | `droppedTimeout` vs `backgroundInterval` could false-trip | Config invariant `droppedTimeout ≥ ~4–5× backgroundInterval` (§6) |
