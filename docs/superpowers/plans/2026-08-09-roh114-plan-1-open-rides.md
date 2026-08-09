# ROH-114 Plan 1 — Open rides, end to end

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A host starts a crew ride with no destination, a guest joins by code, both tap through to a recording ride on the Explore cockpit, and the SQL underneath is actually tested.

**Architecture:** Most of the wire already exists in `794d748`, written before this plan and never verified. So this plan opens by *proving or breaking* that commit rather than building on it. It then closes the `kind` seam, carries the ride kind and destination name to the lobby, wires both entry points, and forks the riding container so an open ride reaches the Explore HUD instead of an error screen. Peer rendering — dots, roster, colours — is Plan 2.

**Tech Stack:** Swift 6 / SwiftUI, `AuraCore` + `AuraKit` packages, Supabase Postgres with pgTAP, PostgREST RPC.

**Spec:** [`2026-08-02-roh114-group-explore-design.md`](../specs/2026-08-02-roh114-group-explore-design.md) revision 5. Covers **D1**, **D2**, **D4.1**, **D4.5**, **D5.4**.

**Revision 2 (2026-08-09), after a three-reviewer adversarial gate.** Revision 1 was scoped to stop before D4.1, which put a working dead end in front of every user of the feature; all three reviewers found it independently. It also carried a pgTAP suite that could not run, a test for a class with no test bundle, three snippets that would not compile, and no step that applied the migration to the project the device test targets. Details in "What the gate caught" at the end. **Weight accordingly:** revision 1 read as careful and was wrong in six places that would have cost cycles.

---

## Preconditions — check these before Task 1, not during it

- [ ] **Docker + the Supabase CLI.** `which supabase` and `docker info` must both succeed. **Neither is available on the machine this plan was written on.** The documented fallback (`2026-06-29-group-rides-sp1-backend-identity.md:21`) is to run the same SQL against a Supabase dev branch through the Supabase MCP `execute_sql`, **and to record that substitution in the task's commit message**. Do not silently skip Task 1 because the stack will not start — that is how `794d748` reached this branch unverified in the first place.
- [ ] **The Mapbox token**, or Task 2 fails on SPM rather than on code. See `docs/COLLABORATOR-SETUP.md:82-93`.

## Read this before Task 1

`794d748` is already on this branch: D1.1, D1.2, D1.4 and D1.5, with `GroupRideOpenRideTests` and 880 green package tests (re-run and confirmed by a reviewer). Its own commit message ends `NOT YET VERIFIED`, and that is accurate — the app target has never compiled with it, and migration `0021_open_rides.sql` has never been applied or tested anywhere.

The SQL half is the dangerous one. D1.5 drops and recreates `join_ride`, and the spec says getting it wrong "takes down joining for **every** client including route rides."

**What it left unfinished**, against D1.3's own seam list: `GroupRide.kind` (item 3) and `rideKind` (the second half of item 4) were never added, so `kind` reaches SQL and stops. *`GroupRideSession.create(route: Route?)` — the first half of item 4 — was done; revision 1 of this plan said otherwise and was wrong.*

## File structure

| File | Responsibility | Status |
| --- | --- | --- |
| `supabase/migrations/0021_open_rides.sql` | nullable route, `kind`, join gate, **+ the kind/route CHECK** | exists, amend |
| `supabase/tests/0021_open_rides_test.sql` | pgTAP | **create** |
| `AuraCore/Sources/AuraCore/GroupRide/GroupRide.swift` | `GroupRide.Kind` | **modify** |
| `AuraCore/Sources/AuraCore/GroupRide/RouteEnvelope.swift` | testable route-bytes folding | **create** |
| `Aura/Sources/Sync/SupabaseGroupRideBackend.swift` | row → domain, calls the above | modify |
| `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` | `rideKind` | modify |
| `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` | fake must not lose `kind` | **modify** |
| `AuraCore/Sources/AuraCore/GroupRide/GroupRideSubtitle.swift` | D5.4 copy | **create** |
| `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift` | `create(Route?, Place?)` | **modify** |
| `Aura/Sources/Plan/RoutePreviewView.swift` | stop dropping the destination name | **modify** |
| `Aura/Sources/GroupRide/GroupLobbyView.swift` | D5.4 line | **modify** |
| `Aura/Sources/GroupRide/GroupRideFlowView.swift` | D4.1 fork | **modify** |
| `Aura/Sources/Ride/RideHUDView.swift` | D4.5 `groupSink` at `.task` | **modify** |
| `Aura/Sources/Home/HomeLaunchBand.swift` | chip label | **modify** |
| `Aura/Sources/GroupRide/GroupRideJoinView.swift` + `AuraApp.swift` | two actions | **modify** |

