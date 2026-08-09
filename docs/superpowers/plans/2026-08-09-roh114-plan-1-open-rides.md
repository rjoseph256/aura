# ROH-114 Plan 1 — Open rides, end to end

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A host starts a crew ride with no destination, a guest joins by code, both ride the Explore cockpit, and both can *end* it — with the SQL underneath actually tested.

**Architecture:** Most of the wire already exists in `794d748`, written before this plan and never verified, so this plan opens by proving or breaking it. It then closes the `kind` seam, carries kind and destination name to the lobby, wires the entry points, forks the riding container onto the Explore HUD, and gives that HUD the minimum crew lifecycle needed to leave a ride. Peer rendering is Plan 2.

**Tech Stack:** Swift 6 / SwiftUI, `AuraCore` + `AuraKit` packages, Supabase Postgres with pgTAP, PostgREST RPC.

**Spec:** [`2026-08-02-roh114-group-explore-design.md`](../specs/2026-08-02-roh114-group-explore-design.md) revision 5. Covers **D1**, **D2**, **D4.1**, **D4.5**, **D5.4**, and a named subset of **D5.1**.

---

## Revision 3, and a change in how this document is written

Two adversarial gates, five reviewers. **Both gates found defects of the same species: fabricated code and drifted citations written with enough confidence to read as verified.** Revision 1 had three non-compiling snippets; revision 2 fixed them and produced three more, in the very task whose premise was "revision 1's snippets were fabricated; these use the file's real helpers." They did not.

Worse, revision 2's list of revision 1's false claims **contained a false claim** — it asserted revision 1 said `GroupRideSession.create(route: Route?)` was unfinished. Revision 1 said no such thing; it correctly named `rideKind`. A fabricated entry in the catalogue of fabrications.

So revision 3 changes the rules rather than making a third attempt at the same trick:

1. **No verbatim Swift.** Every task states the behaviour to implement, the exact real signature of anything it must call, and what the test must assert. The implementer has a compiler; this document does not, and three revisions of evidence say it should stop pretending otherwise. **pgTAP is the exception** — the SQL *is* the deliverable there, so it stays literal and carries its own warnings.
2. **Every file:line in this revision was re-checked** against the tree at `1bfd336`. Where a reviewer found drift, the corrected reference is used.
3. **Where a thing cannot be done, it says so** instead of shipping a substitute that looks like it.

**Weight this plan accordingly.** Its first two revisions read as careful and were wrong in roughly twenty places between them, several of which would have cost hours of debugging pointed at the wrong artifact.

---

## Preconditions

- [ ] **Docker + Supabase CLI.** `which supabase` and `docker info`. **Neither is available on the machine this plan was written on.** The documented fallback (`2026-06-29-group-rides-sp1-backend-identity.md:21`) is MCP `execute_sql` against a dev branch — but see Task 1 Step 5, which cannot run under that fallback as a simple substitution. Record any substitution in the commit message. Do not silently skip Task 1; that is how `794d748` got here unverified.
- [ ] **Mapbox token**, or Task 2 fails on SPM rather than on code (`docs/COLLABORATOR-SETUP.md:82-93`).

## Read this before Task 1

`794d748` is on this branch: D1.1, D1.2, D1.4, D1.5, `GroupRideOpenRideTests`, 880 green package tests. Its commit message ends `NOT YET VERIFIED`, accurately — the app target has never compiled with it and 0021 has never been applied or tested.

**What it left unfinished**, against D1.3's seam list: `GroupRide.kind` (item 3) and `rideKind` (second half of item 4). `GroupRideSession.create(route: Route?)` was done.

## File structure

