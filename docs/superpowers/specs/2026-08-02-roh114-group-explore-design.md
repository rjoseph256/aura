# Group ride without a destination (ROH-114) — design

Date: 2026-08-02 (revision 4: 2026-08-05)
Issue: [ROH-114](https://linear.app/rohun/issue/ROH-114/group-ride-without-a-destination-group-explore-surface)
Status: revision 4, after three three-reviewer adversarial gates.

**Depends on** [ROH-167](https://linear.app/rohun/issue/ROH-167/beginlivesession-latches-before-its-first-await-one-failed-roster)
(the live layer must actually start) and
[ROH-174](https://linear.app/rohun/issue/ROH-174/group-ride-lifecycle-silent-host-promotion-stale-ishost-on-retry-async)
(group-ride lifecycle defects).
**Split out:** [ROH-168](https://linear.app/rohun/issue/ROH-168/crew-compass-a-wheel-of-colour-coded-arrows-showing-where-every-rider) (crew compass).
Related: ROH-105, ROH-72, ROH-115 (D4.3 promotes it), ROH-15 (out of scope).

## Revision history, and what it says about this spec

Three revisions, three gates. **Each of the first three contained at least one defect that would
have shipped dead**, and revisions 2 and 3 each introduced a *new* one while fixing the previous:

- **R1** — the nil route died at a wire layer the spec never read; the cockpit fork named an
  unreachable branch. Plus three false claims (the palette cap, the auth gate, `pg_column_size`).
- **R2** — fixed those, then made the mixed-version gate protect a structurally impossible action
  while leaving the real one open, and specified a compass whose radius axis was a ranking.
- **R3** — fixed those, then sourced self's coordinate from `LocationService.lastKnown`, which is
  ambient-only and is affirmatively **stopped** when the HUD is pushed. Every roster distance would
  have been computed from a frozen pre-ride Home fix.

Revision 4 is deliberately not a fourth attempt at inventing behaviour. It **deletes** one section
(D4.2, which guarded an unreachable state), **completes** two that were incomplete, **extracts**
the lifecycle defects to ROH-174, and **cuts** the most speculative remaining item. No new
mechanism is designed here.

**Weight this spec's clean bill accordingly.** Three times running, the gate caught something
ship-dead written with confident citations. The two-phone device pass is the real check.

## Problem

A crew ride requires a destination. `GroupRideEntry.create` carries a `Route`
(`AppRoute.swift:48`), its only construction site is the route preview's "Ride together" button
(`RoutePreviewView.swift:250`), and `rides.route` is `not null` (`0001_schema.sql:14`).
"Let's just go ride around for an hour" cannot be expressed.

The Explore HUD has no crew layer at all. ROH-105 deleted `RideMapView`'s peer parameters after
establishing they had never once been passed in production. That deletion was correct, and it
means this is a rebuild.

## What this delivers

A host starts a crew ride with no destination, from Home. Guests join by code as today. Everyone
rides the Explore cockpit and sees the crew as colour-coded dots with monograms on the map, plus a
roster giving each rider's name, status, and straight-line distance.

## D1 — Removing the route requirement

### D1.1 — The wire

    // SupabaseGroupRideBackend.swift:136,155
    let route: AnyJSON                                        // NOT optional
    func routeData() throws -> Data { try JSONEncoder().encode(route) }

`AnyJSON` has a `.null` case, so a SQL-null column **decodes successfully** to `.null`, and
`routeData()` returns the four bytes `null`. So `joined.route != nil`, `join` falls through to the
decode at `GroupRideSession.swift:171`, lands in `.routeUnavailable`, and calls `leaveRide` — the
guest sees an error **and is removed from the ride**. A reviewer compiled this both ways.

`GroupRideRow.route` becomes `AnyJSON?`; `routeData()` returns `Data?`, mapping absence and
`.null` to nil.

### D1.2 — The three-way distinction

| `joined.route` | Meaning | Phase |
| --- | --- | --- |
| nil | Open ride, by design | proceed |
| present, decodes | Route ride | proceed, as today |
| present, fails to decode | Corrupt payload | `.routeUnavailable`, leave the ride |

Checked as `joined.route == nil` **before** any decode. **The test must go through the real row
decoder** — a payload with `"route": null` through `GroupRideRow`, asserting `routeData()` yields
nil. R1's test ran against `InMemoryGroupRideBackend`, which returns a true Swift nil because a
fake was written to: the seam introduced for testability is the one place this bug cannot live.

### D1.3 — The seam list, including `kind`

*R3 claimed this list was complete and omitted `kind` entirely — so nothing wrote `'open'`,
nothing read it, and D1.5's gate plus D5.4's lobby line were both silently dead.*

**Swift:**
1. `GroupRideRow.route: AnyJSON?`, `routeData() -> Data?`; **`GroupRideRow.kind: String`**.
2. `GroupRideBackend.createRide(route: Data?)`; `JoinedRide.route: Data?`.
3. **`GroupRide.kind: Kind`** (`enum Kind: String { case route, open }`) — `GroupRide` today has no
   such field (`GroupRide.swift:3-18`), and `JoinedRide` wraps it, so this is how `kind` reaches
   the client at all.
4. `GroupRideSession.create(route: Route?)`; expose `rideKind` for D5.4.
5. `GroupRideEntry.create(Route?)` (`AppRoute.swift:48`) and `GroupRideFlowView.invokeEntry`
   (`:151-152`).

*R3 flagged `GroupRideEntry`'s hand-written `Equatable`/`Hashable` as a trap needing an invented
discriminator. Overstated: `Route?` gives `a?.id == b?.id` and `hasher.combine(route?.id)` free
from `Optional`'s conformances. The naive edit compiles and is correct.*

**SQL:** `rides` gains `kind text not null default 'route' check (kind in ('route','open'))`.

**`create_ride` derives `kind` in its body** — `case when p_route is null then 'open' else 'route' end`
— rather than taking a `p_kind` parameter. This is a deliberate choice: a new parameter changes the
signature and hits the same drop/re-grant hazard D1.5 carries, for no gain. Deriving keeps
`create or replace` valid and the existing grants (`0002_membership_rls.sql:59-60`) intact.

Note this is server-side derivation only. Clients still read the stored `kind` column rather than
re-deriving from a null route, so the read side has one authority.

### D1.4 — Migration

`alter table public.rides alter column route drop not null;`

The existing `check (pg_column_size(route) < 262144)` needs no edit: **a CHECK is satisfied
whenever its expression is not false**, and `pg_column_size` is strict. *R2 asserted two
contradictory byte sizes here, in the paragraph retracting R1's false size claim. Revision 4
asserts none — the CHECK rule is the whole argument.*

`create_ride(p_route jsonb)` (`0002_membership_rls.sql:40`) gains `default null`, and the client
**omits** the argument for an open ride rather than sending `AnyJSON.null` — otherwise the column
holds jsonb `'null'`, which is not SQL NULL, reads as `is not null`, and would make a pgTAP test
that inserts NULL directly pass against a column the app never writes. `routeData() -> Data?`
returning nil must map to **omission** at the PostgREST call, not to a null body; this is asserted
in `SupabaseGroupRideBackend` and tested through the RPC.

### D1.5 — Mixed-version clients: gate the join

*R2 gated `create_ride`. An old build's create path is `GroupRideSession.create(route: Route)` —
non-optional, reached only from a `GroupRideEntry.create(Route)` built with a selected destination.
Old clients structurally cannot create a route-less ride, so that gate forbade the impossible.*

The exposure is **joining**. Alice on the new build creates an open ride; Bob on last month's build
enters the code, gets SQL NULL, decodes `.null`, fails the `Route` decode, and `leaveRide` fires —
removed server-side, with each retry burning a `join_attempts` row toward the 10/minute cap.

`join_ride` gains `p_supports_open boolean default false`. If `kind = 'open'` and the caller did
not pass true, it raises the same generic `'join failed'` as every other rejection, so an old
client sees "double-check the code with your host" instead of being silently removed.

**This one needs `drop function` + recreate + re-grant.** Adding a parameter changes the signature,
so `create or replace` yields a *second* function, and a positional single-argument call then
raises "function is not unique" — which the pgTAP suite would hit immediately, since six test files
call `perform public.join_ride(code)` positionally. *R3 also claimed PostgREST cannot disambiguate
defaulted overloads; a reviewer believes PostgREST resolves by supplied key set and that only the
Postgres-side positional call is ambiguous. The remedy is unchanged; the reason is narrower than
stated.* Getting this wrong takes down joining for **every** client including route rides, so it is
called out rather than left to the implementer.

The current definition to drop is the one in `0014_join_cap_lock.sql`, not `0003_join_ride.sql`.

### D1.6 — Untouched

`GroupLobbyView` reads no route — read line by line across two gates. It ships structurally
unchanged, with one copy addition (**D5.4**).

## D2 — Entry point

**Rename Home's "Join a ride" chip to "Crew"** (`HomeLaunchBand.swift:33`), landing on the existing
crew screen, which now offers both starting a ride and entering a code.

*R2 proposed "Ride with friends" and called it "one string changed, no tax". Chips are
natural-width in an `HStack(spacing: 8)` inside `.padding(.horizontal, 24)` (`:29,46`), so on an
iPhone SE that row runs ~395 pt against **327 pt** of usable width — Explore + the new label +
Saved truncates. (R3 said 311 pt; the SE is 375 wide less 24 each side. Wrong number, same
conclusion.) "Crew" fits. Verified on device with a saved place at the largest supported type size.*

### D2.1 — The landing screen cannot host two actions as it stands

- `.task { isFocused = true }` (`GroupRideJoinView.swift:57`) throws the keyboard up on the first
  frame, so a host who came to *start* meets a keyboard, eight code boxes and a disabled Join.
- The keyboard **cannot be dismissed**: `.contentShape(Rectangle()).onTapGesture { isFocused = true }`
  (`:55-56`) re-focuses on every background tap, and there is no scroll view for
  `scrollDismissesKeyboard`.
- The header reads "Join a ride" (`:70`).

Drop the autofocus (focus on tap, or when the host chooses "Enter a code"); rewrite the header; stop
the background gesture swallowing dismissal.

### D2.2 — Route through `replaceTopWithGroupRide`

`.joinRide` is pushed with **no auth check** (`HomeView.swift:352`, `AuraApp.swift:115`); the gate
is on the handoff (`AppRouter.swift:61,82`). *R1 claimed the screen was gated. It is not.*

Use **`replaceTopWithGroupRide`**, not `startGroupRide`. The latter *pushes* (`:62`), leaving the
code screen underneath, so Back from the lobby lands the host on a code form with the keyboard up;
signed out, it stashes the intent without popping and `resumePendingGroupRide()` pushes on top of
the stale screen. `replaceTopWithGroupRide` exists for exactly this (`:74-93`) and uses the same gate.

## D3 — What the crew sees

Peer dots on the map, and the roster.

### D3.1 — `progressMeters` is a different quantity on an open ride

| Consumer | Unchanged behaviour on an open ride | Change |
| --- | --- | --- |
| `GroupRosterViewData.rows` sort (`:29-35`) | orders by **personal odometer** | sort by straight-line distance |
| `GroupMapDots` trim (`:20`, `maxDots: Int = 7`) | keeps "furthest along" | keep the **nearest** |
| `PeerAnnotations.leaderID` (`:78,123`) | name-tags the biggest odometer | suppress — no leader on an open ride |
| `PeerDistance.label` | "0.4 mi ahead" of someone behind you | coordinate-based mode |

The wire is unchanged; only interpretation. `PeerDistance` needs a new input, signature and call
graph — not a flag: `label(selfProgress:peer:isImperial:)` formats a scalar, and straight-line
distance needs a coordinate.

### D3.2 — Self's coordinate comes from the coordinator's ride stream

*Revision 4 replaces R3's source, which was ship-dead, having replaced R2's, which was stale.*

Both prior answers were wrong. `gems?.riderCoordinate` is written from `discoverySink`, which the
coordinator **gates on pause** (`RideSessionCoordinator.swift:214`), so it freezes at a café stop.
`LocationService.lastKnown` has one writer — the **ambient** Home-foreground manager
(`LocationService.swift:194-200`, and its own doc comment at `:33-34`) — and the ambient monitor is
affirmatively stopped when the HUD is pushed (`AuraApp.swift:269-282` → `.idle` →
`releaseNonRide()`), never restarting during a ride. Every roster distance would have used a frozen
pre-ride, kilometre-accuracy fix. `coordinator.segments.last` is a third wrong answer:
`recorder.record(point)` is a no-op while paused.

The right source is the one already on the wire. `streamTask` forwards `point.coordinate` to
`groupSink` on **every** fix, explicitly including while paused so a rider's dot does not age into
`.dropped` mid-stop (`:198-214`). The coordinator simply does not expose it.

**Add `public private(set) var currentCoordinate: Coordinate?`**, assigned in that same loop beside
the `groupSink` call. It is exactly the coordinate peers receive, it updates while paused, and it
is nil before the first fix.

Two constraints:

- **Nil renders "locating", never a default `(0,0)`** — which would place the crew 8,000 km away.
- **The read happens in a leaf view, not `RideHUDView.body`.** The coordinator is `@Observable` and
  this writes at the fix rate, so a body-level read invalidates the whole HUD every second. This
  codebase has fixed that twice already — `MapZoomCameraBox` exists so camera writes never
  re-render the HUD (`RideHUDView.swift:29-31`), and `PeerAnnotationDriver` is deliberately a plain
  class rather than `@Observable` (`PeerAnnotations.swift:45-48`).

### D3.3 — One colour authority

`PeerAnnotationDriver.updateSet` calls `PeerPalette.assign` directly (`PeerAnnotations.swift:76`),
in the app target where no test can see it. **`RiderColorLatch` becomes the only authority**;
`PeerAnnotationDriver` reads it and no longer calls `assign`.

`assign` gains `reserved: Set<Int>`, and the latch passes the indices it has issued. *R2 said
`assign` "remains the latch's internal first-assignment step", which it cannot be: `taken` is local
and starts empty, so calling it with one newcomer probes an empty set and reissues a live hue.*

**Input is `session.peers` minus self** — `session.peers` includes self (roster seeding at
`GroupRideSession.swift:233`, plus the backend echoing your own positions), so self would consume a
hue and shift every map colour. **One writer**, driven from the uncapped peer set, not from
`GroupMapDots.visiblePeers` — driving release from the capped set would treat a rider merely past
the dot cap as departed and reissue their hue, so map and roster would disagree on exactly the
>8-rider ride the cap exists for.

**Release on departure is bounded, and rarely fires.** `LivePresenceState` removes a peer only on
`.memberLeft` (`:34-36`); staleness flips `status` to `.dropped` and keeps the entry, so a rider in
a tunnel keeps their colour — which is the point. A force-quit rider never releases. State that
rather than claiming the palette bound always holds. *R3's further claim that a rejoiner gets the
same hue is withdrawn: with `reserved:` de-collision, a rider who originally got a probed index
gets it back only if the reserved set matches.*

**Palette widens to eight.** R1 claimed a colour-vision cap; `RiderPaletteTests` asserts
`riderHues.count >= 4` — a floor (`:28-30`). Two reviewers independently reran all six gates over
the colour space and found ~48 mutually-passing hues. Widening changes
`stableHash(id) % paletteCount`, so `PeerPalette`'s "a rider keeps their colour across rides"
**breaks once** at the update; noted in the type's doc comment. *R2's claim that a new test
assertion couples the count to the crew cap is withdrawn — the cap lives in SQL
(`0014_join_cap_lock.sql:37`) and in `GroupMapDots.maxDots`, neither visible to that suite.*

## D4 — Hosting the crew layer on Explore

### D4.1 — The fork goes in `GroupRideFlowView`

Two readers of `session.route` exist and R1 named only the inner one:

- `GroupRideFlowView.swift:118` — guards `session.route != nil`, else `dismissMessage("Couldn't load this ride's route.")`
- `GroupNavigateContainer.swift:13` — `if let route = session.route`, else `Color.clear`

The outer guard fires first, so an open ride lands on the error screen and the inner branch R1 said
to replace is unreachable. **The fork is at `GroupRideFlowView.swift:118`**, carrying that branch's
`.task` (`didEnterRiding = true`, then `beginLiveSession()`).

Verified across three gates: `route` is `private(set)` with two writers
(`GroupRideSession.swift:145,178`), both before `phase` leaves `.idle`, so the condition cannot flip
mid-ride and the `_ConditionalContent` branch is stable across `.riding → .ended`.

**Depends on ROH-167** — `beginLiveSession` latches before its first await, so a failed roster fetch
permanently disables the live layer. This adds a second call site to that function.

### D4.2 — *(deleted)*

*R3 added a section covering `.riding → .lobby`, on the grounds that `authoritativePhase` permits a
backward move to correct a phantom optimistic start. `authoritativePhase` does permit it
(`RideLifecycle.swift:38-42`) — but nothing can produce the input.*

`start_ride` stamps `started_at` and emits the broadcast **in one transaction, guarded on
`if found`** (`0017_ride_start.sql:14-22`), so `.rideStarted` cannot precede a durable
`started_at`. `optimisticPhase` is forward-only, and the other two routes to `.riding` both read
server status first. There is no reachable phantom start.

Deleting this also dissolves a contradiction R3 shipped: D4.2's condition made `GroupLobbyView`
unreachable for any rider who had entered riding, which foreclosed R3's own D5.3 remedy. Two
sections, mutually exclusive, in the same revision.

### D4.3 — `RideMapView`'s peer layer

`PeerAnnotations` needs a `PeerFrame`, which needs `PeerAnnotationDriver.frame(now:project:)`,
which needs a `project` closure over a live `MapProxy`, a `MapReader`, a `TimelineView` clock, and
`updateSet` wiring — mirroring `NavigateHUDView.swift:285-323`. ROH-105 removed **all** of those by
name, not just the four value parameters. Ribbon splitting stays deleted, being route-based.

**`ribbonPieces` must be memoised before the `TimelineView` goes in.** `shouldAnimate` is true
whenever any peer is riding, so `RideMapView.body` re-evaluates ~30×/s for the whole ride while
containing `TrackRibbon.pieces(segments:)` — which copies every point of every segment — plus an
annotation group mapping them again into `CLLocationCoordinate2D` (`RideMapView.swift:32,82`). On
navigate that polyline is a static route; on Explore it is the **growing recorded track**. Two hours
at 1 Hz is ~7,200 points copied twice, thirty times a second, on the MainActor, while recording.
A five-minute device pass sees nothing. This is ROH-115, promoted to a prerequisite.

`RideMapView.swift:6-9` ("solo by construction") becomes false and is rewritten — ROH-105 named a
stale doc comment on this exact type as its reusable lesson.

### D4.4 — `CrewChrome` extraction

The chrome is an extension of `NavigateHUDView` reading `groupSession`,
`coordinator.stats.distanceMeters`, `settings.units` and `endRide()`. Three do not transfer:

- **Self position** — `selfCoordinate: Coordinate?` from `coordinator.currentCoordinate` (D3.2).
- **`endRide()` differs** — navigate's tears down guidance, stops speech, deactivates the audio
  session; Explore's is `coordinator.finish()`. Injected as `onEndOwnRide`, with
  `finishOwnRideIfEnded`'s one-runloop deferral moving with it.
- **One presentation source.** Two presentations armed on one view in one tick means SwiftUI
  silently drops one, and which one decides whether the crew is left.

**Selector is `showsGroupChrome` (`phase == .riding`), not `groupSession != nil`.** The rest of the
crew layer already selects on phase (`NavigateHUDView+GroupCrew.swift:15-17`), and the two diverge
in the commonest ending — host ends, guest rides on solo — where `groupSession` stays non-nil
forever, keeping crew wording and routing End through a `leaveRide` for a membership already gone.

**This is a behaviour change on navigate, and D7 declares it.** *R3 called the extraction
"behaviour-preserving there" while prescribing this change; navigate's `onEndTapped` selects on
`groupSession != nil` today (`NavigateHUDView.swift:335`). Both statements could not hold.*

*R2 called the extracted piece a "roster button". There is none:* `GroupRosterSheet` is an inline
draggable panel whose only tap target is a **36 × 5 pt grab handle** (`:66-71`) — not usable with
gloves on a vibrating mount. Enlarged here, since the roster is now the only crew-position surface.

### D4.5 — `groupSink` attaches at `.task`, never at `init`

`start` is guarded `guard !recorder.isRecording else { return .started }` (`:149`), so a sink not
supplied at the first `start` can **never** attach. Wiring it into the `State(initialValue:)`
coordinator in `RideHUDView.init` would capture the first init's value and silently fail: **the
rider publishes no position, their own map showing the whole crew while they are invisible on
everyone else's.**

`NavigateHUDView` gets this right at `.task` time (`:237`). Explore's `.task` passes `discoverySink:`
and no `groupSink:` (`RideHUDView.swift:216-219`), and both are defaulted-nil on the same call — so
omitting one compiles clean and ships dead, the failure mode ROH-105 documented.

Adding `var groupSession: GroupRideSession? = nil` is safe: `@State` identity is positional and the
solo call site (`AuraApp.swift:108`) stays `RideHUDView()`.

**One teardown note.** `teardownLive` never nils `rideSession` (`GroupRideSession.swift:346-358`)
and `locationSink` returns it (`:53`), so a coordinator that captured the sink keeps calling
`locationDidUpdate` into a stopped session whose ticker is cancelled. Whether `PointOutbox` caps
growth is verified during implementation; Explore becomes a second holder of that reference.

### D4.6 — Placement

Without the compass the only new persistent element is the roster, which keeps its bottom-leading
slot opposite `ControlCluster`, as navigate already arranges it
(`NavigateHUDView+Cockpit.swift:81-89`).

The **transient stack needs an arbiter**. `CrewChrome`'s toasts and status pills have no home on
Explore: navigate tucks them under its turn card, Explore has none, and it already stacks the gem
peek card and mark-spot toast on the same `.padding(.top, 60)` point (`RideHUDView.swift:107,119`)
with the detour overlay above. D5.3 keeps gems on, so without an arbiter "Marcus left" draws under
a gem card.

**Order, highest first:** detour turn card → crew membership toast → crew status pills → mark-spot
toast → gem peek card. Sizes are a device measurement against the documented 29 pt SE overspill
(`:303-311`).

## D5 — Behaviour

### D5.1 — On a crew ride, every exit routes through the crew confirmation

*Revision 4 replaces R2's and R3's versions, which each miscounted the exits and each proposed a
remedy that did not survive review.*

Today's Explore exits: `ControlCluster(onEndRide:)` (`:294`) and `backTapped`'s above-floor branch
(`:350`) both raise `showEndConfirm`; the alert's own button (`:137`) is the sole
`coordinator.finish()`. `backTapped`'s **below-floor** branch (`:342-352`) reaches neither — it
calls `discard()` then `popToRoot()`. And `.swipeBackEnabled(canDiscard)` (`:245`) toggles the
UIKit `interactivePopGestureRecognizer` (`SwipeBackGesture.swift:44`), which **a SwiftUI alert
cannot intercept** — on the group path it pops `GroupRideFlowView`, releasing the session at
`.riding` with no leave.

**Rule: when `groupSession != nil`, the discard floor stops deciding whether the rider is asked.**
Every chevron and every End tap opens the crew confirmation, regardless of distance. The floor
still decides what happens to the *recording* — below it the ride is discarded rather than
summarised (D5.5) — but never whether the crew is left silently. And the edge swipe is disabled:
`canDiscard && groupSession == nil`.

*R3 cited `NavigateHUDView.swift:280` as precedent for a conditional disable. That line is
unconditional `.swipeBackEnabled(false)` — navigate has no `canDiscard` back-out at all, so it is
no precedent for anything conditional. The design stands; the citation was doing work it could
not do.*

This removes R3's "return to the lobby" mechanism entirely, along with its need for a local phase
override and its unanswered question of what the crew sees meanwhile.

### D5.2 — Leaving must be observed to land

`leave()` → `finishRide(.memberLeave)` is **fire-and-forget** (`GroupRideSession.swift:379-416`):
no re-entrancy guard, no `pendingEnd`, and on timeout or throw it records nothing. Then
`popToRoot()` destroys the session and the evidence. Two taps inside the 4 s `endTimeout` fire two
concurrent `leaveRide` calls and two pops. Scoped to a `.task`, `withTimeout` propagates
cancellation into the operation (`Timeout.swift:8,46`), so view teardown kills the call and the
bare `catch` swallows it.

A crew exit uses the **waited-on** path (`.memberEnd`: re-entrancy guard, pending latch, retry) in
an unstructured `Task` outliving the view. Verified: `.memberEnd` computes
`leaveOnly = (intent != .hostEnd)` (`:381`), so it calls the same `backend.leaveRide` and does not
end anyone else's ride; the `memberLeave` no-clobber comment (`:384-387`) is not invalidated, since
its scenario is a fire-and-forget leave stomping a waited-on latch.

**The `isHost`-staleness hazard on retry is ROH-174**, not this change. It is pre-existing: it needs
no code from here and bites navigate group rides today.

### D5.3 — Gems stay on

Discovery is what Explore is for. `GemDiscoveryStore.isSuppressed` stays unwired, and the comment
at `RideHUDView.swift:33-36` claiming it exists for this surface is deleted — this design retires
it. The cost is the overlay contention D4.6 arbitrates.

### D5.4 — The lobby names the ride kind

D1.6's reuse is an engineering win and a guest-facing defect: the lobby would render identically
whether a guest is about to be navigated 8 km or turned loose, and every crew ride that exists today
has a destination. One line under the header, read from `GroupRide.kind` (D1.3): "Open ride — no
destination" or "Heading to Blue Bottle · 8 km".

### D5.5 — Host end below the discard floor, and discard must pop

*R2 justified this with "a host ending would hand every guest a summary for 40 m". A host end never
finishes a guest's ride: the guest gets `.rideEnded` → `teardownLive` (`:280-283`), and
`GroupRideFlowView.swift:39-49` exists to keep their HUD recording. Right change, invented
justification.*

For the **host's own** ride, `finishOwnRideIfEnded` respects `RideBackOutGate.canDiscard`: below the
floor the ride is discarded rather than summarised.

**And the discard must pop explicitly.** `discard()` → `cancel()` never calls `recorder.end()` and
never sets `finishedRide` (`RideSessionCoordinator.swift:439-446`), and `showRideSummary` is reached
only from `.onChange(of: coordinator.finishedRide)`. So a discard here pops nothing:
`GroupRideFlowView` stays mounted rendering a HUD over a torn-down coordinator with cancelled
streams — frozen panel and map — while `recorder.isRecording` stays true, so
`.onChange(of: coordinator.isRecording)` never fires and **`activeRideID` stays non-nil**, dropping
deep links and showing an in-flight ride on Home. *R3 added "location accuracy stays pinned" to that
list; false — `cancel()` → `stopStreaming()` → `location?.stop()` → `setMode(.idle)`
(`LocationService.swift:167`). Every other consequence in that paragraph holds.*

### D5.6 — A guest who joins after the start

A guest who locks their phone in the lobby has nothing on the lock screen (no group push exists;
ROH-15 is out of scope). The only recovery is the `scenePhase` reconcile
(`GroupRideFlowView.swift:32-36`): when they next look, the cockpit mounts and `.task` auto-starts
recording, so their ride begins wherever they are.

**Recording auto-starts, as today**, with a non-blocking notice: "Started recording here — you
joined after the ride began."

*R2 replaced the auto-start with a confirmation. Three defects: `coordinator.start` is the only
place `groupSink` attaches (D4.5), so declining left the rider a permanent crew member publishing
nothing with no way to start; the trigger was not computable in `RideHUDView`, which for a guest
sees only a fresh mount either way, so it would have fired on every group Explore ride including the
host's; and it left `activeRideID` nil while open, disarming `guard !isRideActive` so a join link
could push a second `GroupRideFlowView` over the live one.*

*R3 kept auto-start but added "an undo that discards". Also wrong: `discard()` does not reset the
recorder, so `isRecording` stays true, `start()` can never run again, and the guest is left unable
to record and no longer publishing — the same trap door.* **No undo.** The notice is informational;
a rider who wants rid of the ride uses the normal exit (D5.1).

### D5.7 — A join link tapped while riding

`AppRouter.handle(url:)` opens `guard !isRideActive` and **silently returns** (`:42`). Since "let's
link up" is usually said by people already riding, this is the likeliest first contact.

**The link stops vanishing: a toast explains why, and the code is stashed and re-offered on the ride
summary.** The stash lives in `AppRouter` memory and dies with the process, so a stale code is never
re-offered days later. The toast uses each HUD's standard surface, not the crew stack — the likeliest
tapper is on a *solo* ride, where D4.6's arbiter does not apply.

*R3 also offered "End your ride and join". Cut to the mid-ride-join issue.* It composes
`coordinator.finish()` with a push, and `showRideSummary` assigns the **whole path** from
`.onChange(of: finishedRide)` one update later — so the join would be silently overwritten. That is
the failure already documented at `AppRouter.swift:74-81` ("the manual-join dead-end observed on
device 2026-07-19"). Fixing it needs the path arbiter in ROH-174, and it is not worth blocking this
change on. The link no longer vanishing is the actual complaint.

Copy limit to accept: `DeepLink.join` carries only a code, so the toast says "a crew", not
"Jamie's crew" — naming the host needs a lookup that does not exist.

## D6 — Roster copy across ride kinds

Riders think "group ride", not "Explore group ride". The two rosters would say "0.4 mi ahead"
(along-route) and "0.4 mi away" (straight-line) in the same shape with different meanings.

The semantics go **in the row's unit text** — "0.4 mi away" versus "0.4 mi up the route". *R2 put
them in the roster header, which already carries `displaySummary` in both collapsed and expanded
states (`GroupRosterSheet.swift:80-86,100-104`), so it would evict that or force a second line, and
land in a panel riders on a bike rarely open.*

## D7 — Navigate's exposure

Navigate takes exactly two changes, declared rather than implied: **D6's row copy**, and **D4.4's
selector change** from `groupSession != nil` to `showsGroupChrome`, which fixes a guest riding on
solo after host-end still seeing crew wording. Both are behaviour changes on the surface carrying
ROH-63 and ROH-81, and both are on the device list.

## D8 — Explore only

The navigate group ride is unchanged in kind. A destination-free ride belongs on Explore — there is
no route to follow, so the navigation cockpit has nothing to show.

## D9 — Out of scope

**Mid-ride join.** Not a router change: `start` early-returns once recording (`:149`) and
`groupSink` is only passed *to* `start`, so there is no way to attach a group session to a live
recording today. It needs a new coordinator entry point plus an answer to what happens to the ride
already recording. The `guard !isRideActive` is deliberate — it stops a deep link yanking a
recording rider out of their ride. D5.7 fixes the silence meanwhile, and "end your ride and join"
belongs with that issue.

**The crew compass** (ROH-168). **Group-aware Live Activity** (ROH-15), whose absence D5.6
mitigates. **The lifecycle defects** (ROH-174). **`progressMeters`' computation or transmission** —
only its interpretation changes. **The route preview's "Ride together" entry**, unchanged.

## Verification

**AuraCore:** roster sort, `GroupMapDots` trim and leader-tag suppression on an open ride (D3.1);
`PeerDistance` coordinate mode leaving route-ride output unchanged; `RiderColorLatch` — stability
after assignment, self-exclusion, `reserved:` de-collision, release bounds (D3.3).

**AuraKit:** open-ride create; join with a nil route reaching `.lobby`; join with a present but
undecodable route still reaching `.routeUnavailable` **and** leaving the ride;
`coordinator.currentCoordinate` updating while paused (D3.2).

**Decoder — the test R1 lacked:** `"route": null` through the real `GroupRideRow`, asserting
`routeData()` yields nil. Cannot run against the in-memory fake.

**pgTAP:** `create_ride` with `p_route` omitted, through the RPC not a direct insert, asserting
`kind = 'open'`; `kind` defaulting to `'route'` for existing rows and for a route create;
`join_ride` rejecting an open ride when `p_supports_open` is false and accepting it when true; the
drop/recreate leaving `join_ride` callable by `authenticated`. *Note the re-grant assertion may be
verification theatre — `0020_revoke_maintenance_rpc_from_api_roles.sql:4-10` documents that hosted
Supabase materialises explicit grants at function-create time via ALTER DEFAULT PRIVILEGES, which
the local CLI stack replicates. The test would pass whether or not the migration re-grants. Keep it,
but do not read a pass as proof.*

**Device, two phones:**

- Both riders' dots appear on each other's Explore map, colours stable across a mid-ride join, and
  matching between map and roster (D3.3).
- Roster distances update **while paused** — the specific failure D3.2's two predecessors would have
  produced (D3.2).
- Every exit routes through the crew confirmation, and the edge swipe is disabled (D5.1).
- A guest joining after the start sees the recording notice (D5.6).
- A join link tapped while riding produces a toast, and the summary re-offers it (D5.7).
- **Hour two** — D4.3's `TimelineView` × growing-track cost is invisible in five minutes.
- Navigate's two changes (D7), on the surface with the crash history.
- iPhone SE: the "Crew" chip with a saved place at the largest supported type size (D2), and the
  arbitrated top stack (D4.6).
