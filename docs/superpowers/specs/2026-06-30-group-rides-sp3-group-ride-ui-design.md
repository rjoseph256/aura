# Group Rides SP3 — Group-Ride UI: Design

**Status:** Draft for review
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

## 3. Settled product decisions (do not re-litigate)

These were decided in the SP3 brainstorming interview and are the frame for the whole spec.

| # | Decision | Choice |
|---|----------|--------|
| D1 | Route model for joiners | **Full turn-by-turn on the host's shared route.** One code = one fully-navigable shared route; joiners get the same `GuidanceSession` experience a solo rider gets, with peer dots layered on. |
| D2 | Entry points | **Reuse the existing flow.** *Create* is an action on `RoutePreviewView` (after planning a route). *Join* is an entry on the Plan tab root (`PlanView`). No new tab, no separate route-planning surface. |
| D3 | Lobby / start model | **Rolling join.** The ride is live from creation. Joiners are never blocked; they receive the route and can navigate immediately. The host's "Start riding" only dismisses their own lobby. No new backend ride-state. |
| D4 | Roster placement | **Draggable bottom sheet** over the map. Collapsed = glanceable summary; expanded = full crew list. |
| D5 | Peer state encoding | A **system**, not scattered badges: colour (white = you, lime = riding, amber = stopped, grey = dropped) + heading cone + live pulse + position on the shared route. |
| D6 | Status colour token | Introduce **one** new semantic token, warning **amber `#F5C24B`**, for the stopped/paused state. Everything else stays within the mono-lime + pink AuraTheme. |
| D7 | Join methods | **Share link (deep link) + manual 8-char code.** QR deferred (§12). |
| D8 | Display name | **Apple name as default, editable in Settings, required (non-empty) before creating/joining a crew.** Prompt once if missing. Fallback label of last resort: "Rider." |
| D9 | Host ends ride | Members get a toast and **keep navigating the route solo**; the group layer dissolves. Nobody is pulled to a summary mid-ride. |
| D10 | Leave semantics | Leaving the crew keeps your own solo ride running. Leaving ≠ ending your ride. |
| D11 | Toast policy | Only **membership** changes toast (joined / left / host-ended). Motion-state changes (stopped / dropped) live in the roster only. |

## 4. Architecture

SP3 is almost entirely app-target SwiftUI plus a thin observable owner in AuraKit and a couple of small pure helpers in AuraCore. The SP2 layering invariant holds: **supabase-swift stays in the app target only**; pure logic in AuraCore; the live session owner in AuraKit consuming the SP2 seams.

```
Aura (app target)                         AuraKit                         AuraCore
─────────────────                         ───────                         ────────
GroupRideCreateView   ─┐                  GroupRideSession  ──────────►    LivePresenceState (SP2)
GroupRideJoinView      │                  (@MainActor @Observable         RidePeer / PeerStatus (SP2)
GroupLobbyView         ├─ read/observe ─► owner over RideSession +         PeerDistance (new, pure)
GroupRideMapOverlay    │                  GroupRideBackend +               DisplayName (new, pure validate)
GroupRosterSheet       │                  the ticker; publishes           JoinCode (SP1)
GroupToastHost         ┘                  peers/isLive/toasts/lobby)       GroupRide / RideMember (SP1)
DisplayNameStore                                                          RouteEnvelope (new, pure codable)
   │
   └─ SupabaseGroupRideBackend / SupabaseRideSessionTransport (SP2, live)
```

**Why an observable owner (`GroupRideSession`) in AuraKit and not just the raw `RideSession`:** `RideSession` (SP2) is `@MainActor` but not `@Observable`, is push-driven (no timer, no `Date()`), and exposes `peers`/`isLive` as plain reads. SwiftUI needs an `@Observable` object it can watch, and *someone* has to own the wall-clock ticker that calls `publishIfDue(now:)` / `stalenessTick(now:)` and drive the `GroupRideBackend` create/join/leave/end calls. That owner is `GroupRideSession`. It keeps `RideSession` pure and testable (time still injected) while giving the views one observable surface. It is the single seam the whole UI reads.

### 4.1 The route-vend addition (backend)

D1 requires a joiner to receive the host's route. The shipped seam is asymmetric: `createRide(route: Data)` **stores** the route but `joinRide(code:)` returns only `GroupRide` (id/host/joinCode/status) — **not** the route. SP3 closes this:

