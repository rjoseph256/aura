# Group-ride lifecycle sync — synchronized start & reliable end

**Date:** 2026-07-19
**Issues:** [ROH-71](https://linear.app/rohun/issue/ROH-71) (guest skips the lobby, lands mid-ride) + [ROH-68](https://linear.app/rohun/issue/ROH-68) (host's End-for-everyone fails silently). Specced together per ROH-71's note that both need the same reconciliation primitive.
**Status:** approved in brainstorming 2026-07-19; pending adversarial spec review.

## Problem

Two lifecycle transitions in group rides bypass the codebase's "Broadcast-from-Database" discipline (DB is the source of truth; triggers broadcast changes; clients never send raw broadcasts), and both cause riders to desync:

1. **Start is host-local only.** `GroupRideSession.startRiding()` flips the host's own `phase` from `.lobby` to `.riding`. It never touches the backend and never broadcasts. A guest's `join(code:)` sets `phase = .riding` unconditionally, so guests have no lobby at all and never see the host's start. The "start together" moment the lobby is built around does not happen. (ROH-71)

2. **End is a fire-once, swallowed signal.** `end()`/`leave()` call the RPC with `try?`, discard the error, and tear down local state whether or not the server was told — a failed end is indistinguishable from a success. End-detection on the guest overloads a single `member_left` broadcast matched against the host id; a guest briefly offline at that instant never learns the ride ended, because nothing re-reads ride status afterward. Confirmed on the server: ride `8d6b46de` is still `active`, `ended_at: null`, while the host believed it ended. (ROH-68)

Both are the same missing primitive: **a ride lifecycle transition that is durable, pushed live, and re-readable on reconnect.**

## Design overview

Every lifecycle transition (started, ended) gets three legs:

- **Durable** — a column on `rides` (`started_at`, and the existing `ended_at`), written by an idempotent host-only RPC. The source of truth.
- **Pushed** — a dedicated `realtime.send` broadcast (`ride_started`, `ride_ended`) on the ride topic, for an instant transition.
- **Backstop** — the live snapshot (read on join and every reconnect) carries the ride's lifecycle, so a client that missed the broadcast reconciles on its next snapshot.

No single dropped packet can leave two riders in different phases: the broadcast makes it fast, the snapshot makes it certain.

## 1. Data model (DB / Supabase)

Migrations continue the numbered series (next is `0017`). All validated via the Supabase MCP + CI `db-tests` (pgTAP); local Docker is unusable on this machine.

### 1.1 `started_at` column

```sql
alter table public.rides add column started_at timestamptz;
```

Nullable. `null` = created but not yet riding (lobby). Non-null = riding. Monotonic and symmetric with `ended_at`. Ride-level, not per-member, so a host transfer (below) does not reset it.

### 1.2 `start_ride` RPC

```sql
create function public.start_ride(p_ride_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_host uuid;
begin
  select host_id into v_host from public.rides where id = p_ride_id;
  if v_host is null or v_host <> v_uid then raise exception 'not host'; end if;
  update public.rides
    set started_at = now()
    where id = p_ride_id and started_at is null;   -- idempotent: set once
  perform realtime.send(jsonb_build_object('startedAt', now()),
                        'ride_started', 'ride:' || p_ride_id::text, true);
end;
$$;
revoke execute on function public.start_ride(uuid) from public;
grant execute on function public.start_ride(uuid) to authenticated;
```

Host-only (mirrors `end_ride`). Idempotent via `where started_at is null`, so a double-tap or a retry does not move the timestamp. Broadcasts on the lowercase topic (`p_ride_id::text` is lowercase — matches the ROH-67 topic-case fix). The broadcast fires even on a repeat call so a guest that missed the first still gets a push; the durable column is unchanged.

> Open question for review: should the broadcast be suppressed when the `update` touched zero rows (already started)? Leaning no — an extra `ride_started` to an already-riding guest is a no-op via `reconcile`, and firing unconditionally is the simpler backstop. Reviewers: confirm.

### 1.3 `end_ride` / `leave_ride` — dedicated `ride_ended` broadcast

`end_ride` (and the host-leaves-and-ride-ends branch of `leave_ride`) additionally emits:

```sql
perform realtime.send(jsonb_build_object('endedAt', now()),
                      'ride_ended', 'ride:' || p_ride_id::text, true);
```

This retires the fragile "a `member_left` whose id equals the host means the ride ended" heuristic. `member_left` stays for genuine member departures (peer-dot pruning). Both signals can coexist during the transition; `reconcile` treats `ride_ended` as authoritative for the phase.

### 1.4 Snapshot carries lifecycle

`ride_live_snapshot` today returns latest position per member only. It gains the ride's lifecycle so the reconnect path can reconcile. Preferred shape: a companion RPC or an extra result set rather than repeating the ride row on every position. Decision: add a lightweight `ride_status(p_ride_id)` RPC returning `(status, started_at, ended_at)`, members-only, and have the client read it alongside the positions snapshot on join and every reconnect. (Keeps `ride_live_snapshot`'s row shape unchanged and its pgTAP intact.)