```bash
cd AuraCore && swift test --no-parallel
```

```bash
supabase db reset && supabase test db
```

The app build is **delegated to the `apple-platform-build-tools:builder` subagent** — ~13 minutes, and its output would swamp a session.

---

### Task 1: pgTAP for 0021 — the verification `794d748` skipped

**Files:** Create `supabase/tests/0021_open_rides_test.sql`; amend `supabase/migrations/0021_open_rides.sql`.

**Precedent is `0003_join_ride_test.sql` and `0014_join_cap_lock_test.sql`, and the pattern matters.** Both drive multi-identity flows through a `pg_temp` SECURITY DEFINER helper with `set_config(..., true)`, and **never** `set local role authenticated`. `0003:1-5` says why. Revision 1 of this plan cited 0014 and then wrote the role-switching pattern, which cannot work here: `rides_select` is members-only (`0002_membership_rls.sql:63-64`), so a guest reading `join_code` out of `public.rides` gets NULL, and `join_ride(NULL, …)` dies at the ride-not-found guard without ever reaching the kind gate.

- [ ] **Step 1: Add the missing invariant to the migration**

`kind` is derived in `create_ride`'s body and nowhere enforced, so any service-role write or backfill can produce `kind='route'` with a null route — which lands a rider on the D4.1 error path — or `kind='open'` with a route, which draws a course under a "no destination" label. The column pair has one legal shape:

```sql
alter table public.rides
  add constraint rides_kind_matches_route check ((kind = 'open') = (route is null));
```

- [ ] **Step 2: Write the test through a SECURITY DEFINER helper**

```sql
begin;
select plan(8);

insert into auth.users (instance_id, id, aud, role, email)
select '00000000-0000-0000-0000-000000000000',
       ('bbbbbbbb-0000-0000-0000-00000000000'||g)::uuid,
       'authenticated','authenticated','o'||g||'@test.dev'
from generate_series(1,2) g;

-- A pre-0021 row, to prove the backfill default. Inserted before any identity switch.
insert into public.rides (host_id, join_code, route, expires_at)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'LEGACY01', '{}'::jsonb, now() + interval '1 day');

create function pg_temp.open_ride_flow(
  out open_kind text, out open_route_null boolean, out route_kind text,
  out old_client_rejected boolean, out new_client_joined boolean)
language plpgsql security definer set search_path = '' as $$
declare v_open public.rides; v_route public.rides;
begin
  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000001"}', true);

  -- p_route OMITTED, not passed as null: a jsonb 'null' scalar would satisfy `is not null`.
  select * into v_open from public.create_ride();
  open_kind := v_open.kind;
  open_route_null := v_open.route is null;

  select * into v_route from public.create_ride('{"distanceMeters": 8000}'::jsonb);
  route_kind := v_route.kind;   -- by returned row, NOT by created_at: now() is constant in a txn

  perform set_config('request.jwt.claims','{"sub":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
  begin
    perform public.join_ride(v_open.join_code, false);
    old_client_rejected := false;
  exception when others then old_client_rejected := true; end;

  begin
    perform public.join_ride(v_open.join_code, true);
    new_client_joined := true;
  exception when others then new_client_joined := false; end;
end; $$;

select is(open_kind, 'open', 'a route-less create is stored as kind = open') from pg_temp.open_ride_flow();
select ok(open_route_null, 'route is SQL NULL, not a jsonb null scalar') from pg_temp.open_ride_flow();
select is(route_kind, 'route', 'a create WITH a route derives kind = route') from pg_temp.open_ride_flow();
select ok(old_client_rejected, 'an old client is refused an open ride') from pg_temp.open_ride_flow();
select ok(new_client_joined, 'a supporting client joins an open ride') from pg_temp.open_ride_flow();

select is((select kind from public.rides where join_code = 'LEGACY01'), 'route',
          'a pre-0021 row backfills to kind = route');

-- The CHECK from Step 1 actually bites.
select throws_ok(
  $$ update public.rides set route = null where join_code = 'LEGACY01' $$,
  '23514', 'a route ride cannot lose its route without changing kind');

-- The DISCRIMINATING grant assertion. `has_function_privilege('authenticated', ...)` is true
-- the moment the function exists, because Postgres grants EXECUTE to PUBLIC by default and
-- authenticated inherits it — so the positive assertion the spec suggests cannot fail. The
-- negative one fails if 0021's `revoke ... from public` line is dropped.
select ok(not has_function_privilege('anon', 'public.join_ride(text, boolean)', 'execute'),
          'anon cannot execute join_ride after the drop/recreate');

select * from finish();
rollback;
```