- **Backend seam:** change `joinRide(code:)` to return the stored route alongside the `GroupRide`. Concretely, a small result type `JoinedRide { let ride: GroupRide; let route: Data }` (or add `route: Data` to what join returns). The `SupabaseGroupRideBackend` reads the route column the create RPC already writes; a DB migration exposes it on the join RPC's return (or a sibling `ride_route(rideID)` RPC gated by `is_ride_member`). Either way it is **members-only** (RLS / definer check), consistent with SP1.
- **Route encoding:** `createRide` already takes `route: Data`. SP3 defines a single pure `RouteEnvelope` Codable in AuraCore that both create (encode) and join (decode) use, so the host's `Route` round-trips to the joiner losslessly. This replaces any ad-hoc encoding and is the contract both sides share.

This is the one piece of real backend work in SP3; everything else is UI + the observable owner.

### 4.2 Self-identity addition

The app target does not currently hold the signed-in user's `UUID` (the backend vends it; only `GroupRide.hostID` is visible). The UI needs `selfUserID` to (a) construct `RideSession(selfUserID:)`, and (b) decide host-vs-member (`ride.hostID == selfUserID`). SP3 exposes the current user id from the backend: `GroupRideBackend.currentUserID` (or `signIn` / `createRide` / `joinRide` returns it). The `SupabaseGroupRideBackend` already knows it from the auth session; this just surfaces it. Pure, no new network.

## 5. Components (units, each with one responsibility)

Each unit is small, single-purpose, and testable in isolation.

**AuraCore (pure, fully unit-tested):**

- **`RouteEnvelope`** — Codable value that encodes/decodes a `Route` to/from the `Data` the backend stores. The shared create↔join contract. Round-trip tested.
- **`PeerDistance`** — pure function: given self progress-meters and a peer's progress-meters (both are distance-along-the-shared-route, already in SP2's payload), returns a signed along-route gap and a formatted "ahead"/"behind" label honoring the unit setting (metric/imperial). No coordinate math — SP2 already carries `progressMeters`, so ahead/behind is a subtraction, not a map query.
- **`DisplayName`** — pure validation/normalization: trims, enforces non-empty and a max length, and yields the fallback "Rider" only as a last resort. Used by the gate (D8).
- **`GroupRosterViewData`** — pure transform from `[RidePeer]` + `selfUserID` + unit setting into the ordered rows the sheet renders (self first? or leader first — see §6), each row carrying name, status, colour role, and `PeerDistance` output. Keeps SwiftUI dumb and this logic tested.

**AuraKit (the observable owner + its seam):**

- **`GroupRideSession`** — `@MainActor @Observable`. Owns a `RideSession` (SP2), a `GroupRideBackend` (SP1), and the wall-clock ticker. Publishes: `peers: [RidePeer]`, `isLive: Bool`, `lobbyMembers`, `toasts`, `phase` (`.lobby` / `.riding` / `.ended`), `isHost`. Methods: `create(route:)`, `join(code:)`, `startRiding()`, `leave()`, `end()`. Drives `publishIfDue`/`stalenessTick` from the ticker. Emits toast events by diffing membership across snapshots/`memberLeft`. **The one seam the UI observes.**
- **`GroupToastEvent`** — value type (`.joined(name)`, `.left(name)`, `.hostEnded`). Derived by `GroupRideSession` from membership diffs; never from motion state (D11).
- **`InMemoryGroupRideBackend`** (SP1, extend) — already fakes create/join/leave/end; extend for the route-vend (return the stored route) and `currentUserID` so the whole UI runs against the fake in tests + previews.

**Aura (app target — SwiftUI views, one screen/element each):**

- **`GroupRideCreateAction`** — the "Ride together" affordance on `RoutePreviewView`; calls `GroupRideSession.create(route:)` and routes into the lobby.
- **`GroupRideJoinView`** — the join screen: segmented 8-char input (validates via `JoinCode`), paste, inline errors (§7). Reachable from `PlanView` and from a join deep link.
- **`GroupLobbyView`** — host's rolling-join lobby: shareable code, Share-link button, live-filling roster, "Start riding," empty state.
- **`GroupRideMapOverlay`** — renders peer dots (disc + heading cone + live pulse + sparse name tags) over the Mapbox map from `session.peers`. Extends `RideMapView` rather than replacing it.
- **`GroupRosterSheet`** — the bottom sheet (collapsed + expanded detents) rendering `GroupRosterViewData`.
- **`GroupToastHost`** — top-anchored, auto-dismissing toast presenter fed by `session.toasts`.
- **`DisplayNameStore` + `DisplayNameEditor`** — persists the display name (via `upsert_display_name`), edited in Settings, and the one-time "What should the crew call you?" prompt gating group-ride entry (D8).
- **`GroupNavigateContainer`** — wraps the existing `NavigateHUDView` with the map overlay + roster sheet + toast host, so a group ride is literally "the solo navigate HUD + a crew layer" (D1).