| File | Responsibility | Status |
| --- | --- | --- |
| `supabase/migrations/0022_open_ride_invariant.sql` | the kind/route CHECK | **create** |
| `supabase/tests/0021_open_rides_test.sql` | pgTAP for 0021 + 0022 | **create** |
| `AuraCore/Sources/AuraCore/GroupRide/GroupRide.swift` | `Kind` | **modify** |
| `AuraCore/Sources/AuraCore/GroupRide/RouteEnvelope.swift` | the null-fold rule, testable | **create** |
| `Aura/Sources/Sync/SupabaseGroupRideBackend.swift` | row → domain | modify |
| `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` | `rideKind` | modify |
| `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` | **3 rebuild sites incl. the origin** | **modify** |
| `AuraCore/Tests/.../GroupRideRetryAfterPromotionTests.swift`, `GroupRideSessionLifecycleSyncTests.swift` | 2 more rebuild sites | **modify** |
| `AuraCore/Sources/AuraCore/GroupRide/GroupRideSubtitle.swift` | D5.4 copy | **create** |
| `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift` | `create(Route?, Place?)` | **modify** |
| `Aura/Sources/Plan/RoutePreviewView.swift` | stop dropping the place | **modify** |
| `Aura/Sources/GroupRide/GroupLobbyView.swift` | D5.4 line + 2 previews | **modify** |
| `Aura/Sources/GroupRide/GroupRideFlowView.swift` | D4.1 fork, units + place plumbing | **modify** |
| `Aura/Sources/Ride/RideHUDView.swift` | `init(groupSession:)`, sink, crew exits | **modify** |
| `Aura/Sources/Home/HomeLaunchBand.swift`, `GroupRideJoinView.swift`, `AuraApp.swift` | entry points | **modify** |

```bash
cd AuraCore && swift test --no-parallel
```

App builds are **delegated to `apple-platform-build-tools:builder`** — ~13 min, and the output would swamp a session. Run one after **every** task that touches `Aura/Sources`; the package suite cannot see app-target breakage, which is the entire reason `794d748` needed Task 2.

---

### Task 1: pgTAP for 0021, plus the invariant it is missing

**Files:** create `supabase/migrations/0022_open_ride_invariant.sql`, `supabase/tests/0021_open_rides_test.sql`.

**Why 0022 and not an edit to 0021:** 0021 is unmerged but may already have been applied somewhere (the Task 1 fallback runs against a dev branch). It is not idempotent — `add column kind` has no `if not exists` — so an amended 0021 either gets skipped, leaving the constraint silently absent, or re-runs and aborts. A new migration has neither failure.

**The invariant.** `kind` is derived in `create_ride`'s body (`0021:33-35`) and enforced nowhere, so a service-role write or backfill can produce `kind='route'` with a null route — which lands a rider on the D4.1 error screen — or `kind='open'` with a route.

**It must also cover the jsonb `'null'` scalar.** `routeData()` folds *both* SQL NULL and jsonb `'null'` to nil (`SupabaseGroupRideBackend.swift:179-182`), while `route is null` is false for the scalar. A row holding `'null'::jsonb` would pass a naive CHECK as `kind='route'`, then decode client-side as a route ride with no route — the exact dead end this plan exists to close, through a row the constraint declares legal:

```sql
alter table public.rides
  add constraint rides_kind_matches_route
  check ((kind = 'open') = (route is null or route = 'null'::jsonb));
```

- [ ] **Step 1: Write 0022** with the constraint above.