- [ ] **Step 3: Run it**

Run: `supabase db reset && supabase test db` (or the MCP fallback from Preconditions).
Expected: **8/8 PASS.** This verifies code already written, so a pass is expected — and a failure is a **real defect in `794d748`** unless it is one of the two known test-shaped hazards above (RLS visibility, `created_at` ties). Diagnose which before touching the migration.

- [ ] **Step 4: Prove the join gate assertion discriminates**

Comment out `if v_ride.kind = 'open' and not p_supports_open then raise exception 'join failed'; end if;` in the migration, re-run, and confirm **`old_client_rejected` fails**. If it still passes, the test is not reaching the gate — fix the test, not the migration. Restore, re-run, back to 8/8.

- [ ] **Step 5: Commit**

```bash
git add supabase/tests/0021_open_rides_test.sql supabase/migrations/0021_open_rides.sql
git commit -m "test(roh-114): pgTAP the open-ride migration, and constrain kind to match route"
```

---

### Task 2: Prove the app target compiles

**Files:** none — a gate.

`794d748` changed a protocol the app target conforms to. The package suite cannot see that.

- [ ] **Step 1:** Dispatch `apple-platform-build-tools:builder`: *"Build the Aura app target for an iOS simulator. Report success, or the first compiler error with file and line. Do not attempt fixes."*
- [ ] **Step 2:** Fix any real compiler error and re-dispatch; commit as `fix(roh-114): …`. A missing Mapbox token is an environment failure, not a code one — see Preconditions.

---

### Task 3: The decoder test the spec singles out, made possible

**Files:** Create `AuraCore/Sources/AuraCore/GroupRide/RouteEnvelope.swift`; modify `SupabaseGroupRideBackend.swift`; test in `AuraCore/Tests/AuraCoreTests/GroupRide/`.

The spec's Verification block calls this **"the test R1 lacked"**: `"route": null` through the real row decoder, asserting nil, and it "cannot run against the in-memory fake." It also cannot run where the code currently lives — `GroupRideRow` is `private` (`SupabaseGroupRideBackend.swift:141`) in a target whose only test bundle is `Aura/UITests`. Writing a mirror struct in AuraCore would be the same evasion the spec rejects.

