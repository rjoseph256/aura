# Group Rides — SP1: Backend + Identity Foundation (Design)

**Date:** 2026-06-29
**Status:** Approved (brainstorming complete, ready for implementation plan)
**Wave:** 4, feature "Group Rides", sub-project 1 of 3

---

## 1. Feature context (the whole of Group Rides)

Group Rides lets a small crew ride together as a led ride. The product picture,
settled during the product interview:

- **Core scenario:** a led club-style ride. The host picks one route and shares
  it; everyone navigates that exact route with full turn-by-turn guidance (reusing
  the existing `GuidanceSession`), and sees the others as live positions on the map.
- **Identity:** real accounts via Sign in with Apple (stable identity, ride
  history). Joining a specific ride is by short code / link, not a friends graph.
  The friends graph is explicitly deferred.
- **Group size:** designed for a small crew of 2-8 riders. Larger club/event sizes
  are out of scope for v1.
- **What each rider sees about the others:** a named dot per rider (position +
  display name), each rider's progress along the shared route ("Alex 0.4 mi
  ahead"), and a stopped/dropped status when someone halts or loses contact.
  Live *speed* is deliberately not shared.
- **Reliability bar:** sharing works with the phone pocketed / screen off (reuses
  the existing background-location setup), and survives cellular dead zones. The
  server holds a full backfill of each rider's track, so reconnects and late
  joiners see the complete picture.
- **Privacy & retention:** access is members-only. Server-side tracks auto-expire
  after the ride (within ~48h). Each rider's own permanent ride history stays
  local on their device exactly as it does today.

### Backend decision

The realtime + backend stack is **Supabase** (chosen over a dedicated realtime
vendor such as Ably/PubNub, and over rolling our own server). Rationale:

- It collapses four needs into one stack with one auth token and one SDK: Auth
  (Sign in with Apple), Postgres + Row-Level Security (accounts, rides,
  membership, persisted tracks), Realtime *Broadcast* (live position fan-out),
  and Realtime *Presence* (connect/stopped status).
- RLS gives the members-only privacy model at the database layer, almost for free.
- Backfill is a plain Postgres read.
- At 2-8 riders the load sits comfortably in the free tier.
- The user already has a Supabase organization (one healthy project,
  `pgh-transit`, Postgres 17). Aura gets its own project in that org. No new vendor.
- Supabase Realtime is not the absolute lowest-latency option on the market, but
  at a 1-3s map-update cadence that difference is irrelevant.

### Decomposition

Group Rides is multi-subsystem and is built as three sub-projects, each its own
spec → plan → build → PR, matching how Waves 1-3 shipped:

- **SP1 — Backend + identity foundation (this spec):** Supabase project, schema,
  RLS, Postgres functions, auto-expiry, Sign in with Apple. No UI. Provable with
  tests.
- **SP2 — Live presence transport:** the `RideSession` layer in AuraKit. Publish
  my position/progress via Broadcast, subscribe to others via Presence, handle
  background + reconnect + backfill.
- **SP3 — Group-ride UI:** create / join-by-code flow, the live map with named
  dots + roster (progress, stopped/dropped), wired onto the existing route and
  `GuidanceSession`.

---

## 2. SP1 scope and goal

**Goal:** stand up the data and auth bedrock for Group Rides — a Supabase project
with a schema, database-enforced members-only access, the Postgres operations the
app calls, auto-expiry, and Sign in with Apple — plus the pure Swift models and a
backend protocol seam the rest of the app will depend on. No UI. SP1 is done when
the privacy rules and the pure logic are covered by automated tests and the live
adapter passes one integration check.

**Out of scope for SP1:** the live Broadcast/Presence transport (SP2), all UI
(SP3), the friends graph, club/event sizes, persistent group-ride history.

---

## 3. Architecture & layering

The hard constraint: **AuraCore and AuraKit must keep building and testing on the
macOS CI host**, and AuraCore stays pure (no I/O).

- **New `AuraSync` module**, beside AuraKit in the package, owns the
  `supabase-swift` dependency and all network/auth code. Nothing else in the
  package imports Supabase. This quarantines the dependency to one module.
- **AuraCore gains pure models only:** `GroupRide`, `RideMember`,
  `RemoteTrackPoint`, `JoinCode` as plain `Codable`/`Sendable` value types with no
  Supabase knowledge. The sync layer maps these to/from the wire.
