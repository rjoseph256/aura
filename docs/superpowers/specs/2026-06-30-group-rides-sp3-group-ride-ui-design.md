# Group Rides SP3 — Group-Ride UI: Design

**Status:** Revised after 3-reviewer adversarial pass — for user review
**Date:** 2026-06-30
**Wave:** 4 (Group Rides), sub-project 3 of 3 (final)
**Depends on:** SP1 (backend + identity, PR #17) and SP2 (live presence transport, PR #18), both shipped to `main`.

## 1. Goal

Build the group-ride user interface: the surfaces that let a host create a ride and share a join code, let riders join, and let a 2–8 person crew see each other live on the map with a roster showing each rider's progress and status. This is the sub-project that makes the shipped SP1 backend and SP2 transport visible and usable. It is the app's signature surface and is held to a flagship design bar, not a utility bar.

## 2. Scope

**In (scope option C — MVP + social presence):**

1. **Create** a group ride from a planned route (host).
2. **Join** by shared link or manual 8-character code (joiner).
3. **Pre-ride lobby** (rolling-join model) where the host shares the code and watches the roster fill.
4. **Live map** with named peer dots layered over the existing Mapbox ride map.
5. **Roster** as a draggable bottom sheet: per-rider avatar, name, live route position, distance ahead/behind, and status.
6. **End** (host) and **Leave** (member) lifecycle, plus presence-health handling (dropped / reconnecting).
7. **Arrival / left / host-ended toasts** (the "social presence" layer).
8. **Editable display name**, gated so no one ever appears blank to the crew.

**Explicitly deferred (noted, not built):**

- **QR-code join** (scan). SP3 ships share-link + manual code only. QR scanning needs a camera permission and a capture-session scanner view — a self-contained follow-on once the core join flow is device-verified. See §12.
- **Group-aware Live Activity / Dynamic Island.** The app has a solo-ride Live Activity; extending it to the crew is its own later sub-project.
- **Peer-focus** (tap a rider to frame the map on them) and **richer social** beyond join/leave/end toasts.
- **Host "leave & pass the host"** (host-transfer while the crew rides on). The shipped `leave_ride` already transfers host gracefully, but SP3's host UI offers **End ride only** (see D12); surfacing a graceful host hand-off is a future action.
- **Distinct full/ended/bad-code join errors.** The shipped `join_ride` deliberately returns a single generic error to avoid a ride-existence oracle; SP3 honors that with one join-failure message (see D13).

## 3. Settled product decisions (do not re-litigate)

These were decided in the SP3 brainstorming interview (D1–D11) and the adversarial review (D12–D13), and are the frame for the whole spec.

| # | Decision | Choice |
|---|----------|--------|
| D1 | Route model for joiners | **Full turn-by-turn on the host's shared route.** One code = one navigable shared route; joiners get the same `GuidanceSession` experience a solo rider gets, with peer dots layered on. |
| D2 | Entry points | **Reuse the existing flow.** *Create* is an action on `RoutePreviewView`. *Join* is an entry on the Plan tab root (`PlanView`). No new tab. |
| D3 | Lobby / start model | **Rolling join.** The ride is live from creation. Joiners are never blocked; they receive the route and can navigate immediately. The host's "Start riding" only dismisses their own lobby. No new backend ride-state. |
| D4 | Roster placement | **Draggable bottom sheet** over the map. Collapsed = glanceable summary; expanded = full crew list. |
| D5 | Peer state encoding | A **system**, not scattered badges: colour (white = you, lime = riding, amber = stopped, grey = dropped) + heading cone + live pulse + position on the shared route. |
| D6 | Status colour token | Introduce **one** new semantic token, warning **amber `#F5C24B`**, for the stopped/paused state, added to pure `AuraPalette` so the WCAG guard covers it (§4.3). Everything else stays mono-lime + pink. |
| D7 | Join methods | **Share link (deep link) + manual 8-char code.** QR deferred (§12). |
| D8 | Display name | **Apple name as default, editable in Settings, required (non-empty) before creating/joining a crew.** Prompt once if missing. Gate enforced in the session layer, not a view (§4.4). Fallback label of last resort: **"Rider"** (no trailing period; matches the `profiles.display_name` default). |
| D9 | Host ends ride | Members get a toast and **keep navigating the route solo**; the group layer dissolves. Nobody is pulled to a summary mid-ride. |
| D10 | Leave semantics | Leaving the crew keeps your own solo ride running. Leaving ≠ ending your ride. |
| D11 | Toast policy | Only **membership** changes toast (joined / left / host-ended). Motion-state changes (stopped / dropped) live in the roster only. |
| D12 | **Host lifecycle action (new)** | The host UI offers **End ride only** (ends for everyone, D9). SP3 does **not** surface a host "leave without ending." Rationale: the shipped `leave_ride` transfers host to the next-joined member and keeps the ride alive — a real capability, but surfacing it needs a "you're now the host" hand-off flow (isHost flip, marker/controls change, notice) that is its own scoped feature. Keeping host→End-only removes that whole state class from SP3 while leaving the backend capability intact for a future "pass the host" action. |
| D13 | **Join error granularity (new)** | A **single generic join-failure message.** `join_ride` returns one deliberately generic error for wrong-code / full / ended / rate-limited (an intentional oracle-hiding measure, SP1). SP3 shows one friendly message ("Couldn't join — double-check the code with your host") rather than inventing distinctions the RPC refuses to provide. Distinct full/ended messaging is deferred (§2). |

## 4. Architecture

SP3 is almost entirely app-target SwiftUI plus a thin `@Observable` owner in AuraKit and a few small pure helpers in AuraCore. The SP2 layering invariant holds: **supabase-swift stays in the app target only**; pure logic in AuraCore; the live session owner in AuraKit consuming the SP2 seams. The `@Observable`-owner-with-an-in-object-ticker pattern is already shipped and macOS-CI-safe (`RideSessionCoordinator` does exactly this in AuraKit), so the owner is correctly located.

```
Aura (app target)                         AuraKit                         AuraCore
─────────────────                         ───────                         ────────
GroupRideCreateAction ─┐                  GroupRideSession  ──────────►    LivePresenceState (SP2)
GroupRideJoinView      │                  (@MainActor @Observable         RidePeer / PeerStatus (SP2)
GroupLobbyView         ├─ observe ──────► owner: wraps RideSession +       PeerBearing   (new, pure)
GroupRideMapOverlay    │                  GroupRideBackend + a NAMED       PeerDistance  (new, pure)
GroupRosterSheet       │                  clock/tick seam; publishes       DisplayName   (new, pure)
GroupToastHost         ┘                  peers/isLive/phase/isHost/        GroupRosterViewData (new, pure)
DisplayNameStore                          toasts/lobby/nameMap)            JoinCode / GroupRide / RideMember (SP1)
   │                                                                       Route (existing, already Codable)
   └─ SupabaseGroupRideBackend / SupabaseRideSessionTransport (SP2/SP1, live) + DeepLink (extend)
```

**`GroupRideSession` (AuraKit, `@MainActor @Observable`)** is the single seam the whole UI observes. It owns:
- a `RideSession` (SP2, push-driven, unchanged),
- a `GroupRideBackend` (SP1),
- a **named clock/tick seam** (§4.1),
- a **`nameMap: [UUID: String]`** built from the roster RPC (§4.2),
- and it **snapshots** `session.peers` / `session.isLive` into its own `@Observable`-tracked stored properties after every tick/ingest — because `RideSession` is `@MainActor` but deliberately **not** `@Observable`, so without this copy nothing repaints.

It publishes: `peers`, `isLive`, `phase` (`.lobby`/`.riding`/`.ended`/`.routeUnavailable`), `isHost`, `lobbyMembers`, `nameMap`, `toasts`. Methods: `create(route:)`, `join(code:)`, `startRiding()`, `end()`, `leave()`, `refreshRoster()`.

### 4.1 The clock / tick seam (deterministic time)

`RideSession` must stay push-driven (no `Date()`/`Task.sleep`) — SP2's invariant. `GroupRideSession` owns the wall-clock, but through a **named seam** so tests stay deterministic:

- A single injectable entry point `tick(now:)` on `GroupRideSession` is the *only* place `now` enters; it calls `session.publishIfDue(now:lifecycle:)` and `session.stalenessTick(now:)`, then snapshots peers/isLive.
- Production wiring drives `tick(now:)` from a real repeating timer created in the **app target** (or via an injected `@Sendable () -> Date` clock + an async tick source), constructed at `GroupRideSession` init. Mirrors the existing `RideSessionCoordinator` ticker pattern.
- Tests never start the real timer; they call `tick(now:)` directly with controlled timestamps. No `Date()` or `Task.sleep` in the tested path — the same discipline SP2 used for `RideSession`.

The plan must name this seam explicitly (a `RideClock`/tick abstraction), not bury a raw `Task { Date(); sleep }` loop inside the owner.

### 4.2 Names for post-join peers — the `ride_roster` RPC (the one new DB seam)

Under rolling join (D3), riders arrive *after* `RideSession.start(roster:)`, so they appear as broadcast peers with **no name** (`LivePositionPayload` carries no name; `LivePresenceState` mints `displayName: ""` for unknown peers). Nothing on the live wire will ever name them, and no existing RPC returns the member list with display names. Left unaddressed, everyone who joins after you shows as blank — violating D8/§13.

**Resolution — one small RPC + a name overlay (no wire change, names stay off the hot path):**

- New migration: **`ride_roster(p_ride_id uuid)`** — `security definer`, `search_path = ''`, `revoke execute from public`, `grant execute to authenticated`, **members-only** (guard on `is_ride_member`, matching SP1). Returns `(user_id uuid, display_name text, role text)` for the ride's members by joining `ride_members` → `profiles`. (Migration 0008 already grants members RLS SELECT on co-riders' profiles; this RPC packages that read behind the same members-only gate and is pgTAP-testable.)
- `GroupRideSession` fetches the roster on join, on entering the lobby, and whenever it observes a peer `userID` not in `nameMap` (a fresh joiner) — throttled — building `nameMap: [UUID: String]`.
- Names are applied at the **view-data layer**: `GroupRosterViewData` and the map overlay read `nameMap[peer.userID]`, so SP2's `LivePresenceState` internals are untouched. A not-yet-named peer renders as "Rider" until the next roster refresh names them.
- The roster RPC also returns the current `role`/host, so **`isHost` and the host marker re-derive from it** — the same read that names peers keeps host identity fresh.