So move the logic, not the test: the `.null`-folding rule becomes a pure function in AuraCore, and `GroupRideRow.routeData()` calls it. The bug then lives somewhere a test can see.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aJSONNullRouteFoldsToNil() throws {
    #expect(try RouteEnvelope.bytes(from: AnyJSONLike.null) == nil)
}
@Test func anAbsentRouteIsNil() throws {
    #expect(try RouteEnvelope.bytes(from: nil) == nil)
}
@Test func aPresentRouteSurvives() throws {
    #expect(try RouteEnvelope.bytes(from: .object(["distanceMeters": .number(8000)])) != nil)
}
```

`AnyJSON` belongs to the Supabase SDK and is not visible in AuraCore. Define the minimal `AnyJSONLike` enum this function needs in `RouteEnvelope.swift`, and have `GroupRideRow` map its `AnyJSON` into it at the boundary — a two-line mapping in the app target, with the *rule* in the package.

- [ ] **Step 2:** Run `cd AuraCore && swift test --no-parallel --filter RouteEnvelope` → FAIL (no such type).
- [ ] **Step 3:** Implement `RouteEnvelope.bytes(from:)`, then rewrite `routeData()` to delegate. Behaviour must not change.
- [ ] **Step 4:** Run `cd AuraCore && swift test --no-parallel` → PASS. Then **re-dispatch the builder** — this touches the app target.
- [ ] **Step 5:** Commit as `refactor(roh-114): make the null-route fold testable where the bug was`.

---

### Task 4: `kind` reaches the client, without the fake lying about it

**Files:** `GroupRide.swift`, `SupabaseGroupRideBackend.swift`, `GroupRideSession.swift`, `InMemoryGroupRideBackend.swift`; extend `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideOpenRideTests.swift`.

**Two traps the gate found.**

*Decode side.* `let kind: String` as a **required** key means a build reaching a device before 0021 is applied fails to decode every ride — and `joinRide`'s blanket `catch` (`SupabaseGroupRideBackend.swift:56`) reports "double-check the code with your host" for route rides too. Use `let kind: String?` with `?? "route"`, which survives both rollout directions.

*Fake side.* `InMemoryGroupRideBackend.startRide` (`:92`) and `endRide` (`:109`) **rebuild** `GroupRide` positionally. A trailing defaulted `kind:` would silently reset an open ride to `.route` at every lifecycle write, so Plans 2 and 3 would build crew behaviour on a fake that misreports the seam. Both sites must pass `kind: ride.kind` explicitly.

- [ ] **Step 1: Write the failing tests** — use the file's existing `host()` / `guest(sharing:)` / `route()` helpers (`GroupRideOpenRideTests.swift:32-34`), which sign in and supply `transport:`. Do not hand-roll a session; revision 1's snippets omitted `transport:` (no default) and the sign-in, and used a `Route.fixture()` that does not exist.

```swift
@Test func aCreatedOpenRideReportsItsKind() async {
    let session = host(); await session.create(route: nil)
    #expect(session.rideKind == .open)
}
@Test func anOpenRideStaysOpenAcrossAStart() async {
    let backend = InMemoryGroupRideBackend()
    let h = host(on: backend); await h.create(route: nil); await h.startRiding()
    let g = guest(sharing: backend); await g.join(code: h.joinCode!)
    #expect(g.rideKind == .open)   // the defaulted-parameter trap, caught
}
```

- [ ] **Step 2:** Run `--filter GroupRideOpenRideTests` → FAIL.
- [ ] **Step 3:** Implement. `GroupRide.Kind` beside `Status`; `kind: Kind = .route` as a trailing init parameter **and** an explicit `kind: ride.kind` at both `InMemoryGroupRideBackend` rebuild sites; `GroupRideRow.kind: String?`; `rideKind` on the session assigned in both `create` and `join`.
- [ ] **Step 4:** `swift test --no-parallel` → PASS, then re-dispatch the builder.
- [ ] **Step 5:** Commit as `feat(roh-114): carry the ride kind from the column to the client`.

---

### Task 5: Stop throwing away the destination name (D1.3 item 5, and D5.4's real copy)

**Files:** `AppRoute.swift:47-76` (both `==` **and** `hash(into:)` — they are at `:52-63` and `:65-76`), `RoutePreviewView.swift:250`, `GroupRideFlowView.swift:149-156`.

D5.4 promises "Heading to Blue Bottle · 8 km". Revision 1 concluded the name was unavailable and substituted "Heading somewhere". That was wrong: `RoutePreviewView` holds `destination: Place` (`:19`), already renders `destination.name` (`:80`), and already pairs route-with-Place for the solo path (`:241`). Only `.create(selected)` (`:250`) drops it — and this task is editing that payload anyway.

- [ ] **Step 1: Write the failing test** in `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift` (the real home for `GroupRideEntry` equality; `Tests/AuraCoreTests/Navigation/` does not exist).

```swift
@Test func openCreateEntriesAreEqualAndHashAlike() {
    let a = GroupRideEntry.create(nil, nil), b = GroupRideEntry.create(nil, nil)
    #expect(a == b); #expect(Set([a, b]).count == 1)
}
```

- [ ] **Step 2:** Run `--filter AppRouteTests` → FAIL.
- [ ] **Step 3:** `case create(Route?, Place?)`; `==` compares `a?.id == b?.id` and the place; `hash(into:)` combines `route?.id`. `Optional`'s conformances give this free — no invented discriminator, as the spec says. Update `:250` to pass `destination`, and `invokeEntry` to ignore the place (the lobby reads it in Task 6).
- [ ] **Step 4:** `swift test --no-parallel` → PASS; re-dispatch the builder.
- [ ] **Step 5:** Commit as `feat(roh-114): a create entry carries an optional route and its place`.

---

### Task 6: The lobby names the ride kind (D5.4)

**Files:** Create `GroupRideSubtitle.swift`; modify `GroupLobbyView.swift:84-94`.

Without this, Task 4 is dead code — the failure this plan exists to stop repeating.

**Do not add `@Environment(SettingsStore.self)` to `GroupLobbyView`.** It is injected only at the app root (`AuraApp.swift:13,40`), so the two lobby previews (`GroupLobbyView.swift:313-323`) would trap at runtime. Pass `isImperial` down from `GroupRideFlowView`. **Do not reuse `PeerDistance`** — it takes a `RidePeer` and returns "0.4 mi ahead", not "8.0 mi", and the repo has two mile divisors (`PeerDistance.swift:15` uses 1609.34, `UnitConverter.swift:3` uses 1609.344). Use `UnitConverter`.

- [ ] **Step 1: Write the failing test**

```swift
#expect(GroupRideSubtitle.text(kind: .open, placeName: nil, distanceMeters: nil, isImperial: true)
        == "Open ride — no destination")