## 6. Layout & interaction (the design language)

The approved visual direction (validated via the visual companion):

- **The map stays the hero.** The shared route is one lime ribbon: a lit "ahead" section, a dimmed "behind" section, so the crew's spread reads at a glance. Peer name tags are shown sparingly (leader + a couple), never on every dot, to avoid clutter.
- **Peer dot = disc + heading cone + optional live pulse.** Disc colour is the status role (D5). The cone shows travel heading. A soft pulse marks anyone actively moving. "You" is a white puck.
- **Roster bottom sheet, two detents.** Collapsed: avatar stack + one-line summary ("3 riding · 1 stopped") + a mini spread bar. Expanded: per rider — avatar, name, a live route-position bar, and **distance ahead/behind you** (the question a crew actually keeps asking), plus status. Host carries a quiet "HOST" marker; no crowns everywhere.
- **Row order (expanded):** leader-first by route progress, with "you" pinned visibly, is the default; `GroupRosterViewData` owns this so it's tested and swappable.
- **Type:** Saira Condensed for numerals (distances), SF Pro Rounded for names/labels — the exact cockpit pairing the app ships.
- **Motion (product register, 150–250 ms, conveys state not decoration):** dots interpolate to new positions rather than teleporting; the sheet uses standard detent physics; toasts slide+fade; the live pulse is the one ambient loop and respects Reduce Motion (drops to a static ring).
- **Contrast:** all over-map surfaces use the existing `AuraTheme.mapScrim` / secondary-text resolvers so the roster and tags hold up over a bright sunlit map and under Increase Contrast. Amber `#F5C24B` must clear the same body/large-text contrast bars the palette guards; verify against the panel and near-black backgrounds.

## 7. Key states

| Surface | State | What the user sees |
|---------|-------|--------------------|
| Join | default | Empty segmented input, paste affordance, disabled "Join." |
| Join | typing | Cells fill; "Join" enables only when `JoinCode` validates 8 chars. |
| Join | unknown code | Inline: "That code didn't match a ride." (no modal) |
| Join | ride full | Inline: "This ride is full (8 riders)." |
| Join | ride ended | Inline: "This ride has ended." |
| Join | network error | Inline: "Couldn't reach the ride — try again." |
| Lobby | empty (host, 0 joined) | Code + Share, with "Share your code to get your crew rolling." |
| Lobby | filling | Roster rows animate in; "Start riding" always available (rolling join). |
| Map/roster | riding, healthy | Dots + roster live; collapsed summary reflects counts. |
| Map/roster | a peer silent | That dot desaturates to grey; row reads "no signal"; **stays** in roster. |
| Map/roster | self offline (`isLive == false`) | Quiet "Reconnecting…" pill near the sheet; peers age to grey; snapshot re-seeds silently on reconnect. |
| Lifecycle | host ended | Toast "‹Host› ended the group ride"; group layer dissolves; **solo navigation continues** (D9). |
| Lifecycle | you left | Confirm → group layer gone, **your solo ride continues** (D10). |
| Display name | missing at entry | One-time prompt "What should the crew call you?" blocks create/join until non-empty (D8). |
| Toasts | membership change | Joined / left / host-ended only (D11); top, auto-dismiss. |

## 8. Data flow

1. **Create:** host plans a route → "Ride together" → `GroupRideSession.create(route:)` encodes via `RouteEnvelope`, calls `createRide`, receives `GroupRide` (code) + `selfUserID` → `phase = .lobby`, host `isHost = true`.
2. **Share:** lobby renders the code + a Share-link deep link `aura://join?code=…` (a new `AppRoute` join case, small extension of the existing deep-link routing).
3. **Join:** joiner enters code (or opens the link) → `GroupRideSession.join(code:)` calls `joinRide`, receives `GroupRide` + **route** (§4.1) + `selfUserID` → decodes `RouteEnvelope` → builds the `Route` → enters `GroupNavigateContainer` navigating that route.
4. **Live:** both host and joiners run the SP2 stack — `RideSessionCoordinator` feeds the `GroupLocationSink`; `GroupRideSession`'s ticker calls `publishIfDue`/`stalenessTick`; `session.peers` updates the overlay + sheet; membership diffs emit toasts.
5. **End/leave:** `end()` / `leave()` call the SP1 RPCs; the `member_left`/ended signals (SP2 migration 0015) drive peers' toast + dot removal; local `phase` transitions dissolve the group layer while solo navigation persists.

