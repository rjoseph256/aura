# Group Rides — SP1: Backend + Identity Foundation (Design)

**Date:** 2026-06-29
**Status:** Approved design, revised after 3-reviewer adversarial pass (backend/security,
iOS architecture/CI, product/scope/privacy). Ready for implementation plan.
**Wave:** 4, feature "Group Rides", sub-project 1 of 3

> **Revision note (2026-06-29):** This spec was reviewed by three independent
> adversarial reviewers before planning. Their findings — join-code
> brute-forceability, an unhardened `SECURITY DEFINER` helper, the module-boundary
> error (`AuraSync` must not be a package target), no leave/account-deletion paths,
> the Apple-token name gap, and the missing Tier-2 CI path — are folded into the
> sections below. Section 9 records the resolved findings for traceability.

---

## 1. Feature context (the whole of Group Rides)

Group Rides lets a small crew ride together as a led ride. The product picture,
settled during the product interview:

- **Core scenario:** a led club-style ride. The host picks one route and shares
  it; everyone navigates that exact route with full turn-by-turn guidance (reusing
  the existing `GuidanceSession`), and sees the others as live positions on the map.
- **Identity:** real accounts via Sign in with Apple. Joining a specific ride is by
  short code / link, not a friends graph. The friends graph is explicitly deferred.
- **Group size:** designed for a small crew of 2-8 riders. The 8-rider cap is a
  hard, server-enforced invariant (see §5).
- **What each rider sees about the others:** a named dot per rider (position +
  display name), each rider's progress along the shared route ("Alex 0.4 mi
  ahead"), and a stopped/dropped status. Live *speed* is deliberately not shared.
- **Reliability bar:** sharing works with the phone pocketed / screen off, and
  survives cellular dead zones. The server holds a full backfill of each rider's
  track, so reconnects and late joiners see the complete picture.
- **Privacy & retention:** access is members-only. **Server-side ride tracks and
  membership are deleted within ~48h of the ride ending.** Account identity
  (profile + Apple auth record) is durable by design — see §6 for the exact scope
  of the retention promise. Each rider's own permanent ride history stays local on
  their device as it does today.

### Backend decision

The realtime + backend stack is **Supabase** (chosen over a dedicated realtime
vendor such as Ably/PubNub, and over rolling our own server):

- One stack, one auth token, one SDK covers four needs: Auth (Sign in with Apple),
  Postgres + Row-Level Security (accounts, rides, membership, persisted tracks),
  Realtime *Broadcast* (live position fan-out, SP2), Realtime *Presence*
  (connect/stopped status, SP2).
- RLS gives the members-only privacy model at the database layer.
- Backfill is a plain Postgres read.
- At 2-8 riders the load sits comfortably in the free tier.
- The user already has a Supabase org (project `pgh-transit`, Postgres 17). Aura
  gets its own project in that org. No new vendor.
- Supabase Realtime is not the lowest-latency option on the market, but at a 1-3s
  map-update cadence that is irrelevant.

### Decomposition

Group Rides is multi-subsystem and is built as three sub-projects, each its own
spec → plan → build → PR, matching how Waves 1-3 shipped:

- **SP1 — Backend + identity foundation (this spec):** Supabase project, schema,
  RLS, the Postgres write-API functions, auto-expiry, account deletion, and Sign in
  with Apple — plus the pure Swift models and the `GroupRideBackend` seam. No UI.
  SP1 owns a minimal `record_track_points` function so the backfill store and the
  staleness sweep are self-contained and testable without SP2.
- **SP2 — Live presence transport:** the `RideSession` layer. Publish position /
  progress via Broadcast, subscribe to others via Presence, handle background +
  reconnect + backfill. Reuses `is_ride_member` as the Realtime authorization
  primitive.
- **SP3 — Group-ride UI:** create / join-by-code flow, the live map with named dots
  + roster (progress, stopped/dropped), wired onto the existing route and
  `GuidanceSession`.