- **Protocol seam `GroupRideBackend`** (in AuraCore or AuraKit) defining the SP1
  operations: `signIn`, `createRide`, `joinRide(code:)`, `endRide`, and the track
  read/write entry points. `AuraSync` provides the live Supabase implementation;
  tests use an in-memory fake. Same seam pattern as `WorkoutWriting` and
  `HapticPlaying`.
- **CI:** `supabase-swift` is pure cross-platform Swift and builds on macOS, so
  package CI stays green. It is a new dependency the CI build compiles — verify
  early; if it ever drags, keep `AuraSync` out of the default `swift test` target
  the way ActivityKit is kept out.

Payoff: SP1's logic (code generation, validation, model mapping, expiry rules)
lives in pure, fast-tested AuraCore; only the thin Supabase adapter lives in
`AuraSync`; the app depends on the protocol, not the vendor.

---

## 4. Database schema

Four tables in Postgres. Live position rides over Broadcast in SP2; SP1 owns
identity, the ride record, membership, and the persisted track store that makes
backfill possible.

### `profiles` — one row per account, mirrors `auth.users`
- `id uuid PRIMARY KEY` (= `auth.uid()`)
- `display_name text`
- `created_at timestamptz`

The name shown on the live dots.

### `rides` — one row per group ride
- `id uuid PRIMARY KEY`
- `host_id uuid REFERENCES profiles(id)`
- `join_code text` — 6-char, unique among *active* rides
- `route jsonb` — the host's chosen route: geometry + turn-by-turn steps, so
  members navigate the exact same course and a late joiner fetches it in one read
- `status text` — `active` / `ended`
- `created_at timestamptz`
- `ended_at timestamptz` (nullable)
- `expires_at timestamptz`

### `ride_members` — membership, `PRIMARY KEY (ride_id, user_id)`
- `ride_id uuid REFERENCES rides(id) ON DELETE CASCADE`
- `user_id uuid REFERENCES profiles(id)`
- `role text` — `host` / `member`
- `joined_at timestamptz`
- `last_seen_at timestamptz` — updated as positions flow; backs the
  stopped/dropped judgment

### `ride_track_points` — the backfill store, append-only, high-volume
- `id bigint GENERATED ... PRIMARY KEY`
- `ride_id uuid REFERENCES rides(id) ON DELETE CASCADE`
- `user_id uuid REFERENCES profiles(id)`
- `recorded_at timestamptz`
- `lat double precision`
- `lon double precision`
- `progress_meters double precision` — distance along the shared route; powers
  "Alex 0.4 mi ahead" without re-deriving it client-side

Written in **batches** by the publishing rider, not one round-trip per GPS fix.

### Two decisions baked in
1. **Join code is generated by a Postgres function** (`create_ride`), not the
   client — uniqueness guaranteed atomically, never an empty-string race. Format:
   6 chars, uppercase, ambiguous glyphs removed (no `O 0 I 1 L`).
2. **The host's full route lives on the `rides` row** as `jsonb`.

---

## 5. Auth and Row-Level Security

This is the members-only guarantee, enforced at the database so a leaked or
malformed client cannot read a ride it does not belong to.

### Sign in with Apple → Supabase Auth
iOS runs the native `ASAuthorization` flow, gets Apple's identity token, hands it
to Supabase `signInWithIdToken` (native Apple provider, no web redirect). That
creates the `auth.users` row; a Postgres trigger creates the matching `profiles`
row with a default display name the rider can later edit. The app holds the JWT;
every request carries it, and `auth.uid()` is what every policy keys off.

### RLS policies
- **`ride_track_points`** — *insert:* only rows where `user_id = auth.uid()` AND
  the user is a member of that ride (write only your own track, only into rides
  you joined). *Select:* only members of the ride.
- **`rides`** — *select:* members only. *Insert:* through `create_ride` (you
  become host). *Update:* host only, effectively only to end it.
- **`ride_members`** — *select:* visible to fellow members of the same ride.
  *Insert:* self-only, through `join_ride(code)` which validates the code and that
  the ride is still active.
- **`profiles`** — *select:* yourself, plus anyone you currently share an active
  ride with. *Update:* yourself only.

### RLS recursion gotcha
A `ride_members` policy that references `ride_members` to check membership causes
infinite RLS recursion (a known Supabase footgun). Membership checks route through
a `SECURITY DEFINER` helper function `is_ride_member(ride_id, uid)` that bypasses
RLS internally. Every "are you a member?" test goes through it.

