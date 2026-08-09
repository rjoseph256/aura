# ROH-114 Plan 1 — Open rides, end to end

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A host starts a crew ride with no destination from Home, a guest joins by code, and both land in a lobby that says which kind of ride it is — with the SQL half actually tested.

**Architecture:** Most of the wire already exists in `794d748`, written before this plan and never verified. So this plan opens by *proving or breaking* that commit rather than adding to it: pgTAP against migration 0021, then an app-target build. Only then does it close the `kind` seam the commit left half-built, and wire the two entry points. Nothing on the Explore cockpit is touched here — that is Plan 2.

**Tech Stack:** Swift 6 / SwiftUI, `AuraCore` + `AuraKit` packages, Supabase Postgres with pgTAP, PostgREST RPC.

**Spec:** [`docs/superpowers/specs/2026-08-02-roh114-group-explore-design.md`](../specs/2026-08-02-roh114-group-explore-design.md) revision 5. This plan covers **D1**, **D2** and **D5.4**.

---

## Read this before Task 1

`794d748` is already on this branch. It implements D1.1, D1.2, D1.4 and D1.5, with `GroupRideOpenRideTests` and 880 green package tests. Its own commit message ends `NOT YET VERIFIED`, and that is accurate:

- the app target has never compiled with it;
- migration `0021_open_rides.sql` has never been applied or tested.

The second is the dangerous one. D1.5 drops and recreates `join_ride`, and the spec says in terms that getting it wrong "takes down joining for **every** client including route rides." There is currently no evidence it is right.

**It is also incomplete against its own spec section.** D1.3 lists five Swift seams. `GroupRide.kind` (item 3) and `GroupRideSession.rideKind` (item 4) were never added — `GroupRide.swift` is not in the commit — so `kind` reaches SQL and stops. That is exactly the dead-seam failure D1.3 was written to prevent. Tasks 3 and 4 close it, and Task 4 gives it a consumer in the same plan so it cannot sit dead.

## File structure

| File | Responsibility | Status |
| --- | --- | --- |
| `supabase/migrations/0021_open_rides.sql` | nullable route, `rides.kind`, `join_ride` gate | exists, untested |
| `supabase/tests/0021_open_rides_test.sql` | pgTAP for the above | **create** |
| `AuraCore/Sources/AuraCore/GroupRide/GroupRide.swift` | `GroupRide.kind` | **modify** |
| `Aura/Sources/Sync/SupabaseGroupRideBackend.swift` | `GroupRideRow.kind` → domain | modify (route half done) |
| `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` | `rideKind` for the lobby | modify (route half done) |
| `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` | fake must carry `kind` too | **modify** |
| `Aura/Sources/GroupRide/GroupLobbyView.swift` | D5.4 kind line | **modify** |
| `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift` | `GroupRideEntry.create(Route?)` | **modify** |
| `Aura/Sources/GroupRide/GroupRideFlowView.swift` | `invokeEntry` optional route | **modify** |
| `Aura/Sources/Home/HomeLaunchBand.swift` | "Join a ride" → "Crew" | **modify** |
| `Aura/Sources/GroupRide/GroupRideJoinView.swift` | two actions, no keyboard trap | **modify** |

Commands used throughout:

```bash
cd AuraCore && swift test --no-parallel
```

```bash
supabase db reset && supabase test db
```

The app build is **delegated to the `apple-platform-build-tools:builder` subagent**, never run inline — it takes ~13 minutes and floods a session with xcodebuild output.

---

### Task 1: pgTAP for migration 0021 — the verification `794d748` skipped

**Files:**
- Create: `supabase/tests/0021_open_rides_test.sql`
- Reference: `supabase/migrations/0021_open_rides.sql`, `supabase/tests/0014_join_cap_lock_test.sql` (nearest seeding precedent)

Seeding convention is load-bearing and documented at `docs/superpowers/plans/2026-06-29-group-rides-sp1-backend-identity.md:22`: never insert into `public.profiles` (the `handle_new_user` trigger does it), seed `auth.users` with `(instance_id, id, aud, role, email)` as superuser **before** any role switch, then switch identity with `set local request.jwt.claims`.

- [ ] **Step 1: Write the pgTAP test**

Covers the four claims in the spec's Verification block, plus the discrimination check.