### 4.3 Route delivery — already solved, no migration (finding I1)

D1 needs joiners to receive the host's route. This is **already true on the wire**: the `route jsonb` column lives on `public.rides` (0001), `create_ride` and `join_ride` both `return public.rides` (0002/0003), and `rides` RLS (`rides_select = is_ride_member(id)`) plus the `security definer` join gate make the route members-only. So:

- **No new migration, no `ride_route` RPC, no `RouteEnvelope` type.** `Route` is already `Codable` with no un-serializable Mapbox/live-directions handle.
- The only change: `SupabaseGroupRideBackend`'s row decoder currently **drops** the `route` key; add a `route` field to the decoded row and thread it through what `create`/`join` return. Confirm PostgREST serializes `route` as a JSON object (not a quoted string) before `JSONDecoder().decode(Route.self)`.
- **Size bound:** `rides.route` has `check (pg_column_size(route) < 262144)`. A very long geometry/elevation array could exceed 256 KB and fail *create*; SP3 adds a host-side create-failure state (§7) rather than silently losing the ride.
- **Atomicity dividend:** because the route returns *in the same response* as create/join, there is no separate "fetch route" step to fail mid-way. The only residual failure is a `Route` **decode** error (corrupt/version-skew payload) after a successful join → `phase = .routeUnavailable`: show "Couldn't load this ride's route," and **auto-leave** (`leaveRide`) to release the slot (§7).