- [ ] **Step 2: Write the pgTAP.** Follow `0003_join_ride_test.sql` and `0014_join_cap_lock_test.sql`: seed `auth.users` as superuser first, then drive the whole multi-identity flow through **one** `pg_temp` SECURITY DEFINER helper using `set_config('request.jwt.claims', …, true)`, and **materialise its result into a temp table once** (`0003:43`, `0014:37`) rather than calling it per assertion. Never `set local role authenticated` — `rides_select` is members-only (`0002_membership_rls.sql:63-64`), so a guest reading `join_code` out of `rides` gets NULL and every later assertion tests the ride-not-found guard instead of what it names. Revision 1 made exactly that mistake.

  Assert, from the materialised row:

  1. `create_ride()` with `p_route` **omitted** yields `kind = 'open'`. Omission, not a null argument — a jsonb `'null'` scalar satisfies `is not null`.
  2. That ride's `route` is SQL NULL.
  3. `create_ride('{"distanceMeters": 8000}'::jsonb)` yields `kind = 'route'`. **Identify it by the returned row's id, not by `created_at`** — `now()` is `transaction_timestamp()` and is identical for both rides inside the test transaction.
  4. `join_ride(code, false)` on the open ride raises.
  5. `join_ride(code, true)` on the open ride succeeds.
  6. 0022's constraint bites: `update rides set route = null` on a route ride raises `23514`. **Use the four-argument `throws_ok(sql, '23514', NULL, description)`.** In the three-argument form pgTAP treats a five-byte second argument as a SQLSTATE and the third as the expected **error message**, not a description — so a three-arg call asserts the message text and fails. There is **no `throws_ok` anywhere in `supabase/tests/`**, so there is no in-repo pattern to copy; check the form against pgTAP's docs before running.
  7. The same constraint rejects `update rides set route = 'null'::jsonb` on an open ride.

  **Do not assert anything about `anon` and `join_ride`.** Revision 2 did, reasoning that Postgres's default PUBLIC grant makes the positive assertion vacuous so the negative one discriminates. That is backwards, and `0020_revoke_maintenance_rpc_from_api_roles.sql:5-14` records why — verified on the live project: `ALTER DEFAULT PRIVILEGES` materialises **explicit per-role grants at function-create time**, so after 0021's drop-and-recreate `anon` still holds EXECUTE and `revoke … from public` does not remove it. The negative assertion fails with the migration correct. The posture is fine regardless: `join_ride` derives `auth.uid()` and raises at `0021:67`, so an anon call fails closed.

  **Do not claim to test the backfill.** `supabase db reset` applies every migration before any test row exists, so a row inserted by this test gets `kind` from the column DEFAULT, not from `alter table … add column … default 'route'` backfilling pre-existing rows. That path is structurally untestable here. Revision 2 asserted it anyway with a comment saying it proved the backfill.

  Set `plan(n)` to the assertion count you actually write.

- [ ] **Step 3: Run.** `supabase db reset && supabase test db`, or the fallback. Expected: all pass. A failure is a **real defect in `794d748` or 0022** — *unless* it is one of the four known test-shaped hazards: RLS visibility, `created_at` ties, `throws_ok` arity, or a grant assumption. Diagnose which before touching a migration. Revision 2 pre-committed the implementer to "it's a migration defect" and would have sent them hunting two bugs that do not exist.

- [ ] **Step 4: Prove the join gate discriminates.** Comment out `if v_ride.kind = 'open' and not p_supports_open …` (`0021:74`), re-run, confirm assertion 4 fails, restore, re-run.

- [ ] **Step 5: If running under the MCP fallback, adapt Step 4 explicitly.** There is no "re-run the migration file" against a live branch: 0021 does `drop function` + `create` + `revoke`/`grant`, so mutating it means hand-issuing that sequence twice. Confirm `pgtap` is installed on the branch first, and decide how you will read TAP output from `plan()`/`finish()` through `execute_sql`. If any of that is not workable, **say so in the commit message rather than marking the task done**.

- [ ] **Step 6: Commit.**

```bash
git add supabase/migrations/0022_open_ride_invariant.sql supabase/tests/0021_open_rides_test.sql
git commit -m "test(roh-114): pgTAP the open-ride migration, and constrain kind to match route"
```

---

### Task 2: Prove the app target compiles

- [ ] Dispatch `apple-platform-build-tools:builder`: *"Build the Aura app target for an iOS simulator. Report success, or the first compiler error with file and line. Do not attempt fixes."* Expected: success. Fix real errors and re-dispatch; a missing Mapbox token is an environment failure (Preconditions).

---

### Task 3: Make the null-fold rule testable, and be honest about what still is not

**Files:** create `AuraCore/Sources/AuraCore/GroupRide/RouteEnvelope.swift`; modify `SupabaseGroupRideBackend.swift:179-182`; test in `AuraCore/Tests/AuraCoreTests/GroupRide/`.