```sql
begin;
select plan(7);

-- Two users, seeded before any role switch.
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
   'authenticated', 'authenticated', 'host@example.com'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
   'authenticated', 'authenticated', 'guest@example.com');

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- 1. An open ride is created through the RPC with p_route OMITTED, not passed as null.
--    Omission is the whole point: a jsonb 'null' scalar would satisfy `is not null`.
select lives_ok($$ select public.create_ride() $$, 'create_ride with no p_route succeeds');

select is(
  (select kind from public.rides order by created_at desc limit 1),
  'open',
  'a route-less create is stored as kind = open');

select ok(
  (select route is null from public.rides order by created_at desc limit 1),
  'route is SQL NULL, not a jsonb null scalar');

-- 2. A route create still derives kind = 'route'.
select public.create_ride('{"distanceMeters": 8000}'::jsonb);
select is(
  (select kind from public.rides order by created_at desc limit 1),
  'route',
  'a create WITH a route derives kind = route');

-- 3. join_ride refuses an open ride when the caller has not declared support...
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select throws_ok(
  format($$ select public.join_ride(%L, false) $$,
         (select join_code from public.rides where kind = 'open' order by created_at desc limit 1)),
  'join failed',
  'an old client is refused an open ride, with the generic oracle');

-- 4. ...and accepts it when it has.
select lives_ok(
  format($$ select public.join_ride(%L, true) $$,
         (select join_code from public.rides where kind = 'open' order by created_at desc limit 1)),
  'a supporting client joins an open ride');

-- 5. The drop-and-recreate left the grant intact. See the note below before trusting this.
select ok(
  has_function_privilege('authenticated', 'public.join_ride(text, boolean)', 'execute'),
  'join_ride is still executable by authenticated after the drop/recreate');

select * from finish();
rollback;
```

- [ ] **Step 2: Run it**

Run: `supabase db reset && supabase test db`
Expected: **7/7 PASS.** This is verification of code already written, so a pass is the expected outcome — and a *failure here is a real defect in `794d748`*, not a test bug. Do not edit the test to make it pass. Fix the migration, or stop and report.

- [ ] **Step 3: Prove the join gate test discriminates**

A test that passes against both the fixed and the broken code tests nothing. This is the same reasoning the ROH-167 guard used to reject asserting `isLive` directly.

Temporarily comment out this line in `supabase/migrations/0021_open_rides.sql`:

```sql
  if v_ride.kind = 'open' and not p_supports_open then raise exception 'join failed'; end if;
```

Run: `supabase db reset && supabase test db`
Expected: **the `throws_ok` assertion FAILS.** If it still passes, the test is not reaching the gate — fix the test before restoring.

Then restore the line and re-run: back to 7/7.

- [ ] **Step 4: Record what the grant assertion is worth**

Add this comment above assertion 7, and do not skip it — the spec calls this one out specifically:

```sql
-- NOTE: this assertion may be theatre. 0020_revoke_maintenance_rpc_from_api_roles.sql:4-10
-- documents that hosted Supabase materialises explicit grants at function-create time via
-- ALTER DEFAULT PRIVILEGES, and the local CLI stack replicates it — so this would pass whether
-- or not the migration re-grants. Keep it as a tripwire; do not read a pass as proof.
```

- [ ] **Step 5: Commit**

```bash
git add supabase/tests/0021_open_rides_test.sql supabase/migrations/0021_open_rides.sql
git commit -m "test(roh-114): pgTAP the open-ride migration that shipped unverified"
```

---

### Task 2: Prove the app target still compiles

**Files:** none changed — this is a gate, not an edit.

`794d748` changed a protocol signature (`createRide(route: Data?)`) that the app target conforms to. The package suite cannot see that.

- [ ] **Step 1: Delegate the build**

Dispatch the `apple-platform-build-tools:builder` subagent with: *"Build the Aura app target for an iOS simulator. Report success, or the first compiler error with its file and line. Do not attempt fixes."*

Expected: success.

If it fails on a **missing Mapbox token** rather than a compiler error, that is an environment problem, not a code problem — see `docs/COLLABORATOR-SETUP.md:82-93` for the `~/.netrc` entry SPM needs. Fix the environment and re-dispatch. Do not proceed past this task on an unbuilt app target; the whole reason this plan exists is that someone did.

- [ ] **Step 2: If it fails on a real compiler error, fix and re-dispatch**

Likely sites are the `GroupRideBackend` conformance in `Aura/Sources/Sync/SupabaseGroupRideBackend.swift` and any call to `session.create(route:)`. Commit any fix as `fix(roh-114): <what>` before continuing.

---

