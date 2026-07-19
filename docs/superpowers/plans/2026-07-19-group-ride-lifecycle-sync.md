# Group-Ride Lifecycle Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give group rides a synchronized start (guests wait in a lobby, the host's tap flips everyone together, a late joiner catches up) and a reliable end (the host's End can't silently fail; a guest offline at the end still dissolves its crew), unified by one ride-lifecycle primitive.

**Architecture:** Every lifecycle transition (started, ended) is durable (a column on `rides`), pushed (a `realtime.send` broadcast), and re-readable (a `ride_status` RPC read on join/reconnect/foreground). Reconciliation has two modes: authoritative reads (durable) can correct a phantom optimistic state; broadcasts only move a rider forward. Pure decision logic lives in AuraCore; the session orchestrates in AuraKit; the durable reads are RPCs on `GroupRideBackend`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftPM package `AuraCore` (targets AuraCore + AuraKit, macOS-host unit-tested), app target `Aura`, Supabase (Postgres + Realtime, SECURITY DEFINER RPCs, pgTAP).

## Global Constraints

- Swift language mode `.v6`; AuraCore/AuraKit are `nonisolated`-by-default, the app target is `MainActor`-isolated. Pure lifecycle types are Foundation-only (no iOS-only API) so they build on the macOS CI host.
- Realtime topic strings are lowercase: `'ride:' || p_ride_id::text` in SQL; `RideTopic.name(rideID:)` in Swift. Never `UUID.uuidString` (uppercase) in a topic.
- SQL functions: `security definer`, `set search_path = ''`, schema-qualify everything, and ALWAYS pair `revoke execute … from public;` + `grant execute … to authenticated;`.
- DB is validated via the Supabase MCP + CI `db-tests` (pgTAP); local Docker is unusable. Every pgTAP broadcast assertion must first create today's `realtime.messages_<date>` partition (see `supabase/tests/0015_member_left_test.sql`), or `realtime.send` drops silently and the assertion sees 0 rows.
- App-target UI has no unit-test bundle; its gate is "compiles (builder agent) + preview/device-verify". Keep all decision logic in AuraCore/AuraKit where it is unit-tested.
- Reconcile call sites ALWAYS pass the session's actual projected phase as `current`, never a hardcoded `.lobby`.
- Join-failed copy for an ended/unknown code: "This ride has ended or the code is wrong."

---

## File structure

**Create:**
- `AuraCore/Sources/AuraCore/GroupRide/RideLifecycle.swift` — pure `RideLifecycleStatus`, `RideLifecyclePhase`, `RideLifecycleEvent`, `authoritativePhase`, `optimisticPhase`.
- `AuraCore/Tests/AuraCoreTests/GroupRide/RideLifecycleTests.swift`
- `supabase/migrations/0017_ride_start.sql`, `supabase/tests/0017_ride_start_test.sql`
- `supabase/migrations/0018_ride_ended_broadcast.sql`, `supabase/tests/0018_ride_ended_broadcast_test.sql`
- `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift`

**Modify:**
- `AuraCore/Sources/AuraCore/GroupRide/GroupRide.swift` — `GroupRide` gains `startedAt`/`endedAt`.
- `AuraCore/Sources/AuraKit/GroupRide/RideSessionTransport.swift` — `TransportEvent` gains `.rideStarted`/`.rideEnded`; `InMemoryRideSessionTransport` emits them.
- `AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift` — protocol gains `startRide`, `rideStatus`.
- `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` — implements `startRide`/`rideStatus`; store tracks started/ended.
- `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` — join/start/ingest/end/leave + reconcile + host re-derivation + `startFailed`/`endFailed`.
- `Aura/Sources/Sync/SupabaseGroupRideBackend.swift` — `startRide`/`rideStatus` conformers; `GroupRideRow` decodes `startedAt`/`endedAt`.
- `Aura/Sources/Sync/SupabaseRideSessionTransport.swift` — subscribe `ride_started`/`ride_ended`.
- `Aura/Sources/GroupRide/GroupLobbyView.swift` — role split (guest waiting + Leave→pop), async start, `startFailed` surface.
- `Aura/Sources/GroupRide/GroupRideFlowView.swift` — `.ended` surface + `didEnterRiding` + `beginLiveSession` guard + scenePhase reconcile.
- `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift` — end call-site gated on server confirm.
- `Aura/Sources/GroupRide/GroupNavigateContainer.swift` — `endFailed` surface; migrate preview `memberLeft(hostID)` → `rideEnded`, async start.

---

## Task 1: Pure reconcile primitive (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/RideLifecycle.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/RideLifecycleTests.swift`

**Interfaces:**
- Produces: `RideLifecycleStatus(hostID: UUID, startedAt: Date?, endedAt: Date?)`; `enum RideLifecyclePhase { case lobby, riding, ended }`; `enum RideLifecycleEvent { case started, ended }`; `func authoritativePhase(_ status: RideLifecycleStatus, current: RideLifecyclePhase) -> RideLifecyclePhase`; `func optimisticPhase(_ event: RideLifecycleEvent, current: RideLifecyclePhase) -> RideLifecyclePhase`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AuraCore

struct RideLifecycleTests {
    private func status(started: Bool, ended: Bool) -> RideLifecycleStatus {
        RideLifecycleStatus(hostID: UUID(),
                            startedAt: started ? Date(timeIntervalSince1970: 10) : nil,
                            endedAt: ended ? Date(timeIntervalSince1970: 20) : nil)
    }