### 4.4 Self-identity + the display-name gate

- **`selfUserID`:** the app target genuinely lacks the current user's UUID today. The host's is `createdRide.hostID` (host == self on create). The joiner's is returned from `join`: `join(code:)` yields `JoinedRide { ride, route: Data, selfUserID }`. (The `ride_roster` read can also identify self, but returning it from `join` matches the existing "RPCs run under `auth.uid()`" pattern and avoids an extra async hop.) No new PII on the wire — it's client-side auth state.
- **Display-name gate (D8):** enforced structurally inside `GroupRideSession.create(...)` / `join(...)` — they throw a `needsDisplayName` result if `DisplayName` is empty — **not** as a SwiftUI-screen precondition. This makes the gate unbypassable via the join **deep link**, which jumps straight to the destination and would skip a view-level check. `DisplayName` (pure) trims, enforces non-empty, caps length to **match the server's `left(p_name, 40)`** truncation (grapheme-cluster aware so a 40-char cut can't split an emoji/combining sequence into a broken tail), and yields "Rider" only as a last resort.

## 5. Components (units, each with one responsibility)

**AuraCore (pure, fully unit-tested):**

- **`PeerBearing`** — pure: derive a peer's heading from consecutive coordinates (the wire has no bearing). Degenerate cases pinned by tests: single fix → no cone; stationary/`stopped` → hold last heading (or none); `dropped`/`awaiting` → no cone. Feeds the map overlay's heading cone (D5).
- **`PeerDistance`** — pure: signed along-route gap from `progressMeters` subtraction (both self and peer carry it in SP2), formatted "ahead"/"behind"/"even" honoring the unit setting. Optional-progress cases pinned: `awaiting` (no position) → no distance label; `dropped` → "no signal," not a stale distance.
- **`DisplayName`** — pure validate/normalize (trim, non-empty, ≤40 grapheme-aware, "Rider" fallback). Backs the gate.
- **`GroupRosterViewData`** — pure transform from `[RidePeer]` + `nameMap` + `selfUserID` + unit setting into ordered rows (leader-first by route progress, "you" pinned), each carrying name, status→colour role, and `PeerDistance` output. Keeps SwiftUI dumb and this logic tested.