### Postgres functions (the write API)
- `create_ride(route jsonb) -> rides` — generates a unique active join code,
  inserts the ride with the caller as host, inserts the host's `ride_members` row.
- `join_ride(code text) -> rides` — validates the code maps to an active ride,
  inserts the caller's `ride_members` row, returns the ride (including `route`).
- `end_ride(ride_id uuid)` — host-only; sets `status = ended`, `ended_at = now()`,
  recomputes `expires_at`.
- `is_ride_member(ride_id uuid, uid uuid) -> boolean` — `SECURITY DEFINER` helper.

Raw client inserts into these tables are not the API; the functions are.

---

## 6. Ride lifecycle and auto-expiry

### Happy path
host `create_ride` → `status = active` → members `join_ride(code)` → host
`end_ride` → `ended_at = now()`, `expires_at = ended_at + 48h`.

### Auto-expiry
A single **`pg_cron`** job runs periodically and deletes every ride past its
`expires_at`. Because `ride_members` and `ride_track_points` cascade on delete from
`rides`, that one delete erases the whole ride's data in one shot. No orphan rows.

### The ride that never ends (host force-quits, phone dies, loses signal)
Two backstops:
1. **Hard creation cap:** `expires_at` is set at creation as a ceiling, then
   shortened when the ride ends. Rule: `expires_at = COALESCE(ended_at + 48h,
   created_at + 36h)`, recomputed in `end_ride`. Even a never-ended ride is
   guaranteed to expire and be reaped.
2. **Staleness sweep:** the same cron marks an `active` ride as `ended` if its
   newest `ride_track_points` row (or `last_seen_at`) is older than a few hours —
   nobody has reported a position, the ride is effectively over. That flips it onto
   the normal expiry track.

Result: no ride's data outlives it by more than ~48h, regardless of how it ended,
with zero client cooperation required.

---

## 7. Testing strategy

SP1 has no UI, so "provable with tests" is the whole point. Three tiers:

### Tier 1 — Pure logic → AuraCoreTests, runs in CI (fast, no network)
Everything that can be pure is pure and tested on the macOS host:
- join-code generation and validation (charset, length, ambiguous-glyph exclusion)
- wire ↔ domain model mapping
- the `expires_at` rule (`COALESCE(ended_at + 48h, created_at + 36h)`)
- any route-progress math that lands here

This is the bulk of the testable surface and costs nothing to run.

### Tier 2 — RLS + Postgres functions → pgTAP against real Postgres
The privacy boundary lives in SQL, so it is tested in SQL. Versioned migrations
under `supabase/migrations/*.sql`, and **pgTAP** tests asserting the policies hold.
The critical negative cases:
- User B cannot `SELECT` user A's `ride_track_points` for a ride B never joined.
- `join_ride` with a bad or expired code fails.
- `is_ride_member` does not recurse.
- the expiry sweep deletes past-`expires_at` rides and cascades to members + points.

Run against a local Supabase stack or a Supabase preview branch (via the MCP).
These prove members-only is real, not aspirational.

### Tier 3 — Live `AuraSync` adapter → one integration pass
The thin Supabase-SDK adapter gets a manual/separate integration check (sign in,
create, join, publish a point, read it back) against a throwaway Supabase project.
Network-dependent, so it stays out of the macOS unit CI — same as ActivityKit and
the signed device build.

Net: the logic and the privacy rules are both covered by automated tests; only the
vendor-SDK glue needs a human-run integration pass.

---

## 8. Deliverables checklist (SP1)

- [ ] New Supabase project in the existing org, dev configuration
- [ ] Versioned SQL migrations: 4 tables, RLS policies, `create_ride`,
      `join_ride`, `end_ride`, `is_ride_member`, the `profiles` trigger, the
      `pg_cron` expiry + staleness job
- [ ] Sign in with Apple configured in Supabase Auth (native Apple provider)
- [ ] `AuraSync` module owning `supabase-swift`; nothing else imports it
- [ ] AuraCore pure models: `GroupRide`, `RideMember`, `RemoteTrackPoint`,
      `JoinCode`
- [ ] `GroupRideBackend` protocol seam + in-memory fake
- [ ] Live `SupabaseGroupRideBackend` in `AuraSync`
- [ ] Tier-1 AuraCore tests (code gen/validation, mapping, expiry rule)
- [ ] Tier-2 pgTAP tests (the four RLS/lifecycle assertions above)
- [ ] Tier-3 integration pass documented
- [ ] CI stays green (package build + tests + SwiftLint)