## 9. Testing strategy

- **AuraCore (pure, deterministic, no time waits):** `RouteEnvelope` round-trip; `PeerDistance` sign + unit formatting (metric/imperial, ahead/behind/level, zero); `DisplayName` trim/empty/max/fallback; `GroupRosterViewData` ordering + status→colour mapping + self-pinning.
- **AuraKit (`GroupRideSession`, using the in-memory backend + the SP2 `InMemoryRideSessionTransport`, injected clock):** create→lobby→start transitions; join receives+decodes route; membership diff emits exactly the right toasts (and *no* toast on motion change); `isLive` reconnect re-seeds; host-end vs member-leave phase transitions; host-vs-member from `selfUserID`. All deterministic via the push-injected time seam (no `Date()`, no `Task.sleep`) — the SP2 discipline.
- **App target (SwiftUI):** previews driven by the in-memory backend for every key state in §7; a lightweight snapshot/interaction check on the join validation + the display-name gate. Simulator smoke: create → share → join (second identity) → both see dots → leave/end.
- **No new DB logic beyond the route-vend** — that migration gets a pgTAP test in the existing `db-tests` CI job (members-only route read; non-member rejected), matching SP1/SP2.

## 10. Global constraints (carry into the plan)

- **supabase-swift stays in the app target only.** AuraCore pure; AuraKit seams; live conformers in `Aura/Sources/Sync`.
- **No raw speed on the wire or screen.** SP2's invariant holds; the UI shows motion state (moving/stopped) and along-route distance, never a peer's speed.
- **`GroupRideSession` may own a wall-clock ticker, but `RideSession` stays push-driven** — no `Date()` / `Task.sleep` inside `RideSession`; the owner injects `now`. Tests inject time.
- **Every new DB function** (route-vend): `security definer`, `search_path = ''`, `revoke ... from public`, `grant ... to authenticated`, members-only.
- **Route-vend is members-only.** A non-member who guesses a `rideID` cannot read the route.
- **Display name is gated:** no create/join with an empty display name; never render a blank peer — fall back to "Rider."
- **Amber `#F5C24B`** is the only new colour token; it must clear the palette's contrast bars (WCAG guard).
- **Mono-lime discipline:** pink stays destructive-only; status is the D5 system, not new hues.
- **Deep-link join** reuses the existing `AppRoute` deep-link mechanism; guard against joining while a solo ride is already active (mirror the `isRideActive` guard from Wave 1 navigation).

## 11. Risks

- **Route round-trip fidelity (D1).** If `RouteEnvelope` loses a field the guidance stack needs, joiners navigate a degraded route. Mitigation: round-trip test against a real planned `Route`; the envelope is the single tested contract.
- **selfUserID plumbing.** Surfacing the current user id must not leak it anywhere unsafe; it's already client-side auth state, so this is exposure within the app, not new PII on the wire.
- **Map overlay performance with 8 dots + pulses.** Keep the pulse a single lightweight animation; interpolate positions; avoid per-frame SwiftUI churn (throttle to the SP2 cadence). Verify on device.
- **Deep-link + active-ride collision.** Opening a join link mid-solo-ride needs a defined resolution (prompt / block); handled by the `isRideActive` guard.

## 12. Deferred: QR-code join (next step after SP3)

SP3 ships share-link + manual code only. QR-code *scanning* is deferred: it needs a camera-usage permission and a capture-session scanner view — a self-contained surface best done once the core join flow is device-verified. QR *generation* for the host is trivial and can land with the scanner. Recorded in memory `aura-group-rides-design-bar`. Revisit after SP3 merges.

## 13. Success criteria

- A host can plan a route, tap "Ride together," and get a shareable code/link in a lobby.
- A second device can join by link or code, receive the host's route, and navigate it turn-by-turn.
- Both see each other as named, status-coloured dots on the map and in the roster, with correct ahead/behind distances.
- Stopped/dropped states read correctly; membership changes toast; motion changes do not.
- Host-end and member-leave behave per D9/D10 (solo navigation continues).
- No one ever appears blank; display name is editable and gated.
- All CI green: AuraCore + AuraKit tests, app build, swiftlint --strict (whole repo incl. tests), pgTAP for the route-vend.
- The surfaces meet the flagship design bar (memory `aura-group-rides-design-bar`).
```