**What this does and does not achieve.** The spec's Verification block calls for `"route": null` decoded through the real `GroupRideRow`, asserting nil — "the test R1 lacked". `GroupRideRow` is `private` (`SupabaseGroupRideBackend.swift:141`) and the app target's only test bundle is `AuraUITests` (`Aura/project.yml:123`), so that test **cannot be written today**, and revision 2's plan to define a mirror `AnyJSONLike` enum in AuraCore and assert against a hand-constructed `.null` was the same evasion the spec rejects — it exercises no `Decodable` at all.

So: move the *rule* somewhere testable, test it properly, and **record the decoder-wiring gap as still open** rather than pretending a hand-built value covers it.

- [ ] **Step 1:** Extract the folding rule into `RouteEnvelope` in AuraCore, taking the minimal enum it needs, and have `routeData()` delegate. Note the boundary is **not two lines**: `AnyJSON` has seven cases — `null, bool, integer, double, string, object, array` — with `object`/`array` recursive, so a faithful map is ~11 lines. Do not collapse `.integer` and `.double` into one case without checking what it does to a real payload.
- [ ] **Step 2:** Tests must cover: absent → nil; the null case → nil; **and a round-trip** — encode a real `Route`, map it through the boundary, decode it back, assert equal. That round-trip is the only assertion that can catch a lossy reduction, and revision 2's three tests all asserted nil-folding, with the third asserting merely `!= nil`.
- [ ] **Step 3:** Run the package suite, then **re-dispatch the builder** — this touches the app target.
- [ ] **Step 4:** File a follow-up issue for the app target having no unit-test bundle, blocking the spec's named decoder test. Reference it from the commit. Commit as `refactor(roh-114): make the null-route fold testable where the bug was`.

---

### Task 4: `kind` reaches the client, and the fake stops lying about it

**Files:** `GroupRide.swift`, `SupabaseGroupRideBackend.swift`, `GroupRideSession.swift`, `InMemoryGroupRideBackend.swift`; extend `GroupRideOpenRideTests.swift`.

**Five construction sites, not two.** Revision 2 named `InMemoryGroupRideBackend.swift:92` and `:109` as "both sites". The set is:

| Site | What it is |
| --- | --- |
| `InMemoryGroupRideBackend.swift:55` | **`createRide` — the origin.** Revision 2 missed it entirely. |
| `InMemoryGroupRideBackend.swift:92` | `startRide` rebuild |
| `InMemoryGroupRideBackend.swift:109` | `endRide` rebuild |
| `GroupRideRetryAfterPromotionTests.swift:70` | fixture rebuild |
| `GroupRideSessionLifecycleSyncTests.swift:48` | `LifecycleFixtures.promoteHost` — reused by Plans 2 and 3 |

The origin site is the one that matters most: with `kind` as a trailing defaulted parameter, `createRide` stamps `.route` on **every** fake ride including one created with `route: nil`, and faithfully propagating `ride.kind` at the rebuild sites then propagates the wrong value. Both of this task's tests would fail, and the failure would look like a bug in `rideKind`.

- [ ] **Step 1:** In the fake's `createRide`, derive `kind` from whether `route` is nil — mirroring `create_ride`'s SQL derivation (`0021:33-35`). Pass `kind: ride.kind` explicitly at all four rebuild sites. Consider giving `GroupRide` a copy helper so positional rebuilds stop being possible; `LifecycleFixtures.promoteHost`'s doc comment already flags the pattern as awkward.
- [ ] **Step 2: Decode side.** `GroupRideRow.kind` must be **optional** with a fallback. A required key means a build meeting a project without 0021 fails to decode every ride, and `joinRide`'s blanket `catch` (`:56`) reports "double-check the code with your host" for route rides too. **Fall back toward `.open` when the route is also absent** — given 0022's constraint, `kind` absent with `route` nil unambiguously means open, and defaulting to `.route` there resolves ambiguity toward the branch that renders an error screen.

  Do not over-claim this as rollout safety in both directions: against a pre-0021 project, `joinRide` sends `p_supports_open` and PostgREST cannot resolve the function at all. **Task 10's apply-0021-first ordering is what actually protects the rollout.**
