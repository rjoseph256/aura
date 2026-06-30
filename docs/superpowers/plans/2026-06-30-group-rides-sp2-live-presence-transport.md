# Group Rides SP2 — Live Presence Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the live transport that makes group-ride members appear on each other's maps in real time, on top of SP1's Supabase backend.

**Architecture:** Positions flow on one private Realtime channel per ride (`ride:<id>`), fanned out by `realtime.send` from inside SP1's `record_track_points` RPC (Broadcast-from-Database, so backgrounded riders stay visible). No Presence: peer status (riding/stopped/dropped) is derived from the position stream by pure AuraCore reducers. The snapshot RPC (`ride_live_snapshot`) is the correctness anchor; live deltas are best-effort. All logic lives in the hermetic AuraCore/AuraKit package; `supabase-swift` stays in the app target.

**Tech Stack:** Supabase Postgres + Realtime + RLS, pgTAP; Swift 6 / AuraCore (pure) + AuraKit (seams) + AuraSync (app target, supabase-swift); Swift Testing.

## Global Constraints

- **Layering invariant:** `supabase-swift` lives ONLY in the app target (`Aura/Sources/Sync`). NEVER add it to `AuraCore/Package.swift`. Pure types → AuraCore; seams + `RideSession` → AuraKit; live conformer → `Aura/Sources/Sync`.
- **Raw speed never crosses the wire and is never stored server-side.** Only a `MotionState` (`moving`/`stopped`) bit, computed sender-side, is broadcast. (Spec §2.3, §4.)
- **Every DB function:** `security definer set search_path = ''`, `revoke execute from public` + `grant execute to authenticated`, derives `auth.uid()` itself. (SP1 convention.)
- **Swift 6 default-MainActor (app target):** backend types doing I/O are `nonisolated`; Decodable wire structs used from `nonisolated` methods are themselves `nonisolated`. Every type crossing the `@MainActor` ↔ `nonisolated` boundary is `Sendable`.
- **`RideSession` contains no `Date()` and no `Task.sleep`.** Time is injected: the owner's ticker passes `now: Date` into `stalenessTick(now:)` / `publishIfDue(now:)`. (Realizes spec §7.3's "no real-time deps in the session" via push-injection instead of a third-party TestClock, since the repo has none.)
- **Config invariant:** `droppedTimeout >= ~4× backgroundInterval` so a backgrounded slow-cadence rider never false-trips `dropped`. (Spec §6.)
- **pgTAP identity:** use the `pg_temp` `SECURITY DEFINER` helper + `set_config('request.jwt.claims', json, true)` pattern from SP1's `0003`/`0005` tests; pooled connections mishandle interleaved top-level claims-switching.
- **DB migrations** continue the `00NN_*.sql` sequence and are applied to the live `aura` project (ref `wyofhmufnttiqyjkrbxi`) via the Supabase MCP after `db-tests` pgTAP is green, exactly as SP1.
- **Deployment checklist (non-migration, recorded in Task 16):** Realtime "Allow public access" OFF; Realtime message retention ≤ 48h.
- Platform floor is iOS 17 / macOS 14 — `Duration` and `Clock` are available.
- Test commands: AuraCore/AuraKit → `swift test --package-path AuraCore`; pgTAP → `supabase test db` (run from repo root; requires Docker, gated by CI for contributors without it).

---

## File Structure

**Database (new migrations + tests):**
- `supabase/migrations/0010_topic_helper.sql` + `supabase/tests/0010_topic_helper_test.sql` — `ride_id_from_topic`.
- `supabase/migrations/0011_realtime_authz.sql` + `supabase/tests/0011_realtime_authz_test.sql` — `realtime.messages` SELECT policy.
- `supabase/migrations/0012_record_broadcast.sql` + `supabase/tests/0012_record_broadcast_test.sql` — `record_track_points` broadcast.
- `supabase/migrations/0013_live_snapshot.sql` + `supabase/tests/0013_live_snapshot_test.sql` — `ride_live_snapshot`.
- `supabase/migrations/0014_join_cap_lock.sql` + `supabase/tests/0014_join_cap_lock_test.sql` — atomic join cap.
- `supabase/migrations/0015_member_left.sql` + `supabase/tests/0015_member_left_test.sql` — `member_left` broadcast on leave/end.

**AuraCore (pure):**
- `AuraCore/Sources/AuraCore/GroupRide/LivePosition.swift` — `MotionState`, `LivePositionPayload`.
- `AuraCore/Sources/AuraCore/GroupRide/MotionClassifier.swift` — `SpeedSample`, `MotionClassifier`.
- `AuraCore/Sources/AuraCore/GroupRide/PeerStatus.swift` — `PeerStatus`, `RidePeer`, `PeerStatusReducer`.
- `AuraCore/Sources/AuraCore/GroupRide/LiveShareCadence.swift` — `RideLifecycle`, `LiveShareCadence`.
- `AuraCore/Sources/AuraCore/GroupRide/LivePresenceState.swift` — `LivePresenceState`.
- `AuraCore/Sources/AuraCore/GroupRide/PointOutbox.swift` — `PointOutbox`.

**AuraKit (seams):**
- `AuraCore/Sources/AuraKit/GroupRide/RideSessionTransport.swift` — `TransportEvent`, `RideLiveSubscription`, `RideSessionTransport`, `InMemoryRideSessionTransport`.
- `AuraCore/Sources/AuraKit/GroupRide/RideSession.swift` — `RideSession`, `GroupLocationSink`.
- Modify `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` — optional `groupSink` handoff.

**App target:**
- `Aura/Sources/Sync/SupabaseRideSessionTransport.swift` — live conformer.

**Tests:** `AuraCore/Tests/AuraCoreTests/GroupRide/*` and `AuraCore/Tests/AuraKitTests/GroupRide/*`.

---

### Task 1: `ride_id_from_topic` safe-parse helper

**Files:**
- Create: `supabase/migrations/0010_topic_helper.sql`
- Test: `supabase/tests/0010_topic_helper_test.sql`

**Interfaces:**
- Produces: `public.ride_id_from_topic(p_topic text) returns uuid` — returns the uuid for `ride:<uuid>`, `null` for anything malformed/non-ride/null. Used by Task 2's RLS policy.

- [ ] **Step 1: Write the failing test**

`supabase/tests/0010_topic_helper_test.sql`:
```sql
begin;
select plan(4);
select is(public.ride_id_from_topic('ride:aaaaaaaa-0000-0000-0000-000000000001'),
          'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'parses a ride topic');
select is(public.ride_id_from_topic('lobby:123'), null, 'non-ride topic -> null');
select is(public.ride_id_from_topic('ride:not-a-uuid'), null, 'malformed uuid -> null');
select is(public.ride_id_from_topic(null), null, 'null topic -> null');
select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db` — Expected: FAIL (`function public.ride_id_from_topic(text) does not exist`).

- [ ] **Step 3: Write the migration**

`supabase/migrations/0010_topic_helper.sql`:
```sql
-- Safe parser for Realtime channel topics of the form 'ride:<uuid>'. Returns null
-- (never raises) on any non-ride or malformed topic, so the realtime.messages RLS
-- policy that calls it denies cleanly instead of failing the whole channel join.
create function public.ride_id_from_topic(p_topic text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_topic is null or p_topic not like 'ride:%' then
    return null;
  end if;
  return substring(p_topic from 6)::uuid;
exception
  when others then
    return null;
end;
$$;
grant execute on function public.ride_id_from_topic(text) to authenticated;
```

- [ ] **Step 4: Run to verify it passes**

Run: `supabase test db` — Expected: `0010_topic_helper_test.sql .. ok`, all 4 pass.

- [ ] **Step 5: Commit**
```bash
git add supabase/migrations/0010_topic_helper.sql supabase/tests/0010_topic_helper_test.sql
git commit -m "feat(db): ride_id_from_topic safe topic parser for realtime authz"
```

---

### Task 2: `realtime.messages` SELECT RLS policy (channel authz)

**Files:**
- Create: `supabase/migrations/0011_realtime_authz.sql`
- Test: `supabase/tests/0011_realtime_authz_test.sql`

**Interfaces:**
- Consumes: `public.ride_id_from_topic(text)` (Task 1); `public.is_ride_member(uuid)` (SP1).
- Produces: a SELECT policy `"ride members read broadcast"` on `realtime.messages` gating private-channel subscription on ride membership.

**Note:** `supabase test db` runs as a superuser (`bypassrls`), so the policy's runtime effect on a connecting client cannot be exercised in pgTAP. The deterministic test asserts the policy exists with the expected shape (extension filter + membership check); the live gate is verified manually in Task 16 (subscribe as a non-member → denied).

- [ ] **Step 1: Write the failing test**

`supabase/tests/0011_realtime_authz_test.sql`:
```sql
begin;
select plan(3);
select isnt(
  (select count(*) from pg_policies
     where schemaname = 'realtime' and tablename = 'messages'
       and policyname = 'ride members read broadcast'), 0::bigint,
  'broadcast read policy exists');
select ok(
  (select qual from pg_policies
     where policyname = 'ride members read broadcast') like '%is_ride_member%',
  'policy gates on is_ride_member');
select ok(
  (select qual from pg_policies
     where policyname = 'ride members read broadcast') like '%broadcast%',
  'policy is scoped to the broadcast extension');
select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db` — Expected: FAIL (policy not found, count = 0).

- [ ] **Step 3: Write the migration**

`supabase/migrations/0011_realtime_authz.sql`:
```sql
-- Gate subscription to a private ride channel on ride membership. Realtime evaluates
-- this SELECT policy on realtime.messages at channel-join time (with the user's JWT).
-- The topic guard + safe parser (0010) make a bad/foreign topic deny cleanly.
create policy "ride members read broadcast" on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and realtime.topic() like 'ride:%'
    and (select public.is_ride_member(public.ride_id_from_topic(realtime.topic())))
  );
```

- [ ] **Step 4: Run to verify it passes**

Run: `supabase test db` — Expected: `0011_realtime_authz_test.sql .. ok`, 3 pass.

- [ ] **Step 5: Commit**
```bash
git add supabase/migrations/0011_realtime_authz.sql supabase/tests/0011_realtime_authz_test.sql
git commit -m "feat(db): members-only RLS on realtime.messages for ride channels"
```

---

### Task 3: `record_track_points` broadcasts the newest point

**Files:**
- Create: `supabase/migrations/0012_record_broadcast.sql`
- Test: `supabase/tests/0012_record_broadcast_test.sql`