### Task 3: `kind` reaches the client

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/GroupRide.swift`
- Modify: `Aura/Sources/Sync/SupabaseGroupRideBackend.swift` (`GroupRideRow`, `toDomain()`)
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` (expose `rideKind`)
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideOpenRideTests.swift` (extend)

`join_ride` and `create_ride` both `returns public.rides`, so `kind` is already on the wire the moment the column exists — only the Swift decode is missing.

Per D1.3, the client reads the **stored** column rather than re-deriving from a nil route, so there is one authority for the read side.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aCreatedOpenRideReportsItsKind() async {
    let backend = InMemoryGroupRideBackend()
    let session = GroupRideSession(backend: backend, displayNameProvider: { "Alice" })
    await session.create(route: nil)
    #expect(session.rideKind == .open)
}

@Test func aJoinedRouteRideReportsItsKind() async {
    let backend = InMemoryGroupRideBackend()
    let host = GroupRideSession(backend: backend, displayNameProvider: { "Alice" })
    await host.create(route: .fixture())
    let guest = GroupRideSession(backend: backend, displayNameProvider: { "Bob" })
    await guest.join(code: host.joinCode!)
    #expect(guest.rideKind == .route)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter GroupRideOpenRideTests`
Expected: FAIL — `rideKind` does not exist.

- [ ] **Step 3: Add the field through every layer**

`GroupRide.swift` — the enum is defined here beside `Status`, which it parallels:

```swift
public enum Kind: String, Codable, Sendable { case route, open }
public let kind: Kind
```

Add `kind: Kind = .route` to `init` **at the end of the parameter list with a default**, so the many existing construction sites in tests keep compiling and mean what they meant before.

`GroupRideRow` in `SupabaseGroupRideBackend.swift` — add `let kind: String`, add `case kind` to `CodingKeys`, and in `toDomain()` map it with a fallback rather than a force:

```swift
kind: GroupRide.Kind(rawValue: kind) ?? .route
```

An unknown future kind degrades to a route ride rather than throwing a guest out mid-join.

`GroupRideSession` — expose it for D5.4:

```swift
/// The ride's kind as the server stored it (D1.3): the read side has one authority, so this
/// is never re-derived from `route == nil`.
public private(set) var rideKind: GroupRide.Kind = .route
```

Assign it in **both** `create` and `join`, beside the existing `rideID` assignments.

`InMemoryGroupRideBackend` — its `createRide` must set `kind` from whether `route` was nil, mirroring the SQL derivation, or every fake-backed test lies about the seam.

- [ ] **Step 4: Run to verify it passes**

Run: `cd AuraCore && swift test --no-parallel`
Expected: PASS, whole suite green.

- [ ] **Step 5: Commit**

```bash
git add AuraCore Aura/Sources/Sync/SupabaseGroupRideBackend.swift
git commit -m "feat(roh-114): carry the ride kind from the column to the client"
```

---

### Task 4: The lobby names the ride kind (D5.4)

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupLobbyView.swift` (header, ~`:84-94`)

Without this, Task 3 is dead code, which is the failure this plan exists to stop repeating. D1.6 keeps `GroupLobbyView` structurally unchanged; this is the one copy addition it allows.

**A spec gap to settle first.** D5.4 gives the route-ride example as `"Heading to Blue Bottle · 8 km"`. **`Route` carries no destination name** — `Route.swift:3-18` has `origin`, `destination` and `waypoints` as bare `Coordinate`s. There is no "Blue Bottle" anywhere on the guest's side, and inventing a reverse-geocode here is out of scope. Ship the distance, which is real:

- open: `"Open ride — no destination"`
- route: `"Heading somewhere · 8.0 mi"` — distance from `session.route?.distanceMeters`, formatted through the existing units setting.

Flag this to the spec author rather than silently downgrading the copy.

- [ ] **Step 1: Write the failing test**

There is no view-test harness for the lobby, so test the string, not the view. Put the formatter in AuraCore where it can be seen:

```swift
@Test func openRideSubtitleNamesTheKind() {
    #expect(GroupRideSubtitle.text(kind: .open, distanceMeters: nil, isImperial: true)
            == "Open ride — no destination")
}

@Test func routeRideSubtitleCarriesTheDistance() {
    #expect(GroupRideSubtitle.text(kind: .route, distanceMeters: 12_875, isImperial: true)
            == "Heading somewhere · 8.0 mi")
}