- [ ] **Step 3:** `GroupRide.Kind` beside `Status`; `rideKind` on the session, assigned in both `create` and `join` from the **stored** value — D1.3 forbids re-deriving from route nilness on the read side.
- [ ] **Step 4: Tests.** Extend `GroupRideOpenRideTests`. Its real helpers are `route() -> Route` (`:24`), `host(name:) async throws -> (GroupRideSession, InMemoryGroupRideBackend)` (`:30`), and `guest(sharing:name:) async throws -> (GroupRideSession, InMemoryGroupRideBackend)` (`:38`) — all `async throws`, both session helpers returning **tuples**. There is no way to build a host on a pre-existing store: `host()` constructs its own backend at `:31`. A test that needs a host and guest sharing one store must add a helper; write it against the file, not from memory.

  Assert: a created open ride reports `.open`; **a guest joining after the host has started still reports `.open`** — that is the defaulted-parameter trap, and it is the test that catches the origin site. Note the ordering constraint: `Store.currentUserID` is a single field (`InMemoryGroupRideBackend.swift:29`), so `guest(sharing:)`'s sign-in overwrites the host's identity — the host must finish acting before the guest is built.
- [ ] **Step 5:** Package suite green, builder green, commit as `feat(roh-114): carry the ride kind from the column to the client`.

---

### Task 5: Stop throwing away the destination name

**Files:** `AppRoute.swift` — `==` at `:52-63` and `hash(into:)` at `:65-76`, both need editing; `RoutePreviewView.swift:250`; `GroupRideFlowView.swift:149-156`.

D5.4 promises "Heading to Blue Bottle". `RoutePreviewView` holds `destination: Place` (`:19`), renders `.name` (`:80`), and already pairs route-with-place for the solo path (`:241`) — only `.create(selected)` (`:250`) drops it.

- [ ] Widen the entry to carry an optional route **and** an optional place. `Optional`'s conformances give `==` and `hash` for free from `route?.id` and the place; no invented discriminator (spec D1.3).
- [ ] Test in `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift` — the real home for `GroupRideEntry` equality. Assert two open-create entries are equal and hash alike, and that an open create differs from a route create.
- [ ] Package suite, builder, commit.

---

### Task 6: The lobby names the ride kind (D5.4)

**Files:** create `GroupRideSubtitle.swift`; modify `GroupLobbyView.swift` header at **`:83-93`**, and its two previews at `:343` and `:389`; `GroupRideFlowView.swift` for plumbing.

Without this, Task 4 is dead code — the failure this plan exists to stop repeating.

- [ ] **Step 1: Settle the plumbing before writing anything.** The subtitle needs kind, place name and distance. `rideKind` and `route` are on the session; the **place is not** — Task 5 puts it on the `GroupRideEntry`, which `GroupRideFlowView` holds. Units come from `SettingsStore`, injected **only** at the app root (`AuraApp.swift:13,40`), so adding `@Environment(SettingsStore.self)` to `GroupLobbyView` makes both lobby previews trap at runtime. Pass both down from `GroupRideFlowView` as plain values, and update the two preview call sites in the same commit.
- [ ] **Step 2:** Put the string logic in AuraCore as a pure function over kind, place name and distance, and test it there. **Do not reuse `PeerDistance`** — it takes a `RidePeer` and returns "0.4 mi ahead", not a bare distance. Use `UnitConverter`; note the repo has two mile divisors (`PeerDistance.swift:15` uses 1609.34, `UnitConverter.swift:3` uses 1609.344) and `UnitConverter` is the right one.
- [ ] **Step 3:** Cover: open → names the kind, no destination; route with a place → names the place and distance; route without a place (the guest case — a joiner has no `Place`) → leads with the distance rather than apologising for the missing name. Render as a third line in the header `VStack`, matching the existing subtitle styling.
- [ ] **Step 4:** Package suite, builder, commit.

---

### Task 7: The riding container forks onto Explore, and the HUD can host a crew (D4.1 + D4.5)

