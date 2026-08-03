# Group ride without a destination (ROH-114) — design

Date: 2026-08-02 (revision 3: 2026-08-03)
Issue: [ROH-114](https://linear.app/rohun/issue/ROH-114/group-ride-without-a-destination-group-explore-surface)
Status: revision 3, after two three-reviewer adversarial gates.
Depends on: [ROH-167](https://linear.app/rohun/issue/ROH-167/beginlivesession-latches-before-its-first-await-one-failed-roster) — the live layer must actually start.
Split out: [ROH-168](https://linear.app/rohun/issue/ROH-168/crew-compass-a-wheel-of-colour-coded-arrows-showing-where-every-rider) — the crew compass.
Related: ROH-105 (deleted the dead scaffolding this rebuilds), ROH-72 (the rider palette this
reuses), ROH-115 (ribbon cost — D6 promotes it to a prerequisite), ROH-15 (group Live Activity,
out of scope).

## Revision history

**Revision 1** was refuted on two ship-dead defects and three false claims. **Revision 2** fixed
those and was refuted again, mostly on the crew compass and on second-order consequences of its
own fixes.

**Revision 3 removes the crew compass from this change**, to ROH-168. The compass failed both
gates on fundamentals — first its radius encoding, then its ring arithmetic (log spacing goes
negative below ~40 m, which is where a crew riding together lives) and its scope (absent on a
two-rider ride, the modal case). The destination-free ride converged over the same two rounds.
Keeping them together meant a nearly-clean change waiting on a materially harder design.

Dropping it also deletes this spec's single largest risk surface: revision 2's D6 required a
refcounted multicast heading source, because the compass was a second consumer of a provider
whose two-consumer behaviour is silently broken. Nothing in revision 3 subscribes to heading, so
that section is gone rather than solved.

Corrections from both gates are marked inline.

## Problem

A crew ride requires a destination. `GroupRideEntry.create` carries a `Route`
(`AppRoute.swift:47-50`), its only construction site is the route preview's "Ride together"
button (`RoutePreviewView.swift:250`), and `rides.route` is `not null`
(`0001_schema.sql:14`). "Let's just go ride around for an hour" cannot be expressed.

The Explore HUD has no crew layer at all. `RideHUDView` never receives a `GroupRideSession`, and
ROH-105 deleted `RideMapView`'s peer parameters after establishing they had never once been
passed in production. That deletion was correct, and it means this is a rebuild.

## What this delivers

A host starts a crew ride with no destination, from Home. Guests join by code as they do today.
Everyone rides the Explore cockpit and sees the crew as colour-coded dots with monograms on the
map, plus a roster giving each rider's name, status, and straight-line distance.

Scope is Explore only (D8), rides started from Home only (D9).

## D1 — Removing the route requirement

### D1.1 — The wire is where this breaks

*Revision 2's correction, verified by a second gate and unchanged.*

    // SupabaseGroupRideBackend.swift:136,155
    let route: AnyJSON                                        // NOT optional
    func routeData() throws -> Data { try JSONEncoder().encode(route) }

`AnyJSON` has a `.null` case, so a SQL-null column **decodes successfully** to `.null` rather
than failing or arriving absent, and `routeData()` returns the four bytes `null`. So
`joined.route != nil`, `GroupRideSession.join` falls through to the decode at
`GroupRideSession.swift:171`, lands in `.routeUnavailable`, and calls `backend.leaveRide` — the
guest is shown an error **and silently removed from the ride**.

A reviewer compiled this: a non-optional `AnyJSON`-shaped field decodes `"route": null` to
`.null` and re-encodes to four bytes without throwing; declared optional, it yields Swift nil.

`GroupRideRow.route` becomes `AnyJSON?`, and `routeData()` returns `Data?` mapping both absence
and `.null` to nil.

*Revision 3 corrects a hedge.* Revision 2 wrote "or throws on a top-level fragment encode. Either
way…". If it threw, the "either way" would be false: `routeData()` is called inside `joinRide`'s
`do` block (`SupabaseGroupRideBackend.swift:44-45`), whose `catch` maps to `.joinFailed`, which
never calls `leaveRide` — a different symptom, where the rider stays a ghost member holding a cap
slot rather than being removed. It does not throw in practice, so the conclusion stands, but the
reasoning was sloppy in the section that matters most.

### D1.2 — The three-way distinction, and where it must be tested

| `joined.route` | Meaning | Phase |
| --- | --- | --- |
| nil | Open ride, by design | proceed (`.lobby`/`.riding`) |
| present, decodes | Route ride | proceed, as today |
| present, fails to decode | Corrupt payload | `.routeUnavailable`, leave the ride |

Collapsing rows 1 and 3 is the trap, and revision 1 fell into it one layer below where it was
looking. The check is `joined.route == nil`, before any decode is attempted.

**The test must go through the real row decoder.** Revision 1's stated test ran against
`InMemoryGroupRideBackend`, which returns a true Swift nil because a fake was written to. The
seam introduced for testability is the one place this bug cannot live.

### D1.3 — The full seam list

*Revision 3 completes this. Revision 2 criticised revision 1 for listing two changes "and
stopping", then stopped one layer higher itself.*

1. `GroupRideRow.route: AnyJSON?`, `routeData() -> Data?` (D1.1).
2. `GroupRideBackend.createRide(route: Data?)`; `JoinedRide.route: Data?`.
3. `GroupRideSession.create(route: Route?)` — today it unconditionally encodes
   (`GroupRideSession.swift:134,141`).
4. `GroupRideEntry.create(Route?)` (`AppRoute.swift:48`).
5. **`GroupRideEntry`'s hand-written `Equatable` and `Hashable`.** `==` compares `a.id == b.id`
   (`:55-56`) and `hash` combines `route.id` (`:70`). A nil-route case has no id, so the
   implementer must invent a discriminator. Getting it wrong produces a **navigation-path bug,
   not a compile error** — `navigationDestination(for:)` depends on this conformance. Two open-ride
   entries must hash and compare equal; there is only ever one pending create.
6. `GroupRideFlowView.invokeEntry`'s `case let .create(route)` (`:151-152`).

### D1.4 — Migration

`alter table public.rides alter column route drop not null;`

The existing `check (pg_column_size(route) < 262144)` needs no edit, because **a CHECK constraint
is satisfied whenever its expression is not false**, and `pg_column_size` is strict so a NULL
input yields NULL.

*Revision 3 deletes both of revision 2's size claims.* Revision 2 said `1` in one paragraph and
`4` in the next for the size of `'null'::jsonb`, in the section whose stated job was retracting a
false size claim. Neither number is load-bearing and a reviewer believes both are wrong. The
CHECK-passes-on-NULL rule is the whole argument; no size is asserted.

`create_ride(p_route jsonb)` (`0002_membership_rls.sql:40`) has no default, so PostgREST requires
the argument. It gains `default null`, and the client **omits** it for an open ride rather than
sending `AnyJSON.null` — otherwise the column may hold jsonb `'null'`, which is not SQL NULL,
reads as `is not null`, and would make every test that inserts NULL directly pass against a
column the app never writes. **The pgTAP test goes through `create_ride`, not a direct insert.**

Adding a default does not change the signature, so `create or replace` applies and the existing
grants (`:59-60`) hold. This is *not* true of D1.5's change — see there.

### D1.5 — Mixed-version clients: gate the join, not the create

*Revision 3 replaces revision 2's gate, which was vacuous.*

Revision 2 put a capability argument on `create_ride` so "old clients cannot create open rides, so
old clients never encounter one." Both halves fail. An old build's create path is
`GroupRideSession.create(route: Route)` — non-optional, reached only from
`GroupRideEntry.create(Route)`, whose only production construction site passes a selected
destination. **An old client has no code path that can produce a route-less create.** The gate
forbade something structurally impossible.

The real exposure is **joining**, which revision 2 left ungated while conceding "joining a route
ride is unaffected" — without noticing that joining an *open* ride is the entire hazard. Alice on
the new build creates an open ride and shares the code; Bob on last month's build enters it, gets
SQL NULL, decodes `.null`, fails the `Route` decode, and `leaveRide` fires. Removed server-side,
with each retry burning a `join_attempts` row toward the 10/minute cap.

`rides` gains `kind text not null default 'route' check (kind in ('route','open'))`, and
`join_ride` gains `p_supports_open boolean default false`. If the ride is open and the caller did
not pass true, it raises the same generic `'join failed'` every other rejection raises — so an old
client gets "double-check the code with your host", which is wrong but harmless, instead of being
silently removed from a ride it briefly belonged to.

**This one needs `drop function` and re-grant, not `create or replace`.** Adding a parameter
changes the signature, so `create or replace` produces a *second* function; a single-argument call
then raises "function is not unique", and PostgREST does not disambiguate defaulted overloads. The
migration drops `join_ride(text)`, creates `join_ride(text, boolean)`, and re-issues
`grant execute … to authenticated`. Getting this wrong takes down joining for **every** client,
including route rides, so it is called out rather than left to the implementer.

`kind` is also what the lobby reads for D7.6, rather than inferring ride kind from a null route.

### D1.6 — Untouched

`GroupLobbyView` reads no route. Join code, share link, live roster, and the role-split CTA are
route-free — read line by line and confirmed by two gates. It ships structurally unchanged, with
one copy addition (D7.6).

## D2 — Entry point

**Rename Home's "Join a ride" chip to "Crew"** (`HomeLaunchBand.swift:33`), landing on the
existing crew screen, which now offers both starting a ride and entering a code.

*Revision 3 shortens the label.* Revision 2 proposed "Ride with friends" and claimed "one string
changed… no tax". A reviewer measured it: chips are natural-width in an `HStack(spacing: 8)`
inside `.padding(.horizontal, 24)` (`HomeLaunchBand.swift:29,46`), and Explore + "Ride with
friends" + Saved runs roughly 395 pt against 311 pt of usable width on an iPhone SE. Any rider
with a saved place would see a truncated row, and one Dynamic Type bump breaks it everywhere.
"Crew" fits; the label is verified on device against the SE with a saved place, at the largest
supported type size.

Revision 1 hid the action behind a chip reading "Join a ride" and accepted discoverability as a
cost — a cost accepted against a strawman, since the only alternative it weighed was forking
Home's Explore chip. A host reading "Join a ride" is being told the door is not for them.

### D2.1 — The landing screen cannot host two actions as it stands

`GroupRideJoinView` is built to do one thing:

- `.task { isFocused = true }` (`:57`) throws the keyboard up on the first frame, so a host who
  came to *start* a ride meets a keyboard, eight empty code boxes and a disabled Join button.
- The keyboard **cannot be dismissed**: the container is
  `.contentShape(Rectangle()).onTapGesture { isFocused = true }` (`:55-56`), so every tap on empty
  space re-focuses, and there is no scroll view to carry `scrollDismissesKeyboard`.
- The header still reads "Join a ride" (`:70`).

Required: drop the autofocus (focus on tap, or when the host chooses "Enter a code"); rewrite the
header; and stop the background tap gesture swallowing dismissal. A screen presenting two peer
actions cannot autofocus one of them.

### D2.2 — Route through `replaceTopWithGroupRide`, and mind the auth gate

*Revision 3 corrects revision 2's function choice; revision 2 corrected revision 1's auth claim.*

`.joinRide` is pushed with **no auth check** (`HomeView.swift:352`, `AuraApp.swift:115`); the gate
is on the handoff, in `AppRouter.startGroupRide` / `replaceTopWithGroupRide` (`:61,82`). So the
action must go through one of those, or a signed-out rider reaches `GroupRideFlowView`,
`currentUserID()` throws, and the session lands in `.createFailed`.

It must be **`replaceTopWithGroupRide`**, not `startGroupRide`. `startGroupRide` *pushes* (`:62`),
leaving the code-entry screen underneath — so Back from the lobby lands the host on a code form
with the keyboard up. Signed out, it stashes the intent without popping, and
`resumePendingGroupRide()` pushes on top of the stale screen too. `replaceTopWithGroupRide` exists
for exactly this — a group-ride action fired from a transient pushed entry screen (`:74-93`) — and
routes through the same gate.

Consequence to accept: hosting becomes reachable from two places under two names — "Ride together"
on the route preview (with destination) and "Start a ride" on the crew screen (without). The crew
screen names both; the route preview is unchanged in this pass.

## D3 — What the crew sees

Peer dots on the map, and the roster. No compass (ROH-168).

### D3.1 — `progressMeters` is a different quantity on an open ride

Revision 1 claimed "Navigate reads it; Explore ignores it." Four consumers read it, and the
Explore path reuses all of them:

| Consumer | On an open ride, unchanged | Change |
| --- | --- | --- |
| `GroupRosterViewData.rows` sort (`:29-35`) | orders the crew by **personal odometer**; whoever started earliest sits top all ride | sort by straight-line distance |
| `GroupMapDots` trim (`:20`, `maxDots: Int = 7`) | keeps "the leader (furthest along)" — an arbitrary rider survives | keep the **nearest** |
| `PeerAnnotations.leaderID` (`:78,123`) | pins a persistent name tag to the biggest odometer | suppress; there is no leader on an open ride |
| `PeerDistance.label` | "0.4 mi ahead" of someone who may be behind you | coordinate-based mode |

The wire is unchanged — `progressMeters` keeps flowing because navigate needs it. Only its
interpretation changes, and each consumer is told which quantity it is looking at rather than
inferring.

*Revision 3 corrects revision 2's characterisation of the last row.* Revision 2 called it "a mode
of one function," implying a flag. `PeerDistance.label(selfProgress:peer:isImperial:)` is a
formatter over a scalar; straight-line distance needs self's **coordinate**. It is a new input, a
new signature, and a changed call graph up through `GroupRosterViewData` and `CrewChrome`.

*Revision 3 also corrects a citation.* Revision 2 called `GroupMapDots` an "8-rider trim (`:28`)".
The cap is `maxDots: Int = 7` at `:20` — seven peers plus self — and `:28` is `kept.append(peer)`.

### D3.2 — Self's coordinate comes from `LocationService`

*Revision 3 corrects revision 2, which asserted the only source was the gem store.*

Revision 2 wrote "on Explore the only self coordinate is `gems?.riderCoordinate`". False, and the
false premise drove a bad coupling. `RideHUDView` already holds
`@Environment(LocationService.self)` (`:15`), which exposes `lastKnown: LocationFix?`
(`LocationService.swift:35`).

This matters beyond tidiness. `gems?.riderCoordinate` is written only from `discoverySink`, which
`RideSessionCoordinator` **gates on pause** (`:214`) while continuing to publish to `groupSink`
(`:204-214`). So a rider paused at a café would compute every roster distance from their last
pre-pause fix while their peers saw them correctly — a plausible, continuously worsening error, in
the state an open ride spends the most time in. `stopStreaming()` also nils `discoverySink`
(`:452`), so the same staleness follows `finish()`/`cancel()`.

The pre-first-fix nil window renders "locating", never a default `(0,0)` — which would put the
crew 8,000 km away.

### D3.3 — One colour authority

`PeerAnnotationDriver.updateSet` calls `PeerPalette.assign` directly (`PeerAnnotations.swift:76`),
in the app target, where no test can see it. Revision 1 added `RiderColorLatch` in AuraCore
without saying that call must go, so the two would have disagreed about who is cyan.

**`RiderColorLatch` is the only authority**; `PeerAnnotationDriver` reads it and no longer calls
`assign`.

*Revision 3 fixes how the latch assigns.* Revision 2 said `PeerPalette.assign` "remains the
latch's internal first-assignment step". It cannot be called that way: `taken` is local and starts
empty (`PeerPalette.swift`), so calling it with only a newcomer's id probes against an empty set
and hands out a hue an already-latched rider holds. `assign` gains a `reserved: Set<Int>`
parameter, and the latch passes the indices it has already issued.

**The latch is bounded to concurrent members.** Revision 2 said it is never cleared on departure.
Over a long rolling-join ride that accumulates past the palette size, at which point `assign` stops
de-colliding (`if taken.count < paletteCount`) and two *live* riders share a hue. A departed
rider's index is released once they are no longer in the roster, and re-latched to the same hue if
they rejoin while a slot is free.

**Latch input is `session.peers` minus self.** `session.peers` includes self (roster seeding at
`GroupRideSession.swift:233`, plus the backend echoing your own positions), so self would silently
consume a hue and shift every map colour.

*Revision 3 records what the latch does not fix.* Revision 2 argued this input beats
`GroupMapDots.visiblePeers` because the latter makes "first sight" mean "first fix". A reviewer
showed the advantage does not exist: presence is seeded from the roster exactly once, inside
`beginLiveSession` (`:230-236`), and every later rider is materialised from their first published
position. On a rolling-join open ride the seed set is roughly `{host}`, so every joiner is latched
at first fix either way. The latch's value is **stability after assignment**, not assignment order.
That is the property that was broken and is worth fixing; the ordering claim is withdrawn.

**Palette widens to eight.** Revision 1 claimed it was capped by a colour-vision test. That test
asserts `riderHues.count >= 4` — a floor (`RiderPaletteTests.swift:28-30`). Two reviewers
independently reran every gate the suite applies and found the existing five extend to roughly
50 mutually-passing hues.

Two consequences to record rather than assert away. Widening changes
`stableHash(id) % paletteCount`, so `PeerPalette`'s documented "a rider keeps their colour across
rides" **breaks once**, at the update; that is acceptable and is noted in the type's doc comment.
And *revision 3 withdraws revision 2's claim* that a new upper assertion in `RiderPaletteTests`
keeps the count and the crew cap from diverging: the cap lives in SQL (`0014_join_cap_lock.sql:37`)
and in `GroupMapDots.maxDots`, neither visible to that suite. An assertion there pins a literal and
nothing more. The real coupling is a comment on each, pointing at the others.

## D4 — Hosting the crew layer on Explore

### D4.1 — The fork goes in `GroupRideFlowView`, not `GroupNavigateContainer`

Two readers of `session.route` exist, and revision 1 named only the inner one:

- `GroupRideFlowView.swift:118` — `if session.route != nil { GroupNavigateContainer(...).task { ... } } else { dismissMessage("Couldn't load this ride's route.") }`
- `GroupNavigateContainer.swift:14` — `if let route = session.route { NavigateHUDView(...) } else { Color.clear }`

The outer guard fires first, so an open ride lands on the error screen and the inner `Color.clear`
branch revision 1 said to replace is unreachable in production.

**The fork is at `GroupRideFlowView.swift:118`**, and it carries that branch's `.task`:
`didEnterRiding = true`, then `await session.beginLiveSession()`. Without `didEnterRiding`,
host-end falls through to `endedLobbySurface` and tears the HUD down **mid-recording**.

Verified independently by both gates: `route` is `private(set)` with exactly two writers
(`GroupRideSession.swift:145,178`), both before `phase` leaves `.idle`, so the fork's condition
cannot flip mid-ride, the `_ConditionalContent` branch is stable across `.riding → .ended`, and
`.task` is keyed to view identity so it neither re-runs nor cancels on that transition.

*Revision 3 corrects a claim.* Revision 2 said that without this `.task`, "`beginLiveSession()`
never runs, so the crew never appears at all." True only for a guest who joins straight into
`.riding`; `GroupLobbyView.swift:78` already calls it on the lobby path.

**This depends on ROH-167.** `beginLiveSession` latches `didBeginLive = true` *before* its first
await (`:228`), so a failed roster fetch or a cancelled task permanently disables the live layer —
no subscription, no ticker, and the rider publishes nothing while their own screen looks fine.
D4.1 adds a second call site to a function whose idempotency guard is the bug. ROH-167 lands
first.

### D4.2 — `.riding → .lobby` must be covered

*New in revision 3.*

`authoritativePhase` explicitly permits moving a rider backward to correct a phantom optimistic
start (`RideLifecycle.swift:38-42`); only `.ended` is terminal. `GroupRideFlowView.swift:51` covers
`.riding` and `.ended && didEnterRiding`, but **not `.lobby && didEnterRiding`**.

Sequence: guest receives an optimistic `.rideStarted` → `.riding` → HUD mounts and starts
recording → a `.connected` or foreground reconcile reads `startedAt == nil` →
`applyLifecyclePhase(.lobby)` → `content` flips to `GroupLobbyView`. The HUD subtree is destroyed
mid-recording, and `onDisappear` runs `coordinator.cancel()`, which does not save.

This is the ROH-81 failure through the one transition the outer `if` does not guard, and it is a
today bug on navigate too. The condition becomes
`.riding || ((.ended || .lobby) && didEnterRiding)`, with the lobby case rendering the cockpit
rather than the lobby once a rider has entered riding.

### D4.3 — `RideMapView`'s peer layer is a larger change than revision 1 admitted

`PeerAnnotations` needs a `PeerFrame`, which only `PeerAnnotationDriver.frame(now:project:)`
produces, which needs a `project` closure over a live `MapProxy`, a `MapReader`, a `TimelineView`
clock, and `updateSet` wiring on `onAppear`/`onChange` — mirroring `NavigateHUDView.swift:285-323`.
ROH-105 D1 removed **all** of those by name, not just the four value parameters. Only
`peers`/`selfUserID`/`nameMap`/`selfProgress` stay deleted; ribbon splitting also stays deleted,
being route-based.

**`ribbonPieces` must be memoised before the `TimelineView` goes in.** `shouldAnimate` is true
whenever any peer is riding, so `RideMapView.body` re-evaluates ~30×/s for the whole ride, and it
contains `TrackRibbon.pieces(segments:)` — which copies every point of every segment — plus an
annotation group mapping them all again into `CLLocationCoordinate2D` (`RideMapView.swift:32,82`).
On navigate the equivalent polyline is a static route. On Explore it is the **growing recorded
track**: a two-hour ride at 1 Hz is ~7,200 points copied twice, thirty times a second, on the
MainActor, while recording. Cost grows with duration, so a five-minute device pass sees nothing and
hour two is a thermal problem. This is ROH-115, promoted from "worth measuring" to a prerequisite.

`RideMapView.swift:6-9` ("solo by construction: group rides run through `NavigateHUDView`") becomes
false and is rewritten. ROH-105 named a stale doc comment on this exact type as its reusable lesson.

### D4.4 — `CrewChrome` extraction

The crew chrome is an extension of `NavigateHUDView` reading `groupSession`,
`coordinator.stats.distanceMeters`, `settings.units` and `endRide()`. Three do not transfer:

- **Self position** — `selfCoordinate: Coordinate?` from `LocationService.lastKnown` (D3.2), where
  navigate passes a scalar.
- **`endRide()` differs.** Navigate's tears down guidance, stops speech and deactivates the audio
  session; Explore's is `coordinator.finish()`. The chrome takes an injected `onEndOwnRide`, and
  `finishOwnRideIfEnded`'s one-runloop deferral moves with it.
- **Presentation collision.** Explore already has `.alert("End ride?", isPresented: $showEndConfirm)`.
  Two presentations armed on one view in one tick means SwiftUI silently drops one — and which one
  decides whether the crew is left. **One presentation source.**

**The selector is `showsGroupChrome` (`phase == .riding`), not `groupSession != nil`.**
*Revision 3 corrects revision 2 here.* The rest of the crew layer already selects on phase
(`NavigateHUDView+GroupCrew.swift:15-17`), and the two diverge in the most common group-ride
ending: the host ends, the guest rides on solo. `groupSession` stays non-nil forever, so a
`groupSession != nil` selector would keep crew wording ("Leave the crew or end your ride?") for the
remaining hours of a solo ride, make "Leave crew" a no-op that still fires a network call, and — since
`rideID` is never cleared by `teardownLive` — route End through a `leaveRide` for a membership that
is already gone, showing "Ending…" for the full 4 s timeout and then a retry chip before the summary.

*Revision 3 corrects a description.* Revision 2 called the extracted piece a "roster button". There
is no button: `GroupRosterSheet` is an inline draggable panel whose only tap target is a
**36 × 5 pt grab handle** (`:66-71`) — not a mid-ride target with gloves on a vibrating mount. It
is enlarged as part of this change, since the roster is now the only crew-position surface.

### D4.5 — `groupSink` attaches at `.task`, never at `init`

`RideSessionCoordinator.start` is guarded `guard !recorder.isRecording else { return .started }`
(`:149`), so a sink not supplied at the first `start` can **never** attach. Wiring
`groupSession?.locationSink` into the `State(initialValue:)` coordinator in `RideHUDView.init`
would capture the first init's value and silently fail: **the rider would publish no position,
their own map showing the whole crew while they are invisible on everyone else's.**

`NavigateHUDView` gets this right at `.task` time (`:237`). Explore's `.task` currently passes
`discoverySink:` and no `groupSink:` (`RideHUDView.swift:216-219`), and both are defaulted-nil
parameters on the same call — so omitting one compiles clean and ships dead, the exact failure mode
ROH-105 documented.

Adding `var groupSession: GroupRideSession? = nil` is otherwise safe: `@State` identity is
positional and the solo call site (`AuraApp.swift:108`) stays `RideHUDView()`.

### D4.6 — Placement

Without the compass, the only new persistent element is the roster, which keeps its bottom-leading
slot opposite `ControlCluster` — the arrangement navigate already uses
(`NavigateHUDView+Cockpit.swift:81-89`).

The **transient stack still needs an arbiter**. `CrewChrome`'s membership toasts and status pills
have no home on Explore: navigate tucks them under its turn card, Explore has no turn card, and it
already stacks the gem peek card and the mark-spot toast on the same `.padding(.top, 60)` point
(`RideHUDView.swift:107,119`) with the detour overlay above. D5.4 keeps gems on, so without an
arbiter "Marcus left" draws under a gem card.

**Order, highest first:** detour turn card → crew membership toast → crew status pills → mark-spot
toast → gem peek card. Sizes and the SE budget are a device measurement, against the documented
29 pt overspill at `RideHUDView.swift:303-311`.

## D5 — Behaviour

### D5.1 — Every exit from the cockpit must leave the crew

*Revision 3 corrects revision 2's count and adds the exit both earlier revisions missed.*

Revision 2 said "all three raise the same alert and all three end in `coordinator.finish()`". There
are **two triggers, one alert, one terminus**:

- `ControlCluster(onEndRide:)` (`RideHUDView.swift:294`) — raises the alert
- `backTapped`'s above-floor branch (`:350`) — raises the alert
- `Button("End ride", role: .destructive) { coordinator.finish() }` (`:137`) — **is** the alert,
  and is the only `coordinator.finish()` in the file

So the crew-leave fix is a single edit at `:137`, not a three-site sweep.

**Sequence today:** rider taps End → `coordinator.finish()` → `finishedRide` →
`router.showRideSummary` collapses the path → `GroupRideFlowView` leaves the stack → its `@State`
session is released **at `phase == .riding`**. `leave()` was never called. The server still lists
the rider; they hold a cap slot for the ride's life; peers watch them ghost then drop.
`RideSession.stop()` never runs, so `subscription?.cancel()` never runs.

**The fourth exit is the edge swipe, and it cannot be confirmed.** `.swipeBackEnabled(canDiscard)`
(`:245`) toggles the UIKit `interactivePopGestureRecognizer` (`SwipeBackGesture.swift:44`). A UIKit
interactive pop **cannot be intercepted by a SwiftUI alert**, so revision 2's "a confirmation… plus
an edge swipe" was not implementable. On the group path `RideHUDView` is not the stack entry —
`GroupRideFlowView` is — so the swipe pops the flow view and releases the session at `.riding` with
no leave, reached without a tap, during the huddle when `canDiscard` is true.

**On a crew ride the swipe is disabled**: `canDiscard && groupSession == nil`. Navigate already
does this (`NavigateHUDView.swift:280`). The chevron, with its confirmation, becomes the only exit.

### D5.2 — Leaving must be observed to land

`leave()` → `finishRide(.memberLeave)` is the **fire-and-forget** branch
(`GroupRideSession.swift:379-416`): no re-entrancy guard, no `pendingEnd`, and on timeout or throw
it records *nothing*. Then `popToRoot()` destroys the session and the evidence. Two back taps inside
the 4 s `endTimeout` fire two concurrent `leaveRide` calls and two pops. And if the leave is scoped
to a `.task`, `withTimeout` propagates cancellation into the operation (`Timeout.swift:8,46`), so
tearing the view down kills the call mid-flight and the bare `catch` swallows it.

A crew exit uses the **waited-on** path (`.memberEnd`: re-entrancy guard, pending latch, retry) in
an unstructured `Task` that outlives the view. The rider is not popped until it lands or fails
visibly. Verified: `.memberEnd` computes `leaveOnly = (intent != .hostEnd)` (`:381`), so it calls
the same `backend.leaveRide` as `leave()` and does not end the ride for anyone else. The
`memberLeave` no-clobber comment (`:384-387`) is not invalidated — its scenario is a
fire-and-forget leave stomping a waited-on latch, and `.memberEnd` is a waited-on intent.

**One residual hazard, from `isHost` being mutable.** `retryEndIfNeeded` replays the latched
`finishIntent` without re-deriving it (`:421-425`). Sequence: member taps End → `.memberEnd` times
out → chip shown, rider stays → the host discards during the huddle → `leave_ride` promotes this
rider → `reconcileFromStatus` sets `isHost = true` (`:300`) → they tap Retry → `.memberEnd`
replays as a *leave*, the crew rides on hostless, and they believe they ended the ride for
everyone. D5.3's promotion notice makes this **more** reachable, not less. `retryEndIfNeeded`
re-derives intent from current `isHost` before replaying.

### D5.3 — Discarding with a live crew, and the silent host handoff

The discard path is one tap on the top-left chevron with no confirmation, armed for the entire
pre-roll huddle — everyone stationary, below the 25 m floor — which on an open ride is the longest
it will ever be. `leave_ride` then promotes the earliest joiner to host **silently**
(`0018_ride_ended_broadcast.sql:24-38`).

*Revision 3 replaces revision 2's remedy.* Revision 2 required the join code be surfaced outside
the lobby so a discarding host could rejoin. Rejoining with the code makes them **a guest in their
own ride**: Priya keeps host, their End control now means "leave", and the roster they built is
someone else's.

**On a crew ride below the discard floor, the chevron discards the recording and returns to the
lobby** — not to Home. Host, code and roster stay intact, and the need to surface the code
elsewhere disappears. Above the floor it opens the End confirmation as today.

Where the rider does leave a crew, the confirmation says what is actually lost ("Priya will become
the host"), and the promoted rider gets a **non-transient** notice explaining that their End button
changed meaning — learning it from a 2.5 s chip is the state this section exists to fix.

### D5.4 — Gems stay on

Discovery is what Explore is for, and a crew has no more reason to suppress it than a solo rider.
`GemDiscoveryStore.isSuppressed` stays unwired, and the comment at `RideHUDView.swift:33-36`
claiming it exists for this surface is deleted — this design retires it. The cost is the
top-overlay contention D4.6 arbitrates.

### D5.5 — The lobby names the ride kind

D1.6's structural reuse is an engineering win and a guest-facing defect. The lobby is a guest's
only pre-ride surface, and it would render identically whether they are about to be navigated 8 km
to a café or turned loose. Every crew ride that exists today has a destination, so that is the
expectation they arrive with.

One line under the header, read from `rides.kind` (D1.5): "Open ride — no destination" or
"Heading to Blue Bottle · 8 km".

### D5.6 — A guest who pockets the phone

There is no group-ride push in this codebase and ROH-15 is out of scope, so a guest who locks their
phone in the lobby has nothing on the lock screen. The only recovery is `GroupRideFlowView`'s
`scenePhase` reconcile (`:32-36`): when they next look, the session reconciles to `.riding`, the
cockpit mounts, and `RideHUDView`'s `.task` auto-starts recording — their ride begins wherever they
are, with a straight-line jump from the meeting point or minutes missing.

*Revision 3 withdraws revision 2's fix, which was worse than the bug.* Revision 2 replaced the
auto-start with a "Ride started — start recording?" confirmation. Three defects:
`coordinator.start` is the **only** place `groupSink` attaches (D4.5), so declining leaves the rider
a permanent crew member publishing nothing, with no "start recording" control anywhere on the HUD;
the trigger ("entering `.riding` from a background reconcile") is not computable in `RideHUDView`,
which for a guest sees only a fresh mount either way, so it would fire on **every** group Explore
ride including the host's; and it would leave `activeRideID` nil while the prompt is up, disarming
`AppRouter`'s `guard !isRideActive` and letting a join deep link push a *second* `GroupRideFlowView`
over the live one.

**Recording auto-starts, as today.** A non-blocking notice — "Started recording here — you joined
after the ride began" — with an undo that discards, fixes the fabricated segment without making
participation contingent on catching a tap. Push notification remains ROH-15's, and this
requirement is written here so ROH-15 inherits it.

### D5.7 — Host end below the discard floor

*Revision 3 corrects revision 2's premise and completes its mechanism.*

Revision 2 justified this with "a host ending twenty seconds after start would hand every guest a
summary for 40 m". A host end never finishes a guest's ride: the guest gets `.rideEnded` →
`phase = .ended` → `teardownLive` (`:280-283`), and `GroupRideFlowView.swift:39-49` exists
specifically to keep the guest's HUD recording. The change is right for the **host's own** ride and
the justification named a behaviour that does not exist.

`finishOwnRideIfEnded` calls `endRide()`, guarded on `phase == .ended`
(`NavigateHUDView+GroupCrew.swift:158-164`). On Explore it respects `RideBackOutGate.canDiscard`:
below the floor the ride is discarded rather than summarised.

**And the discard must pop.** `discard()` → `cancel()` never calls `recorder.end()` and never sets
`finishedRide` (`RideSessionCoordinator.swift:439-446`), and `router.showRideSummary` is only
reached from `.onChange(of: coordinator.finishedRide)`. So a discard here pops nothing:
`GroupRideFlowView` stays mounted rendering a HUD over a torn-down coordinator with its streams
cancelled, so the panel and map freeze; `recorder.isRecording` stays true, so
`.onChange(of: coordinator.isRecording)` never fires and **`activeRideID` stays non-nil** — deep
links keep being dropped, Home shows an in-flight ride, and location accuracy stays pinned. The
discard path pops explicitly rather than relying on `finishedRide`.

### D5.8 — A join link tapped while riding

`AppRouter.handle(url:)` opens `guard !isRideActive` and **silently returns** (`:42`). The rider
taps, nothing happens, and no explanation exists anywhere in the path. Since "let's link up" is
usually said by people already riding, this is the likeliest first contact with the feature.

The full capability is out of scope (D9). In this change the link stops vanishing, and the rider is
offered the action that matches their intent:

- **"End your ride and join"** — composes `coordinator.finish()` (or `discard()` below the floor)
  with the existing join path. No new coordinator entry point, no D9 work. At a trailhead where the
  crew is forming, this is what the rider actually wants.
- **"Not now"** — stashes the code and re-offers it on the ride summary.

Two limits to state rather than paper over. The link carries only a code (`DeepLink.join`), so the
copy cannot name the host without a lookup that does not exist — it reads "a crew", not "Jamie's
crew". And the likeliest tapper is on a *solo* Explore or navigate ride, where D4.6's arbiter does
not apply; the notice therefore uses the standard toast surface each HUD already has, not the crew
stack. The stash lives in `AppRouter` memory and dies with the process, so a stale code is never
re-offered days later.

## D6 — Roster copy across ride kinds

Riders do not think "Explore group ride" versus "navigate group ride" — they think "group ride".
The two rosters would say "0.4 mi ahead" (along-route) and "0.4 mi away" (straight-line) in the
same visual shape with different meanings.

*Revision 3 moves this from the header into the row.* Revision 2 put the disambiguation in the
roster header, which already carries `displaySummary` ("3 riding · 1 stopped") in both collapsed
and expanded states (`GroupRosterSheet.swift:80-86,100-104`) — so it would either evict that or
force a second line, and land in the expanded panel a rider on a bike rarely opens. Putting the
semantics in the unit — "0.4 mi away" versus "0.4 mi up the route" — costs no layout and travels
with the value.

## D7 — Why not navigate

The crew layer stays off navigate's HUD in this change beyond the `CrewChrome` extraction, which is
behaviour-preserving there. Navigate carries ROH-63 (nested `NavigationStack` crash), ROH-81
(`@State` destroyed by a phase-driven rebuild), and a top-overlay ordering bug that took a device
pass to find. The one change navigate does take is D6's row copy, so the two rosters do not use one
shape for two meanings.

## D8 — Explore only

Group rides on the Explore cockpit; the navigate group ride is unchanged in kind. This is where a
destination-free ride belongs — there is no route to follow, so the navigation cockpit has nothing
to show.

## D9 — Mid-ride join is out of scope

Filed separately. It is not a router change: `RideSessionCoordinator.start` early-returns once
recording (`:149`) and `groupSink` is only ever passed *to* `start`, so **there is no way to attach
a group session to a live recording today**. It needs a new coordinator entry point plus an answer
to what happens to the ride already being recorded (adopt it into the crew, or end and restart,
losing the split).

The `guard !isRideActive` is also deliberate — it stops a deep link yanking a recording rider out
of their ride. D5.8 fixes the silence and offers end-and-join in the meantime.

## Verification

**AuraCore:** the roster sort, the `GroupMapDots` trim and the leader-tag suppression on an open
ride (D3.1); `PeerDistance` coordinate mode leaving route-ride output unchanged;
`RiderColorLatch` — stability after assignment, self-exclusion, `reserved:` de-collision, and index
release on departure (D3.3).

**AuraKit:** open-ride create; join with a nil route reaching `.lobby`; join with a present but
undecodable route still reaching `.routeUnavailable` **and** leaving the ride;
`retryEndIfNeeded` re-deriving intent after an `isHost` flip (D5.2).

**Decoder — the test revision 1 lacked:** a JSON payload with `"route": null` through the real
`GroupRideRow`, asserting `routeData()` yields nil. This cannot run against the in-memory fake.

**pgTAP:** `create_ride` with `p_route` omitted, through the RPC not a direct insert; `kind`
defaulting to `'route'` for existing rows; `join_ride` rejecting an open ride when
`p_supports_open` is false, and accepting it when true; the `drop`/re-`grant` leaving
`join_ride` callable by `authenticated` (D1.5).

**Device, two phones:**

- Both riders' dots appear on each other's Explore map, with stable colours across a mid-ride join
  (D3.3) — and the colours match between map and roster.
- All exits leave the crew: End from the cluster, End from the alert, the chevron above the floor,
  and the edge swipe **disabled** on a crew ride (D5.1).
- The chevron below the floor returns the host to the lobby with code and roster intact (D5.3).
- A guest joining after the start sees the recording notice and can undo it (D5.6).
- A join link tapped while riding offers end-and-join (D5.8).
- **Hour two.** The `TimelineView` × growing-track cost in D4.3 is invisible in a five-minute pass.
- iPhone SE: the "Crew" chip with a saved place at the largest supported type size (D2), and the
  arbitrated top stack (D4.6).

## Out of scope

The crew compass (ROH-168). Mid-ride join (D9). Group-aware Live Activity (ROH-15), whose absence
D5.6 partially mitigates. Changing how `progressMeters` is computed or transmitted — only how it is
interpreted. The route preview's "Ride together" entry, unchanged.