```sql
create function public.ride_status(p_ride_id uuid)
returns table (status text, started_at timestamptz, ended_at timestamptz)
language plpgsql security definer set search_path = '' stable as $$
begin
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  return query select r.status, r.started_at, r.ended_at from public.rides r where r.id = p_ride_id;
end;
$$;
```

### 1.5 `create_ride` / `join_ride` return lifecycle

The `GroupRideRow` those RPCs return already carries `status`. Add `started_at` and `ended_at` to the selected columns so `join_ride` lets the client decide lobby-vs-riding-vs-ended without a second round trip.

## 2. Wire / transport seam (Swift)

`TransportEvent` (AuraKit) gains two arms:

```swift
case rideStarted
case rideEnded
```

`snapshot(rideID:)` grows a lifecycle field. New return type:

```swift
public struct RideLiveSnapshot: Sendable {
    public let positions: [LivePositionPayload]
    public let lifecycle: RideLifecycleStatus   // from ride_status
}
```

`RideLiveSubscription`'s stream now yields `.rideStarted` / `.rideEnded`. `LiveBroadcastDecoder` (AuraCore) decodes the two new event names; the Supabase transport (`SupabaseRideSessionTransport`) maps them and reads `ride_status` in `snapshot`. `InMemoryRideSessionTransport` gains a settable lifecycle and `emit(.rideStarted)` / `emit(.rideEnded)` for tests.

## 3. Domain (AuraCore) — the shared reconciliation primitive

A pure, `Sendable`, unit-tested value + function that both issues call. No I/O, no actor.

```swift
public struct RideLifecycleStatus: Equatable, Sendable {
    public let startedAt: Date?
    public let endedAt: Date?
}

public enum RideLifecyclePhase: Equatable, Sendable { case lobby, riding, ended }

/// Given the authoritative ride lifecycle, what phase should this rider be in?
/// ended dominates started dominates lobby. Monotonic: never moves backward.
public func reconcilePhase(_ status: RideLifecycleStatus,
                           current: RideLifecyclePhase) -> RideLifecyclePhase
```

Rules: `endedAt != nil` → `.ended`; else `startedAt != nil` → `.riding`; else `.lobby`. Monotonic guard: never return a phase "earlier" than `current` (a late/duplicate snapshot cannot un-end or un-start a rider). `GroupRide` gains `startedAt`/`endedAt` (decoded from the extended rows).

This function is where late-join catch-up, missed-broadcast recovery, and end-reconciliation all resolve. Designed and table-tested once; ROH-68's guest-side end path is the same call.

## 4. Session state machine (`GroupRideSession`)

New guest lobby phase; `Phase` already has `.lobby`, so join simply stops forcing `.riding`.