**Files:** `GroupRideFlowView.swift:117-133`, the stale comment at `GroupNavigateContainer.swift:16-18`, `RideHUDView.swift:53`.

**Revision 2 split this across two tasks and neither compiled.** `RideHUDView` declares an explicit `init()` at `:53`, which suppresses the memberwise initialiser — so `RideHUDView(groupSession:)` has nothing to call, and adding a stored property does not create one. `NavigateHUDView.swift:81` shows the shape: an explicit `init` taking `groupSession: GroupRideSession? = nil`. Revision 2 inherited D4.5's "@State identity is positional, so this is safe" from the spec and dropped the initialiser that made it true on navigate. The two halves must land in **one** commit: a commit that forks onto the HUD without the sink records a ride that publishes nothing, permanently, because `start` early-returns on `guard !recorder.isRecording` (`RideSessionCoordinator.swift:149`) — and a green build cannot see it.

- [ ] **Step 1:** Give `RideHUDView` an explicit `init(groupSession: GroupRideSession? = nil)`. The solo call site (`AuraApp.swift:108`) stays argument-free.
- [ ] **Step 2:** Pass `groupSink: groupSession?.locationSink` in the existing `coordinator.start(...)` call inside `RideHUDView`'s `.task` (`:216-219`) — beside `discoverySink:`, exactly as `NavigateHUDView.swift:237` does. **Never in `init`**: the `State(initialValue:)` coordinator would capture the first init's value and the sink could never attach.
- [ ] **Step 3:** Fork `ridingContainer` on `session.rideKind == .open` → the Explore HUD; else `route != nil` → `GroupNavigateContainer`; else the existing dismiss message, which is now genuinely for a route ride whose route did not arrive. Both live branches carry the `.task` that sets `didEnterRiding` then awaits `beginLiveSession()`. This is the third production call site of that function; the entry latch is what makes it safe (spec D4.1) — do not move it.
- [ ] **Step 4:** Rewrite the "unreachable in practice" comment at `:125-127` and the one at `GroupNavigateContainer.swift:16-18`. ROH-105's documented lesson was a stale doc comment on exactly this kind of type.
- [ ] **Step 5:** Builder green. There is no unit test for a `@ViewBuilder` fork; the evidence is Task 10. Commit as `feat(roh-114): an open ride rides the Explore cockpit and publishes its position`.

---

### Task 8: An open ride must be leaveable (the D5.1 subset Plan 1 cannot defer)

**Files:** `RideHUDView.swift:136-139, 294, 342-352, 245`; precedent at `NavigateHUDView+GroupCrew.swift:125-148`.

**Both re-gate reviewers found this and it is the reason Plan 1 is not done at Task 7.** `RideHUDView` has no crew lifecycle. Every exit — the End alert (`:137`), `backTapped` below the discard floor (`:342-352`), and the edge swipe (`:245`) — reaches `coordinator.finish()` or `discard()` and destroys the session **without ever calling `endRide` or `leaveRide`**. The result is silent on every phone: the ride stays `active` server-side with a live join code and no `ended_at` for up to 36 hours; guests watch the host age to `.dropped` and never learn it ended; `authoritativePhase` never returns `.ended`; host promotion never fires because `leave_ride` was never called, so no guest can end it either.

Full D5.1 — every exit through a crew confirmation regardless of the discard floor — stays in Plan 3. This task takes only what stops the wedge.

- [ ] **Step 1:** When a group session is present, route the host's End through the session's host-end path and a member's End through the member-end path, each finishing the local ride only once the server side has landed. `NavigateHUDView+GroupCrew.swift:125-148` already implements exactly this — `endGroupRideAsHost`, `endRideAsMember`, `leaveCrewKeepRiding` — and is the pattern to follow rather than reinvent.
- [ ] **Step 2:** Disable the edge swipe whenever a group session is present. A SwiftUI alert cannot intercept the UIKit `interactivePopGestureRecognizer` (spec D5.1), so on the group path it pops the flow view and releases the session mid-ride with no leave.
- [ ] **Step 3:** Make the below-floor `backTapped` branch take the same crew exit before discarding. It currently reaches neither confirmation.
- [ ] **Step 4:** Builder green, then commit as `feat(roh-114): an open-ride rider can actually leave the ride`. **Record explicitly in the commit** that this is a subset of D5.1 and the full exit-confirmation rules remain in Plan 3.