#expect(GroupRideSubtitle.text(kind: .route, placeName: "Blue Bottle", distanceMeters: 12_875, isImperial: true)
        == "Heading to Blue Bottle · 8.0 mi")
#expect(GroupRideSubtitle.text(kind: .route, placeName: nil, distanceMeters: 12_875, isImperial: true)
        == "8.0 mi route")
```

The no-name fallback leads with the fact rather than apologising for the gap — a guest who joined by code has no Place, and "Heading somewhere" tells them nothing.

- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement and render as a third line in the header `VStack`, `.font(.subheadline)`, `AuraTheme.textSecondary`. **Step 4:** `swift test` → PASS; re-dispatch the builder.
- [ ] **Step 5:** Commit as `feat(roh-114): the lobby says which kind of ride a guest just joined`.

---

### Task 7: The riding container stops treating "no route" as a failure (D4.1)

**Files:** `GroupRideFlowView.swift:117-132`, `GroupNavigateContainer.swift:13-14`.

**This is the task revision 1 deferred, and deferring it is what made revision 1 unshippable.** Today an open ride that starts lands on "Couldn't load this ride's route." — the host taps the lobby's unconditional **Start riding** (`GroupLobbyView.swift:198`), `phase` goes `.riding`, and the fork at `:118` reads `route != nil` as "something went wrong". A guest joining an already-started open ride skips the lobby entirely (`GroupRideSession.swift:198-201` reconciles to `.riding`) and lands there directly. The only control is Back → `router.pop()`, which drops the session without leaving the ride, so the code stays poisoned until the ride expires.

- [ ] **Step 1: Fork on kind, not on route**

```swift
@ViewBuilder private var ridingContainer: some View {
    if session.rideKind == .open {
        RideHUDView(groupSession: session)          // Task 8 wires the sink
            .task { didEnterRiding = true; await session.beginLiveSession() }
    } else if session.route != nil {
        GroupNavigateContainer(session: session)
            .task { didEnterRiding = true; await session.beginLiveSession() }
    } else {
        dismissMessage(title: "Couldn't load this ride's route.", …)   // now genuinely corrupt-only
    }
}
```

The third branch keeps its meaning for the case it was written for — a route ride whose route did not arrive. **Rewrite the stale comment at `:125-127`** ("unreachable in practice") and the one at `GroupNavigateContainer.swift:13`; ROH-105's documented lesson was a stale doc comment on exactly this kind of type.

This is the third production call site of `beginLiveSession()`. The entry latch is what makes that safe — see the spec's D4.1, and do not move it.

- [ ] **Step 2:** Re-dispatch the builder. There is no unit test for a `@ViewBuilder` fork; the evidence is Task 10.
- [ ] **Step 3:** Commit as `feat(roh-114): an open ride rides the Explore cockpit, not an error screen`.

---

### Task 8: `groupSink` attaches at `.task` (D4.5)

**Files:** `RideHUDView.swift:216-219`.

The spec is emphatic and the code confirms it. `RideHUDView`'s `.task` passes `discoverySink:` and no `groupSink:`; navigate passes `groupSink: groupSession?.locationSink` (`NavigateHUDView.swift:234-237`). **Both parameters default to nil on the same call**, so omitting one compiles clean and ships dead — and `start` early-returns on `guard !recorder.isRecording` (`RideSessionCoordinator.swift:149`), so a sink not supplied at the first `start` can **never** attach. The rider then publishes nothing while seeing everyone else: invisible to their whole crew.

Wiring it into the `State(initialValue:)` coordinator in `init` fails the same way. It goes in `.task`, beside `discoverySink:`.

- [ ] **Step 1:** Add `var groupSession: GroupRideSession? = nil` to `RideHUDView`. Safe: `@State` identity is positional and the solo call site (`AuraApp.swift:108`) stays `RideHUDView()`.
- [ ] **Step 2:** Pass `groupSink: groupSession?.locationSink` in the existing `coordinator.start(...)` call.
- [ ] **Step 3:** Re-dispatch the builder. Commit as `feat(roh-114): an open-ride rider actually publishes their position`.

---

### Task 9: Home's chip, and a crew screen that hosts two actions (D2, D2.1, D2.2)

**Files:** `HomeLaunchBand.swift:5,33`, `GroupRideJoinView.swift:5,53-57,70,163`, `AuraApp.swift:118`.

Revision 1 split this across two tasks with a closure passed between them. That was wrong twice: `GroupRideJoinView()` takes no arguments at `AuraApp.swift:118` and in three `#Preview`s, so the closure either breaks four call sites or ships a dead button — and the view already holds `@Environment(AppRouter.self)` (`:12`) and calls `router.replaceTopWithGroupRide` directly at `:163`. No seam needed.