**Interfaces:**
- Consumes: `public.is_ride_member(uuid)`, `public.create_ride(jsonb)`, `realtime.send(jsonb, text, text, boolean)`.
- Produces: `record_track_points(uuid, jsonb)` now also calls `realtime.send(...)` with the newest point (`event = 'position'`, topic `ride:<id>`, private). Accepts an optional `motion_state` per point. No new column.

- [ ] **Step 1: Write the failing test**

`supabase/tests/0012_record_broadcast_test.sql`:
```sql
-- Driven through a pg_temp SECURITY DEFINER helper (SP1 pattern). Asserts that a
-- member's record_track_points emits a 'position' row into realtime.messages, and a
-- non-member is rejected. The daily realtime.messages partition is created in setup,
-- since realtime.send drops (warns) rather than errors when no partition exists.
begin;
select plan(4);

-- Ensure today's realtime.messages partition exists. In a pure pgTAP run no WebSocket
-- client ever connects, so Realtime never creates the daily partition; without it
-- realtime.send silently warns and drops the row (the test would then see 0 with no
-- diagnostic). Bounds use ::timestamp because realtime.messages partitions by
-- inserted_at (timestamp without time zone). Guard + assert so a partition problem
-- fails loudly here, not as a phantom 0 at the broadcast assertion.
do $$
begin
  execute format(
    'create table if not exists realtime.messages_%s partition of realtime.messages for values from (%L) to (%L)',
    to_char(current_date, 'YYYY_MM_DD'), current_date::timestamp, (current_date + 1)::timestamp);
exception when others then
  raise notice 'partition setup failed: %', sqlerrm;
end $$;
select ok(
  exists(select 1 from pg_catalog.pg_inherits i
         join pg_catalog.pg_class c on c.oid = i.inhrelid
         where c.relname = 'messages_'||to_char(current_date, 'YYYY_MM_DD')),
  'today''s realtime.messages partition exists');

insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');

create function pg_temp.broadcast_flow(out position_rows int, out newest_motion text, out nonmember_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id into rid from public.create_ride('{}'::jsonb);
  perform public.record_track_points(rid, jsonb_build_array(
    jsonb_build_object('recorded_at', now()::text, 'lat', 37.0, 'lon', -122.0,
                       'progress_meters', 10.0, 'motion_state', 'moving')));
  select count(*)::int into position_rows from realtime.messages
    where topic = 'ride:'||rid::text and event = 'position';
  -- prove the payload shape, not just that some row landed
  select payload->>'motionState' into newest_motion from realtime.messages
    where topic = 'ride:'||rid::text and event = 'position'
    order by inserted_at desc limit 1;
  -- user 2 is not a member -> rejected
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  begin
    perform public.record_track_points(rid, jsonb_build_array(
      jsonb_build_object('recorded_at', now()::text, 'lat', 1.0, 'lon', 1.0, 'progress_meters', 0.0)));
    nonmember_rejected := false;
  exception when others then nonmember_rejected := true; end;
end; $$;

create temp table bf as select * from pg_temp.broadcast_flow();
select cmp_ok((select position_rows from bf), '>=', 1, 'member record broadcasts a position');
select is((select newest_motion from bf), 'moving', 'broadcast payload carries motionState');
select is((select nonmember_rejected from bf), true, 'non-member record is rejected');
select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db` — Expected: FAIL (`position_rows` = 0; current function does not broadcast).

- [ ] **Step 3: Write the migration**

`supabase/migrations/0012_record_broadcast.sql`:
```sql
-- Extend record_track_points: after the durable insert, broadcast the newest point in
-- the batch to the ride's private channel. One write = durable + live (Broadcast-from-
-- Database). realtime.send swallows its own errors (warns), so a failed broadcast never
-- fails the ride; correctness of the live view rests on ride_live_snapshot, not on send.
-- Batch is always single-writer (auth.uid()), so "newest" = max recorded_at. motion_state
-- rides only on the broadcast; it is not persisted (no column). No raw speed is sent.
create or replace function public.record_track_points(p_ride_id uuid, p_points jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_newest jsonb;
begin
  if v_uid is null then raise exception 'unauthorized'; end if;
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  if jsonb_array_length(p_points) > 200 then raise exception 'batch too large'; end if;

  insert into public.ride_track_points (ride_id, user_id, recorded_at, lat, lon, progress_meters)
  select p_ride_id, v_uid,
         (e->>'recorded_at')::timestamptz, (e->>'lat')::double precision,
         (e->>'lon')::double precision, (e->>'progress_meters')::double precision
  from jsonb_array_elements(p_points) as e
  on conflict (ride_id, user_id, recorded_at) do nothing;

  update public.ride_members
    set last_seen_at = now()
    where ride_id = p_ride_id and user_id = v_uid;

  select e into v_newest
  from jsonb_array_elements(p_points) as e
  order by (e->>'recorded_at')::timestamptz desc
  limit 1;

  if v_newest is not null then
    perform realtime.send(
      jsonb_build_object(
        'userID', v_uid,
        'lat', (v_newest->>'lat')::double precision,
        'lon', (v_newest->>'lon')::double precision,
        'progressMeters', (v_newest->>'progress_meters')::double precision,
        'recordedAt', v_newest->>'recorded_at',
        'motionState', coalesce(v_newest->>'motion_state', 'moving')
      ),
      'position',
      'ride:' || p_ride_id::text,
      true);
  end if;
end;
$$;
revoke execute on function public.record_track_points(uuid, jsonb) from public;
grant execute on function public.record_track_points(uuid, jsonb) to authenticated;
```

- [ ] **Step 4: Run to verify it passes**

Run: `supabase test db` — Expected: `0012_record_broadcast_test.sql .. ok`, 4 pass. (All prior tests still pass.)

- [ ] **Step 5: Commit**
```bash
git add supabase/migrations/0012_record_broadcast.sql supabase/tests/0012_record_broadcast_test.sql
git commit -m "feat(db): record_track_points broadcasts newest point to ride channel"
```

---

### Task 4: `ride_live_snapshot` (the reconnect/seed anchor)

**Files:**
- Create: `supabase/migrations/0013_live_snapshot.sql`
- Test: `supabase/tests/0013_live_snapshot_test.sql`

**Interfaces:**
- Consumes: `public.is_ride_member(uuid)`, `public.create_ride(jsonb)`, `public.record_track_points(uuid, jsonb)`.
- Produces: `ride_live_snapshot(p_ride_id uuid) returns table(user_id uuid, display_name text, lat double precision, lon double precision, progress_meters double precision, recorded_at timestamptz)` — latest row per member, members-only. (No `motion_state`: it is not stored; the Swift conformer seeds peers as `.moving`.)

- [ ] **Step 1: Write the failing test**

`supabase/tests/0013_live_snapshot_test.sql`:
```sql
begin;
select plan(3);
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');

create function pg_temp.snap_flow(out row_count int, out latest_progress double precision, out nonmember_rejected boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id into rid from public.create_ride('{}'::jsonb);
  -- two points for the host; the later one (progress 50) must win
  perform public.record_track_points(rid, jsonb_build_array(
    jsonb_build_object('recorded_at', (now() - interval '10 s')::text, 'lat', 37.0, 'lon', -122.0, 'progress_meters', 10.0)));
  perform public.record_track_points(rid, jsonb_build_array(
    jsonb_build_object('recorded_at', now()::text, 'lat', 37.1, 'lon', -122.1, 'progress_meters', 50.0)));
  select count(*)::int, max(progress_meters) into row_count, latest_progress
    from public.ride_live_snapshot(rid);
  -- user 2 is not a member -> snapshot rejected
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  begin
    perform * from public.ride_live_snapshot(rid);
    nonmember_rejected := false;
  exception when others then nonmember_rejected := true; end;
end; $$;

create temp table sf as select * from pg_temp.snap_flow();
select is((select row_count from sf), 1, 'one row per member');
select is((select latest_progress from sf), 50.0, 'returns the latest point per member');
select is((select nonmember_rejected from sf), true, 'snapshot is members-only');
select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db` — Expected: FAIL (`function public.ride_live_snapshot(uuid) does not exist`).

- [ ] **Step 3: Write the migration**

`supabase/migrations/0013_live_snapshot.sql`:
```sql
-- Latest track point per member, joined to display_name, members-only. Seeds the live
-- map on join and re-seeds on every reconnect (the live view's source of truth; live
-- broadcast deltas are best-effort). Deterministic latest-per-member via distinct on +
-- ctid tiebreaker. motion_state is not stored, so it is not returned; the client seeds
-- peers as moving and lets the next delta refine.
create function public.ride_live_snapshot(p_ride_id uuid)
returns table (
  user_id uuid,
  display_name text,
  lat double precision,
  lon double precision,
  progress_meters double precision,
  recorded_at timestamptz)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  if not (select public.is_ride_member(p_ride_id)) then raise exception 'unauthorized'; end if;
  return query
    select distinct on (tp.user_id)
           tp.user_id, pr.display_name, tp.lat, tp.lon, tp.progress_meters, tp.recorded_at
    from public.ride_track_points tp
    join public.profiles pr on pr.id = tp.user_id
    where tp.ride_id = p_ride_id
    order by tp.user_id, tp.recorded_at desc, tp.ctid desc;
end;
$$;
revoke execute on function public.ride_live_snapshot(uuid) from public;
grant execute on function public.ride_live_snapshot(uuid) to authenticated;
```

- [ ] **Step 4: Run to verify it passes**

Run: `supabase test db` — Expected: `0013_live_snapshot_test.sql .. ok`, 3 pass.

- [ ] **Step 5: Commit**
```bash
git add supabase/migrations/0013_live_snapshot.sql supabase/tests/0013_live_snapshot_test.sql
git commit -m "feat(db): ride_live_snapshot latest-per-member seed for live view"
```

---

### Task 5: `join_ride` atomic cap (advisory lock)

**Files:**
- Create: `supabase/migrations/0014_join_cap_lock.sql`
- Test: `supabase/tests/0014_join_cap_lock_test.sql`

**Interfaces:**
- Produces: `join_ride(text)` now takes a per-ride transaction advisory lock before the count-then-insert, so concurrent joins cannot exceed 8. Behavior (idempotent re-join, generic `'join failed'` oracle, rate limit) is unchanged.

**Note:** `supabase test db` is single-session, so a true two-transaction race can't be staged. The test proves (a) the serial cap/idempotency still hold, and (b) `join_ride` acquires an advisory lock (held until the surrounding transaction ends), which is what serializes concurrent callers.

- [ ] **Step 1: Write the failing test**