---

### Task 9: The entry points (D2, D2.1, D2.2)

**Files:** `HomeLaunchBand.swift:5,33`; `GroupRideJoinView.swift:5,55-57,70,163`; previews at `:169,177,185`.

- [ ] **Step 1:** Rename Home's chip to "Crew". Keep `.accessibilityIdentifier("home.join")` — `Screens.swift:7` keys off it. Update the file's stale doc comment at `:5`. `grep "Join a ride"` also hits `JoinRideUITests.swift:13,14` and `HomeUITests.swift:7`, which are comments and an assertion *message* — **do not** edit them into this commit.
- [ ] **Step 2: Do not rename the toolbar "Cancel" button.** Revision 2 proposed "Close" on the grounds that Cancel reads wrong on a screen that now creates. It does — but `Screens.swift:62` uses `app.buttons["Cancel"]` as the **locator** for the join sheet, in three assertions in `JoinRideUITests.swift:24,27,28`. Renaming breaks them, and silently: `.github/workflows/ci.yml:116` runs only `RideE2EUITests`. If the copy is worth changing, change the locator in the same commit — but it is not worth it in this plan.
- [ ] **Step 3: Fix the keyboard trap.** Delete `.task { isFocused = true }` so a host arriving to *start* does not meet a keyboard. **Leave the background `.onTapGesture` alone**: the real `TextField` is `.opacity(0.02)` with no height behind boxes that are `.allowsHitTesting(false)` (`:85-108`), so inverting it to dismiss would shrink the entry target to a ~22 pt strip and make a near-miss actively unfocus. Tapping anywhere then focuses, which is the pre-existing behaviour and is fine.

  **Record as deferred:** D2.1's third fix — the keyboard still cannot be dismissed once raised, because the background gesture re-focuses and there is no scroll view for `scrollDismissesKeyboard`. Revision 2 declined it without recording it. It belongs with Plan 3's copy pass or its own issue.
- [ ] **Step 4:** Header → "Crew" / "Start a ride together, or enter a code to join one".
- [ ] **Step 5:** Add the start action **inline**, calling `router.replaceTopWithGroupRide` with an open create. The view already holds `@Environment(AppRouter.self)` (`:12`) and calls that method at `:163`. *(Revision 2 justified inlining by claiming a closure would break four call sites; that was false — `init(seed: String = "")` at `:22` shows defaulted injection works here and two previews already pass arguments. The conclusion stands, the argument did not.)*

  **Not `startGroupRide`** — it pushes, leaving the code screen underneath, so Back from the lobby lands on a code form; signed out it stashes without popping and resumes onto a stale screen (`AppRouter.swift:61-93`).
- [ ] **Step 6:** Builder, then simulator: arriving raises no keyboard; tapping the code area raises it; the start action reaches a lobby; Back from the lobby goes Home. Commit.

---

### Task 10: Two phones, through the whole loop