    // authoritative: exact match, ended dominates started dominates lobby
    @Test func authoritativeLobbyWhenNeither() {
        #expect(authoritativePhase(status(started: false, ended: false), current: .lobby) == .lobby)
    }
    @Test func authoritativeRidingWhenStarted() {
        #expect(authoritativePhase(status(started: true, ended: false), current: .lobby) == .riding)
    }
    @Test func authoritativeEndedWhenEnded() {
        #expect(authoritativePhase(status(started: true, ended: true), current: .riding) == .ended)
    }
    // authoritative CORRECTS a phantom optimistic riding back to lobby (the key fix)
    @Test func authoritativeCorrectsPhantomStart() {
        #expect(authoritativePhase(status(started: false, ended: false), current: .riding) == .lobby)
    }
    // authoritative never leaves ended, even if a stale read disagrees
    @Test func authoritativeEndedIsTerminal() {
        #expect(authoritativePhase(status(started: false, ended: false), current: .ended) == .ended)
    }

    // optimistic: only moves forward
    @Test func optimisticStartMovesLobbyToRiding() {
        #expect(optimisticPhase(.started, current: .lobby) == .riding)
    }
    @Test func optimisticEndMovesRidingToEnded() {
        #expect(optimisticPhase(.ended, current: .riding) == .ended)
    }
    @Test func optimisticStartNeverUnEnds() {
        #expect(optimisticPhase(.started, current: .ended) == .ended)   // reordered start after end
    }
    @Test func optimisticEndFromLobbyGoesEnded() {
        #expect(optimisticPhase(.ended, current: .lobby) == .ended)     // host ends before starting
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideLifecycleTests`
Expected: FAIL — `cannot find 'authoritativePhase' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The authoritative ride lifecycle read from a durable source (join seed, reconnect
/// snapshot, foreground). `hostID` is included so a promoted host learns it is host.
public struct RideLifecycleStatus: Equatable, Sendable {
    public let hostID: UUID
    public let startedAt: Date?
    public let endedAt: Date?
    public init(hostID: UUID, startedAt: Date?, endedAt: Date?) {
        self.hostID = hostID; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// The three live phases reconciliation reasons about. `GroupRideSession.Phase` projects
/// onto this (its non-live phases don't participate).
public enum RideLifecyclePhase: Equatable, Sendable { case lobby, riding, ended }

/// A pushed lifecycle broadcast (optimistic).
public enum RideLifecycleEvent: Equatable, Sendable { case started, ended }

private func rank(_ p: RideLifecyclePhase) -> Int {
    switch p { case .lobby: return 0; case .riding: return 1; case .ended: return 2 }
}

private func naturalPhase(_ s: RideLifecycleStatus) -> RideLifecyclePhase {
    if s.endedAt != nil { return .ended }
    if s.startedAt != nil { return .riding }
    return .lobby
}

/// AUTHORITATIVE reconcile from a durable read. Applies the durable phase exactly — it
/// MAY move a rider backward (correcting a phantom optimistic start) — except `.ended`
/// is terminal and is never left.
public func authoritativePhase(_ status: RideLifecycleStatus,
                               current: RideLifecyclePhase) -> RideLifecyclePhase {
    if current == .ended { return .ended }
    return naturalPhase(status)
}

/// OPTIMISTIC reconcile from a broadcast. Only ever moves forward; a reordered/duplicate
/// event that would move a rider backward is ignored.
public func optimisticPhase(_ event: RideLifecycleEvent,
                            current: RideLifecyclePhase) -> RideLifecyclePhase {
    let target: RideLifecyclePhase = (event == .ended) ? .ended : .riding
    return rank(target) > rank(current) ? target : current
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter RideLifecycleTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/GroupRide/RideLifecycle.swift AuraCore/Tests/AuraCoreTests/GroupRide/RideLifecycleTests.swift
git commit -m "feat(core): two-mode ride-lifecycle reconcile primitive"
```

---

## Task 2: `GroupRide` gains `startedAt` / `endedAt` (AuraCore)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/GroupRide.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/GroupRideCodableTests.swift` (add cases)

**Interfaces:**
- Produces: `GroupRide` with `public let startedAt: Date?` and `public let endedAt: Date?`; the memberwise `init` gains `startedAt: Date? = nil, endedAt: Date? = nil` (defaulted so existing call sites keep compiling).

- [ ] **Step 1: Add a failing test**

Append to `GroupRideCodableTests.swift`:

```swift
@Test func groupRideCarriesLifecycleTimestamps() throws {
    let started = Date(timeIntervalSince1970: 100)
    let ended = Date(timeIntervalSince1970: 200)
    let ride = GroupRide(id: UUID(), hostID: UUID(), joinCode: JoinCode(rawValue: "ABCDEFGH")!,
                         status: .ended, createdAt: Date(timeIntervalSince1970: 0),
                         startedAt: started, endedAt: ended)
    let round = try JSONDecoder().decode(GroupRide.self, from: JSONEncoder().encode(ride))
    #expect(round.startedAt == started)
    #expect(round.endedAt == ended)
}

@Test func groupRideDefaultsLifecycleToNil() {
    let ride = GroupRide(id: UUID(), hostID: UUID(), joinCode: JoinCode(rawValue: "ABCDEFGH")!,
                         status: .active, createdAt: Date(timeIntervalSince1970: 0))
    #expect(ride.startedAt == nil)
    #expect(ride.endedAt == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GroupRideCodableTests`
Expected: FAIL — extra argument `startedAt` / no member `startedAt`.

- [ ] **Step 3: Implement**

In `GroupRide.swift`, add the two stored properties and extend `init` (defaults keep every existing caller valid):

```swift
public struct GroupRide: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case active, ended }
    public let id: UUID
    public let hostID: UUID
    public let joinCode: JoinCode
    public let status: Status
    public let createdAt: Date
    public let startedAt: Date?
    public let endedAt: Date?
    public init(id: UUID, hostID: UUID, joinCode: JoinCode, status: Status, createdAt: Date,
                startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.hostID = hostID; self.joinCode = joinCode
        self.status = status; self.createdAt = createdAt
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter GroupRideCodableTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/GroupRide/GroupRide.swift AuraCore/Tests/AuraCoreTests/GroupRide/GroupRideCodableTests.swift
git commit -m "feat(core): GroupRide carries started_at/ended_at"
```

---

## Task 3: DB migration `0017` — `started_at`, `start_ride`, `ride_status` (Supabase)

**Files:**
- Create: `supabase/migrations/0017_ride_start.sql`
- Test: `supabase/tests/0017_ride_start_test.sql`

**Interfaces:**
- Produces (SQL): `public.start_ride(uuid)`, `public.ride_status(uuid) returns table(host_id uuid, status text, started_at timestamptz, ended_at timestamptz)`, and a `rides.started_at timestamptz` column.

- [ ] **Step 1: Write the migration**

```sql
-- ROH-71: durable "ride has started" state + an authoritative status read.
alter table public.rides add column started_at timestamptz;

create function public.start_ride(p_ride_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_host uuid;
  v_started timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select host_id into v_host from public.rides where id = p_ride_id;
  if v_host is null or v_host <> v_uid then raise exception 'not host'; end if;
  update public.rides
    set started_at = now(),
        expires_at = greatest(expires_at, now() + interval '48 hours')
    where id = p_ride_id and started_at is null and ended_at is null
    returning started_at into v_started;
  if found then
    perform realtime.send(jsonb_build_object('startedAt', v_started),
                          'ride_started', 'ride:' || p_ride_id::text, true);
  end if;
end;
$$;
revoke execute on function public.start_ride(uuid) from public;
grant execute on function public.start_ride(uuid) to authenticated;

create function public.ride_status(p_ride_id uuid)
returns table (host_id uuid, status text, started_at timestamptz, ended_at timestamptz)
language plpgsql security definer set search_path = '' stable as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  return query select r.host_id, r.status, r.started_at, r.ended_at
               from public.rides r where r.id = p_ride_id;
end;
$$;
revoke execute on function public.ride_status(uuid) from public;
grant execute on function public.ride_status(uuid) to authenticated;
```

- [ ] **Step 2: Write the pgTAP test**

Mirror the auth/partition harness of `supabase/tests/0005_lifecycle_test.sql` and `0015_member_left_test.sql`. Cover: `start_ride` sets `started_at` when host and unstarted; is idempotent (second call does NOT move the timestamp); rejects a non-host (`not host`); does NOT start an ended ride (`started_at` stays null after `end_ride`); emits exactly one `ride_started` broadcast on the real transition and none on the no-op repeat (create today's `realtime.messages_<date>` partition first); `ride_status` returns the row for a member, `unauthorized` for a non-member, and `host_id` reflects a transfer. Use the project's `pg_temp` SECURITY-DEFINER claims helper + `set_config('request.jwt.claims', …, true)` pattern from those files.

- [ ] **Step 3: Validate via Supabase MCP**

Apply `0017_ride_start.sql` to a Supabase dev branch (MCP `apply_migration`), then run the pgTAP test body via MCP `execute_sql`. Expected: every `ok`/`is` assertion passes; no failing plan lines.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0017_ride_start.sql supabase/tests/0017_ride_start_test.sql
git commit -m "feat(db): started_at column + start_ride + ride_status RPCs"
```

---

## Task 4: DB migration `0018` — idempotent end + `ride_ended` broadcast (Supabase)

**Files:**
- Create: `supabase/migrations/0018_ride_ended_broadcast.sql`
- Test: `supabase/tests/0018_ride_ended_broadcast_test.sql`

**Interfaces:**
- Produces (SQL): `end_ride`/`leave_ride` redefined — idempotent write (`where ended_at is null`), emit `ride_ended` (with the stored `ended_at`), and `end_ride` no longer emits the host's `member_left`.

- [ ] **Step 1: Write the migration**

`create or replace` both functions, copying the bodies from `0015_member_left.sql` and changing only:
- `end_ride`: guard the update with `... where id = p_ride_id and ended_at is null;`, then `select ended_at into v_ended from public.rides where id = p_ride_id;` and `perform realtime.send(jsonb_build_object('endedAt', v_ended), 'ride_ended', 'ride:' || p_ride_id::text, true);`. **Remove** the trailing `member_left` send.
- `leave_ride`: keep the member-departure `member_left(v_uid)` send (a real departure). In the host-leaves-with-no-next-member branch (the one that sets `status='ended'`), guard it with `and ended_at is null` and, after that branch, additionally `perform realtime.send(jsonb_build_object('endedAt', now()), 'ride_ended', 'ride:' || p_ride_id::text, true);` so a host leaving an empty ride ends it for any straggler exactly like `end_ride`.

Declare `v_ended timestamptz;` in `end_ride`.

- [ ] **Step 2: Write the pgTAP test**

Cover: `end_ride` sets `status='ended'`/`ended_at`; a second `end_ride` does NOT move `ended_at`; `end_ride` emits `ride_ended` and does NOT emit a `member_left` for the host; `leave_ride` by a plain member still emits `member_left`; host-leaves-empty emits `ride_ended`. Create today's partition before broadcast assertions.

- [ ] **Step 3: Validate via Supabase MCP** — apply + run the pgTAP body; all assertions pass.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0018_ride_ended_broadcast.sql supabase/tests/0018_ride_ended_broadcast_test.sql
git commit -m "feat(db): idempotent end + dedicated ride_ended broadcast"
```

---

## Task 5: Transport events + backend seams + in-memory fakes (AuraKit)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/RideSessionTransport.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/InMemoryGroupRideBackendTests.swift` (add cases)

**Interfaces:**
- Produces: `TransportEvent.rideStarted`, `TransportEvent.rideEnded`; `GroupRideBackend.startRide(rideID: UUID) async throws`; `GroupRideBackend.rideStatus(rideID: UUID) async throws -> RideLifecycleStatus`.
- Consumes: `RideLifecycleStatus` (Task 1), `GroupRide.startedAt/endedAt` (Task 2).

- [ ] **Step 1: Add failing fake-behavior tests**

Append to `InMemoryGroupRideBackendTests.swift`:

```swift
@Test func startRideSetsStartedAtReadableByRideStatus() async throws {
    let backend = InMemoryGroupRideBackend()
    try await backend.signIn(idToken: "t", nonce: "n", displayName: "Host")
    let ride = try await backend.createRide(route: Data("{}".utf8))
    var status = try await backend.rideStatus(rideID: ride.id)
    #expect(status.startedAt == nil)
    try await backend.startRide(rideID: ride.id)
    status = try await backend.rideStatus(rideID: ride.id)
    #expect(status.startedAt != nil)
    #expect(status.endedAt == nil)
    #expect(status.hostID == ride.hostID)
}

@Test func startRideByNonHostThrows() async throws {
    let host = InMemoryGroupRideBackend()
    try await host.signIn(idToken: "t", nonce: "n", displayName: "Host")
    let ride = try await host.createRide(route: Data("{}".utf8))
    let guest = InMemoryGroupRideBackend(sharing: host)
    try await guest.signIn(idToken: "t2", nonce: "n", displayName: "Guest")
    _ = try await guest.joinRide(code: ride.joinCode)
    await #expect(throws: GroupRideError.notHost) { try await guest.startRide(rideID: ride.id) }
}

@Test func endRideSetsEndedAtInStatus() async throws {
    let backend = InMemoryGroupRideBackend()
    try await backend.signIn(idToken: "t", nonce: "n", displayName: "Host")
    let ride = try await backend.createRide(route: Data("{}".utf8))
    try await backend.endRide(rideID: ride.id)
    let status = try await backend.rideStatus(rideID: ride.id)
    #expect(status.endedAt != nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter InMemoryGroupRideBackendTests`
Expected: FAIL — no member `startRide`/`rideStatus`.

- [ ] **Step 3: Implement**

In `RideSessionTransport.swift`, add the two arms to `TransportEvent`:

```swift
case rideStarted
case rideEnded
```

In `GroupRideBackend.swift` protocol, add:

```swift
func startRide(rideID: UUID) async throws
func rideStatus(rideID: UUID) async throws -> RideLifecycleStatus
```

In `InMemoryGroupRideBackend.swift`: `startRide` sets `started_at` on the stored ride (host-only, else `.notHost`); `endRide` (already present) additionally stamps `ended_at`; `rideStatus` reads the stored ride. Because `GroupRide` is immutable, replace the stored copy:

```swift
public func startRide(rideID: UUID) async throws {
    guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
    guard let ride = store.rides[rideID], ride.hostID == uid else { throw GroupRideError.notHost }
    guard ride.startedAt == nil, ride.endedAt == nil else { return }   // idempotent
    store.rides[rideID] = GroupRide(id: ride.id, hostID: ride.hostID, joinCode: ride.joinCode,
                                    status: ride.status, createdAt: ride.createdAt,
                                    startedAt: Date(timeIntervalSince1970: 10), endedAt: ride.endedAt)
}

public func rideStatus(rideID: UUID) async throws -> RideLifecycleStatus {
    guard let ride = store.rides[rideID] else { throw GroupRideError.joinFailed }
    return RideLifecycleStatus(hostID: ride.hostID, startedAt: ride.startedAt, endedAt: ride.endedAt)
}
```

And extend the existing `endRide` to stamp `ended_at`:

```swift
public func endRide(rideID: UUID) async throws {
    guard let uid = store.lock.withLock({ store.currentUserID }), let ride = store.rides[rideID], ride.hostID == uid
    else { throw GroupRideError.notHost }
    store.rides[rideID] = GroupRide(id: ride.id, hostID: ride.hostID, joinCode: ride.joinCode,
                                    status: .ended, createdAt: ride.createdAt,
                                    startedAt: ride.startedAt, endedAt: Date(timeIntervalSince1970: 20))
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter InMemoryGroupRideBackendTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/RideSessionTransport.swift AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift AuraCore/Tests/AuraKitTests/GroupRide/InMemoryGroupRideBackendTests.swift
git commit -m "feat(kit): startRide/rideStatus backend seams + rideStarted/rideEnded events"
```

---

## Task 6: Session — guest lobby on join, async start with retry (AuraKit)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Test: Create `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift`

**Interfaces:**
- Consumes: `authoritativePhase`/`optimisticPhase` (Task 1), `backend.startRide`/`rideStatus` (Task 5).
- Produces: `GroupRideSession.startRiding() async`; `public private(set) var startFailed: Bool`; a private `Phase → RideLifecyclePhase` projection `phase.lifecycle`.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideSessionLifecycleSyncTests {
    private func makeGuestJoin(startedOnServer: Bool) async -> GroupRideSession {
        let host = InMemoryGroupRideBackend()
        try? await host.signIn(idToken: "h", nonce: "n", displayName: "Host")
        let ride = try! await host.createRide(route: Data("{\"id\":\"\(UUID())\"}".utf8))
        if startedOnServer { try? await host.startRide(rideID: ride.id) }
        let guest = InMemoryGroupRideBackend(sharing: host)
        try? await guest.signIn(idToken: "g", nonce: "n", displayName: "Guest")
        // route bytes must decode to a Route; reuse the host's stored route via a real Route
        return GroupRideSession(backend: guest, transport: InMemoryRideSessionTransport(),
                                displayNameProvider: { "Guest" })
    }

    @Test func joinBeforeStartLandsInLobby() async {
        // Arrange a real Route round-trip through the fake so join decodes it.
        let (session, code) = await LifecycleFixtures.hostedRide(started: false)
        await session.join(code: code)
        #expect(session.phase == .lobby)
    }

    @Test func joinAfterStartLandsInRiding() async {
        let (session, code) = await LifecycleFixtures.hostedRide(started: true)
        await session.join(code: code)
        #expect(session.phase == .riding)
    }

    @Test func hostStartSuccessMovesToRiding() async {
        let (session, _) = await LifecycleFixtures.createdHost()
        await session.startRiding()
        #expect(session.phase == .riding)
        #expect(session.startFailed == false)
    }

    @Test func hostStartFailureStaysInLobby() async {
        let (session, _) = await LifecycleFixtures.createdHost(forceStartError: .joinFailed)
        await session.startRiding()
        #expect(session.phase == .lobby)
        #expect(session.startFailed == true)
    }
}
```

Add a `LifecycleFixtures` helper in the same file that builds a host session (via `create`) and a guest session (via a shared backend) with a real `Route` so `join` decodes, and supports a `forceStartError` (add a `forceStartError` spy to `InMemoryGroupRideBackend.Store` mirroring `forceCreateError`, and honor it in `startRide`).

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GroupRideSessionLifecycleSyncTests`
Expected: FAIL — `startRiding()` is not async / `startFailed` missing.

- [ ] **Step 3: Implement**

In `GroupRideSession.swift`:
- Add `public private(set) var startFailed = false` and `public private(set) var endFailed = false`.
- Change `hostID` to `private var hostID: UUID?` (already var-able) and make `isHost` re-derivable.
- Add the projection:

```swift
private var lifecyclePhase: RideLifecyclePhase? {
    switch phase { case .lobby: return .lobby; case .riding: return .riding; case .ended: return .ended
    default: return nil }
}
```

- In `join(code:)`, replace the unconditional `phase = .riding` with an authoritative decision built from the joined ride:

```swift
let status = RideLifecycleStatus(hostID: joined.ride.hostID,
                                 startedAt: joined.ride.startedAt, endedAt: joined.ride.endedAt)
switch authoritativePhase(status, current: .lobby) {
case .riding: phase = .riding
default:      phase = .lobby
}
```

- Replace `startRiding()`:

```swift
public func startRiding() async {
    guard let rideID else { return }
    startFailed = false
    do {
        try await backend.startRide(rideID: rideID)
        phase = .riding
    } catch {
        startFailed = true
    }
}
```

(The lobby view owns retry by re-invoking `startRiding()`; a session-held backoff `Task` is added in Task 8 alongside the end retry, sharing one retry helper. For this task the Retry button re-calls `startRiding()`.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter GroupRideSessionLifecycleSyncTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift
git commit -m "feat(kit): guest lobby on join + server-confirmed async start"
```

---

## Task 7: Session — live reconcile (`rideStarted`/`rideEnded`/`connected`) + host re-derivation (AuraKit)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift` (add cases)

**Interfaces:**
- Consumes: `optimisticPhase`/`authoritativePhase`, `backend.rideStatus`, `TransportEvent.rideStarted/.rideEnded`.

- [ ] **Step 1: Add failing tests**

```swift
@Test func rideStartedBroadcastMovesLobbyToRiding() async {
    let (session, code) = await LifecycleFixtures.hostedRide(started: false)
    await session.join(code: code)
    await session.beginLiveSession()
    await session.ingest(.rideStarted)
    #expect(session.phase == .riding)
}

@Test func rideEndedBroadcastTearsDown() async {
    let (session, code) = await LifecycleFixtures.hostedRide(started: true)
    await session.join(code: code)
    await session.beginLiveSession()
    await session.ingest(.rideEnded)
    #expect(session.phase == .ended)
}

@Test func connectedReconcileCorrectsPhantomStart() async {
    // In lobby, an optimistic start fired, but the server never recorded it (phantom).
    let (session, code) = await LifecycleFixtures.hostedRide(started: false)
    await session.join(code: code)
    await session.beginLiveSession()
    await session.ingest(.rideStarted)            // optimistic → riding
    #expect(session.phase == .riding)
    await session.ingest(.connected)              // authoritative read: started_at still nil
    #expect(session.phase == .lobby)              // corrected back
}

@Test func connectedReconcileRederivesPromotedHost() async {
    // Guest becomes host server-side (host transferred); connected read flips isHost.
    let (session, code, guestID) = await LifecycleFixtures.hostedRideWithGuestID(started: false)
    await session.join(code: code)
    await LifecycleFixtures.promoteHost(to: guestID)   // mutate the shared fake's ride host
    await session.ingest(.connected)
    #expect(session.isHost == true)
}
```

Extend `LifecycleFixtures` with `hostedRideWithGuestID` and `promoteHost(to:)` (the latter replaces the stored ride's `hostID` in the shared `InMemoryGroupRideBackend.store`).

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GroupRideSessionLifecycleSyncTests`
Expected: FAIL — events fall through / no reconcile.

- [ ] **Step 3: Implement**

In `GroupRideSession.ingest(_:)`, before the trailing `await session.ingest(event)`:
- Remove the `case .memberLeft(let id) where id == hostID:` special case (host-end now arrives as `.rideEnded`).
- Add:

```swift
case .rideStarted:
    if let current = lifecyclePhase {
        applyLifecyclePhase(optimisticPhase(.started, current: current))
    }
case .rideEnded:
    phase = .ended
    teardownLive(session)
case .connected:
    await reconcileFromStatus()
```

Add the helpers:

```swift
/// Authoritative re-read used on connect and on foreground. Corrects a phantom optimistic
/// transition and re-derives host identity (so a promoted host gains controls).
public func reconcileFromStatus() async {
    guard let rideID, let current = lifecyclePhase,
          let status = try? await backend.rideStatus(rideID: rideID) else { return }
    hostID = status.hostID
    if let selfUserID { isHost = (status.hostID == selfUserID) }
    applyLifecyclePhase(authoritativePhase(status, current: current))
}

private func applyLifecyclePhase(_ next: RideLifecyclePhase) {
    switch next {
    case .lobby:  phase = .lobby
    case .riding: phase = .riding
    case .ended:
        phase = .ended
        teardownLive(rideSession)
    }
}
```

Make `isHost` settable: change `public private(set) var isHost` to remain `private(set)` (only the session writes it — fine). Keep `hostID` as `private var`.

Note: `.connected` still forwards to `session.ingest(.connected)` (inner reseeds positions) via the existing trailing call — do not remove that.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter GroupRideSessionLifecycleSyncTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift
git commit -m "feat(kit): live lifecycle reconcile + promoted-host re-derivation"
```

---

## Task 8: Session — reliable end/leave (idempotent, already-gone-is-success, retry) (AuraKit)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift` (add cases)

**Interfaces:**
- Produces: `end()`/`leave()` set `.ended` only on success or already-gone; set `endFailed` + keep chrome on a transient error; a session-held retry `Task`.

- [ ] **Step 1: Add failing tests**

Add a `forceEndError`/`forceLeaveError` spy to `InMemoryGroupRideBackend.Store` and honor it (throw the forced error once, then clear it so a retry succeeds). Then:

```swift
@Test func endTransientFailureKeepsRidingThenRetrySucceeds() async {
    let (session, _) = await LifecycleFixtures.createdHost()
    await session.startRiding()                       // .riding
    await LifecycleFixtures.forceNextEndError(session, .joinFailed)  // one transient failure
    await session.end()
    #expect(session.phase == .riding)                 // chrome retained, not faked ended
    #expect(session.endFailed == true)
    await session.retryEndIfNeeded()                  // second attempt succeeds
    #expect(session.phase == .ended)
}

@Test func endAlreadyGoneCountsAsSuccess() async {
    let (session, _) = await LifecycleFixtures.createdHost()
    await session.startRiding()
    await LifecycleFixtures.forceNextEndError(session, .notHost)   // "already ended"
    await session.end()
    #expect(session.phase == .ended)                  // notHost/notMember ⇒ treat as done
    #expect(session.endFailed == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GroupRideSessionLifecycleSyncTests`
Expected: FAIL — `end()` swallows errors / no `retryEndIfNeeded`.

- [ ] **Step 3: Implement**

Replace `end()` and `leave()`:

```swift
private var pendingEnd = false      // an end/leave the server hasn't confirmed
private var isLeaveNotEnd = false

public func end() async { await finishRide(leaveOnly: false) }
public func leave() async { await finishRide(leaveOnly: true) }

private func finishRide(leaveOnly: Bool) async {
    guard let rideID else { phase = .ended; teardownLive(rideSession); return }
    endFailed = false
    isLeaveNotEnd = leaveOnly
    do {
        if leaveOnly { try await backend.leaveRide(rideID: rideID) }
        else { try await backend.endRide(rideID: rideID) }
        phase = .ended; teardownLive(rideSession)
    } catch GroupRideError.notHost, GroupRideError.notMember {
        // Already gone server-side (or a lost-response retry) — treat as success.
        phase = .ended; teardownLive(rideSession)
    } catch {
        endFailed = true
        pendingEnd = true            // keep chrome (phase stays .riding), allow retry
    }
}

/// Re-attempts a pending end/leave. Bound to a Retry button and to an auto-backoff Task.
public func retryEndIfNeeded() async {
    guard pendingEnd else { return }
    pendingEnd = false
    await finishRide(leaveOnly: isLeaveNotEnd)
}
```

Also refactor `startRiding()`'s retry to a symmetric `retryStartIfNeeded()` and, in production, a session-held backoff `Task` started when `startFailed`/`endFailed` first set and cancelled in `teardownLive`. (Backoff cadence: 2s, 4s, 8s, cap 8s; unit tests drive `retryEndIfNeeded()`/`retryStartIfNeeded()` directly rather than the timer.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter GroupRideSessionLifecycleSyncTests`
Expected: PASS. Also run the existing lifecycle suite to catch regressions: `swift test --package-path AuraCore --filter GroupRideSession`.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift
git commit -m "feat(kit): reliable end/leave with retry, no fake success"
```

---

## Task 9: Supabase conformers (app target)

**Files:**
- Modify: `Aura/Sources/Sync/SupabaseGroupRideBackend.swift`
- Modify: `Aura/Sources/Sync/SupabaseRideSessionTransport.swift`

**Interfaces:**
- Consumes: the RPCs `start_ride`, `ride_status` (Tasks 3), the broadcasts `ride_started`/`ride_ended` (Task 4), `GroupRide.startedAt/endedAt` (Task 2).

- [ ] **Step 1: Implement backend conformers + row decode**

In `SupabaseGroupRideBackend.swift`:
- Add to `GroupRideRow.CodingKeys`: `case startedAt = "started_at"`, `case endedAt = "ended_at"`, and stored `let startedAt: Date?`, `let endedAt: Date?` (optionals → synthesized `decodeIfPresent`; a null or missing key is nil). Thread them into `toDomain()`'s `GroupRide(…, startedAt: startedAt, endedAt: endedAt)`.
- Add:

```swift
public nonisolated func startRide(rideID: UUID) async throws {
    _ = try await client.rpc("start_ride", params: ["p_ride_id": rideID.uuidString]).execute()
}
public nonisolated func rideStatus(rideID: UUID) async throws -> RideLifecycleStatus {
    let row: RideStatusRow = try await client
        .rpc("ride_status", params: ["p_ride_id": rideID.uuidString]).single().execute().value
    return RideLifecycleStatus(hostID: row.hostID, startedAt: row.startedAt, endedAt: row.endedAt)
}
```

Add a `private nonisolated struct RideStatusRow: Decodable` with `hostID`/`startedAt`/`endedAt` mapped from `host_id`/`started_at`/`ended_at`.

- [ ] **Step 2: Implement transport broadcast subscription**

In `SupabaseRideSessionTransport.swift`, subscribe to the `ride_started` and `ride_ended` broadcast events on the same `RideTopic.name(rideID:)` channel the position/member_left streams already use, and yield `.rideStarted`/`.rideEnded` (no body decode needed — the event name is the signal). Mirror the existing per-event `broadcastStream(event:)` wiring.

- [ ] **Step 3: Compile-verify (app target)**

Dispatch the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for the iOS Simulator. Expected: builds clean (no unit tests here; supabase-swift API shapes are compile-verified). Fix any API-shape mismatches the builder reports.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Sync/SupabaseGroupRideBackend.swift Aura/Sources/Sync/SupabaseRideSessionTransport.swift
git commit -m "feat(sync): start_ride/ride_status RPCs + ride_started/ride_ended subscription"
```

---

## Task 10: Guest lobby UI — role split, Leave→pop, start retry (app target)

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupLobbyView.swift`

**Interfaces:**
- Consumes: `session.isHost`, `session.startFailed`, `session.startRiding()` (async), `session.nameMap`, `session.hostID`, `router.pop()`.

- [ ] **Step 1: Implement**

- Read `@Environment(AppRouter.self) private var router`.
- Gate the CTA on role. Host: the existing "Start riding" button, now `Button("Start riding") { Task { await session.startRiding() } }`; when `session.startFailed`, show an inline "Couldn't start — Retry" row whose Retry re-calls `Task { await session.startRiding() }`.
- Guest (`!session.isHost`): replace the Start CTA with a "Waiting for \(hostName) to start…" label (host name from `session.nameMap[session.hostID ?? …]` via `DisplayName.forDisplay`, fallback "the host"), plus a **Leave** button: `Button("Leave") { Task { await session.leave(); router.pop() } }`. Keep the roster, code card, and share link visible for both roles (mirror + invite).

(Guest Leave uses `session.leave()`, whose already-gone-is-success rule from Task 8 guarantees it resolves; then `router.pop()` exits the pushed group-ride entry back home. This is deliberately NOT routed through the `.ended` container.)

- [ ] **Step 2: Compile + preview-verify**

Dispatch the builder agent to build `Aura`. Then confirm the existing `#Preview("Lobby — crew filling in")` still renders and add a guest-mode preview (a second `GroupLobbyPreviewHost` variant that joins as a non-host) showing "Waiting for … to start" + Leave.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/GroupRide/GroupLobbyView.swift
git commit -m "feat(group): guest lobby (waiting + invite + leave) and start retry"
```

---

## Task 11: Flow view — `.ended` surface, `didEnterRiding`, foreground reconcile (app target)

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideFlowView.swift`

**Interfaces:**
- Consumes: `session.phase`, `session.reconcileFromStatus()`, `router.pop()`, `@Environment(\.scenePhase)`.

- [ ] **Step 1: Implement**

- Add `@State private var didEnterRiding = false`, set true in the `.riding`/`.ended` container branch's `.task` (before/after `beginLiveSession`).
- Split the `.ended` rendering:

```swift
case .riding:
    ridingContainer
case .ended:
    if didEnterRiding { ridingContainer }        // D9/D10: keep solo HUD running
    else { endedLobbySurface }                    // ended from lobby/join: a real screen
```

where `ridingContainer` is the existing `GroupNavigateContainer(session:).task { didEnterRiding = true; await session.beginLiveSession() }` and `endedLobbySurface` reuses `dismissMessage(title: "This ride has ended.", systemImage: "flag.checkered")` (its Back already calls `router.pop()`).

- Guard `beginLiveSession` re-entry: it already latches on `didBeginLive`, and the ended-from-lobby branch no longer mounts the container, so `.task` won't re-fire it. Additionally, in `GroupRideSession.beginLiveSession()` add an early `guard phase != .ended else { return }` (belt-and-suspenders — a one-line AuraKit change; add a quick AuraKit test `beginLiveSessionNoOpWhenEnded`).
- Foreground reconcile: add to the root of `content`/the view: `.onChange(of: scenePhase) { _, new in if new == .active { Task { await session.reconcileFromStatus() } } }`.

- [ ] **Step 2: Compile-verify** — builder agent builds `Aura`. Add the AuraKit `beginLiveSessionNoOpWhenEnded` test and run `swift test --package-path AuraCore --filter GroupRideSession`.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/GroupRide/GroupRideFlowView.swift AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideSessionLifecycleSyncTests.swift
git commit -m "feat(group): dedicated ended surface + foreground lifecycle reconcile"
```

---

## Task 12: End call-site — finish only on confirm; failure surfaces; preview migration (app target)

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift`
- Modify: `Aura/Sources/GroupRide/GroupNavigateContainer.swift`
- (surface) `Aura/Sources/Ride/NavigateHUDView.swift` or `+GroupCrew.swift` for the "Couldn't end — Retry" chip.

**Interfaces:**
- Consumes: `session.phase`, `session.endFailed`, `session.retryEndIfNeeded()`.

- [ ] **Step 1: Gate the finish on confirmation**

Rewrite the two host/member finish paths so `endRide()` (finish → summary) runs ONLY once the session reached `.ended`:

```swift
func endGroupRideAsHost() {
    Task {
        await groupSession?.end()
        if groupSession?.phase == .ended { endRide() }   // finished only if server confirmed
    }
}
func endRideAsMember() {
    Task {
        await groupSession?.leave()
        if groupSession?.phase == .ended { endRide() }
    }
}
```

`leaveCrewKeepRiding()` is unchanged (D10: dissolve chrome, keep riding) — its `leave()` failure now sets `endFailed` and retries, which is acceptable because the rider keeps navigating regardless.

- [ ] **Step 2: Surface the failure**

When `showsGroupChrome` and `groupSession?.endFailed == true`, render a non-blocking "Couldn't end — Retry" chip (styled like `reconnectingPill`) whose Retry runs `Task { await groupSession?.retryEndIfNeeded(); if groupSession?.phase == .ended { endRide() } }`. The chip lives in the crew chrome overlay so it only shows while `phase == .riding`.

- [ ] **Step 3: Migrate the preview end-driver**

In `GroupNavigateContainer.swift` preview: change `session.startRiding()` → `await session.startRiding()`, and the ended driver from `await session.ingest(.memberLeft(hostID))` → `await session.ingest(.rideEnded)` (the `member_left == hostID` end heuristic was removed in Task 7). Do the same in any other preview/test using that trick (search `ingest(.memberLeft(` and `.memberLeft(hostID)` / `.memberLeft(session.selfUserID`).

- [ ] **Step 4: Compile-verify** — builder agent builds `Aura`; grep confirms no remaining `member_left`-as-host-end call sites.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift Aura/Sources/GroupRide/GroupNavigateContainer.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "fix(group): finish ride only after server-confirmed end; retry chip"
```

---

## Task 13: Whole-package regression + strict lint + build gate

**Files:** none (verification task).

- [ ] **Step 1: Full AuraCore/AuraKit suite** — `swift test --package-path AuraCore`. Expected: all pass (watch for `.swiftDataSerialized` flakes — unrelated, but re-run once if a SavedPlaceRecord suite aborts).
- [ ] **Step 2: SwiftLint strict** — `swiftlint lint --strict --quiet` at repo root. Expected: exit 0 (local merges skip CI lint; catch it here).
- [ ] **Step 3: App build** — builder agent builds the `Aura` scheme for the iOS Simulator, clean.
- [ ] **Step 4: DB migrations apply in order** — via Supabase MCP, apply `0017` then `0018` on a fresh dev branch and run both pgTAP test bodies; all assertions pass.
- [ ] **Step 5: Commit** (if any lint/build fixes were needed) — `git commit -m "chore(group): lint + regression pass for lifecycle sync"`.

---

## Deferred to device-verify (needs two identities; Silver Bar currently unavailable)

Not plan tasks — the on-device tail once a second device is back: synchronized start (host tap → guest flips within ~1s), late-join catch-up, host-ends-while-guest-in-lobby → ended surface, end-under-lost-signal retry, and host-transfer-in-lobby (promoted host gains Start).

---

## Self-review

**Spec coverage:** started_at/start_ride/ride_status (T3), idempotent end + ride_ended, drop host member_left (T4), two-mode reconcile (T1), GroupRide lifecycle (T2), transport events + backend seams + fakes (T5), guest lobby on join + async start (T6), live reconcile + host re-derivation + phantom correction (T7), reliable end/leave retry (T8), Supabase conformers + row decode (T9), guest lobby UI + Leave→pop + start retry (T10), ended surface + didEnterRiding + beginLiveSession guard + foreground reconcile (T11), end call-site confirm-gating + failure chip + preview migration (T12), regression/lint/build/DB gate (T13). Every §1–§7 spec item maps to a task. The `.joined`-toast-in-lobby and force-quit-host items are explicitly out of scope (own tickets).

**Placeholder scan:** DB pgTAP tests (T3/T4) describe assertions rather than pasting full SQL bodies — this is deliberate: they mirror the exact harness in `supabase/tests/0005`/`0015`, which the implementer copies; the migration SQL itself is complete. All Swift steps carry complete code.

**Type consistency:** `RideLifecycleStatus(hostID:startedAt:endedAt:)`, `authoritativePhase(_:current:)`, `optimisticPhase(_:current:)`, `startRide(rideID:)`, `rideStatus(rideID:)->RideLifecycleStatus`, `TransportEvent.rideStarted/.rideEnded`, `startRiding() async`, `retryEndIfNeeded()`, `reconcileFromStatus()`, `startFailed`/`endFailed` — used consistently T1→T13.