@Test func aRouteRideWithNoDistanceStillSaysSomething() {
    #expect(GroupRideSubtitle.text(kind: .route, distanceMeters: nil, isImperial: true)
            == "Heading somewhere")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter GroupRideSubtitle`
Expected: FAIL — no such type.

- [ ] **Step 3: Implement**

Create `AuraCore/Sources/AuraCore/GroupRide/GroupRideSubtitle.swift`, a pure function over `(kind, distanceMeters, isImperial)`. Reuse the existing distance formatter rather than writing a second one — grep for how `GroupRosterViewData` formats distance and match it.

Then render it in `GroupLobbyView`'s header, under `Text("Ride together")`, as a third line in that `VStack`, styled like the existing subtitle (`.font(.subheadline)`, `AuraTheme.textSecondary`).

- [ ] **Step 4: Run to verify it passes**

Run: `cd AuraCore && swift test --no-parallel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore Aura/Sources/GroupRide/GroupLobbyView.swift
git commit -m "feat(roh-114): the lobby says which kind of ride a guest just joined"
```

---

### Task 5: `GroupRideEntry.create` takes an optional route (D1.3 item 5)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift:47-60`
- Modify: `Aura/Sources/GroupRide/GroupRideFlowView.swift:149-156` (`invokeEntry`)
- Test: `AuraCore/Tests/AuraCoreTests/Navigation/` (nearest existing `GroupRideEntry` test)

The spec settles the `Equatable`/`Hashable` question: `Route?` gives `a?.id == b?.id` and `hasher.combine(route?.id)` free from `Optional`'s conformances. The naive edit compiles and is correct — no invented discriminator.

- [ ] **Step 1: Write the failing test**

```swift
@Test func twoOpenCreateEntriesAreEqualAndHashAlike() {
    let a = GroupRideEntry.create(nil)
    let b = GroupRideEntry.create(nil)
    #expect(a == b)
    #expect(Set([a, b]).count == 1)
}

@Test func anOpenCreateDiffersFromARouteCreate() {
    #expect(GroupRideEntry.create(nil) != GroupRideEntry.create(.fixture()))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter GroupRideEntry`
Expected: FAIL — `create` does not accept nil.

- [ ] **Step 3: Implement**

`case create(Route?)`; in `==`, `case let (.create(a), .create(b)): return a?.id == b?.id`; in `hash(into:)`, `hasher.combine(route?.id)`. In `invokeEntry`, `case let .create(route): await session.create(route: route)` — which now type-checks unchanged, since `create` already takes `Route?`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd AuraCore && swift test --no-parallel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore Aura/Sources/GroupRide/GroupRideFlowView.swift
git commit -m "feat(roh-114): a create entry can carry no route"
```

---

### Task 6: Home's chip becomes "Crew" (D2)

**Files:**
- Modify: `Aura/Sources/Home/HomeLaunchBand.swift:33`

One string. The width argument behind it is in D2: chips are natural-width in an `HStack(spacing: 8)` inside `.padding(.horizontal, 24)`, so on an iPhone SE that row has 327 pt of usable width and "Ride with friends" overflows it. "Crew" fits.

Leave `.accessibilityIdentifier("home.join")` **unchanged** — UI tests key off it, and renaming the identifier alongside the label turns a copy change into a test-suite change for no gain.

- [ ] **Step 1: Change the title**

```swift
HomeChip(title: "Crew", systemImage: "person.2.badge.plus", action: onJoin)
```

- [ ] **Step 2: Check no test asserts the old string**

Run: `grep -rn "Join a ride" --include="*.swift" .`
Expected: hits only in `GroupRideJoinView.swift` (Task 7 rewrites that one). Any UI-test hit must be updated in this same commit.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Home/HomeLaunchBand.swift
git commit -m "feat(roh-114): Home's crew chip stops saying 'join'"
```

---

### Task 7: The crew screen hosts two actions (D2.1)

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideJoinView.swift:55-57` (the gestures and `.task`), `:68-70` (the header)

Three defects, all in the spec and all confirmed in the file:

1. `.task { isFocused = true }` throws the keyboard up on the first frame, so a host who came to *start* a ride meets a keyboard, eight code boxes and a disabled Join.
2. The keyboard cannot be dismissed — `.contentShape(Rectangle()).onTapGesture { isFocused = true }` re-focuses on every background tap, and there is no scroll view for `scrollDismissesKeyboard`.
3. The header says "Join a ride".

- [ ] **Step 1: Remove the autofocus and the re-focusing background tap**

Delete `.task { isFocused = true }`. Change the background gesture to dismiss rather than focus:

```swift
.contentShape(Rectangle())
.onTapGesture { isFocused = false }
```

The code field keeps its own tap-to-focus; a tap on the *background* should mean "put that keyboard away", which is the one thing the screen cannot currently do.

- [ ] **Step 2: Rewrite the header for two actions**

```swift
Text("Crew")
Text("Start a ride together, or enter a code to join one")
```

- [ ] **Step 3: Add the "start a ride" action**

A button above the code field, calling back to the host screen's handler. Wire the handler in Task 8 — leave it as a passed-in closure here so this task stays reviewable on its own.

- [ ] **Step 4: Verify on the simulator**

This is a keyboard-behaviour change and cannot be asserted from a unit test. Launch the app, open Crew from Home, and confirm: no keyboard on arrival; tapping the code field raises it; tapping the background dismisses it.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/GroupRide/GroupRideJoinView.swift
git commit -m "feat(roh-114): the crew screen greets a host, not a keyboard"
```