**AuraKit (the observable owner + its seam):**

- **`GroupRideSession`** — as §4. Owns `RideSession` + `GroupRideBackend` + clock/tick seam + `nameMap`; snapshots peers/isLive into `@Observable` props; derives toasts from membership diffs (never from motion state, D11); derives `isHost` from the roster read.
- **`GroupToastEvent`** — value type: `.joined(name)`, `.left(name)`, `.hostEnded`. From membership diffs only.
- **`GroupRideBackend` (extend)** — add `route` to what `create`/`join` return, `selfUserID` to `join`'s result, and a `roster(rideID:)` call fronting the `ride_roster` RPC. `InMemoryGroupRideBackend` gains matching behavior (stored route round-trips; roster returns fake members with names; `selfUserID`) so the whole UI runs against the fake in tests + previews.

**Aura (app target — SwiftUI, one screen/element each):**

- **`GroupRideCreateAction`** — "Ride together" on `RoutePreviewView`; encodes the `Route` (its existing `Codable`), calls `create`, routes into the lobby.
- **`GroupRideJoinView`** — join screen: segmented 8-char input (validates via `JoinCode`), paste, single inline error (D13). Reachable from `PlanView` and from the join deep link.
- **`GroupLobbyView`** — host rolling-join lobby: code, Share-link button, live roster, "Start riding," empty state.
- **`GroupRideMapOverlay`** — the Mapbox `ViewAnnotation` peer-dot subsystem (§6). Extends `RideMapView`.
- **`GroupRosterSheet`** — bottom sheet (collapsed + expanded detents) rendering `GroupRosterViewData`.
- **`GroupToastHost`** — top-anchored auto-dismiss toasts from `session.toasts`.
- **`DisplayNameStore` + `DisplayNameEditor`** — persists via `upsert_display_name`; edited in Settings; the one-time "What should the crew call you?" prompt (gate lives in the session, this is the UI to satisfy it).
- **`GroupNavigateContainer`** — wraps the existing `NavigateHUDView` with the overlay + roster sheet + toast host, so a group ride is literally "the solo navigate HUD + a crew layer" (D1).
- **`DeepLink` (extend, AuraCore) + `AppRouter.handle` (arm):** add `.join(code:)` to the **`DeepLink`** enum (not `AppRoute` — deep links parse to `DeepLink`), extend `DeepLink.parse` to read `?code=` (mirroring `preview(from:)`), and add an `AppRouter.handle` arm that routes to the join flow through `GroupRideSession.join` (so the display-name gate + `isRideActive` guard both apply).