- [ ] **Step 1: Rename the chip.** `HomeChip(title: "Crew", …)`. Keep `.accessibilityIdentifier("home.join")` — `Screens.swift:7` keys off it. Update the file's own stale doc comment at `:5`.

  `grep -rn "Join a ride" --include="*.swift" .` also hits `JoinRideUITests.swift:13,14`, `HomeUITests.swift:7` and both files' comments. Those are comments and an assertion *message* — **do not** edit them into this commit.

- [ ] **Step 2: Fix the keyboard trap without shrinking the target.** Delete `.task { isFocused = true }`. **Do not** invert the background gesture to `isFocused = false`: the real `TextField` is `.opacity(0.02)` with no height behind boxes that are `.allowsHitTesting(false)` (`:85-108`), so the entry target is a ~22 pt strip and a near-miss would actively dismiss. Take D2.1's other branch — **focus when the host chooses "Enter a code"** — leaving the background gesture alone.
- [ ] **Step 3:** Header → "Crew" / "Start a ride together, or enter a code to join one". Toolbar "Cancel" reads wrong on a screen that now creates; make it "Close". Update the view's stale doc comment at `:5`.
- [ ] **Step 4:** Add the start action calling `router.replaceTopWithGroupRide(.create(nil, nil))` inline. **Not `startGroupRide`** — that pushes, leaving the code screen underneath, so Back from the lobby lands on a code form; signed out it stashes without popping and resumes onto a stale screen (`AppRouter.swift:61-93`).
- [ ] **Step 5:** Re-dispatch the builder, then verify on the simulator: no keyboard on arrival; "Enter a code" raises it; the start action reaches a lobby; Back from the lobby goes Home.
- [ ] **Step 6:** Commit as `feat(roh-114): the crew screen greets a host, not a keyboard`.

---

### Task 10: Two phones, past the button revision 1 stopped before

**Files:** none.