- [ ] **Apply 0021 and 0022 to the project the phones talk to**, *before* installing the build. `supabase db push` or MCP `apply_migration`. With `kind` on the decode path, a build meeting a project without them fails joins. Migrations land first and cannot be reverted once a build ships.
- [ ] Host: Home → Crew → Start a ride → lobby, code visible, the open-ride line.
- [ ] Guest: Home → Crew → code → lobby, **not** the route error.
- [ ] **Host taps Start riding.** Both phones reach the Explore cockpit and record.
- [ ] **A guest joining after the start** goes straight to `.riding` — confirm the cockpit, not the error screen.
- [ ] Positions publish: check `ride_track_points` rows for both riders. D4.5's failure is silent on the publishing phone.
- [ ] **Both riders can end.** Host ends → the ride is `ended` server-side and the guest learns it. Guest ends → their membership is gone. **This is the check revision 2 lacked**, and the wedge behind it is invisible from a single phone.
- [ ] Background/foreground the guest phone a dozen times mid-ride. `authoritativePhase` permits `.riding → .lobby` when `startedAt` is nil, which under Task 7 would unmount the HUD and run `coordinator.cancel()` — no save, no summary. Spec D4.2 argues the input is unreachable; Explore foregrounds far more often than navigate, so this is the surface to test the argument on.
- [ ] A route ride still works end to end.
- [ ] Signed out, tapping Start a ride: the sign-in sheet appears with no explanation. **Known pre-existing gap** on the join path — record what it looks like; not fixed here.
- [ ] iPhone SE, largest type size, saved place present: the chip row does not truncate, **and** the lobby's new third line does not push Start riding off a screen that has no ScrollView (`GroupLobbyView.swift:42-70`).
- [ ] Commit the notes: `git commit --allow-empty -m "chore(roh-114): record the plan-1 two-phone pass"`

---

## Carried back to the spec, not fixed here

- **D1.5's rate-limit reasoning is false.** It argues each rejected retry burns a `join_attempts` row toward the 10/minute cap. `join_ride` has no exception block, so the insert rolls back with the statement whenever a later `raise` fires — failed joins never count, and a wrong-code spammer is never limited. Pre-existing since 0003.
- **D2 claims the SE chip width was "verified on device"** while the spec's Verification block still lists that check as pending. Task 10 treats it as unverified.
- **The spec's named decoder test cannot be written** — `GroupRideRow` is private in a target with no unit-test bundle. Task 3 gets the rule under test; the decoder wiring stays uncovered, with a follow-up issue.
- **D4.5's open question is answerable:** `PointOutbox` caps at 1000 and drops oldest, and `stopStreaming()` nils `groupSink`, so the `teardownLive` reference the spec flags is bounded. The spec can close it.
- **An old client is told to double-check a correct code**, with nothing anywhere saying "update the app".
- **"Open ride" above a 40 pt JOIN CODE** reads as *open to anyone* when it means "no route".

## What the two gates caught

Gate 1 (three reviewers, revision 1): a complete tested path to "Couldn't load this ride's route."; no constraint tying `kind` to route nullability; pgTAP that could not run under RLS; a defaulted `kind:` that would make the fake misreport the seam; no step applying the migration before the device test; the spec's decoder test omitted; a destination name that was one identifier away. Plus five false factual claims — `Route.fixture()`, an `AppRouter(isSignedIn:)` initialiser, `AppRouter` as package-testable, a non-existent test directory, and a wrong grep expectation.

Gate 2 (two reviewers, revision 2): an open ride with no exit that leaves the crew; `RideHUDView`'s explicit `init()` making Tasks 7 and 8 uncompilable; a grant assertion that contradicts migration 0020's live-verified finding and would have failed with the code correct; the fake's **origin** construction site missed, which alone would have failed both of Task 4's tests; `throws_ok` arity; a UI-test locator broken by a copy change; `RouteEnvelope` performing the evasion it claimed to reject; a backfill assertion that cannot test the backfill; a control verified but never built; and — in the list of revision 1's false claims — one false claim.

## Deferred

**Plan 2 — the crew layer** (D3, D4.2–D4.6). Note that **D3.1 already appears to be implemented** in `5b6aafe` on `claude/group-ride-explore-mode-dab041` (unpushed), including a new `CrewReference` type. Plan 2 should open by verifying that commit, the way this plan opens on `794d748`. Two further prerequisites: `RiderColorLatch` does not exist despite D3.3 and the Verification block referencing it as though it does; and D4.3 promotes ROH-115.

**Plan 3 — behaviour and copy** (the rest of D5, D6, D7), including full D5.1 and D2.1's keyboard-dismissal fix.

**Out of scope** (D9): mid-ride join, crew compass (ROH-168), group-aware Live Activity (ROH-15), the remaining lifecycle defects (ROH-174).