---

## 2. SP1 scope and goal

**Goal:** stand up the data and auth bedrock for Group Rides — a Supabase project
with a schema, database-enforced members-only access, the Postgres operations the
app calls, rate-limited joins, auto-expiry, account deletion, and Sign in with
Apple — plus the pure Swift models and a backend protocol seam the rest of the app
depends on. No UI.

**SP1 is done when:** the privacy rules and pure logic are covered by automated
tests (Tiers 1-2 below, both gating CI), and the live adapter passes one
integration check (Tier 3).

**Out of scope for SP1:** the live Broadcast/Presence transport (SP2), all UI
(SP3), the friends graph, club/event sizes, persistent group-ride history.

---

## 3. Architecture & layering

Hard constraint: **AuraCore and AuraKit must keep building and `swift test`-ing on
the macOS CI host**, hermetically and network-free, under Swift 6 language mode +
SwiftLint `--strict`. AuraCore stays pure (no I/O).

The existing quarantine mechanism is **package vs. app project**: pure / near-pure
code lives in `AuraCore/Package.swift` (AuraCore + AuraKit); everything that imports
a heavy or iOS-only framework (UIKit, HealthKit, ActivityKit, Mapbox) lives in the
**`Aura` app target** declared in `Aura/project.yml`, which consumes the package.
`supabase-swift` is the network/auth analog of Mapbox and follows the same rule.

- **`AuraSync` is an app-target module, NOT a package target.** It lives as a
  `Sources/Sync` group in the Xcode app project with a `supabase-swift` package
  dependency declared in `Aura/project.yml`. It is **not** added to
  `AuraCore/Package.swift` — doing so would force `swift test` to resolve and
  compile supabase-swift + ~7 transitive deps and couple the hermetic unit gate to
  8 upstream repos. (This is the primary design, not a fallback.)
- **AuraCore gains pure value types only:** `GroupRide`, `RideMember`,
  `RemoteTrackPoint`, `JoinCode` — `Codable`/`Sendable`, no Supabase knowledge.