**Join** (`join(code:)`): after decoding the route, map the returned lifecycle through `reconcilePhase(.init(startedAt:endedAt:), current: .lobby)`:
- `endedAt` set → `.ended` (joining an already-ended ride; also leave the ride server-side as today's route-unavailable path does).
- `startedAt` set → `.riding` (late-join catch-up).
- else → `.lobby`.

**Host start** (`startRiding()` becomes `func startRiding() async`): call `backend.startRide(rideID)`. On success flip host to `.riding`. On throw, stay in `.lobby` and surface a retryable start-failure (a `startFailed` flag the lobby shows as "Couldn't start — Retry"; auto-retry with backoff, RPC idempotent). **Never flip on a swallowed error.** Confirmed decision: host flip is gated on server confirm, not optimistic.

**Live handling** (`ingest`): the guest lobby runs `beginLiveSession()` too (as the host lobby already does), so it receives `ride_started`/`ride_ended` live.
- `.rideStarted` → `reconcilePhase` with `startedAt = now` → `.lobby` becomes `.riding`.
- `.rideEnded` → `.ended` + `teardownLive` (replaces the `member_left == hostID` special case; that case is removed).
- `.connected` (reconnect) and the join seed → read `ride_status`, run `reconcilePhase`. This is the tunnel / missed-broadcast backstop.

**End reliability** (`end()` / `leave()`): remove `try?`. On success → `.ended` + teardown. On throw → a retryable `endFailed` state; keep the crew chrome up (do NOT tear down), auto-retry with backoff, and only reach `.ended` after the server confirms. `end_ride`/`leave_ride` are idempotent, so retrying is safe. Confirmed decision: retry with chrome retained; no local-only fallback that could strand guests.

New/changed phases: reuse `.ended`, `.lobby`. Add lightweight retryable flags (`startFailed`, `endFailed`) rather than new terminal phases, so the underlying live session and solo HUD keep running underneath a failed end (same reasoning as the existing `.riding`/`.ended` shared branch in `GroupRideFlowView`).

## 5. UI

**Guest lobby** — parameterize `GroupLobbyView` by role (or a small `LobbyMode`):
- Host: unchanged — "Start riding" CTA (now driving the async `startRiding()`), with a "Couldn't start — Retry" inline state on failure.
- Guest: "Waiting for [host] to start…" in place of the CTA, plus the live roster, the join code, the share link (mirror + invite — every rider can recruit; newcomers join the same ride via the same code, no host hierarchy), and a Leave button.

Host name resolves from `nameMap[hostID]`.

**Host end-failure** — a non-blocking "Ending…" state that becomes "Couldn't end — Retry" on failure, crew chrome retained until the server confirms. No fake success.

`GroupRideFlowView` keeps its single `.riding`/`.ended` shared branch. The guest `.lobby` renders `GroupLobbyView(mode: .guest)`.

## 6. Correctness / edge cases

- **Late join** (started already) → `.riding` on join. Verified by `reconcilePhase`.
- **Join into ended ride** → `.ended`; leave server-side; show the ended surface.
- **Host ends while guest in lobby** (never started) → guest lobby dissolves to `.ended` via `ride_ended` broadcast, with the `ride_status` backstop if the broadcast is missed.
- **Missed `ride_started`** (guest in a tunnel at the start moment) → reconciled to `.riding` on the next reconnect snapshot.
- **Host transfer** (`leave_ride` promotes the oldest member when the host leaves without ending) → `started_at` is ride-level and untouched, so the promoted host does not reset the ride; a guest stays riding.
- **Idempotent start** — `started_at` is set once; double-tap or retry does not move it.
- **Monotonic reconcile** — a stale snapshot cannot un-start or un-end a rider.
- **`.joined` toast** (ROH-71 secondary note): verify whether a `.joined` toast fires when a guest arrives, given the guest is typically already in the host's roster seed by the time positions arrive (which suppresses it). Confirm behavior; fix only if it is genuinely swallowed. Low priority; may split to its own ticket if it needs real work.

## 7. Testing (TDD)

- **AuraCore (pure):** `reconcilePhase` table tests — every (startedAt, endedAt, current) combination, including monotonic guards and duplicate/stale inputs. `GroupRide` lifecycle decoding.
- **AuraKit (`GroupRideSession`) over in-memory fakes:** join → lobby / riding / ended by lifecycle; `.rideStarted` moves lobby→riding; `.rideEnded` tears down; reconnect snapshot reconciles a missed transition; `startRiding()` failure stays in lobby (no fake success) and retries; `end()`/`leave()` failure stays live with chrome and retries, reaches `.ended` only on confirm. Extend `InMemoryGroupRideBackend`/`InMemoryRideSessionTransport` with lifecycle + `start_ride`.
- **DB (pgTAP):** `start_ride` host-only, idempotent, broadcasts `ride_started`; `end_ride` broadcasts `ride_ended`; `ride_status` members-only and returns the lifecycle; extended `join_ride`/`create_ride` rows include `started_at`/`ended_at`.
- **App target:** guest-lobby rendering is app-target (untestable by unit tests, per the standing pattern) — keep the decision logic in AuraCore/AuraKit where it is tested, and device-verify the lobby + synchronized start + end-retry on the real phone. Two identities required (host + guest); Silver Bar is currently unavailable, so device-verify is a tail step gated on a second device.

## 8. Migration / rollout notes

- Adds columns and functions only; no destructive change. `started_at` defaults null, so existing/in-flight rides read as lobby — acceptable, as any ride created before this ships has no live clients on the new build.
- Client and DB ship together: the new `TransportEvent` arms and `ride_status` read are additive; an old client ignoring `ride_started` still reconciles via the snapshot backstop once updated. No forced-migration ordering beyond "DB migration applied before the new client relies on `start_ride`."

## Out of scope (own tickets)

- ROH-68 defect-1's deeper connectivity UX beyond retry (e.g. a persistent "ride may still be live" banner across app relaunch) — the retry + backstop here covers the reported failure; anything further is separate.
- ROH-66 (no heartbeat) — related theme (presence with no durable backstop) but distinct fix.
- The unticketed "`ride_members` row deleted on leave, so the roster forgets a departed rider" observation — matters for post-ride summaries, not for live sync; note and leave for a summary-side ticket.