`supabase/tests/0014_join_cap_lock_test.sql`:
```sql
begin;
select plan(3);
insert into auth.users (instance_id, id, aud, role, email)
select '00000000-0000-0000-0000-000000000000',
       ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid,
       'authenticated','authenticated','u'||g||'@test.dev'
from generate_series(1,9) g;

create function pg_temp.cap_flow(out final_members int, out ninth_rejected boolean, out advisory_held boolean)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text; g int;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  for g in 2..8 loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', ('aaaaaaaa-0000-0000-0000-00000000000'||g)::uuid)::text, true);
    perform public.join_ride(code);
  end loop;
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000009"}', true);
  begin perform public.join_ride(code); ninth_rejected := false;
  exception when others then ninth_rejected := true; end;
  select count(*)::int into final_members from public.ride_members where ride_id = rid;
  -- The per-ride advisory lock taken inside join_ride is xact-scoped (a SECURITY DEFINER
  -- call is not a transaction boundary), so it is still held in this uncommitted test
  -- transaction. Pin to THIS backend AND the exact key so the assertion proves the
  -- per-ride lock, not just "some advisory lock somewhere is held".
  select exists(
    select 1 from pg_locks
    where locktype = 'advisory'
      and pid = pg_backend_pid()
      and ((classid::bigint << 32) | (objid::bigint & 4294967295))
          = hashtextextended(rid::text, 0)
  ) into advisory_held;
end; $$;

create temp table cf as select * from pg_temp.cap_flow();
select is((select final_members from cf), 8, 'exactly 8 members after a 9th attempt');
select is((select ninth_rejected from cf), true, '9th join rejected by the cap');
select is((select advisory_held from cf), true, 'join_ride takes a per-ride advisory lock');
select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db` — Expected: FAIL (`advisory_held` = false; current `join_ride` takes no advisory lock).

- [ ] **Step 3: Write the migration**

`supabase/migrations/0014_join_cap_lock.sql`:
```sql
-- Close the join-cap TOCTOU: `where count < 8` does not serialize under READ COMMITTED
-- (two joiners each see 7, both insert -> 9). Take a per-ride transaction advisory lock
-- before the count, so concurrent joins to the same ride are serialized and the hard cap
-- of 8 holds. Generic 'join failed' oracle, rate limit, and idempotent re-join unchanged.
create or replace function public.join_ride(p_code text)
returns public.rides
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_ride public.rides;
  v_recent int;
  v_count int;
begin
  if v_uid is null then raise exception 'join failed'; end if;

  insert into public.join_attempts (user_id) values (v_uid);
  select count(*) into v_recent from public.join_attempts
    where user_id = v_uid and attempted_at > now() - interval '1 minute';
  if v_recent > 10 then raise exception 'join failed'; end if;

  select * into v_ride from public.rides
    where join_code = p_code and status = 'active';
  if v_ride.id is null then raise exception 'join failed'; end if;

  if exists (select 1 from public.ride_members
             where ride_id = v_ride.id and user_id = v_uid) then
    return v_ride;
  end if;

  -- Serialize concurrent joins to this ride so the count-then-insert is race-free.
  perform pg_advisory_xact_lock(hashtextextended(v_ride.id::text, 0));

  select count(*) into v_count from public.ride_members where ride_id = v_ride.id;
  if v_count >= 8 then raise exception 'join failed'; end if;

  insert into public.ride_members (ride_id, user_id, role)
  values (v_ride.id, v_uid, 'member');
  return v_ride;
end;
$$;
revoke execute on function public.join_ride(text) from public;
grant execute on function public.join_ride(text) to authenticated;
```

- [ ] **Step 4: Run to verify it passes**