- **`GroupRideBackend` protocol lives in AuraKit**, beside `RideSessionSeams.swift`,
  matching the existing `WorkoutWriting` / `HapticPlaying` / `RideActivityControlling`
  seams. Its networking methods are `nonisolated async` (the app target runs under
  `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, so backend I/O must be explicitly
  `nonisolated` or it serializes onto the main actor). `AuraSync` provides the live
  Supabase conformer; an in-memory fake lives in `AuraKitTests`.
- **Sign in with Apple's `ASAuthorization` flow lives in the app target**, not in
  `AuraSync`. The app runs the native controller and the nonce dance (§5), then
  hands the resulting Apple identity token + raw nonce to
  `GroupRideBackend.signIn(idToken:nonce:)`. The seam never drives Apple UI, which
  keeps it testable with a fake and keeps `AuraSync` UI-free.
- **Swift 6 verification is the first SP1 task:** confirm the pinned supabase-swift
  version compiles clean against `SWIFT_VERSION 6.0` + default-MainActor in the app
  target *before* any schema work. supabase-swift ships at tools 5.10 with
  strict-concurrency *checking* (not full Swift 6 language mode); its public async
  API is Sendable-forward and should bridge, but the conformer's methods must be
  `nonisolated`.

Payoff: SP1's logic (code generation, validation, model mapping, expiry math) lives
in pure, fast-tested AuraCore; the protocol lives in AuraKit; only the thin Supabase
adapter lives in the app-target `AuraSync`; the package CI never sees supabase-swift.

---

## 4. Database schema

Five tables. Live position rides over Broadcast in SP2; SP1 owns identity, the ride
record, membership, the persisted backfill store, and join-attempt accounting.

### `profiles` — one row per account, mirrors `auth.users`
- `id uuid PRIMARY KEY` (= `auth.uid()`)
- `display_name text NOT NULL DEFAULT 'Rider'` — **never PII by default.** Apple's
  identity token does **not** carry the name; the trigger writes the placeholder,
  and the first-login client capture (§5) replaces it. The user can edit it later.
- `created_at timestamptz NOT NULL DEFAULT now()`

### `rides` — one row per group ride
- `id uuid PRIMARY KEY DEFAULT gen_random_uuid()`
- `host_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE`
- `join_code text NOT NULL` — **8 chars**, uppercase, ambiguous glyphs removed
  (no `O 0 I 1 L`); **unique among all non-reaped rides** (active *or* ended but not
  yet expired), so a saved link can't silently resolve to a different ride after
  code reuse. `join_ride` resolves only `active` rides.
- `route jsonb NOT NULL` — host's chosen route: geometry + turn-by-turn steps.
  `CHECK (pg_column_size(route) < 256*1024)` — bounded; it is trusted host input
  returned by `join_ride` to every joiner.
- `status text NOT NULL DEFAULT 'active'` — `active` / `ended`
- `created_at timestamptz NOT NULL DEFAULT now()`
- `ended_at timestamptz`
- `expires_at timestamptz NOT NULL` — see §6 for the rule.

### `ride_members` — membership, `PRIMARY KEY (ride_id, user_id)`
- `ride_id uuid NOT NULL REFERENCES rides(id) ON DELETE CASCADE`
- `user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE`
- `role text NOT NULL` — `host` / `member`
- `joined_at timestamptz NOT NULL DEFAULT now()`
- `last_seen_at timestamptz` — updated by `record_track_points`; backs
  stopped/dropped and the staleness sweep.

### `ride_track_points` — backfill store, append-only
- `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`
- `ride_id uuid NOT NULL REFERENCES rides(id) ON DELETE CASCADE`
- `user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE`
- `recorded_at timestamptz NOT NULL`
- `lat double precision NOT NULL`, `lon double precision NOT NULL`
- `progress_meters double precision NOT NULL` — distance along the shared route;
  powers "ahead/behind" without client re-derivation.
- `UNIQUE (ride_id, user_id, recorded_at)` — idempotency key: reconnect replays of
  a batch are no-ops, never double-counted.

### `join_attempts` — rate-limit accounting (defeats code brute force, §5/C1)
- `user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE`
- `attempted_at timestamptz NOT NULL DEFAULT now()`
- One row per `join_ride` call; the function counts recent rows per `auth.uid()`
  and rejects past the cap. Old rows reaped by the cron.

### Indexes (none were specified before; the per-row RLS scans need these)
- `ride_track_points (ride_id, user_id)`, `ride_track_points (ride_id, recorded_at)`
- `ride_members (user_id)`
- partial `rides (join_code) WHERE status = 'active'`
- `join_attempts (user_id, attempted_at)`

---

## 5. Auth, the write-API, and Row-Level Security

This is the members-only guarantee, enforced at the database.

### Sign in with Apple → Supabase Auth (app target owns the UI)
The app target runs `ASAuthorizationAppleIDProvider` and the nonce dance, then calls
`GroupRideBackend.signIn(idToken:nonce:)` → supabase `signInWithIdToken` (native
Apple provider, no web redirect). A Postgres `on auth.users insert` trigger creates
the `profiles` row with the `'Rider'` placeholder.

- **Nonce (pin the hashed-vs-raw asymmetry — the classic break):** generate one
  cryptographically random **raw** nonce per attempt; send `sha256(rawNonce)` to
  Apple's `ASAuthorizationRequest.nonce`; send the **raw** nonce to
  `signInWithIdToken(nonce:)`. Never reuse a nonce; bind it to one in-flight request.
- **Display name (Apple's token has no name):** Apple returns `fullName` only on the
  **first** authorization, client-side, never in the JWT, never again. SP1 client
  contract: on first sign-in, capture `credential.fullName`, **immediately** persist
  it via an `upsert_display_name` RPC, with a retry/repair path if that write drops.
  "Display name persisted on first sign-in" is an SP1 acceptance criterion. If the
  user hides their name, the placeholder stands until they set one in SP3.

### Write-API functions (all `SECURITY DEFINER`, `SET search_path = ''`, EXECUTE granted only to `authenticated`)
Raw client inserts are not the API; these functions are. Each re-checks
authorization in its own body, because `SECURITY DEFINER` bypasses RLS.

- `is_ride_member(ride_id uuid) returns boolean` — `language sql stable security
  definer set search_path = ''`, body keyed on **`auth.uid()`** (no caller-supplied
  uid — that would be an enumeration oracle). `REVOKE EXECUTE FROM public`, grant to
  `authenticated`. **This is the shared authz primitive reused by SP2's Realtime
  RLS** — design it for reuse now.
- `create_ride(route jsonb) returns rides` — generates a unique 8-char active code,
  inserts the ride with caller as `host_id`, inserts the host's `ride_members` row
  (`role = host`). Validates route size.
- `join_ride(code text) returns rides` — (1) **rate-limit:** insert a `join_attempts`
  row, count this user's attempts in the trailing window, reject past the cap with a
  **generic, indistinguishable failure** (wrong code / expired / rate-limited all
  return the same error, closing the oracle); (2) resolve `code` to an `active` ride
  or fail generically; (3) **enforce the 8-member cap** (count members, reject if
  full); (4) **idempotent:** if the caller is already a member, return the ride
  instead of hitting the PK violation (reconnect re-taps are safe); (5) insert the
  `ride_members` row and return the ride incl. `route`.
- `record_track_points(ride_id uuid, points jsonb) returns void` — asserts caller is
  a member via `is_ride_member`; **single-ride, single-user** batch; caps
  points-per-batch and enforces a server-side insert-rate guard; upserts on the
  `(ride_id, user_id, recorded_at)` idempotency key; updates the caller's
  `ride_members.last_seen_at`. (Defined in SP1 so the backfill store and staleness
  sweep are self-contained and testable; wired to live GPS in SP2.)
- `end_ride(ride_id uuid) returns void` — **asserts `auth.uid() = host_id` in the
  body** (the DEFINER function bypasses the host-only RLS update policy); sets
  `status = ended`, `ended_at = now()`, recomputes `expires_at` (§6).
- `leave_ride(ride_id uuid) returns void` — deletes the caller's `ride_members` row
  (**revokes their read access immediately** — closes the lingering-access hole). If
  the caller is the host: **transfer host to the earliest-joined remaining member**;
  if none remain, `end_ride`. A left member's already-written track points remain
  until ride expiry (they are part of the ride's shared record); state this in UI
  copy later.
- `delete_account() returns void` — deletes the caller's `auth.users` row; FK
  `ON DELETE CASCADE` removes their profile, hosted rides (and those rides' members
  + points), memberships, and points. Satisfies **App Store 5.1.1(v)** in-app
  account deletion (a submission blocker, hence in SP1).

### RLS policies (use `(select …)` forms so the optimizer caches per-statement)
- **`ride_track_points`** — *insert:* `user_id = (select auth.uid())` AND
  `(select is_ride_member(ride_id))`. *Select:* `(select is_ride_member(ride_id))`.
  Inserts arrive only via `record_track_points`, single-ride per batch so the cached
  initPlan form is correct.
- **`rides`** — *select:* `(select is_ride_member(id))`. *Insert/update:* only
  through the functions.
- **`ride_members`** — *select:* `(select is_ride_member(ride_id))`. *Insert/delete:*
  only through `join_ride` / `leave_ride`.
- **`profiles`** — *select:* `id = (select auth.uid())` OR a `SECURITY DEFINER`
  shared-ride helper (same recursion/perf class as `is_ride_member`; must not
  cross-reference `ride_members` directly). *Update:* `id = (select auth.uid())`.

---

## 6. Ride lifecycle and auto-expiry

### Happy path
host `create_ride` → `active` → members `join_ride(code)` → host `end_ride` →
`ended_at = now()`, `expires_at` recomputed.

### The retention rule (reconciled with the "~48h after the ride" promise)
`expires_at = LEAST(COALESCE(ended_at, created_at) + interval '48 hours',
last_activity + interval '48 hours')`, where `last_activity` is the newest
`ride_track_points.recorded_at` (or `last_seen_at`). At creation, before any
activity, `expires_at = created_at + 36h` as the hard ceiling; `end_ride` and the
cron recompute it. Net guarantee: **ride tracks + membership are deleted within ~48h
of the ride ending (or of last activity for an abandoned ride)** — matching the §1
promise. The retention promise covers ride tracks + membership only; `profiles` and
`auth.users` are durable by design and removed only by `delete_account`.

### Auto-expiry + staleness sweep — one `pg_cron` job, **every 5 minutes**
1. **Staleness:** mark an `active` ride `ended` (and recompute `expires_at`) if its
   newest `ride_track_points.recorded_at` / `last_seen_at` is older than **3 hours**
   — nobody is reporting a position, the ride is effectively over.
2. **Reap:** `DELETE FROM rides WHERE expires_at < now()`. `ride_members`,
   `ride_track_points` cascade. Also delete `join_attempts` older than the window.

Cadence (5 min) and the staleness threshold (3 h) are pinned so the behavior is
testable. `pg_cron` is a standard Supabase extension; enabling/verifying it in the
new project is an SP1 deliverable. pgTAP cannot exercise the cron *schedule*, so the
tests invoke the underlying expiry/staleness *function* directly.

---

## 7. Testing strategy

### Tier 1 — Pure logic → AuraCoreTests, gates CI (fast, no network)
join-code generation/validation (charset, 8-char length, glyph exclusion), wire↔
domain mapping, the `expires_at` math, route-progress helpers. The bulk of the
testable surface, free to run.

### Tier 2 — RLS + functions → pgTAP, **gates CI via a dedicated `ubuntu` job**
A new GitHub Actions job on `ubuntu-latest` runs `supabase start` (local stack) +
`supabase test db` (pgTAP), independent of the macOS jobs — so the privacy boundary
is an automated gate, not a developer-only check. Required pgTAP assertions:
- User B **cannot** `SELECT` user A's `ride_track_points` for a ride B never joined.
- `join_ride` with a bad/expired code fails generically; joining an **ended** ride
  fails; **double-join** is idempotent (returns the ride).
- The **8-member cap** rejects the 9th join.
- `join_ride` **rate limit** rejects past the cap with the generic failure.
- `is_ride_member` does not recurse and ignores any non-caller identity.
- `end_ride` rejects a non-host; `leave_ride` revokes read access and transfers host.
- `delete_account` succeeds and cascades (no FK violation; rows gone).
- The expiry function deletes past-`expires_at` rides and cascades; the staleness
  function ends a stale active ride. Assert the **actual retention bound**, not just
  "past-expires_at gets reaped."

### Tier 3 — Live `AuraSync` adapter → one integration pass (manual, non-CI)
Against a throwaway Supabase project: sign in (incl. a **replayed/mismatched nonce
is rejected** assertion), create, join, `record_track_points`, read back, leave,
delete account. Network-dependent, stays out of CI like ActivityKit and the signed
device build.

---

## 8. Deliverables checklist (SP1)

- [ ] Swift 6 + default-MainActor compile check of pinned `supabase-swift` in the app
      target (first task, before schema work)
- [ ] New Supabase project in the existing org; `pg_cron` enabled/verified
- [ ] Versioned SQL migrations: 5 tables + indexes; RLS policies in `(select …)`
      form; functions `is_ride_member`, `create_ride`, `join_ride` (rate limit +
      member cap + idempotent + generic failure), `record_track_points`, `end_ride`,
      `leave_ride` (host transfer), `delete_account`, `upsert_display_name`; the
      `profiles` trigger; the 5-min `pg_cron` expiry + staleness job. All write
      functions `SECURITY DEFINER`, `SET search_path = ''`, EXECUTE → `authenticated`
- [ ] Sign in with Apple configured in Supabase Auth (native provider); nonce
      raw/hashed split implemented in the app target; first-login name capture +
      repair path (acceptance criterion)
- [ ] FK `ON DELETE CASCADE` on every `profiles`-referencing FK; `delete_account`
      proven by pgTAP
- [ ] `AuraSync` app-target module owning `supabase-swift` (in `project.yml`, **not**
      `AuraCore/Package.swift`); `nonisolated async` conformer methods
- [ ] AuraCore pure models: `GroupRide`, `RideMember`, `RemoteTrackPoint`, `JoinCode`
- [ ] `GroupRideBackend` protocol in AuraKit + in-memory fake in AuraKitTests
- [ ] Live `SupabaseGroupRideBackend` in `AuraSync`
- [ ] Tier-1 AuraCore tests
- [ ] Tier-2 pgTAP suite + the `ubuntu` `db-tests` CI job
- [ ] Tier-3 integration pass documented
- [ ] Existing CI stays green (package build + tests + SwiftLint); new db-tests job green

---

## 9. Resolved review findings (traceability)

Three adversarial reviewers (backend/security, iOS architecture/CI, product/privacy)
returned **SOUND WITH FIXES**. Resolutions:

**Critical**
- Brute-forceable join codes → 8-char entropy + `join_attempts` rate limiter +
  generic indistinguishable failure + member cap (§4, §5 `join_ride`).
- Unhardened `is_ride_member` (caller-supplied uid, no `search_path`) → keyed on
  `auth.uid()`, `SET search_path = ''`, EXECUTE locked to `authenticated` (§5).
- `AuraSync` as a package target → moved to the app target; never in
  `AuraCore/Package.swift` (§3).
- No leave/remove path, lingering read access → `leave_ride` with immediate access
  revocation + host transfer (§5).
- No account deletion + FKs blocking it → `delete_account` + `ON DELETE CASCADE`;
  App Store 5.1.1(v) (§4, §5).
- `last_seen_at`/track-write API named but undefined (cross-SP leak) →
  `record_track_points` defined in SP1 (§5).

**Important**
- Apple token carries no name → trigger placeholder + first-login capture as
  acceptance criterion (§5).
- Nonce hashed/raw asymmetry → pinned (§5).
- Per-row RLS on bulk insert → `(select …)` forms, single-ride batches, indexes
  added (§4, §5).
- Track-insert abuse/dup → rate guard, batch cap, `(ride_id,user_id,recorded_at)`
  idempotency (§4, §5).
- Cron cadence/threshold undefined + retention overclaim → 5-min cron, 3-h
  staleness, `LEAST(...)` retention rule reconciled to the promise (§6).
- `GroupRideBackend` layer + ASAuthorization placement → AuraKit seam, app-target
  Apple UI, `signIn(idToken:nonce:)` (§3, §5).
- Swift 6 / default-MainActor interop with supabase-swift → first-task compile
  check, `nonisolated` conformer (§3, §8).
- Tier-2 had no CI path → dedicated `ubuntu` `db-tests` job (§7).

**Minor**
- `create_ride`/`end_ride` DEFINER vs INVOKER → DEFINER with in-body host assert (§5).
- `profiles` SELECT recursion → DEFINER shared-ride helper (§5).
- `route jsonb` unbounded → `pg_column_size` CHECK (§4).
- Code reuse after expiry → unique among non-reaped rides (§4).
- 36h/48h asymmetry → folded into the reconciled `LEAST(...)` rule (§6).