---

### Task 8: Start an open ride through `replaceTopWithGroupRide` (D2.2)

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideJoinView.swift` (the handler from Task 7)
- Reference: `Aura/Sources/App/AppRouter.swift:73-93`

**Use `replaceTopWithGroupRide`, not `startGroupRide`.** The spec's reasoning holds against the current file: `startGroupRide` *pushes*, leaving the code screen underneath, so Back from the lobby lands the host on a code form with the keyboard up; and signed out it stashes the intent without popping, so `resumePendingGroupRide()` pushes on top of the stale screen. `replaceTopWithGroupRide` exists for exactly this case — its doc comment names the manual-join dead-end observed on device on 2026-07-19 — and it applies the same sign-in gate.

- [ ] **Step 1: Write the failing test**

`AppRouter` is testable directly:

```swift
@Test func startingAnOpenRideReplacesTheEntryScreen() {
    let router = AppRouter(isSignedIn: { true })
    router.push(.joinRide)
    router.replaceTopWithGroupRide(.create(nil))
    #expect(router.path == [.groupRide(.create(nil))])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --no-parallel --filter AppRouter`
Expected: FAIL if `AppRoute`/`GroupRideEntry` equality does not yet accept nil — otherwise this passes off Task 5's work, which is fine; the point is the call site.

- [ ] **Step 3: Wire the handler**

```swift
onStartOpenRide: { router.replaceTopWithGroupRide(.create(nil)) }
```

- [ ] **Step 4: Verify the whole path on the simulator**

Home → Crew → Start a ride → lobby shows a join code and the line "Open ride — no destination". Back from the lobby goes **Home**, not to the code screen.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/GroupRide/GroupRideJoinView.swift
git commit -m "feat(roh-114): a host starts a destination-free ride from the crew screen"
```

---

### Task 9: Two-phone check on what this plan actually shipped

**Files:** none.

Plan 1 ships a real, user-visible slice, and the repo's rule is that UI is verified on a device rather than asserted. Explore's crew layer does not exist yet, so the check stops at the lobby.

- [ ] Host on phone A: Home → Crew → Start a ride → lobby, code visible, subtitle reads "Open ride — no destination".
- [ ] Guest on phone B: Home → Crew → enter the code → **lobby, not the "Couldn't load this ride's route" screen.** This is the D1.1 bug; if it appears, the wire fix is not working end to end against real Supabase, which no unit test can tell you.
- [ ] A normal route ride still works: route preview → "Ride together" → lobby, subtitle carries the distance.
- [ ] iPhone SE, largest supported type size, with a saved place present: the Home chip row does not truncate (D2).

- [ ] **Commit the device notes**

```bash
git commit --allow-empty -m "chore(roh-114): record the plan-1 two-phone pass"
```

---

## What this plan deliberately leaves out

**Plan 2 — the crew layer on Explore** (D3, D4). Peer dots, the roster, `coordinator.currentCoordinate`, the `CrewChrome` extraction, and the colour authority. Two things to settle before it starts:

- **`RiderColorLatch` does not exist.** D3.3 says it "becomes the only authority" and the Verification block lists tests for it, both phrased as though the type were already in the tree. It is not — `PeerPalette.assign` is the only colour code today, and it has no `reserved:` parameter. Plan 2 creates it.
- **D4.3 promotes ROH-115 to a prerequisite.** `ribbonPieces` must be memoised *before* the `TimelineView` goes in, or `RideMapView.body` re-evaluates ~30×/s while copying every point of a growing recorded track. A five-minute device pass cannot see this; hour two can.

**Plan 3 — behaviour and copy** (D5 except D5.4, D6, D7). The exit rules, the waited-on leave, the late-join notice, the join-link toast, roster copy, and navigate's two declared changes.

**Out of scope entirely** (D9): mid-ride join, the crew compass (ROH-168), group-aware Live Activity (ROH-15), the lifecycle defects (ROH-174).