- [ ] **Apply 0021 to the project the phones talk to.** `supabase db push`, or MCP `apply_migration`. **No revision-1 step did this**, and with `kind` on the decode path a build meeting a project without 0021 fails every join — route rides included. 0021 lands **before** the build, and cannot be reverted after one ships.
- [ ] Host: Home → Crew → Start a ride → lobby, code visible, "Open ride — no destination".
- [ ] Guest: Home → Crew → code → lobby, **not** the route error.
- [ ] **Host taps Start riding.** Both phones reach the Explore cockpit and record. This is the tap revision 1's device pass stopped short of, and all three reviewers found the dead end behind it.
- [ ] **A guest joining after the start** goes straight to `.riding` — confirm they land on the cockpit, not the error screen.
- [ ] Both riders' positions publish (D4.5's failure is silent on the publishing phone — check the *other* phone's roster in Plan 2, or the `ride_track_points` rows now).
- [ ] A route ride still works end to end: preview → Ride together → lobby subtitle names the place → navigate cockpit.
- [ ] Signed out, tapping Start a ride: the sign-in sheet appears with no explanation of why. **Known gap, pre-existing on the join path** — record what it looks like; fixing it is not in this plan.
- [ ] iPhone SE, largest type size, saved place present: the chip row does not truncate, **and the lobby's new third line does not push Start riding off a screen with no ScrollView** (`GroupLobbyView.swift:42-70`).

- [ ] **Commit the notes:** `git commit --allow-empty -m "chore(roh-114): record the plan-1 two-phone pass"`

---

## What the gate caught

Three reviewers, independent, distinct lenses. All three found the same critical defect by different routes, which is the argument for running more than one.

- **Critical, all three:** revision 1 shipped a complete, tested path to "Couldn't load this ride's route." Fixed by pulling D4.1 and D4.5 in (Tasks 7–8) and extending the device pass (Task 10).
- **Critical, architecture:** nothing enforced `kind = 'open' ⟺ route is null`. Now a table CHECK.
- **High, skeptic + architecture:** the pgTAP could not run — RLS hides the ride from the guest role. Rewritten on the repo's actual precedent.
- **High, architecture:** a trailing defaulted `kind:` would have made the in-memory fake silently reset open rides to `.route` at every lifecycle write, poisoning Plans 2 and 3.
- **High, skeptic:** no step applied 0021 to the project the device test targets, while `kind` was a required decode key. Now a rollout order plus an optional key.
- **High, skeptic:** the spec's headline decoder test was omitted, and cannot be written where `GroupRideRow` lives. Task 3 moves the rule into AuraCore.
- **High, product:** the destination name was one identifier away and revision 1 wrote copy apologising for its absence.
- **Medium:** the keyboard fix would have shrunk the code-entry target to ~22 pt; the closure seam had no caller; four app-target commits ran with no build between them; `SettingsStore` in the lobby would trap both previews.
- **Wrong facts in revision 1:** `Route.fixture()` and an `AppRouter(isSignedIn:)` initialiser (neither exists), `AppRouter` as package-testable (it is app-target-only, so the filter would have run zero tests and exited 0), a non-existent test directory, a wrong line range, a wrong grep expectation, and the claim that `create(route: Route?)` was unfinished (it was done).

## Carried back to the spec, not fixed here

- **D1.5's rate-limit reasoning appears false.** It argues each rejected retry burns a `join_attempts` row toward the 10/minute cap. `join_ride` has no exception block, so the insert rolls back with the statement whenever a later `raise` fires — failed joins never count. Pre-existing since 0003.
- **D2's "verified on device" is contradicted** by the spec's own Verification block, which still lists the SE chip check as pending. Task 10 treats it as unverified.
- **An old client is told to check a correct code.** D1.5's generic oracle is the right security call, but nothing anywhere says "update the app", and the host gets no warning at creation that older builds cannot join.
- **"Open ride" beside a large JOIN CODE reads as a privacy claim** — open to *anyone* — when it means "no route".

## Deferred

**Plan 2 — the crew layer** (D3, D4.2–D4.6): peer dots, roster, `coordinator.currentCoordinate`, `CrewChrome`. Two prerequisites: **`RiderColorLatch` does not exist** despite D3.3 and the Verification block both referencing it as though it does, and **D4.3 promotes ROH-115** (memoise `ribbonPieces` before the `TimelineView`, or `RideMapView.body` copies a growing track ~30×/s).

**Plan 3 — behaviour and copy** (D5 except D5.4, D6, D7).

**Out of scope** (D9): mid-ride join, crew compass (ROH-168), group-aware Live Activity (ROH-15), lifecycle defects (ROH-174).