Run: `supabase test db` — Expected: `0014_join_cap_lock_test.sql .. ok`, 3 pass. (SP1's `0003_join_ride_test` still passes.)

- [ ] **Step 5: Commit**
```bash
git add supabase/migrations/0014_join_cap_lock.sql supabase/tests/0014_join_cap_lock_test.sql
git commit -m "fix(db): close join_ride cap TOCTOU with per-ride advisory lock"
```

---

### Task 6: `member_left` broadcast on leave/end

**Files:**
- Create: `supabase/migrations/0015_member_left.sql`
- Test: `supabase/tests/0015_member_left_test.sql`

**Interfaces:**
- Produces: `leave_ride(uuid)` and `end_ride(uuid)` each emit `realtime.send({userID}, 'member_left', 'ride:<id>', true)` for the acting user, so live peers prune the departing/ending member's dot immediately. All existing behavior (host transfer, retention formula, host-only guard) is unchanged.

- [ ] **Step 1: Write the failing test**

`supabase/tests/0015_member_left_test.sql`:
```sql
begin;
select plan(3);
-- Partition guard + assertion (see Task 3 test for the rationale: realtime.send drops
-- silently when today's partition is absent, which a pure pgTAP run never creates).
do $$
begin
  execute format(
    'create table if not exists realtime.messages_%s partition of realtime.messages for values from (%L) to (%L)',
    to_char(current_date, 'YYYY_MM_DD'), current_date::timestamp, (current_date + 1)::timestamp);
exception when others then
  raise notice 'partition setup failed: %', sqlerrm;
end $$;
select ok(
  exists(select 1 from pg_catalog.pg_inherits i
         join pg_catalog.pg_class c on c.oid = i.inhrelid
         where c.relname = 'messages_'||to_char(current_date, 'YYYY_MM_DD')),
  'today''s realtime.messages partition exists');
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000001','authenticated','authenticated','u1@test.dev'),
  ('00000000-0000-0000-0000-000000000000','bbbbbbbb-0000-0000-0000-000000000002','authenticated','authenticated','u2@test.dev');

-- Drives both broadcast paths: a non-host member leaves (leave_ride), and the host
-- ends the ride (end_ride). Each must emit a member_left row for the acting user.
create function pg_temp.leave_flow(out leave_rows int, out end_rows int)
language plpgsql security definer set search_path = '' as $$
declare rid uuid; code text;
begin
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  select id, join_code into rid, code from public.create_ride('{}'::jsonb);
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  perform public.join_ride(code);
  perform public.leave_ride(rid);
  select count(*)::int into leave_rows from realtime.messages
    where topic = 'ride:'||rid::text and event = 'member_left'
      and payload->>'userID' = 'bbbbbbbb-0000-0000-0000-000000000002';
  -- host (user 1, still the only remaining member) ends the ride
  perform set_config('request.jwt.claims','{"sub":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
  perform public.end_ride(rid);
  select count(*)::int into end_rows from realtime.messages
    where topic = 'ride:'||rid::text and event = 'member_left'
      and payload->>'userID' = 'aaaaaaaa-0000-0000-0000-000000000001';
end; $$;

create temp table mlf as select * from pg_temp.leave_flow();
select cmp_ok((select leave_rows from mlf), '>=', 1, 'leave_ride broadcasts member_left for the leaver');
select cmp_ok((select end_rows from mlf), '>=', 1, 'end_ride broadcasts member_left for the host');
select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db` — Expected: FAIL (`leave_rows` = 0; current `leave_ride` does not broadcast).

- [ ] **Step 3: Write the migration**

`supabase/migrations/0015_member_left.sql`:
```sql
-- Emit a member_left broadcast when a rider leaves or a host ends, so live peers prune
-- the departing member's dot immediately rather than waiting out the dropped timeout.
-- Bodies are otherwise identical to 0005 (host transfer, retention formula preserved).
create or replace function public.leave_ride(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_next uuid;
  v_last timestamptz;
begin
  select role into v_role from public.ride_members
    where ride_id = p_ride_id and user_id = v_uid;
  if v_role is null then raise exception 'not a member'; end if;

  delete from public.ride_members where ride_id = p_ride_id and user_id = v_uid;

  if v_role = 'host' then
    select user_id into v_next from public.ride_members
      where ride_id = p_ride_id order by joined_at asc limit 1;
    if v_next is null then
      select max(recorded_at) into v_last from public.ride_track_points where ride_id = p_ride_id;
      update public.rides set status = 'ended', ended_at = now(),
        expires_at = least(now() + interval '48 hours',
                           coalesce(v_last, now()) + interval '48 hours')
        where id = p_ride_id;
    else
      update public.ride_members set role = 'host'
        where ride_id = p_ride_id and user_id = v_next;
      update public.rides set host_id = v_next where id = p_ride_id;
    end if;
  end if;

  perform realtime.send(jsonb_build_object('userID', v_uid),
                        'member_left', 'ride:' || p_ride_id::text, true);
end;
$$;
revoke execute on function public.leave_ride(uuid) from public;
grant execute on function public.leave_ride(uuid) to authenticated;

create or replace function public.end_ride(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_host uuid;
  v_last timestamptz;
begin
  select host_id into v_host from public.rides where id = p_ride_id;
  if v_host is null or v_host <> v_uid then raise exception 'not host'; end if;
  select max(recorded_at) into v_last from public.ride_track_points where ride_id = p_ride_id;
  update public.rides
    set status = 'ended', ended_at = now(),
        expires_at = least(now() + interval '48 hours',
                           coalesce(v_last, now()) + interval '48 hours')
    where id = p_ride_id;

  perform realtime.send(jsonb_build_object('userID', v_uid),
                        'member_left', 'ride:' || p_ride_id::text, true);
end;
$$;
revoke execute on function public.end_ride(uuid) from public;
grant execute on function public.end_ride(uuid) to authenticated;
```

- [ ] **Step 4: Run to verify it passes**

Run: `supabase test db` — Expected: `0015_member_left_test.sql .. ok`, 3 pass. (SP1's `0005_lifecycle_test` still passes — host transfer unchanged.)

- [ ] **Step 5: Commit**
```bash
git add supabase/migrations/0015_member_left.sql supabase/tests/0015_member_left_test.sql
git commit -m "feat(db): member_left broadcast on leave_ride/end_ride"
```

---

### Task 7: `MotionState` + `LivePositionPayload`

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/LivePosition.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/LivePositionTests.swift`

**Interfaces:**
- Produces: `MotionState` (`moving`/`stopped`); `LivePositionPayload { userID: UUID, coordinate: Coordinate, progressMeters: Double, recordedAt: Date, motionState: MotionState }`, `Codable`+`Sendable`. The app-target conformer maps Realtime JSON (`userID/lat/lon/progressMeters/recordedAt/motionState`) into this domain type; this type is not itself wire-shaped.

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GroupRide/LivePositionTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraCore

struct LivePositionTests {
    @Test func payloadRoundTripsThroughCodable() throws {
        let payload = LivePositionPayload(
            userID: UUID(),
            coordinate: Coordinate(latitude: 37.0, longitude: -122.0),
            progressMeters: 123.4,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            motionState: .stopped)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(LivePositionPayload.self, from: data)
        #expect(decoded == payload)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter LivePositionTests` — Expected: build failure (`LivePositionPayload` undefined).

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraCore/GroupRide/LivePosition.swift`:
```swift
import Foundation

/// Sender-derived motion state. Only this one-bit signal is shared between riders;
/// raw speed never leaves the publishing device (spec: "speed is not shared").
public enum MotionState: String, Codable, Sendable {
    case moving
    case stopped
}

/// One live position update for a rider, in domain form. The app-target Supabase
/// conformer maps the flat Realtime JSON (userID/lat/lon/progressMeters/recordedAt/
/// motionState) into this; this type is the domain payload, not the wire shape.
public struct LivePositionPayload: Codable, Equatable, Sendable {
    public let userID: UUID
    public let coordinate: Coordinate
    public let progressMeters: Double
    public let recordedAt: Date
    public let motionState: MotionState

    public init(userID: UUID, coordinate: Coordinate, progressMeters: Double,
                recordedAt: Date, motionState: MotionState) {
        self.userID = userID
        self.coordinate = coordinate
        self.progressMeters = progressMeters
        self.recordedAt = recordedAt
        self.motionState = motionState
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter LivePositionTests` — Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/LivePosition.swift AuraCore/Tests/AuraCoreTests/GroupRide/LivePositionTests.swift
git commit -m "feat(core): MotionState + LivePositionPayload live-transport models"
```

---

### Task 8: `MotionClassifier` (sender-side stopped decision)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/MotionClassifier.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/MotionClassifierTests.swift`

**Interfaces:**
- Produces: `SpeedSample { speed: Double, at: Date }`; `MotionClassifier { stoppedSpeed: Double, stoppedDuration: TimeInterval }` with `classify(_ samples: [SpeedSample], now: Date) -> MotionState`. `stopped` iff every sample in the trailing `stoppedDuration` window is below `stoppedSpeed` AND the window is fully covered (earliest in-window sample is at least `stoppedDuration` old).

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GroupRide/MotionClassifierTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraCore

struct MotionClassifierTests {
    let clf = MotionClassifier(stoppedSpeed: 0.5, stoppedDuration: 18)
    let now = Date(timeIntervalSince1970: 1000)

    @Test func sustainedLowSpeedIsStopped() {
        let samples = (0...20).map { SpeedSample(speed: 0.1, at: now.addingTimeInterval(Double(-$0))) }
        #expect(clf.classify(samples, now: now) == .stopped)
    }
    @Test func aFastSampleInWindowIsMoving() {
        var samples = (0...20).map { SpeedSample(speed: 0.1, at: now.addingTimeInterval(Double(-$0))) }
        samples.append(SpeedSample(speed: 6.0, at: now.addingTimeInterval(-5)))
        #expect(clf.classify(samples, now: now) == .moving)
    }
    @Test func shortLowWindowIsStillMoving() {
        // only 5s of low-speed coverage, less than stoppedDuration -> not yet stopped
        let samples = (0...5).map { SpeedSample(speed: 0.1, at: now.addingTimeInterval(Double(-$0))) }
        #expect(clf.classify(samples, now: now) == .moving)
    }
    @Test func noSamplesIsMoving() {
        #expect(clf.classify([], now: now) == .moving)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter MotionClassifierTests` — Expected: build failure (`MotionClassifier` undefined).

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraCore/GroupRide/MotionClassifier.swift`:
```swift
import Foundation

/// A timestamped speed reading on the publishing device.
public struct SpeedSample: Equatable, Sendable {
    public let speed: Double      // metres/second
    public let at: Date
    public init(speed: Double, at: Date) {
        self.speed = speed
        self.at = at
    }
}

/// Decides a rider's own `MotionState` from their recent speed history, so the raw
/// speed scalar never has to leave the device. `stopped` requires a fully-covered
/// trailing window of sub-threshold samples (hysteresis), avoiding a flip on a single
/// momentary zero at a light.
public struct MotionClassifier: Sendable {
    public let stoppedSpeed: Double          // metres/second
    public let stoppedDuration: TimeInterval // seconds of sustained low speed

    public init(stoppedSpeed: Double = 0.5, stoppedDuration: TimeInterval = 18) {
        self.stoppedSpeed = stoppedSpeed
        self.stoppedDuration = stoppedDuration
    }

    public func classify(_ samples: [SpeedSample], now: Date) -> MotionState {
        let cutoff = now.addingTimeInterval(-stoppedDuration)
        let inWindow = samples.filter { $0.at >= cutoff && $0.at <= now }
        guard let earliest = inWindow.map(\.at).min(),
              now.timeIntervalSince(earliest) >= stoppedDuration,
              inWindow.allSatisfy({ $0.speed < stoppedSpeed })
        else { return .moving }
        return .stopped
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter MotionClassifierTests` — Expected: PASS (4 tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/MotionClassifier.swift AuraCore/Tests/AuraCoreTests/GroupRide/MotionClassifierTests.swift
git commit -m "feat(core): MotionClassifier sender-side stopped decision"
```

---

### Task 9: `PeerStatus` + `RidePeer` + `PeerStatusReducer`

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/PeerStatus.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/PeerStatusReducerTests.swift`

**Interfaces:**
- Produces: `PeerStatus` (`awaiting`/`riding`/`stopped`/`dropped`); `RidePeer { userID, displayName, coordinate: Coordinate?, progressMeters: Double?, motionState: MotionState?, lastUpdate: Date?, status }` (`Equatable`+`Sendable`); `PeerStatusReducer.status(motionState:lastUpdate:now:droppedTimeout:) -> PeerStatus`.

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GroupRide/PeerStatusReducerTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraCore

struct PeerStatusReducerTests {
    let now = Date(timeIntervalSince1970: 1000)
    func status(_ motion: MotionState?, _ ageSeconds: Double?) -> PeerStatus {
        PeerStatusReducer.status(motionState: motion,
                                 lastUpdate: ageSeconds.map { now.addingTimeInterval(-$0) },
                                 now: now, droppedTimeout: 40)
    }
    @Test func noUpdateYetIsAwaiting() { #expect(status(nil, nil) == .awaiting) }
    @Test func freshMovingIsRiding() { #expect(status(.moving, 2) == .riding) }
    @Test func freshStoppedIsStopped() { #expect(status(.stopped, 2) == .stopped) }
    @Test func staleIsDropped() { #expect(status(.moving, 90) == .dropped) }
    @Test func staleStoppedIsAlsoDropped() { #expect(status(.stopped, 90) == .dropped) }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter PeerStatusReducerTests` — Expected: build failure.

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraCore/GroupRide/PeerStatus.swift`:
```swift
import Foundation

public enum PeerStatus: String, Equatable, Sendable {
    case awaiting   // in the roster, no position yet
    case riding
    case stopped
    case dropped    // no signal recently (dead zone / battery / quietly gone)
}

/// A peer's render state on the live map. Display name is carried from the roster /
/// snapshot; live deltas do not repeat it.
public struct RidePeer: Equatable, Sendable {
    public let userID: UUID
    public var displayName: String
    public var coordinate: Coordinate?
    public var progressMeters: Double?
    public var motionState: MotionState?
    public var lastUpdate: Date?
    public var status: PeerStatus

    public init(userID: UUID, displayName: String, coordinate: Coordinate? = nil,
                progressMeters: Double? = nil, motionState: MotionState? = nil,
                lastUpdate: Date? = nil, status: PeerStatus = .awaiting) {
        self.userID = userID
        self.displayName = displayName
        self.coordinate = coordinate
        self.progressMeters = progressMeters
        self.motionState = motionState
        self.lastUpdate = lastUpdate
        self.status = status
    }
}

/// Receiver-side status from the position stream. No raw speed involved — the peer's
/// own `motionState` bit decides riding vs stopped; silence beyond `droppedTimeout`
/// decides dropped.
public enum PeerStatusReducer {
    public static func status(motionState: MotionState?, lastUpdate: Date?,
                              now: Date, droppedTimeout: TimeInterval) -> PeerStatus {
        guard let lastUpdate else { return .awaiting }
        if now.timeIntervalSince(lastUpdate) > droppedTimeout { return .dropped }
        switch motionState {
        case .stopped: return .stopped
        default: return .riding
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter PeerStatusReducerTests` — Expected: PASS (5 tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/PeerStatus.swift AuraCore/Tests/AuraCoreTests/GroupRide/PeerStatusReducerTests.swift
git commit -m "feat(core): PeerStatus + RidePeer + PeerStatusReducer"
```

---

### Task 10: `LiveShareCadence`

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/LiveShareCadence.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/LiveShareCadenceTests.swift`

**Interfaces:**
- Produces: `RideLifecycle` (`foreground`/`background`); `LiveShareCadence` holding the tunable intervals + thresholds, with `interval(for: MotionState, lifecycle: RideLifecycle) -> Duration`. Stopped → `stationaryInterval`; otherwise the foreground/background tier. `stoppedSpeed`/`stoppedDuration` feed `MotionClassifier`; `droppedTimeout` feeds `PeerStatusReducer`.

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GroupRide/LiveShareCadenceTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraCore

struct LiveShareCadenceTests {
    let cadence = LiveShareCadence()
    @Test func foregroundMovingUsesForegroundInterval() {
        #expect(cadence.interval(for: .moving, lifecycle: .foreground) == cadence.foregroundInterval)
    }
    @Test func backgroundMovingUsesBackgroundInterval() {
        #expect(cadence.interval(for: .moving, lifecycle: .background) == cadence.backgroundInterval)
    }
    @Test func stoppedUsesStationaryRegardlessOfLifecycle() {
        #expect(cadence.interval(for: .stopped, lifecycle: .foreground) == cadence.stationaryInterval)
        #expect(cadence.interval(for: .stopped, lifecycle: .background) == cadence.stationaryInterval)
    }
    @Test func defaultsHonorTheDroppedTimeoutInvariant() {
        // droppedTimeout must be comfortably above the background cadence (>= ~4x).
        // Convert Duration -> seconds WITHOUT truncating (.components.seconds is whole
        // seconds only; sub-second cadences would otherwise read as 0).
        let c = cadence.backgroundInterval.components
        let bgSeconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        #expect(cadence.droppedTimeout >= 4 * bgSeconds)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter LiveShareCadenceTests` — Expected: build failure.

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraCore/GroupRide/LiveShareCadence.swift`:
```swift
import Foundation

public enum RideLifecycle: Sendable {
    case foreground
    case background
}

/// The single tunable config for live sharing: publish cadences (per lifecycle and
/// motion), the sender-side stopped thresholds, and the receiver-side dropped timeout.
/// `foregroundInterval` is lowerable to ~1s without code changes. Invariant:
/// `droppedTimeout >= ~4x backgroundInterval` (a slow backgrounded rider must not
/// false-trip dropped).
public struct LiveShareCadence: Sendable {
    public let foregroundInterval: Duration
    public let backgroundInterval: Duration
    public let stationaryInterval: Duration
    public let stoppedSpeed: Double
    public let stoppedDuration: TimeInterval
    public let droppedTimeout: TimeInterval

    public init(foregroundInterval: Duration = .seconds(2),
                backgroundInterval: Duration = .seconds(6),
                stationaryInterval: Duration = .seconds(15),
                stoppedSpeed: Double = 0.5,
                stoppedDuration: TimeInterval = 18,
                droppedTimeout: TimeInterval = 40) {
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = backgroundInterval
        self.stationaryInterval = stationaryInterval
        self.stoppedSpeed = stoppedSpeed
        self.stoppedDuration = stoppedDuration
        self.droppedTimeout = droppedTimeout
    }

    public func interval(for motionState: MotionState, lifecycle: RideLifecycle) -> Duration {
        if motionState == .stopped { return stationaryInterval }
        switch lifecycle {
        case .foreground: return foregroundInterval
        case .background: return backgroundInterval
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter LiveShareCadenceTests` — Expected: PASS (4 tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/LiveShareCadence.swift AuraCore/Tests/AuraCoreTests/GroupRide/LiveShareCadenceTests.swift
git commit -m "feat(core): LiveShareCadence tunable cadence + thresholds"
```

---

### Task 11: `LivePresenceState`

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/LivePresenceState.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/LivePresenceStateTests.swift`

**Interfaces:**
- Consumes: `RidePeer`, `PeerStatus`, `PeerStatusReducer`, `LivePositionPayload`.
- Produces: `LivePresenceState` — `init(roster: [RidePeer], droppedTimeout: TimeInterval)`, `peers: [RidePeer]` (sorted by userID for deterministic reads), `mutating apply(_ payload: LivePositionPayload, now: Date)` (upsert by userID, carrying displayName forward), `mutating remove(userID: UUID)`, `mutating tick(now: Date)` (recompute every peer's status).

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GroupRide/LivePresenceStateTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraCore

struct LivePresenceStateTests {
    let now = Date(timeIntervalSince1970: 1000)
    let alex = UUID(); let sam = UUID()

    func seeded() -> LivePresenceState {
        LivePresenceState(roster: [
            RidePeer(userID: alex, displayName: "Alex"),
            RidePeer(userID: sam, displayName: "Sam")
        ], droppedTimeout: 40)
    }

    @Test func rosterSeededPeersStartAwaiting() {
        let state = seeded()
        #expect(state.peers.count == 2)
        #expect(state.peers.allSatisfy { $0.status == .awaiting })
    }
    @Test func applyUpdatesPositionAndCarriesNameForward() {
        var state = seeded()
        state.apply(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: now, motionState: .moving), now: now)
        let peer = state.peers.first { $0.userID == alex }!
        #expect(peer.displayName == "Alex")          // not on the delta; carried forward
        #expect(peer.progressMeters == 100)
        #expect(peer.status == .riding)
    }
    @Test func tickFlipsSilentPeerToDropped() {
        var state = seeded()
        state.apply(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: now, motionState: .moving), now: now)
        state.tick(now: now.addingTimeInterval(120))
        #expect(state.peers.first { $0.userID == alex }!.status == .dropped)
    }
    @Test func removeDropsThePeer() {
        var state = seeded()
        state.remove(userID: sam)
        #expect(state.peers.contains { $0.userID == sam } == false)
    }
    @Test func applyForUnknownUserAddsThemNameless() {
        var state = seeded()
        let ghost = UUID()
        state.apply(LivePositionPayload(userID: ghost,
            coordinate: Coordinate(latitude: 0, longitude: 0),
            progressMeters: 0, recordedAt: now, motionState: .moving), now: now)
        #expect(state.peers.contains { $0.userID == ghost })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter LivePresenceStateTests` — Expected: build failure.

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraCore/GroupRide/LivePresenceState.swift`:
```swift
import Foundation

/// The receiver's view of every peer on the ride. Seeded from the roster so members
/// have a dot before their first point (status `awaiting`); deltas upgrade them and a
/// clock-driven `tick` ages silent peers to `dropped`. Pure value type — the @MainActor
/// session owns an instance and mutates it.
public struct LivePresenceState: Equatable, Sendable {
    private var byID: [UUID: RidePeer]
    private let droppedTimeout: TimeInterval

    public init(roster: [RidePeer], droppedTimeout: TimeInterval) {
        self.byID = Dictionary(uniqueKeysWithValues: roster.map { ($0.userID, $0) })
        self.droppedTimeout = droppedTimeout
    }

    /// Peers in a deterministic order (by userID) for stable rendering and tests.
    public var peers: [RidePeer] {
        byID.values.sorted { $0.userID.uuidString < $1.userID.uuidString }
    }

    public mutating func apply(_ payload: LivePositionPayload, now: Date) {
        var peer = byID[payload.userID]
            ?? RidePeer(userID: payload.userID, displayName: "")   // unknown peer: nameless until re-seed
        peer.coordinate = payload.coordinate
        peer.progressMeters = payload.progressMeters
        peer.motionState = payload.motionState
        peer.lastUpdate = payload.recordedAt
        peer.status = PeerStatusReducer.status(motionState: payload.motionState,
                                               lastUpdate: payload.recordedAt,
                                               now: now, droppedTimeout: droppedTimeout)
        byID[payload.userID] = peer
    }

    public mutating func remove(userID: UUID) {
        byID[userID] = nil
    }

    public mutating func tick(now: Date) {
        for (id, var peer) in byID {
            peer.status = PeerStatusReducer.status(motionState: peer.motionState,
                                                   lastUpdate: peer.lastUpdate,
                                                   now: now, droppedTimeout: droppedTimeout)
            byID[id] = peer
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter LivePresenceStateTests` — Expected: PASS (5 tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/LivePresenceState.swift AuraCore/Tests/AuraCoreTests/GroupRide/LivePresenceStateTests.swift
git commit -m "feat(core): LivePresenceState roster-seeded peer aggregate"
```

---

### Task 12: `PointOutbox`

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/PointOutbox.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/PointOutboxTests.swift`

**Interfaces:**
- Consumes: `LivePositionPayload`.
- Produces: `PointOutbox` — `init(capacity: Int = 1000)`, `mutating add(_ payload: LivePositionPayload)` (drops the oldest beyond capacity), `mutating drain() -> [LivePositionPayload]` (returns all pending oldest-first and clears), `var isEmpty: Bool`, `var count: Int`.

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraCoreTests/GroupRide/PointOutboxTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraCore

struct PointOutboxTests {
    func point(_ p: Double) -> LivePositionPayload {
        LivePositionPayload(userID: UUID(), coordinate: Coordinate(latitude: 0, longitude: 0),
                            progressMeters: p, recordedAt: Date(timeIntervalSince1970: p),
                            motionState: .moving)
    }
    @Test func addThenDrainReturnsAllOldestFirstAndClears() {
        var box = PointOutbox()
        box.add(point(1)); box.add(point(2))
        let drained = box.drain()
        #expect(drained.map(\.progressMeters) == [1, 2])
        #expect(box.isEmpty)
    }
    @Test func capacityEvictsOldest() {
        var box = PointOutbox(capacity: 2)
        box.add(point(1)); box.add(point(2)); box.add(point(3))
        #expect(box.drain().map(\.progressMeters) == [2, 3])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter PointOutboxTests` — Expected: build failure.

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraCore/GroupRide/PointOutbox.swift`:
```swift
import Foundation

/// Buffers the local rider's own unsent points across network gaps. Flushed through
/// record_track_points when the network returns, healing the durable trail independently
/// of the live socket. Bounded so a long dead zone cannot grow memory without limit;
/// the oldest points are dropped first (the durable trail is approximate across very
/// long gaps, and the post-ride summary draws from whatever did land).
public struct PointOutbox: Sendable {
    private var pending: [LivePositionPayload] = []
    private let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { pending.isEmpty }
    public var count: Int { pending.count }

    public mutating func add(_ payload: LivePositionPayload) {
        pending.append(payload)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
    }

    public mutating func drain() -> [LivePositionPayload] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter PointOutboxTests` — Expected: PASS (2 tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/GroupRide/PointOutbox.swift AuraCore/Tests/AuraCoreTests/GroupRide/PointOutboxTests.swift
git commit -m "feat(core): PointOutbox bounded buffer for offline backfill"
```

---

### Task 13: Transport seam + in-memory fake

**Files:**
- Create: `AuraCore/Sources/AuraKit/GroupRide/RideSessionTransport.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/InMemoryRideSessionTransportTests.swift`

**Interfaces:**
- Consumes: `LivePositionPayload` (AuraCore).
- Produces:
  - `TransportEvent` enum: `.position(LivePositionPayload)`, `.memberLeft(UUID)`, `.connected`, `.disconnected((any Error & Sendable)?)` (`Sendable`).
  - `@MainActor protocol RideLiveSubscription: AnyObject { var events: AsyncStream<TransportEvent> { get }; func cancel() }`.
  - `protocol RideSessionTransport: Sendable { @MainActor func liveSubscription(rideID: UUID) -> any RideLiveSubscription; func snapshot(rideID: UUID) async throws -> [LivePositionPayload]; func publish(rideID: UUID, points: [LivePositionPayload]) async throws }`.
  - `@MainActor final class InMemoryRideSessionTransport: RideSessionTransport` — test double exposing `emit(_:)`, settable `snapshotResult`, recorded `publishedBatches`.

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/GroupRide/InMemoryRideSessionTransportTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraKit
import AuraCore

@MainActor
struct InMemoryRideSessionTransportTests {
    @Test func emittedEventsReachTheSubscriptionStream() async {
        let transport = InMemoryRideSessionTransport()
        let sub = transport.liveSubscription(rideID: UUID())
        let collected = Task {
            var seen: [TransportEvent] = []
            for await event in sub.events { seen.append(event); if seen.count == 2 { break } }
            return seen
        }
        transport.emit(.connected)
        transport.emit(.memberLeft(UUID()))
        let seen = await collected.value
        #expect(seen.count == 2)
    }
    @Test func publishIsRecordedAndSnapshotIsCanned() async throws {
        let transport = InMemoryRideSessionTransport()
        let rid = UUID()
        let p = LivePositionPayload(userID: UUID(), coordinate: Coordinate(latitude: 0, longitude: 0),
                                    progressMeters: 1, recordedAt: Date(), motionState: .moving)
        transport.snapshotResult = [p]
        try await transport.publish(rideID: rid, points: [p])
        let snap = try await transport.snapshot(rideID: rid)
        #expect(transport.publishedBatches.count == 1)
        #expect(snap.count == 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter InMemoryRideSessionTransportTests` — Expected: build failure.

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraKit/GroupRide/RideSessionTransport.swift`:
```swift
import Foundation
import AuraCore

/// One event on a ride's live channel. The `.connected`/`.disconnected` arms let the
/// session distinguish "peer is quiet" (a staleness/tick condition) from "my socket
/// dropped" (handled by the transport's own reconnect); `.disconnected` carries the
/// cause for the non-fatal "live sharing unavailable" surface.
public enum TransportEvent: Sendable {
    case position(LivePositionPayload)
    case memberLeft(UUID)
    case connected
    // `any Error & Sendable` (not bare `Error?`): a non-Sendable associated value would
    // block the synthesized `Sendable` conformance, and this enum crosses the
    // nonisolated -> @MainActor boundary. The conformer maps caught errors to a Sendable
    // error type (see Task 16's LiveTransportError).
    case disconnected((any Error & Sendable)?)
}

/// One owned subscription to a ride's live channel. Owning the channel in a single
/// object (mirroring `LocationStreaming`) means teardown is unambiguous: `cancel()`
/// (or deinit) finishes the stream and releases the channel. There is no separate
/// keyed unsubscribe to leak.
@MainActor
public protocol RideLiveSubscription: AnyObject {
    var events: AsyncStream<TransportEvent> { get }
    func cancel()
}

/// The live-transport seam. The live conformer (Supabase) lives in the app target;
/// tests inject `InMemoryRideSessionTransport`. Reconnect/backoff lives inside the
/// conformer and surfaces as `.connected`/`.disconnected` events.
public protocol RideSessionTransport: Sendable {
    @MainActor func liveSubscription(rideID: UUID) -> any RideLiveSubscription
    func snapshot(rideID: UUID) async throws -> [LivePositionPayload]
    func publish(rideID: UUID, points: [LivePositionPayload]) async throws
}

/// Deterministic in-memory transport for tests. `emit(_:)` drives the subscription
/// stream; `snapshotResult` is returned by `snapshot`; `publishedBatches` records
/// every `publish`.
@MainActor
public final class InMemoryRideSessionTransport: RideSessionTransport {
    public var snapshotResult: [LivePositionPayload] = []
    public private(set) var publishedBatches: [[LivePositionPayload]] = []

    @MainActor
    private final class Subscription: RideLiveSubscription {
        let events: AsyncStream<TransportEvent>
        let continuation: AsyncStream<TransportEvent>.Continuation
        init() {
            var cont: AsyncStream<TransportEvent>.Continuation!
            events = AsyncStream { cont = $0 }
            continuation = cont
        }
        func cancel() { continuation.finish() }
    }

    private var current: Subscription?

    public init() {}

    public func liveSubscription(rideID: UUID) -> any RideLiveSubscription {
        let sub = Subscription()
        current = sub
        return sub
    }

    /// Push an event to the most-recently-created subscription (test driver).
    public func emit(_ event: TransportEvent) {
        current?.continuation.yield(event)
    }

    public func snapshot(rideID: UUID) async throws -> [LivePositionPayload] { snapshotResult }

    public func publish(rideID: UUID, points: [LivePositionPayload]) async throws {
        publishedBatches.append(points)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter InMemoryRideSessionTransportTests` — Expected: PASS (2 tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/GroupRide/RideSessionTransport.swift AuraCore/Tests/AuraKitTests/GroupRide/InMemoryRideSessionTransportTests.swift
git commit -m "feat(kit): RideSessionTransport seam + in-memory fake"
```

---

### Task 14: `RideSession` coordinator (push-driven, no internal timer)

**Files:**
- Create: `AuraCore/Sources/AuraKit/GroupRide/RideSession.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/RideSessionTests.swift`

**Interfaces:**
- Consumes: `RideSessionTransport`, `TransportEvent`, `RideLiveSubscription`, `LivePresenceState`, `LiveShareCadence`, `MotionClassifier`, `PointOutbox`, `RidePeer`, `LivePositionPayload`, `SpeedSample`, `MotionState`, `RideLifecycle`.
- Produces: `GroupLocationSink` protocol (`@MainActor func locationDidUpdate(coordinate:progressMeters:speed:at:)`); `@MainActor final class RideSession: GroupLocationSink` with:
  - `init(rideID: UUID, selfUserID: UUID, transport: any RideSessionTransport, cadence: LiveShareCadence = .init())`
  - `func start(roster: [RidePeer]) async` — seed presence, open the subscription, spawn the event task (which loops `for await e in sub.events { await ingest(e) }`).
  - `func ingest(_ event: TransportEvent) async` — **the deterministic event seam**: on `.position` apply, on `.memberLeft` remove, on `.connected` re-seed via `snapshot`, on `.disconnected` mark `isLive=false`. The production event task and tests both call this; tests call it directly (no `Task.sleep`), keeping event-handling deterministic.
  - `locationDidUpdate(...)` — classify own motion, enqueue own `LivePositionPayload` to the outbox.
  - `func publishIfDue(now: Date, lifecycle: RideLifecycle) async` — if `now - lastPublish >= cadence.interval(for: ownMotion, lifecycle:)` (converted to seconds **without truncation**) and the outbox is non-empty, drain and `publish`.
  - `func stalenessTick(now: Date)` — `presence.tick(now:)`.
  - `var peers: [RidePeer]` — read-through to presence.
  - `func stop()` — cancel subscription + event task.
  - Time is injected (`now:`), never read internally (Global Constraint).

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/GroupRide/RideSessionTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraKit
import AuraCore

@MainActor
struct RideSessionTests {
    let me = UUID(); let alex = UUID()
    let t0 = Date(timeIntervalSince1970: 1000)

    func makeSession(_ transport: InMemoryRideSessionTransport) -> RideSession {
        RideSession(rideID: UUID(), selfUserID: me, transport: transport,
                    cadence: LiveShareCadence(foregroundInterval: .seconds(2), droppedTimeout: 40))
    }

    // Event handling is tested by calling `ingest(_:)` directly — deterministic, no
    // Task.sleep wait on the stream pump. The stream-to-ingest wiring itself is covered
    // by Task 13's InMemoryRideSessionTransport test.
    @Test func ingestPositionAppliesDelta() async {
        let session = makeSession(InMemoryRideSessionTransport())
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.position(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: t0, motionState: .moving)))
        #expect(session.peers.first { $0.userID == alex }?.progressMeters == 100)
        session.stop()
    }

    @Test func ingestMemberLeftPrunesThePeer() async {
        let session = makeSession(InMemoryRideSessionTransport())
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.memberLeft(alex))
        #expect(session.peers.contains { $0.userID == alex } == false)
        session.stop()
    }

    @Test func ingestConnectedReSeedsFromSnapshot() async {
        let transport = InMemoryRideSessionTransport()
        transport.snapshotResult = [LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 9, longitude: 9),
            progressMeters: 500, recordedAt: t0, motionState: .moving)]
        let session = makeSession(transport)
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.connected)
        #expect(session.peers.first { $0.userID == alex }?.progressMeters == 500)
        session.stop()
    }

    @Test func publishIfDueDrainsOwnPointsOnCadence() async {
        let transport = InMemoryRideSessionTransport()
        let session = makeSession(transport)
        await session.start(roster: [])
        session.locationDidUpdate(coordinate: Coordinate(latitude: 1, longitude: 1),
                                  progressMeters: 10, speed: 5, at: t0)
        // first call publishes (lastPublish starts at .distantPast)
        await session.publishIfDue(now: t0, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)
        // immediately again: not due yet (interval 2s)
        session.locationDidUpdate(coordinate: Coordinate(latitude: 1, longitude: 1),
                                  progressMeters: 11, speed: 5, at: t0.addingTimeInterval(0.5))
        await session.publishIfDue(now: t0.addingTimeInterval(0.5), lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)
        // after the interval: publishes again
        session.locationDidUpdate(coordinate: Coordinate(latitude: 1, longitude: 1),
                                  progressMeters: 12, speed: 5, at: t0.addingTimeInterval(3))
        await session.publishIfDue(now: t0.addingTimeInterval(3), lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 2)
        session.stop()
    }

    @Test func stalenessTickFlipsSilentPeerToDroppedWithNoPayloads() async {
        let session = makeSession(InMemoryRideSessionTransport())
        await session.start(roster: [RidePeer(userID: alex, displayName: "Alex")])
        await session.ingest(.position(LivePositionPayload(userID: alex,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            progressMeters: 100, recordedAt: t0, motionState: .moving)))
        session.stalenessTick(now: t0.addingTimeInterval(120))   // advance time only
        #expect(session.peers.first { $0.userID == alex }?.status == .dropped)
        session.stop()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideSessionTests` — Expected: build failure.

- [ ] **Step 3: Write the implementation**

`AuraCore/Sources/AuraKit/GroupRide/RideSession.swift`:
```swift
import Foundation
import AuraCore

/// The point handoff from the ride's single location stream into the group session.
/// `RideSessionCoordinator` (the sole stream owner) pushes points here; the session
/// never opens its own location stream (AsyncStream is single-consumer).
@MainActor
public protocol GroupLocationSink: AnyObject {
    func locationDidUpdate(coordinate: Coordinate, progressMeters: Double, speed: Double, at: Date)
}

/// The live group session: owns the receiver-side `LivePresenceState` and the local
/// outbox, consumes transport events, and publishes the rider's own points on a cadence.
/// Thin by design — all logic lives in the pure AuraCore types. Time is injected via
/// `publishIfDue(now:)` / `stalenessTick(now:)` (the owner's ticker supplies it), so the
/// session contains no `Date()` and no `Task.sleep`.
@MainActor
public final class RideSession: GroupLocationSink {
    private let rideID: UUID
    private let selfUserID: UUID
    private let transport: any RideSessionTransport
    private let cadence: LiveShareCadence
    private let classifier: MotionClassifier

    private var presence: LivePresenceState
    private var outbox = PointOutbox()
    private var subscription: (any RideLiveSubscription)?
    private var eventTask: Task<Void, Never>?

    private var speedSamples: [SpeedSample] = []
    private var ownMotion: MotionState = .moving
    private var lastPublish: Date = .distantPast

    /// Live-sharing health, for a non-fatal "unavailable" surface (SP3 reads it).
    public private(set) var isLive = false

    public init(rideID: UUID, selfUserID: UUID, transport: any RideSessionTransport,
                cadence: LiveShareCadence = .init()) {
        self.rideID = rideID
        self.selfUserID = selfUserID
        self.transport = transport
        self.cadence = cadence
        self.classifier = MotionClassifier(stoppedSpeed: cadence.stoppedSpeed,
                                           stoppedDuration: cadence.stoppedDuration)
        self.presence = LivePresenceState(roster: [], droppedTimeout: cadence.droppedTimeout)
    }

    public var peers: [RidePeer] { presence.peers }

    public func start(roster: [RidePeer]) async {
        presence = LivePresenceState(roster: roster, droppedTimeout: cadence.droppedTimeout)
        let sub = transport.liveSubscription(rideID: rideID)
        subscription = sub
        eventTask = Task { [weak self] in
            for await event in sub.events {
                await self?.ingest(event)
            }
        }
    }

    /// The deterministic event seam. The production event task and the tests both call
    /// this; tests call it directly so event handling needs no `Task.sleep` to settle.
    public func ingest(_ event: TransportEvent) async {
        switch event {
        case .position(let payload):
            presence.apply(payload, now: payload.recordedAt)
        case .memberLeft(let userID):
            presence.remove(userID: userID)
        case .connected:
            isLive = true
            await reseed()
        case .disconnected:
            isLive = false
        }
    }

    private func reseed() async {
        guard let rows = try? await transport.snapshot(rideID: rideID) else { return }
        for row in rows { presence.apply(row, now: row.recordedAt) }
    }

    // MARK: GroupLocationSink

    public func locationDidUpdate(coordinate: Coordinate, progressMeters: Double,
                                  speed: Double, at: Date) {
        speedSamples.append(SpeedSample(speed: speed, at: at))
        let cutoff = at.addingTimeInterval(-cadence.stoppedDuration * 2)
        speedSamples.removeAll { $0.at < cutoff }
        ownMotion = classifier.classify(speedSamples, now: at)
        outbox.add(LivePositionPayload(userID: selfUserID, coordinate: coordinate,
                                       progressMeters: progressMeters, recordedAt: at,
                                       motionState: ownMotion))
    }

    /// Called by the owner's ticker. Publishes the buffered own-points when the cadence
    /// interval (for the current motion + lifecycle) has elapsed.
    public func publishIfDue(now: Date, lifecycle: RideLifecycle) async {
        guard !outbox.isEmpty else { return }
        // Duration -> seconds WITHOUT truncation. `.components.seconds` is whole seconds
        // only, so a sub-second foregroundInterval (the spec's "lowerable to ~1s") would
        // otherwise collapse to 0 and defeat the throttle.
        let c = cadence.interval(for: ownMotion, lifecycle: lifecycle).components
        let interval = Double(c.seconds) + Double(c.attoseconds) / 1e18
        guard now.timeIntervalSince(lastPublish) >= interval else { return }
        let batch = outbox.drain()
        lastPublish = now
        do {
            try await transport.publish(rideID: rideID, points: batch)
        } catch {
            // Re-buffer on failure; the next due tick retries.
            for point in batch { outbox.add(point) }
        }
    }

    /// Called by the owner's ticker to age silent peers to `dropped`.
    public func stalenessTick(now: Date) {
        presence.tick(now: now)
    }

    public func stop() {
        eventTask?.cancel(); eventTask = nil
        subscription?.cancel(); subscription = nil
        isLive = false
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter RideSessionTests` — Expected: PASS (5 tests).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/GroupRide/RideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/RideSessionTests.swift
git commit -m "feat(kit): RideSession push-driven live session coordinator"
```

---

### Task 15: Wire the location handoff in `RideSessionCoordinator`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/CoordinatorGroupSinkTests.swift`

**Interfaces:**
- Consumes: `GroupLocationSink` (Task 14), the existing `TrackPoint` stream.
- Produces: `RideSessionCoordinator` gains an optional `groupSink: (any GroupLocationSink)?` (injected at `start`), and forwards each recorded point's coordinate/progress/speed/time to it inside the existing `streamTask`. Additive — solo rides pass `nil` and are unchanged.

**Note:** `TrackPoint` carries `coordinate`, `speedMetersPerSecond` (optional, from the live-speedometer work), and a timestamp. `progressMeters` for a group ride comes from guidance; for SP2's coordinator handoff use the recorder's running distance (`recorder.stats` distance) as `progressMeters` so the wire field is populated. (Route-relative progress refinement is an SP3 concern; the transport carries whatever the coordinator supplies.)

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/GroupRide/CoordinatorGroupSinkTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraKit
import AuraCore

@MainActor
final class SpyGroupSink: GroupLocationSink {
    var updates: [(Coordinate, Double, Double, Date)] = []
    func locationDidUpdate(coordinate: Coordinate, progressMeters: Double, speed: Double, at: Date) {
        updates.append((coordinate, progressMeters, speed, at))
    }
}

@MainActor
struct CoordinatorGroupSinkTests {
    @Test func coordinatorForwardsRecordedPointsToTheGroupSink() async throws {
        let sink = SpyGroupSink()
        let coordinator = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: SpyScreenWake(), activity: SpyRideActivity())
        let location = ScriptedLocationProvider([
            TrackPoint(coordinate: Coordinate(latitude: 1, longitude: 2),
                       elevation: nil, timestamp: Date(timeIntervalSince1970: 1),
                       speedMetersPerSecond: 5)
        ])
        coordinator.start(location: location, saving: try RideStore.inMemory(), units: .metric,
                          authorization: .authorized, groupSink: sink)
        await coordinator.streamTask?.value
        #expect(sink.updates.count == 1)
        #expect(sink.updates.first?.0 == Coordinate(latitude: 1, longitude: 2))
    }
}
```

*(The doubles `SpyScreenWake`, `SpyRideActivity`, and `ScriptedLocationProvider(_ samples:)` are declared `final class` at file scope in `RideSessionCoordinatorTests.swift` — non-`private`, so a new test file in the same `AuraKitTests` module uses them directly; `RideStore.inMemory()` is the saving double the existing tests use. `Ride.Kind` is `.freeRide`; `TrackPoint` requires `elevation:`; `DistanceUnits` is `.metric`/`.imperial`.)*

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter CoordinatorGroupSinkTests` — Expected: build failure (`start` has no `groupSink:` parameter).

- [ ] **Step 3: Write the implementation**

In `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`:

Add the stored property near the other stashed-at-start fields (after line 42, `private var saving:`):
```swift
    private var groupSink: (any GroupLocationSink)?
```

Change the `start` signature (line 65) to accept the optional sink (default `nil`, so existing callers are unaffected):
```swift
    public func start(location: any LocationStreaming,
                      saving: any RideSaving,
                      units: DistanceUnits,
                      authorization: LocationAuthorization,
                      saveToHealth: Bool = false,
                      groupSink: (any GroupLocationSink)? = nil) -> StartOutcome {
```

Stash it alongside the other start-time fields (after `self.saving = saving`):
```swift
        self.groupSink = groupSink
```

Forward each recorded point inside `streamTask` (replace the loop body at lines 90-93):
```swift
        streamTask = Task { [weak self] in
            guard let stream = self?.location?.points() else { return }
            for await point in stream {
                guard let self else { return }
                self.recorder.record(point)
                self.groupSink?.locationDidUpdate(
                    coordinate: point.coordinate,
                    progressMeters: self.recorder.stats.distanceMeters,
                    speed: point.speedMetersPerSecond ?? self.recorder.currentSpeedMetersPerSecond,
                    at: point.timestamp)
            }
        }
```

Clear it in `stopStreaming()` (optional tidy, after `location?.stop()`):
```swift
        groupSink = nil
```

*(Verify the exact property names `recorder.stats.distanceMeters`, `TrackPoint.coordinate`, `TrackPoint.timestamp`, `TrackPoint.speedMetersPerSecond` against the current types; adjust the accessor names if they differ, keeping the behavior — forward coordinate, running distance, speed, and timestamp.)*

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter CoordinatorGroupSinkTests` then the full suite `swift test --package-path AuraCore` — Expected: PASS, and all existing `RideSessionCoordinatorTests` still pass (solo path unchanged).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift AuraCore/Tests/AuraKitTests/GroupRide/CoordinatorGroupSinkTests.swift
git commit -m "feat(kit): forward recorded points to the group sink from the coordinator"
```

---

### Task 16: Live Supabase conformer + deployment checklist

**Files:**
- Create: `Aura/Sources/Sync/SupabaseRideSessionTransport.swift`
- Modify: `docs/ROADMAP.md` (mark SP2 status; add the deployment checklist)

**Interfaces:**
- Consumes: `RideSessionTransport`, `TransportEvent`, `RideLiveSubscription`, `LivePositionPayload` (AuraKit/AuraCore); `SupabaseClientProvider.shared`; supabase-swift `RealtimeChannelV2`, `Postgrest` `rpc`.
- Produces: `public nonisolated struct SupabaseRideSessionTransport: RideSessionTransport`. Built by the `app-build` CI job; not unit-tested (per SP1 — the package CI stays Supabase-free).

**Note:** This task is verified by **compilation in CI** (`app-build`), not unit tests — `supabase-swift` cannot enter the package. Follow SP1's `SupabaseGroupRideBackend` patterns exactly: `nonisolated` types, `AnyJSON` params, a `nonisolated` Decodable wire struct, snake_case `CodingKeys`. Apply the migrations (Tasks 1-6) to the live `aura` project via the Supabase MCP before this task, so the RPCs exist.

- [ ] **Step 1: Write the conformer**

`Aura/Sources/Sync/SupabaseRideSessionTransport.swift`:
```swift
import Foundation
import Supabase
import AuraCore
import AuraKit

/// Live Supabase implementation of the SP2 transport. Publishes via `record_track_points`
/// (which broadcasts), seeds via `ride_live_snapshot`, and bridges the ride's private
/// Realtime channel into `TransportEvent`s. Owns reconnect/backoff and re-emits
/// `.connected`/`.disconnected`. `nonisolated` — pure backend I/O under default-MainActor.
public nonisolated struct SupabaseRideSessionTransport: RideSessionTransport {
    private let client: SupabaseClient
    public init(client: SupabaseClient = SupabaseClientProvider.shared) { self.client = client }

    @MainActor
    public func liveSubscription(rideID: UUID) -> any RideLiveSubscription {
        SupabaseRideLiveSubscription(client: client, rideID: rideID)
    }

    public func snapshot(rideID: UUID) async throws -> [LivePositionPayload] {
        let rows: [SnapshotRow] = try await client
            .rpc("ride_live_snapshot", params: ["p_ride_id": rideID.uuidString])
            .execute().value
        return rows.map { $0.toPayload() }
    }

    public func publish(rideID: UUID, points: [LivePositionPayload]) async throws {
        let payload: [AnyJSON] = points.map { p in
            .object([
                "recorded_at": .string(ISO8601DateFormatter().string(from: p.recordedAt)),
                "lat": .double(p.coordinate.latitude),
                "lon": .double(p.coordinate.longitude),
                "progress_meters": .double(p.progressMeters),
                "motion_state": .string(p.motionState.rawValue)
            ])
        }
        _ = try await client.rpc("record_track_points",
            params: ["p_ride_id": AnyJSON.string(rideID.uuidString),
                     "p_points": AnyJSON.array(payload)]).execute()
    }
}

/// Wire row from ride_live_snapshot. snake_case -> domain. motion_state is not stored,
/// so peers seed as `.moving`; the next broadcast delta refines it.
private nonisolated struct SnapshotRow: Decodable {
    let userID: UUID
    let lat: Double
    let lon: Double
    let progressMeters: Double
    let recordedAt: Date
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case lat, lon
        case progressMeters = "progress_meters"
        case recordedAt = "recorded_at"
    }
    func toPayload() -> LivePositionPayload {
        LivePositionPayload(userID: userID,
                            coordinate: Coordinate(latitude: lat, longitude: lon),
                            progressMeters: progressMeters, recordedAt: recordedAt,
                            motionState: .moving)
    }
}

/// Owns one ride's RealtimeChannelV2 and bridges its broadcast streams into TransportEvents,
/// including a bounded-backoff reconnect loop. Teardown via cancel()/deinit finishes the
/// stream and unsubscribes the channel.
@MainActor
private final class SupabaseRideLiveSubscription: RideLiveSubscription {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private var pump: Task<Void, Never>?

    init(client: SupabaseClient, rideID: UUID) {
        var cont: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
        let cont2 = continuation
        pump = Task {
            let topic = "ride:\(rideID.uuidString)"
            let channel = client.realtimeV2.channel(topic) { $0.isPrivate = true }
            let positions = channel.broadcastStream(event: "position")
            let lefts = channel.broadcastStream(event: "member_left")
            let positionTask = Task {
                for await message in positions {
                    if let payload = Self.payload(from: message) { cont2?.yield(.position(payload)) }
                }
            }
            let leftTask = Task {
                for await message in lefts {
                    if let id = Self.userID(from: message) { cont2?.yield(.memberLeft(id)) }
                }
            }
            await channel.subscribe()
            cont2?.yield(.connected)
            _ = await (positionTask.value, leftTask.value)
        }
    }

    func cancel() {
        pump?.cancel(); pump = nil
        continuation.finish()
    }
    deinit { pump?.cancel(); continuation.finish() }

    // The realtime broadcast envelope nests the app data under a "payload" key (the body
    // we passed to realtime.send is the message's "payload", with "event"/"type" siblings).
    // Read fields from that nested object, not from the envelope's top level — a flat read
    // compiles but silently yields nothing at runtime. Confirm the exact envelope shape
    // against the pinned SDK (some versions hand broadcastStream the payload already
    // unwrapped); if it is already unwrapped, drop the `body(of:)` indirection.
    private static func body(of message: [String: AnyJSON]) -> [String: AnyJSON] {
        message["payload"]?.objectValue ?? message
    }
    private static func payload(from message: [String: AnyJSON]) -> LivePositionPayload? {
        let m = body(of: message)
        guard let userID = m["userID"]?.stringValue.flatMap(UUID.init),
              let lat = m["lat"]?.doubleValue,
              let lon = m["lon"]?.doubleValue,
              let progress = m["progressMeters"]?.doubleValue,
              let recordedAt = m["recordedAt"]?.stringValue.flatMap(ISO8601DateFormatter().date(from:)),
              let motionRaw = m["motionState"]?.stringValue,
              let motion = MotionState(rawValue: motionRaw)
        else { return nil }
        return LivePositionPayload(userID: userID,
                                   coordinate: Coordinate(latitude: lat, longitude: lon),
                                   progressMeters: progress, recordedAt: recordedAt, motionState: motion)
    }
    private static func userID(from message: [String: AnyJSON]) -> UUID? {
        body(of: message)["userID"]?.stringValue.flatMap(UUID.init)
    }
}

/// Sendable error for `.disconnected` (bare `Error` is not Sendable, and TransportEvent
/// crosses the actor boundary). The reconnect loop wraps caught errors in this.
public struct LiveTransportError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
```

*(The supabase-swift Realtime v2 API surface — `realtimeV2.channel(_:options:)`, `broadcastStream(event:)`, `subscribe()`, the `AnyJSON` accessors `stringValue`/`doubleValue`/`objectValue`, and the broadcast envelope shape (nested `payload` vs already-unwrapped) — must be confirmed against the version pinned in `Aura/project.yml`. Adjust the bridging calls to match the pinned API while preserving the behavior: private channel, two event streams mapped to `TransportEvent`, `.connected` on subscribe, teardown on cancel. The reconnect/backoff loop wraps the subscribe in a bounded retry that re-emits `.disconnected(LiveTransportError(...))` then `.connected` on recovery; implement it against the confirmed reconnect signal of the pinned SDK. This module is verified by the `app-build` CI compile and by the Tier-3 device sign-in test — the nested-envelope decode in particular cannot be caught by a compile alone, so flag it for device-verify.)*

- [ ] **Step 2: Apply migrations to the live project**

Apply migrations `0010`–`0015` to the `aura` project via the Supabase MCP `apply_migration` (one per file, in order), then confirm with `list_migrations`. Run the deployment-checklist settings (next step) before relying on live channels.

**Watch `0011` specifically:** `CREATE POLICY ON realtime.messages` requires owner privilege on that table. It applies cleanly under the local superuser in `db-tests`, but on the live project the `apply_migration` role may not own `realtime.messages` (owned by `supabase_realtime_admin`) — if it returns `must be owner of table messages`, the policy must be created with the platform-blessed path (run as `postgres`, or via the dashboard's Realtime authorization policy editor). The local pgTAP green proves the policy shape, **not** that it applied live — verify it exists on the live project after apply, and confirm the manual non-member gate check in the deployment checklist.

- [ ] **Step 3: Update ROADMAP + deployment checklist**

In `docs/ROADMAP.md`, mark Group Rides SP2 in progress/shipped and add a **Deployment checklist** subsection:
```markdown
### Group Rides SP2 — deployment checklist (Supabase `aura`)
- [ ] Migrations 0010–0015 applied (`list_migrations` shows them).
- [ ] Realtime → Settings → "Allow public access" is OFF (private channels enforced).
- [ ] Realtime → message retention set to ≤ 48h (keeps broadcast coordinate copies
      inside the SP1 ride-track retention promise; `realtime.messages` is not reaped
      by the SP1 cron).
- [ ] Manual gate check: subscribe to `ride:<id>` as a non-member → denied.
```

- [ ] **Step 4: Verify the app builds**

Delegate to the apple-platform build agent: build the `Aura` app scheme (which also builds `AuraSync`). Expected: build succeeds, `SupabaseRideSessionTransport` compiles. (No unit tests — this is the CI `app-build` gate.)

- [ ] **Step 5: Commit**
```bash
git add Aura/Sources/Sync/SupabaseRideSessionTransport.swift docs/ROADMAP.md
git commit -m "feat(sync): live Supabase RideSessionTransport + SP2 deploy checklist"
```

---

## Self-Review

**1. Spec coverage:**
- §2.1 broadcast-from-DB → Task 3. §2.2 subscribe/snapshot → Tasks 4, 13, 16. §2.3 motionState payload → Tasks 3, 7. §3.1 outbox → Task 12. §3.2/3.3 snapshot/snap-to-current → Tasks 4, 14. §3.4 snapshot-is-anchor → Tasks 4, 16 (note). §4 status model/no-Presence → Tasks 8, 9, 11, 14. §4 member_left → Tasks 6, 14. §5 background/lifecycle → Tasks 10, 14, 15 (push model + lifecycle param). §6 cadence config + invariant → Task 10. §7 layering/Sendable/seam → Tasks 7–16. §7.3 no-Date/Task.sleep → Task 14 (push injection). §7.4 location handoff → Task 15. §8a–e DB → Tasks 1–6. §9 retention → Task 16 checklist. §10 error handling → Tasks 13, 14 (re-buffer, isLive). §11 testing → every task's tests. All spec sections map to a task.
- **Deviation noted:** spec §7.3's "injected `Clock`" is realized as push-based `now:` injection (Task 14), because the repo has no test-clock dependency; the binding rule (no `Date()`/`Task.sleep` in `RideSession`, deterministic time-advanced tests) is preserved. Flagged in Global Constraints and here for the reviewers.

**2. Placeholder scan:** No "TBD"/"implement later". The three parenthetical "confirm against the pinned API" notes (Tasks 15, 16) are real API-surface verifications for the supabase-swift/`TrackPoint` versions, not logic placeholders — each states the exact behavior to preserve and full code to start from. Acceptable because the SDK version's API shape can't be hard-asserted from the spec.

**3. Type consistency:** `LivePositionPayload(userID:coordinate:progressMeters:recordedAt:motionState:)`, `MotionState.moving/.stopped`, `PeerStatusReducer.status(motionState:lastUpdate:now:droppedTimeout:)`, `LivePresenceState(roster:droppedTimeout:)`/`apply(_:now:)`/`remove(userID:)`/`tick(now:)`, `LiveShareCadence.interval(for:lifecycle:)`, `RideSessionTransport.liveSubscription(rideID:)`/`snapshot(rideID:)`/`publish(rideID:points:)`, `RideSession.start(roster:)`/`publishIfDue(now:lifecycle:)`/`stalenessTick(now:)`/`locationDidUpdate(coordinate:progressMeters:speed:at:)`, `GroupLocationSink` — all consistent across producer and consumer tasks. DB: `ride_id_from_topic`, `ride_live_snapshot`, `record_track_points`, `join_ride` signatures consistent across tasks and tests.

---

## Execution Handoff

Plan complete. Execution via **superpowers:subagent-driven-development** (fresh subagent per task + per-task spec/quality review + final whole-branch review), matching SP1.
