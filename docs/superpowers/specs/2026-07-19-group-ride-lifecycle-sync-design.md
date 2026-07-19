# Group-ride lifecycle sync — synchronized start & reliable end

**Date:** 2026-07-19
**Issues:** [ROH-71](https://linear.app/rohun/issue/ROH-71) (guest skips the lobby, lands mid-ride) + [ROH-68](https://linear.app/rohun/issue/ROH-68) (host's End-for-everyone fails silently). Specced together per ROH-71's note that both need the same reconciliation primitive.
**Status:** v2 — reconciled after a three-reviewer adversarial spec review (correctness/races, DB/security, UX/state-machine). Pending PO review, then writing-plans.

## Problem

Two lifecycle transitions in group rides bypass the codebase's "Broadcast-from-Database" discipline (DB is the source of truth; triggers broadcast changes; clients never send raw broadcasts), and both desync riders:

1. **Start is host-local only.** `GroupRideSession.startRiding()` flips the host's own `phase` from `.lobby` to `.riding`; it never touches the backend and never broadcasts. `join(code:)` sets `phase = .riding` unconditionally, so guests have no lobby and never see the host's start. The "start together" moment doesn't happen. (ROH-71)

2. **End is a fire-once, swallowed signal.** `end()`/`leave()` call the RPC with `try?`, discard the error, and tear down local state whether or not the server was told. End-detection on the guest overloads a single `member_left` broadcast matched against the host id; a guest briefly offline at that instant never learns the ride ended. Confirmed on the server: ride `8d6b46de` is still `active`, `ended_at: null`, while the host believed it ended. (ROH-68)

Both are the same missing primitive: **a ride lifecycle transition that is durable, pushed live, and re-readable on reconnect.**

## Design overview

Every lifecycle transition (started, ended) gets three legs:

- **Durable** — a column on `rides` (`started_at`; `ended_at` already exists), written by an idempotent host-only RPC. The source of truth.
- **Pushed** — a dedicated `realtime.send` broadcast (`ride_started`, `ride_ended`) on the ride topic, for an instant transition. **Optimistic:** only ever moves a rider forward.
- **Backstop** — a durable `ride_status` read on join, on every reconnect, and on app-foreground. **Authoritative:** it can correct an optimistic transition that never became durable (see the reconcile model below).

The durable column is the truth. The broadcast is a fast hint. The authoritative read is what makes it certain — including undoing a hint that turns out to be wrong.

---

## The reconcile model (load-bearing — read first)

The single most important correction from review: a naive "monotonic, never move backward" guard lets a spurious `ride_started` pin a guest in `.riding` forever, because the durable backstop could then never correct it. So reconciliation has **two modes**:

```swift
public struct RideLifecycleStatus: Equatable, Sendable {
    public let hostID: UUID          // re-derived so a promoted host gains controls
    public let startedAt: Date?
    public let endedAt: Date?
}
public enum RideLifecyclePhase: Equatable, Sendable { case lobby, riding, ended }

/// AUTHORITATIVE — from a durable read (join seed, reconnect snapshot, foreground).
/// Sets phase to exactly match the durable lifecycle. `.ended` is terminal (once ended,
/// stays ended even if a later read somehow disagrees). CAN move a rider backward from an
/// optimistic-but-not-durable `.riding` to `.lobby` — this is what corrects a phantom start.
public func authoritativePhase(_ s: RideLifecycleStatus, current: RideLifecyclePhase) -> RideLifecyclePhase

/// OPTIMISTIC — from a broadcast (ride_started / ride_ended). Only moves forward
/// (lobby → riding → ended); never backward. A duplicate/reordered ride_started after a
/// ride_ended is absorbed (stays ended).
public func optimisticPhase(event: RideLifecycleEvent, current: RideLifecyclePhase) -> RideLifecyclePhase
```

Rules (both): `endedAt`/`ride_ended` → `.ended`; else `startedAt`/`ride_started` → `.riding`; else `.lobby`. Authoritative applies the computed phase directly except it never leaves `.ended`. Optimistic applies only if the computed phase is strictly ahead of `current`.

**`current` must always be the session's live phase**, projected 9-case `GroupRideSession.Phase` → 3-case `RideLifecyclePhase`:

| `Phase` | projects to | reconcile applies? |
|---|---|---|
| `.lobby` | `.lobby` | yes |
| `.riding` | `.riding` | yes |
| `.ended` | `.ended` | yes (terminal; no-op in practice) |
| `.idle`, `.needsDisplayName`, `.createFailed`, `.joinFailed`, `.routeUnavailable` | — | **no — reconcile is skipped entirely** |

Reconcile runs only when `rideSession != nil` and phase ∈ {`.lobby`, `.riding`, `.ended`}. Every call site passes the session's actual projected phase — never a hardcoded `.lobby`. Both functions are pure, `Sendable`, and table-tested in AuraCore; this is the primitive ROH-71 and ROH-68 both call.

**Transactionality assumption (must be tested):** the host flips to `.riding`/`.ended` on RPC success, which is sound only if `realtime.send` inserts into `realtime.messages` inside the RPC's transaction (so a rollback un-sends the broadcast). This is the documented Supabase behavior; a pgTAP test pins it. Even if a broadcast ever escaped a rolled-back transaction, the authoritative backstop corrects the resulting phantom `.riding` — the two-mode model is the real safety net, transactionality is the first line.

---

## 1. Data model (DB / Supabase)

Migrations continue the numbered series (next `0017`). Validated via Supabase MCP + CI `db-tests` (pgTAP); local Docker is unusable on this machine.

### 1.1 `started_at` column

```sql
alter table public.rides add column started_at timestamptz;   -- null = lobby, set = riding
```

Nullable, no default → no table rewrite, no backfill. All four `(started_at, ended_at)` null-combinations are valid; no new CHECK. `started_at` is ride-level, so a host transfer does not reset it.

### 1.2 `start_ride` RPC — guarded, broadcast only on the real transition

```sql
create function public.start_ride(p_ride_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_host uuid;
  v_started timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;   -- null-uid guard
  select host_id into v_host from public.rides where id = p_ride_id;
  if v_host is null or v_host <> v_uid then raise exception 'not host'; end if;
  update public.rides
    set started_at = now(),
        expires_at = greatest(expires_at, now() + interval '48 hours')  -- a started ride gets a fresh window
    where id = p_ride_id and started_at is null and ended_at is null    -- can't start an ended/swept ride
    returning started_at into v_started;
  if found then
    perform realtime.send(jsonb_build_object('startedAt', v_started),
                          'ride_started', 'ride:' || p_ride_id::text, true);
  end if;   -- no row changed (already started, or ended) → no broadcast; backstop covers late joiners
end;
$$;
revoke execute on function public.start_ride(uuid) from public;
grant execute on function public.start_ride(uuid) to authenticated;
```

Fixes from review: null-uid guard (consistent with `join_ride`/`create_ride`); `and ended_at is null` so an already-ended or cron-swept ride can't be "started" into a nonsensical `started_at > ended_at` row; broadcast only when a row actually changed and with the **stored** timestamp, so no repeat call sends a diverging `now()`. Guests who miss the one broadcast recover via the authoritative backstop.

### 1.3 `end_ride` / `leave_ride` — idempotent write, `ride_ended` broadcast, no host `member_left`

`end_ride` guards the write so retries don't walk `ended_at`/`expires_at` forward, but still broadcasts every call (a retry may be because the first notify was lost) with the stored value:

```sql
update public.rides
  set status = 'ended', ended_at = now(),
      expires_at = least(now() + interval '48 hours', coalesce(v_last, now()) + interval '48 hours')
  where id = p_ride_id and ended_at is null;      -- idempotent: write once
select ended_at into v_ended from public.rides where id = p_ride_id;
perform realtime.send(jsonb_build_object('endedAt', v_ended),
                      'ride_ended', 'ride:' || p_ride_id::text, true);
-- the host's own member_left is REMOVED from end_ride (ride_ended is the end signal now)
```

`end_ride` no longer emits `member_left` for the host (that produced a spurious "[host] left" toast and a weaker second end path). `leave_ride`: the **host-leaves-and-ride-ends** branch (no next member) emits `ride_ended`, same as `end_ride`; the **host-transfer** branch (a next member is promoted) keeps `member_left(oldHost)` (a genuine departure) — and clients re-derive the new host from `ride_status.hostID` (§3, §4). `member_left` remains only for real member departures / dot-pruning. `leave_ride`'s existing "not a member" raise is unchanged server-side; the **client** treats it as success (§4) so a lost-response retry can't strand a guest.

### 1.4 `ride_status` RPC — the authoritative backstop

```sql
create function public.ride_status(p_ride_id uuid)
returns table (host_id uuid, status text, started_at timestamptz, ended_at timestamptz)
language plpgsql security definer set search_path = '' stable as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  return query select r.host_id, r.status, r.started_at, r.ended_at from public.rides r where r.id = p_ride_id;
end;
$$;
revoke execute on function public.ride_status(uuid) from public;   -- the GRANT the codebase always pairs
grant execute on function public.ride_status(uuid) to authenticated;
```

Returns `host_id` so a promoted host learns it is now the host. Members-only via `is_ride_member` (same guard as `ride_live_snapshot`/`ride_roster`); members aren't deleted on `end_ride`, so a lobby guest can still read status after the host ends — the backstop works. `revoke`/`grant` present (the review caught their omission).

### 1.5 `join_ride` / `create_ride` return `started_at`

Both RPCs already `return public.rides` (the whole row), so `ended_at` is already on the wire and `started_at` appears automatically once the column exists. **The only change is client-side:** `GroupRideRow` (Swift) adds `startedAt`/`endedAt` to its `CodingKeys`, decoded as `Date?` via the synthesized `decodeIfPresent` (a `null` or a pre-migration missing key both → nil; declaring them non-optional would throw on any lobby ride). No SQL projection change. **`join_ride` is unchanged and still filters `status = 'active'`** — so a guest joining an *ended* ride gets `joinFailed` (copy improved to "This ride has ended or the code is wrong"), not a fake `.ended` reconcile path. Late-join into a *started* ride works, because a started ride is still `status='active'`.

## 2. Wire / transport seam (Swift)

`TransportEvent` (AuraKit) gains `case rideStarted` and `case rideEnded`. `LiveBroadcastDecoder` (AuraCore) decodes the two event names.

**Snapshot shape — decided (resolves the v1 contradiction):** keep `ride_live_snapshot` returning positions only and `RideSession.reseed()` unchanged. Add a **separate** `ride_status` read owned by `GroupRideSession`, called on join-seed, on `.connected`, and on foreground. This is two small RPCs on a reconnect rather than one; the extra round-trip is on a cold, non-hot path and is worth the far smaller blast radius than restructuring the `RideSession`/`GroupRideSession` snapshot ownership. No `RideLiveSnapshot` bundling type. The Supabase transport gains `func rideStatus(rideID:) async throws -> RideLifecycleStatus`; `InMemoryRideSessionTransport`/`InMemoryGroupRideBackend` gain a settable lifecycle + `emit(.rideStarted)`/`emit(.rideEnded)` + `start_ride` for tests.

## 3. Domain (AuraCore)

`RideLifecycleStatus`, `RideLifecyclePhase`, `authoritativePhase`, `optimisticPhase` (§reconcile model). `GroupRide` gains `startedAt`/`endedAt`. All pure and table-tested.

## 4. Session state machine (`GroupRideSession`)

`Phase` already has `.lobby`. New retryable **flags** (not phases, so the live session and solo HUD keep running underneath): `startFailed`, `endFailed`. `hostID`/`isHost` become updatable.

**Join** (`join(code:)`): stop forcing `.riding`. Decode the returned lifecycle and apply `authoritativePhase(current: .lobby)`: `startedAt` set → `.riding` (late-join catch-up); else → `.lobby`. (Ended rides can't be joined — §1.5 — so no `.ended`-on-join branch.)

**Host start** (`startRiding()` → `func startRiding() async`): call `backend.startRide(rideID)`. On success → `.riding`. On throw → stay `.lobby`, set `startFailed`; auto-retry with backoff owned by a session-held `Task` (cancelled in `teardownLive`). Never flip on a swallowed error. Call sites wrap in `Task { await … }` (`GroupLobbyView`, the container preview).

**Live handling** (`ingest`): the guest lobby runs `beginLiveSession()` too, so it receives events live.
- `.rideStarted` → `optimisticPhase(current: <live phase>)` → lobby becomes riding.
- `.rideEnded` → `.ended` + `teardownLive`. (Replaces the removed `member_left == hostID` special case.)
- `.connected` (reconnect) → **new case**: read `ride_status`, apply `authoritativePhase`, and re-derive `hostID`/`isHost = (status.hostID == selfUserID)`. This is the load-bearing backstop; `ingest` has no `.connected` case today and must gain one.
- Foreground (see §5) → same authoritative re-read.

**End reliability** (`end()` / `leave()`): remove `try?`. Distinguish outcomes:
- Success → `.ended` + teardown.
- **"Already gone"** (the RPC raises `not host` / `not a member` / ride not found — mapped to `GroupRideError.notHost`/`.notMember`) → treat as success → `.ended` + teardown. This makes a lost-response retry safe even though `leave_ride`/`end_ride` raise on the second call. Resolves the "retry strands the guest" defect.
- **Transient** (network / 5xx) → set `endFailed`, keep the crew chrome and live session up, auto-retry with backoff (session-held `Task`), reach `.ended` only on a success/already-gone outcome.

**Host-transfer re-derivation:** `hostID`/`isHost` are refreshed on every authoritative read (`.connected`, foreground, and the join seed), so a promoted host (server-side `leave_ride` transfer) gains `isHost = true` on its next status read and the lobby then shows it the Start CTA. Without this the promoted host's lobby would deadlock (nobody able to start).

## 5. UI

**Guest lobby** — parameterize `GroupLobbyView` by role:
- Host: "Start riding" CTA driving the async `startRiding()`, with an inline "Couldn't start — Retry" on `startFailed`.
- Guest: "Waiting for [host] to start…" (host name from `nameMap[hostID]`), the live roster, join code, share link (mirror + invite — newcomers join the same ride via the same code, no host hierarchy), and a **Leave** button.
- **Guest lobby Leave** is its own path: `await leaveRide` (with the already-gone-⇒-success rule) then `router.pop()` — exit the group ride back home. It must NOT go through `.ended` (which renders the riding container). The lobby reads `@Environment(AppRouter.self)`.

**The `.ended` surface (new — resolves "`.ended` has no screen"):** `GroupRideFlowView` today collapses `.riding`/`.ended` into `GroupNavigateContainer`, which was safe only because `.ended` used to be reachable *only* out of a running ride. The new lobby adds no-HUD entrances to `.ended`. Fix: track `didEnterRiding` (set true the first time the `.riding` container mounts).
- `.ended` **with** `didEnterRiding` (rode, then ended — the D9 host-end and D10 member-leave cases) → keep `GroupNavigateContainer` so the solo `RideSessionCoordinator`/HUD keeps running underneath dissolved chrome. Unchanged behavior.
- `.ended` **without** `didEnterRiding` (host ended while guest still in lobby) → render a dedicated ended surface ("This ride has ended", Back → `router.pop()`). No solo-nav launch, and critically **no `beginLiveSession()` re-subscribe** on a torn-down ride (the lobby→ended view-identity change would otherwise re-run the container's `.task`). `beginLiveSession` also gains a `phase != .ended` guard as belt-and-suspenders.

**Host end-failure** — a non-blocking "Ending…" → "Couldn't end — Retry" on `endFailed`, crew chrome retained (phase stays `.riding`) until the server confirms. **The call site must change:** `endGroupRideAsHost()` currently runs `endRide()` (finish → summary) unconditionally after `end()`. It must only `endRide()` once `end()` reaches `.ended`; on `endFailed` it stays in the HUD showing the retry. `endRideAsMember()` has the same shape and the same fix. `leaveCrewKeepRiding()` (D10) already tolerates `.ended` dissolving only the chrome — its failure path uses the same already-gone/transient rule.

**Membership toasts in the lobby** — `GroupToastHost` is mounted only inside `NavigateHUDView`, so lobby `.joined`/`.left` events are dropped by construction (not merely "typically suppressed"). Decision: the live roster already gives "crew filling in" feedback, so the lobby stays roster-only for now; a `.joined`-toast-in-lobby is split to its own low-priority ticket rather than mounting a second toast host here. Documented, not silently dropped.

## 6. Correctness / edge cases

- **Late join** (started) → `.riding` via `authoritativePhase` on join.
- **Join into ended** → `joinFailed` with improved copy (join_ride refuses ended rides; no fake reconcile path).
- **Host ends while guest in lobby** → `ride_ended` broadcast flips the guest to the `.ended` lobby surface; the `ride_status` backstop covers a missed broadcast.
- **Missed `ride_started`** (tunnel) → corrected to `.riding` on the next `.connected`/foreground authoritative read.
- **Phantom `ride_started`** (spurious/rolled-back broadcast) → authoritative read (`started_at = null`) corrects the guest back to `.lobby`. The two-mode reconcile is what allows this.
- **Host transfer before start** → promoted host re-derives `isHost` from `ride_status.hostID` and gains the Start CTA; no lobby deadlock.
- **App backgrounded in lobby, socket suspended** (no `.disconnected`/`.connected` cycle) while host starts/ends → the scenePhase→foreground `ride_status` re-read reconciles. Without it a suspended socket misses both broadcasts.
- **Idempotent start/end** — `start_ride`/`end_ride` write once (`where … is null`); retries don't move timestamps; broadcasts don't diverge.
- **Retry safety** — client treats server "already gone" raises as success, so a lost-response retry can't loop forever.
- **Force-quit host** (no leave/end emitted) → guests wait in the lobby with no timeout; this is the same durable-backstop-for-presence gap as ROH-66 (no heartbeat), which the always-lobby design widens. Out of scope here; flagged so ROH-66 accounts for the lobby case.
- **Lobby reaped/swept** — a lobby ride with `started_at` null is swept after ~3h of no track points and reaped at its `expires_at`; `start_ride` bumps `expires_at` to now+48h so a started ride gets a fresh window. A host who opens a lobby and walks away lets it lapse — acceptable.

## 7. Testing (TDD)

- **AuraCore (pure):** `authoritativePhase`/`optimisticPhase` table tests — every (startedAt, endedAt, current) combo, forward and backward, `.ended` terminality, the phantom-start correction (authoritative moves riding→lobby), reordered ride_started-after-ride_ended (optimistic stays ended), and the `Phase → RideLifecyclePhase` projection incl. the skip-set. `GroupRide` lifecycle decoding incl. missing/null keys.
- **AuraKit (`GroupRideSession`) over in-memory fakes:** join → lobby / riding by lifecycle; `.rideStarted` lobby→riding; `.rideEnded` teardown; `.connected` authoritative reconcile incl. phantom-start correction and host-transfer `isHost` re-derivation; `startRiding()` transient failure stays lobby + retries (no fake success); `end()`/`leave()` transient failure keeps chrome + retries, "already gone" raise → success; foreground reconcile.
- **DB (pgTAP):** `start_ride` — host-only, null-uid rejected, idempotent *timestamp does not move*, rejected on ended/swept ride, broadcasts `ride_started` only on the real transition; `end_ride` — idempotent (ended_at doesn't move on retry), broadcasts `ride_ended`, no host `member_left`; `ride_status` — members-only, returns host_id, identical `unauthorized` for non-member vs non-existent (no existence oracle), readable by a lobby guest after host end; the **`realtime.send` same-transaction** assumption. **Every broadcast assertion must first create today's `realtime.messages_<date>` partition** — pure pgTAP runs don't, and `realtime.send` drops silently without it (documented trap in `tests/0015`).
- **App target (device-verify):** guest lobby, synchronized start, host-transfer-in-lobby, end-retry under lost signal, and the `.ended` lobby surface are app-target — keep decision logic in AuraCore/AuraKit where it's tested; device-verify needs two identities (host + guest). Silver Bar is currently unavailable, so device-verify is a gated tail step.

## 8. Migration / rollout

Additive only (one column, three functions, two new wire events, client decode + call-site changes). DB migration applies before the client relies on `start_ride`/`ride_status`. An old client ignoring the new events still reconciles via the authoritative backstop once updated. `started_at` defaults null → in-flight pre-migration rides read as lobby, which is harmless (no live clients on the new build for them).

## Out of scope (own tickets)

- ROH-66 (no heartbeat) — now also covers the force-quit-host-strands-lobby case; note it there.
- `.joined`-toast-in-lobby — split low-priority ticket (roster gives adequate lobby feedback).
- The unticketed "`ride_members` row deleted on leave, so the roster forgets a departed rider" — matters for summaries, not live sync.

---

## Adversarial review reconciliation (v1 → v2)

Three independent reviewers, refuting mandate, distinct lenses. Confirmed findings and their resolutions:

**Blockers**
- *ROH-68 unfixed at the call site* (`endGroupRideAsHost` runs `endRide()` unconditionally) → §5 call-site redesign: finish only after `end()` confirms; retry in-HUD otherwise.
- *`.ended` has no screen* → §5 `didEnterRiding` split: ended surface for lobby/join entrances, container retained for rode-then-ended.
- *Join-into-ended unreachable* (`join_ride` filters `status='active'`) → §1.5 drop the branch; ended → `joinFailed` with better copy.
- *Lobby host-transfer deadlock* (promoted host stuck as guest) → §1.4 `ride_status` returns `host_id`; §4 re-derive `isHost` on every authoritative read.
- *`leave_ride`/`end_ride` not idempotent → retry strands guest / walks timestamps* → §1.3 `where … is null` write guard; §4 client "already gone ⇒ success" rule.

**Majors**
- *Monotonic guard vetoes phantom-start correction* → the two-mode reconcile (§reconcile model): authoritative reads can move backward, optimistic broadcasts can't.
- *`current` must be live phase; Phase(9)↔RideLifecyclePhase(3) undefined* → §reconcile model projection table + "pass the session's actual phase" rule.
- *`member_left(host)` coexistence → spurious toast + weaker end* → §1.3 remove host `member_left` from `end_ride`; ride_ended is the end signal.
- *`beginLiveSession` re-subscribes on lobby→ended* → §5 ended surface (no container `.task`) + `phase != .ended` guard.
- *`startRiding()` async breaks sync call sites; retry ownership* → §4 `Task`-wrapped call sites, session-held retry `Task` cancelled on teardown.
- *Backstop reconnect-only* → §5 scenePhase→foreground authoritative re-read.
- *`realtime.send` transactionality unstated* → §reconcile model assumption + §7 pgTAP test; two-mode model as the deeper safety net.
- *Transport shape contradiction* → §2 decided: separate `ride_status` RPC, `ride_live_snapshot` unchanged.
- *`.connected` reconcile not wired in `ingest`* → §4 new `.connected` case, called out as load-bearing.
- *Guest own-publishing on lobby-driven start* → confirmed handled: entering `.riding` mounts `GroupNavigateContainer` → `NavigateHUDView` starts `coordinator.start(groupSink:)`, identical to the host; §7 device-verifies it.

**Minors** — `ride_status` missing GRANT (§1.4 added); pgTAP realtime-partition guard (§7); `start_ride` ended-guard + null-uid guard (§1.2); broadcast-only-on-change to fix payload divergence (§1.2/§1.3); §1.5 factual fix (only Swift CodingKeys change); `GroupRideRow` `Date?`/`decodeIfPresent` contract (§1.5); lobby reaped/swept documented + `start_ride` bumps `expires_at` (§1.2/§6); `.joined`-toast-in-lobby split to a ticket (§5); preview/test seams that used `member_left(hostID)` migrate to `ride_ended` (called out for the plan).