## 6. Layout & interaction (the design language)

Approved visual direction (validated via the visual companion):

- **The map stays the hero.** The shared route is one lime ribbon with a lit "ahead" section and a dimmed "behind" section (a Mapbox **line-gradient**, or two polylines split at self's `progressMeters` — a distinct styling task, not free), so the crew's spread reads at a glance. Name tags shown sparingly (leader + a couple), never on every dot.
- **Peer dot = disc + heading cone + optional live pulse.** Disc colour is the status role (D5); cone from `PeerBearing`; a soft pulse marks active movement; "you" is a white puck.
- **Mapbox mechanics (finding M3):** today `RideMapView`/`NavigateHUDView` use only the declarative `Map { Puck2D; PolylineAnnotationGroup }` DSL. Custom pulsing discs + tags are **`ViewAnnotation`s** (UIView-backed, main-thread), *not* `PointAnnotation` symbol layers. So `GroupRideMapOverlay` is a **new annotation subsystem**: up to 8 `ViewAnnotation`s updated at the SP2 cadence (not per frame), positions interpolated, a single lightweight pulse animation. This is a real component with its own update budget — must be device-verified.
- **The sheet does real work.** Collapsed: avatar stack + one-line summary ("3 riding · 1 stopped") + a mini spread bar. Expanded: per rider — avatar, name, live route-position bar, **distance ahead/behind you**, status. Host carries a quiet "HOST" marker; no crowns everywhere.
- **Type:** Saira Condensed for numerals, SF Pro Rounded for names/labels — the shipped cockpit pairing.
- **Motion (product register, 150–250 ms, conveys state):** dots interpolate rather than teleport; standard sheet detent physics; toasts slide+fade; the pulse is the one ambient loop and respects Reduce Motion (drops to a static ring).
- **Contrast:** all over-map surfaces use `AuraTheme.mapScrim` / secondary-text resolvers. Amber is added to **pure `AuraPalette`** with a `WCAGContrast` test against `panel` and `nearBlack` (§4.3 / D6), so CI guards it like every other token.

## 7. Key states

| Surface | State | What the user sees |
|---------|-------|--------------------|
| Create | route too large (>256 KB) | Host-side failure: "This route is too detailed to share as a group ride." Ride not created. |
| Join | default | Empty segmented input, paste affordance, disabled "Join." |
| Join | typing | Cells fill; "Join" enables only when `JoinCode` validates 8 chars. |
| Join | join failed (any reason) | One inline message (D13): "Couldn't join — double-check the code with your host." No modal. |
| Join | network error | Inline: "Couldn't reach the ride — try again." |
| Join | joined but route won't decode | `phase = .routeUnavailable`: "Couldn't load this ride's route." Auto-leaves to free the slot; offer retry. |
| Lobby | empty (host, 0 joined) | Code + Share, with "Share your code to get your crew rolling." |
| Lobby | filling | Roster rows animate in; "Start riding" always available (rolling join). |
| Roster (expanded) | solo, no crew yet | "Waiting for your crew…" with the code/share affordance — not a bare empty list (flagship bar). |
| Map/roster | riding, healthy | Dots + roster live; collapsed summary reflects counts; names filled from `nameMap`. |
| Map/roster | peer not yet named | Renders as "Rider" until the next `ride_roster` refresh names them. |
| Map/roster | a peer silent (`dropped`) | Dot desaturates to grey; row reads "no signal · last seen ‹Xm› ago"; **stays** in roster; row is informative, not a focus target (peer-focus deferred). |
| Map/roster | self offline (`isLive == false`) | Quiet "Reconnecting…" pill near the sheet; peers age to grey; snapshot re-seeds silently on reconnect. |
| Lifecycle | host ended | Toast "‹Host› ended the group ride"; group layer dissolves; **solo navigation continues** (D9). |
| Lifecycle | you left | Confirm → group layer gone, **your solo ride continues** (D10). |
| Display name | missing at entry | One-time prompt "What should the crew call you?"; `GroupRideSession.create/join` refuse until non-empty (D8, gate in session). |
| Toasts | membership change | Joined / left / host-ended only (D11); top, auto-dismiss. |

## 8. Data flow

1. **Create:** host plans a route → "Ride together" → `GroupRideSession.create(route:)` (`JSONEncoder().encode(route)`) → `createRide` returns the `rides` row incl. **route + hostID(=selfUserID)** → `phase = .lobby`, `isHost = true`. Route >256 KB → create-failure state.
2. **Share:** lobby renders the code + a Share-link deep link `aura://join?code=…` (new `DeepLink.join` case).
3. **Join:** joiner enters code (or opens link → `DeepLink.join` → `AppRouter.handle` → `GroupRideSession.join`, gated on display name + `isRideActive`) → `joinRide` returns `JoinedRide { ride, route, selfUserID }` → decode `Route` (fail → `.routeUnavailable` + auto-leave) → fetch `ride_roster` for names → enter `GroupNavigateContainer` navigating that route.
4. **Live:** host + joiners run the SP2 stack — `RideSessionCoordinator` feeds `GroupLocationSink`; `GroupRideSession.tick(now:)` drives `publishIfDue`/`stalenessTick` and snapshots peers; unknown `userID`s trigger a throttled `ride_roster` refresh (names + host); membership diffs emit toasts.
5. **End:** host `end()` → `endRide` → `member_left`/ended signal (SP2 0015) → members toast + dissolve group layer, solo navigation persists. **Member leave:** `leave()` → `leaveRide` → crew sees "left" toast + dot removed. (Host uses End only, D12.)

## 9. Testing strategy

- **AuraCore (pure, deterministic):** `PeerBearing` (heading + all degenerate cases); `PeerDistance` (sign, units, `awaiting`/`dropped` label cases, zero); `DisplayName` (trim/empty/40-grapheme/fallback); `GroupRosterViewData` (ordering, self-pin, status→colour, name overlay incl. missing-name→"Rider").
- **AuraKit (`GroupRideSession`, in-memory backend + SP2 `InMemoryRideSessionTransport`, injected clock via `tick(now:)`):** create→lobby→start; join decodes route; route-decode-failure → `.routeUnavailable` + auto-leave; `nameMap` fills post-join peers and clears "Rider"; membership diff emits exactly the right toasts (and *no* toast on motion change); `isLive` reconnect re-seeds; host-end dissolves; member-leave; `isHost` derives from roster read; display-name gate refuses empty on both create and join. All deterministic (no `Date()`/`Task.sleep`).
- **App target (SwiftUI):** in-memory-backed previews for every §7 state; a light check on join validation + the display-name gate + the deep-link → gate path. Simulator smoke: create → share → join (second identity) → both see named dots → leave/end.
- **DB (pgTAP, existing `db-tests` CI job):** `ride_roster` — members-only (member gets the list with names; non-member rejected). **No route-vend migration** (route already round-trips — §4.3).

## 10. Global constraints (carry into the plan)

- **supabase-swift stays in the app target only.** AuraCore pure; AuraKit seams; live conformers in `Aura/Sources/Sync`. The **real production timer lives in the app target**; AuraKit's `GroupRideSession` takes an injected clock/tick.
- **`RideSession` stays push-driven** — no `Date()`/`Task.sleep` inside it or in the tested path of `GroupRideSession`; `tick(now:)` is the sole time entry.
- **No raw speed on the wire or screen.** SP2's invariant holds; the UI shows motion state + along-route distance, never a peer's speed.
- **The only new DB function is `ride_roster`** — `security definer`, `search_path = ''`, `revoke ... from public`, `grant ... to authenticated`, members-only. No route-vend migration.
- **Display name gated in the session layer** (deep-link-proof); ≤40 grapheme-aware to match server truncation; never render blank → "Rider."
- **Amber `#F5C24B`** is the only new colour token; it goes in **pure `AuraPalette`** with a `WCAGContrast` test. Pink stays destructive-only; status is the D5 system, not new hues.
- **Deep-link join** uses the **`DeepLink`** enum (+ `DeepLink.parse` + `AppRouter.handle` arm), routed through `GroupRideSession.join` so the display-name gate and the Wave-1 `isRideActive` guard both apply.
- **Host UI = End only (D12); one generic join error (D13).**

## 11. Risks

- **Route round-trip fidelity (D1).** If a `Route` field the guidance stack needs fails to decode, joiners get `.routeUnavailable`. Mitigation: round-trip test against a real planned `Route`; route arrives atomically with join; explicit failure state + auto-leave.
- **256 KB route bound.** Long geometry/elevation can exceed the `rides.route` size check and fail create. Mitigation: the create-failure state; consider a geometry-simplification follow-up if it bites in practice.
- **Map overlay performance:** 8 `ViewAnnotation`s + pulse over Mapbox at the SP2 cadence. Mitigation: interpolate, throttle to cadence, one shared pulse animation; **device-verify** (a named plan step).
- **Join-code exposure / guessability.** The share link (`aura://join?code=`) persists in the recipient's message history / link caches and **outlives the ride**; a stale link fails naturally (expired/ended ride → the generic join failure, and code freed on reap). Codes are ~39 bits (8 chars / 31-glyph alphabet). The defense is SP1 T4's per-user join rate limit (10/min) + the 8-rider cap + 48 h expiry; per-user limiting is thinner against many throwaway identities, and rolling-join (D3, no host approval) means a *correctly guessed* code yields instant membership. Accepted for a small-crew feature; host-approval is a possible future hardening. (No new exposure beyond a share link the host chooses to send.)
- **Deep-link + active solo ride collision.** Opening a join link mid-solo-ride resolves via the Wave-1 `isRideActive` guard (prompt/block); named as a plan step.
- **`nameMap` staleness.** A peer can appear a beat before the roster refresh names them (shows "Rider" briefly). Acceptable; the throttle keeps it short and the refresh is idempotent.

## 12. Deferred: QR-code join (next step after SP3)

SP3 ships share-link + manual code only. QR *scanning* needs a camera permission + capture-session scanner view — a self-contained follow-on once the core join flow is device-verified. QR *generation* for the host is trivial and can land with the scanner. Recorded in memory `aura-group-rides-design-bar`. Revisit after SP3 merges.

## 13. Success criteria

- A host can plan a route, tap "Ride together," and get a shareable code/link in a lobby.
- A second device can join by link or code, receive the host's route, and navigate it turn-by-turn.
- Both see each other as **named** (via `ride_roster`), status-coloured dots on the map and roster, with correct ahead/behind distances — **nobody appears blank** (peers named within one refresh; "Rider" only as true fallback).
- Stopped/dropped read correctly; membership changes toast; motion changes do not.
- Host-end behaves per D9 (solo navigation continues); member-leave per D10; host has End only (D12); one generic join error (D13).
- Display name is editable, gated in the session (deep-link-proof), never blank.
- All CI green: AuraCore + AuraKit tests, app build, swiftlint --strict (whole repo incl. tests), pgTAP for `ride_roster`.
- The surfaces meet the flagship design bar (memory `aura-group-rides-design-bar`).

## 14. Traceability — adversarial review findings → resolution

Three independent reviewers (integration/correctness, concurrency/platform, security/edges). All findings resolved below.

| # | Finding (severity) | Resolution |
|---|--------------------|------------|
| 1 | **Nameless post-join peers; no member-name RPC** (Critical) | New `ride_roster` RPC + `nameMap` overlay at the view-data layer; names applied without touching SP2 internals (§4.2). |
| 2 | **Ticker re-imports `Date()`/`Task.sleep`; no clock seam named** (Critical) | Named `tick(now:)` clock seam; real timer in app target, tests pump time (§4.1). |
| 3 | **Heading cone has no wire data** (Critical) | New pure `PeerBearing` helper derives heading from consecutive coordinates; degenerate cases tested (§5). |
| 4 | **Host-leave vs host-end unresolved; `leave_ride` transfers host** (Critical) | D12: SP3 host UI = **End only**; graceful host-transfer deferred (backend capability retained). |
| 5 | **Joiner joins but route fetch fails — no state** (Critical) | Route now arrives atomically in the join row (§4.3); only decode-failure remains → `.routeUnavailable` + auto-leave (§7). |
| 6 | **Route-vend needs no migration; route already in the returned row** (Important) | Dropped the migration + `ride_route` RPC; decode the existing `route` field; note 256 KB bound (§4.3). |
| 7 | **`RouteEnvelope` redundant — `Route` already `Codable`** (Important) | Removed `RouteEnvelope`; use `Route`'s `Codable` directly (§4.3). |
| 8 | **Deep-link targets `DeepLink`, not `AppRoute`** (Important) | Retargeted to the `DeepLink` enum + `parse` + `AppRouter.handle` arm (§5/§10). |
| 9 | **`selfUserID` source wrong (backend is stateless/`nonisolated`)** (Important) | Host = `createdRide.hostID`; joiner = `JoinedRide.selfUserID` returned from `join` (§4.4). |
| 10 | **Amber in `AuraTheme` bypasses the WCAG guard** (Important) | Amber → pure `AuraPalette` + `WCAGContrast` test vs panel/nearBlack; surfaced via a theme role (§4.3/§6/D6). |
| 11 | **Mapbox overlay is a `ViewAnnotation` subsystem, not DSL nodes** (Important) | §6 rewritten around `ViewAnnotation` (8 max, cadence-throttled, one pulse) + a device-verify step; ahead/behind ribbon = line-gradient/split polyline. |
| 12 | **Generic join error vs 3 distinct §7 messages** (Important/Minor ×2) | D13: single generic join-failure message; distinct messaging deferred. |
| 13 | **Display-name gate bypassable via deep link if view-level** (Important) | Gate enforced in `GroupRideSession.create/join`, not a view (§4.4). |
| 14 | **`upsert_display_name` truncates at 40; client cap must match + grapheme-aware** (Important) | `DisplayName` caps at ≤40 grapheme-clusters to match server `left(p_name,40)` (§4.4/§5). |
| 15 | **`RideSession.peers`/`isLive` not observable — owner must mirror** (Minor) | `GroupRideSession` snapshots them into `@Observable` props each tick/ingest (§4). |
| 16 | **`RideSession.start(roster:)` empty for later joiners; no re-seed path** (Minor) | Names handled by `nameMap` overlay, not by re-seeding `LivePresenceState` (§4.2) — no `RideSession` change needed. |
| 17 | **`PeerDistance` optional-progress cases unspecified** (Minor) | `awaiting` → no label; `dropped` → "no signal" (§5/§9). |
| 18 | **Deep-link code exposure / rate-limit reasoning absent** (Important/Minor) | §11 Risks paragraph: link outlives ride (fails safely), SP1 T4 rate limit cited, rolling-join tradeoff acknowledged. |
| 19 | **"Rider." vs "Rider" inconsistency** (Minor) | Standardized to **"Rider"** (no period), matching `profiles` default (D8). |
| 20 | **Roster expanded empty state + dropped-row tap undefined** (Minor) | "Waiting for your crew…" state; dropped row shows "last seen"/informative, not a focus target (§7). |
```
