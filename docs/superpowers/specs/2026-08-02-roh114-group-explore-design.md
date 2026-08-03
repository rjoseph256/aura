# Group ride without a destination, and the crew compass (ROH-114) — design

Date: 2026-08-02 (revision 2: 2026-08-03)
Issue: [ROH-114](https://linear.app/rohun/issue/ROH-114/group-ride-without-a-destination-group-explore-surface)
Status: revision 2, after a three-reviewer adversarial gate (skeptic, product, architecture).
Related: ROH-105 (deleted the dead scaffolding this rebuilds), ROH-72 (built the rider palette
this reuses), ROH-15 (group-aware Live Activity, out of scope), ROH-115 (ribbon cost — this
change makes it urgent, see D7).

Revision 1 contained two defects that would have shipped dead, and three false factual claims.
The route-less join was broken end-to-end at a layer revision 1 never read (D2); the cockpit fork
was aimed at a branch that cannot render (D7); the rider palette was said to be capped by a
colour-vision test that in fact only sets a floor (D4); the join screen was said to be behind the
auth gate, which it is not (D3); and `pg_column_size(NULL)` was said to be 1, which it is not
(D2). Each correction is marked inline. The wheel's radius encoding was also refuted and is
redesigned (D4).

## Problem

A crew ride requires a destination. `GroupRideEntry.create` carries a `Route`
(`AppRoute.swift:47-50`), its only construction site is the route preview's "Ride together"
button (`RoutePreviewView.swift:250`), and `rides.route` is `not null` in the database
(`supabase/migrations/0001_schema.sql:14`). "Let's just go ride around for an hour" cannot be
expressed.

The Explore HUD has no crew layer at all. `RideHUDView` never receives a `GroupRideSession`, and
ROH-105 deleted `RideMapView`'s peer parameters after establishing they had never once been
passed in production. That deletion was correct, and it means this is a rebuild.

## What this delivers

A host starts a crew ride with no destination, from Home. Guests join by code as they do today.
Everyone rides the Explore cockpit, sees the crew as coloured dots on the map, and sees a **crew
compass**: one wheel, one arrow per rider, angle giving direction and radius giving range against
fixed distance rings.

Scope is Explore only (D9), and rides started from Home only (D10).

## D1 — Why a compass wheel, honestly

*Revision 2 rewrites this section. Revision 1 justified the wheel against a strawman map.*

The Explore map is already a rider-centred compass: `Puck2D(bearing: .heading)` under
`.followPuck(zoom: 16, bearing: .heading)` (`RideMapView.swift:42`). A peer dot's on-screen
direction from the puck already **is** the relative bearing an arrow would draw. Revision 1's
claim — that reading a distant rider means zooming out until you are a speck — describes a map
that does not have a heading-up follow mode. This one does.

So the wheel's real delta over the map is narrower than revision 1 claimed, and it is exactly
two things:

1. **Bounded radius.** A rider outside the viewport is not small, they are absent, and the map
   gives no indication they exist. The wheel's rim always holds them.
2. **A fixed, legible distance scale.** The map's scale is whatever the zoom happens to be. The
   wheel's rings are constant, so "are we together or have we come apart" is a shape, readable
   without reading anything.

The cheaper alternative to (1) alone is an edge-of-viewport chevron with a distance label. That
was considered and is not chosen, because it solves only the first half: chevrons tell you a
rider is off-screen in some direction at some distance, in a frame whose scale changes every time
the rider zooms. It is the right fix if the wheel fails its device pass, and it is recorded here
so that fallback is a decision rather than a scramble.

**The kill criterion stands.** If the wheel is not readable in a glance from a bar mount, it is
cut and the destination-free ride ships without it — which is what ROH-114 actually asks for. The
wheel is sequenced second so that outcome is survivable. Revision 2 sharpens the criterion: the
device pass asks *"does this beat an edge-of-viewport chevron"*, not *"is this readable"*.
Readable and redundant is still a cut.

## D2 — Removing the route requirement

*Revision 2 rewrites this section. Revision 1's version shipped a route-less join that bounced
every guest and removed them from the ride server-side.*

### D2.1 — The wire is where this breaks

Revision 1 listed two seam changes — `GroupRideBackend.createRide` and `JoinedRide.route` — and
stopped. The layer below is where nil dies:

    // SupabaseGroupRideBackend.swift:136,155
    let route: AnyJSON                                        // NOT optional
    func routeData() throws -> Data { try JSONEncoder().encode(route) }

`AnyJSON` has a `.null` case, so a SQL-null column **decodes successfully** to `.null` rather
than failing or arriving absent. `routeData()` then returns the four bytes `null` (or throws on a
top-level fragment encode). Either way `joined.route != nil`, so `GroupRideSession.join` falls
through to the decode at `GroupRideSession.swift:171`, lands in `.routeUnavailable`, and calls
`backend.leaveRide(rideID:)` — **the guest is shown an error and silently removed from the ride**.

`GroupRideRow.route` becomes `AnyJSON?`, and `routeData()` returns `Data?` mapping both absence
and `.null` to nil. This is the highest-value single change in the spec.

### D2.2 — The three-way distinction, and where it must be tested

| `joined.route` | Meaning | Phase |
| --- | --- | --- |
| nil | Open ride, by design | proceed (`.lobby`/`.riding`) |
| present, decodes | Route ride | proceed, as today |
| present, fails to decode | Corrupt payload | `.routeUnavailable`, leave the ride |

Collapsing rows 1 and 3 is the trap, and revision 1 fell into it one layer below where it was
looking. The check is `joined.route == nil`, evaluated before any decode is attempted.

**The test must go through the real row decoder.** Revision 1's stated test ("join with a nil
route reaching `.lobby`") runs against `InMemoryGroupRideBackend`, which returns a true Swift nil
because a fake was written to. The seam introduced for testability is the one place this bug
cannot live. A decoder-level test feeding a JSON payload with `"route": null` through
`GroupRideRow` is required, and it is the test that would have caught this.

### D2.3 — Migration, and what jsonb null means

`alter table public.rides alter column route drop not null;`

*Revision 2 corrects revision 1's justification.* Revision 1 claimed `pg_column_size` of a null
jsonb is 1. `pg_column_size` is strict, so it returns NULL for a NULL input; `1` is the size of
`'null'::jsonb`, a **different value**. The existing `check (pg_column_size(route) < 262144)`
still needs no edit, because a CHECK is satisfied when its expression is not false — but the
conclusion now rests on one justification rather than two, and the distinction revision 1 blurred
is precisely the one D2.1 turns on.

`create_ride(p_route jsonb)` (`0002_membership_rls.sql:40`) has no default, so PostgREST requires
the argument. It gains `default null`, and the client omits it for an open ride rather than
sending `AnyJSON.null` — otherwise the column may hold jsonb `'null'` (size 4, `is not null` true)
while every test that inserts SQL NULL directly passes. **The pgTAP test goes through
`create_ride`, not through a direct insert.**

### D2.4 — Mixed-version clients

Dropping the constraint is a server change that reaches every installed build at once. An older
App Store client joining an open ride hits `GroupRideSession.swift:171`, fails the decode, and
`leaveRide` fires: the rider is removed server-side, the host sees a join toast followed
instantly by a leave toast, and each retry burns a `join_attempts` row toward the 10/minute cap.

`create_ride` gains a client-capability argument (a version or a boolean the new build sends),
and open rides are only creatable by clients that pass it. Old clients cannot create open rides,
so old clients never encounter one. Joining a *route* ride is unaffected. This is a deployment
requirement, not a nicety; without it the migration is a live incident for anyone slow to update.

### D2.5 — Untouched

`GroupLobbyView` reads no route. Join code, share link, live roster, and the role-split CTA are
route-free, verified line by line and confirmed by two reviewers. The lobby ships structurally
unchanged — with one copy addition, see D8.6.

## D3 — Entry point

*Revision 2 replaces revision 1's placement and corrects its auth claim.*

**Rename the existing Home chip.** "Join a ride" becomes **"Ride with friends"**
(`HomeLaunchBand.swift:33`), landing on the existing crew screen, which now presents both actions:
start a ride, or enter a code. One string changed, zero extra taps for a joiner, and no tax on
solo Explore.

Revision 1 put the action behind a chip labelled "Join a ride" and accepted discoverability as a
cost. That was a cost accepted against a strawman: the only alternative it weighed was forking
Home's Explore chip, which does tax every solo launch. Renaming was never considered and is free.
A host reading "Join a ride" is being told the door is not for them.

*Revision 2 corrects the auth claim.* Revision 1 said the join screen is "already behind the auth
gate." It is not. `.joinRide` is pushed with no check (`HomeView.swift:352`, `AuraApp.swift:115`);
the gate lives on the handoff, in `AppRouter.startGroupRide` / `replaceTopWithGroupRide`
(`AppRouter.swift:61,82`). The new action must route through `startGroupRide(.create(nil))` so
sign-in is enforced. Pushing `.groupRide(.create(nil))` directly would put a signed-out rider into
`GroupRideFlowView`, where `currentUserID()` throws and the session lands in `.createFailed`.

Consequence to accept and write down: hosting becomes reachable from two places under two names —
"Ride together" on the route preview (with destination) and "Start a ride" on the crew screen
(without). The crew screen names both; the route preview is not changed in this pass.

## D4 — The crew compass

*Revision 2 redesigns the scale and the declutter, and deletes the degradation rule.*

Computation lives in AuraCore as `CrewCompassViewData`; the view lives in the app target, per the
standing rule that the app target has no unit test bundle (`Aura/project.yml`, one UI-test target).

    CrewArrow {
      id: UUID, monogram: String, colorIndex: Int,
      absoluteBearingDegrees: Double, distanceMeters: Double,
      normalizedRadius: Double, distanceLabel: String, status: PeerStatus
    }

### D4.1 — Fixed rings, not auto-ranging

Revision 1 auto-ranged to `dMax = max(farthest peer, 400)`. Two reviewers refuted it
independently, and they are right:

- Above 400 m, `dMax` **is** the farthest peer, so that rider sits exactly at the rim at 800 m and
  at 8 km alike. The radius axis was a ranking wearing a magnitude's clothes. A crew inside 300 m
  and a crew spread over 8 km drew the same wheel — losing the one fact the instrument exists to
  show.
- Rescaling moves every arrow at once, and always inward when the crew spreads. A rider glancing
  at 0 s and 10 s across a rescale reads "everyone got closer" at the moment they got further
  apart. The only signal the wheel gave over time had two causes and did not distinguish them.

**Three fixed rings: 200 m, 1 km, 5 km.** Radius is `log`-spaced between them so the inner ring
has usable area; beyond 5 km an arrow pins to the rim and its label carries the true distance.
Nothing rescales, ever. "We are together" and "we are scattered" become shapes, and no legend is
needed because the rings are constant and can be labelled once, faintly, at rest.

This also deletes the hysteresis machinery revision 1 specified, along with the unowned-state
problem it had: `CrewCompassViewData` is a pure function producing a value type, with nowhere to
hold a last-rescale timestamp. Fixed rings need no such state.

### D4.2 — Declutter must preserve the encoding

Revision 1 said `ClusterDeclutter` is reused unchanged. It cannot be. `ClusterDeclutter.resolve`
relocates clustered points onto a circle around the **cluster centroid**
(`ClusterDeclutter.swift:52-68`), returning a free 2D delta. On a map that is harmless — dot
position encodes nothing. On the wheel, **angle is bearing and radius is distance**, so a free
delta corrupts both readings.

Worked with this spec's own numbers: three riders 20 m away cluster near the hub, and a centroid
fan sends one arrowhead essentially onto the hub (bearing undefined) and the others to unrelated
bearings. A crew all riding due north renders as three arrows pointing three ways — in the case
D4 itself calls the common one.

The wheel gets its own separation rule: **bearing is never altered.** Colliding arrowheads are
nudged *radially outward* along their true bearing, in fixed small steps, with the label showing
the true distance. Radius is already a compressed axis, so a few points of outward nudge is a
smaller lie than any change of angle — and unlike angle, the lie is bounded and in a direction the
ring labels already qualify. If riders share a bearing to within the nudge budget, they stack
along one spoke, which reads correctly: *they are in the same direction*.

### D4.3 — Identity, and the palette is not capped

*Revision 2 retracts revision 1's central claim here.* Revision 1 said the palette cannot be
widened because five hues are the result of a colour-vision constraint gated by
`RiderPaletteTests`. That test asserts `riderHues.count >= 4` — a **floor, not a ceiling**
(`RiderPaletteTests.swift:28-30`). Reviewers reimplemented every gate the suite applies (ΔE in
normal and simulated deuteranopia vision, separation from mint and amber, contrast on `nearBlack`,
a conforming monogram ink) and found the existing five extend to dozens of mutually-passing hues.
The real constraint is the aesthetic note at `AuraPalette.swift:36-42`, which contradicts revision
1's own "out of scope" line.

So: **the palette widens to eight**, matching the crew cap, chosen to keep the Aura family look
while clearing every gate the suite already enforces. `RiderPaletteTests` gains an upper assertion
so the count and the cap cannot silently diverge.

**This deletes revision 1's degradation rule entirely.** Showing "the four nearest plus +N"
contradicted D1 outright — it culled the rider off the back, the one person whose position you
need — and it existed only to work around a hue shortage that does not exist. Every rider gets an
arrow.

Identity is still **colour plus monogram**, never colour alone.

### D4.4 — Heading, and detecting when it lies

Arrows carry **absolute** bearing; the wheel applies one `.rotationEffect(-heading)`. Revision 1
baked `relativeBearing` into each arrow, which forced the whole array to be rebuilt and re-diffed
on every heading tick for no gain. This codebase already knows that lesson twice over
(`MapZoomCameraBox` exists so camera writes never re-render the HUD; `PeerAnnotationDriver` is
deliberately a plain class, not `@Observable`).

**Heading staleness is a watchdog, not an absence check.** Revision 1 specified a north-up
fallback "when heading is unavailable" — which cannot fire for the failure that actually occurs.
Per D6, a clobbered stream never finishes and never errors; it simply stops yielding, leaving every
arrow rotated by a fixed, plausible-looking, wrong offset. The wheel therefore tracks the last
heading's timestamp and falls back to north-up with an N marker after 3 s of silence, whatever the
stream's state.

### D4.5 — States revision 1 left undefined

- **No peers yet.** The normal first minute of a rolling-join open ride. The wheel shows rings and
  a hub with a single line: "Waiting for your crew." It does not render an empty instrument.
- **One peer.** The wheel is strictly worse than a line of text at n=1; it appears at n≥2 and the
  roster covers n=1.
- **`.awaiting` peers** (joined, no fix yet) have no bearing and no radius. They are listed by
  monogram in a row beneath the wheel, not placed on it. Placing them anywhere would fabricate a
  position; omitting them silently would break D1's promise that nobody is lost.
- **Dropped peers.** *Revision 2 reverses revision 1 here.* Revision 1 ghosted them at last known
  bearing and radius "for consistency with the map." That trade is right for the map and wrong for
  the wheel: a map dot is anchored to the world and honestly says "he was here," while a wheel
  arrow is anchored to **you**, and you are moving — so a frozen relative bearing is wrong the
  moment you turn a corner. Dropped peers move to the same row as `.awaiting`, labelled "no
  signal," and leave the wheel.

### D4.6 — Accessibility

Every comparable view in this repo writes its accessibility decisions down; revision 1 wrote none
for the most visual instrument in the app.

- The wheel is one `.accessibilityElement(children: .ignore)` with a label enumerating riders by
  name, clock direction and distance ("Marcus, 2 o'clock, 400 metres"), refreshed on the peer tick
  rather than the heading tick.
- Monograms honour Dynamic Type up to `.accessibility1`, matching `GroupRosterSheet`'s existing cap.
- Under Reduce Motion the rotation snaps in 45° steps rather than animating, matching
  `PeerAnnotations.swift:132-143`.

## D5 — One colour authority

`PeerAnnotationDriver.updateSet` calls `PeerPalette.assign` directly (`PeerAnnotations.swift:76`),
in the app target, where no test can see it. Revision 1 added `RiderColorLatch` in AuraCore without
saying that call must go — so the wheel and the map would have disagreed about who is cyan, on the
same screen, at the same instant, while the AuraCore tests passed.

**`RiderColorLatch` is the only authority.** `PeerAnnotationDriver` reads it and no longer calls
`assign`. `PeerPalette.assign` remains only as the latch's internal first-assignment step.

**Latch input is `session.peers`, and self is excluded explicitly.** The two candidate inputs both
have a defect that has to be chosen against: `session.peers` includes self (roster seeding at
`GroupRideSession.swift:233`, plus the backend echoing your own position), so self would silently
consume a hue and shift every map colour; `GroupMapDots.visiblePeers` excludes anyone without a
coordinate, so "first sight" would mean "first fix," and a rider who joins and stands still gets
assigned last — reintroducing the reshuffle the latch exists to prevent. `session.peers` minus
self, latched at first appearance in the roster, has neither property.

Latch lifetime is the ride. A rider who leaves and rejoins keeps their hue, since it is keyed by
userID and not cleared on departure.

The latch also fixes this reshuffle on today's navigate map dots. That is an incidental bug fix
and is called out rather than smuggled.

## D6 — One heading source

`CompassHeadingProvider.headings()` stores `manager` and `delegate` as instance state
(`CompassHeadingProvider.swift:30-35`) and nils them in `onTermination` (`:38-43`).
`CLLocationManager.delegate` is **weak**, and `self.delegate` is the only strong reference — so a
second `headings()` call deallocates the first subscriber's delegate and manager. The first stream
then never finishes and never errors. **It silently stops yielding**, which is why D4.4 specifies a
staleness watchdog rather than an absence check.

Requirements for the shared source:

- **Refcounted.** Hardware starts on the first subscriber and stops on the **last**. A direct port
  of the current `onTermination` reproduces the cross-consumer teardown one level up.
- **`.bufferingNewest(1)`.** `AsyncStream`'s default policy is unbounded; a suspended consumer
  (view off-screen, app backgrounded, ride still recording) would accumulate headings and drain
  the whole backlog in one MainActor turn on resume, each element a wheel recompute.
- **Nothing in `init`.** `RideHUDView.init()` runs on every parent body evaluation and discards its
  `State(initialValue:)` results after the first (`RideHUDView.swift:53-68`). Today that is free
  because `CompassHeadingProvider.init` is inert. Starting a Task or touching CoreLocation in a
  wrapper's `init` would do so on every repaint.
- **Not a process-global singleton.** The file has precedent (`HapticPlayer.shared`) and it is the
  wrong shape here: one leaked subscriber pins the compass on for the app's lifetime.
- **Explicit teardown.** `GuidanceController` is torn down because `coordinator.cancel()` calls
  `guidance?.detach()` explicitly (`RideSessionCoordinator.swift:425`). This repo already documents
  `onDisappear` as unreliable on the retained nav root (`:434-438`), so the wheel's subscription
  needs a named owner and an explicit stop, not a view lifecycle hook.

*Revision 2 corrects revision 1's framing.* Revision 1 required "one `CLLocationManager`." That is
already false: Mapbox runs its own location provider for `Puck2D(bearing: .heading)`. The
requirement is one `CompassHeadingProvider`-owned manager and no cross-consumer teardown.

**Battery and thermals are a named cost.** `headingFilter = 3` means an update every 3° of
rotation, which on a bar mount over rough road is near-continuous. On top of that: the session's
1 Hz ticker, Mapbox rendering a heading-up map, and `setKeepAwake(true)` for the whole ride. A
three-hour open ride in the sun is the thermal case, and throttling degrades the map — the surface
that is actually useful — to keep the wheel fed. Measured on device, not asserted.

## D7 — Hosting the crew layer on Explore

### D7.1 — The fork goes in `GroupRideFlowView`, not `GroupNavigateContainer`

*Revision 2 corrects revision 1's central instruction, which would have shipped the feature dead.*

There are two readers of `session.route`, and revision 1 named only the inner one:

- `GroupRideFlowView.swift:118` — `if session.route != nil { GroupNavigateContainer(...).task { ... } } else { dismissMessage("Couldn't load this ride's route.") }`
- `GroupNavigateContainer.swift:14` — `if let route = session.route { NavigateHUDView(...) } else { Color.clear }`

The outer guard fires first. An open ride reaching `.riding` takes its `else` and lands on the
error screen; `GroupNavigateContainer` is never constructed, and its `Color.clear` branch — the one
revision 1 said to replace — is unreachable in production.

**The fork is at `GroupRideFlowView.swift:118`**, and it must carry the `.task` that branch owns:

    didEnterRiding = true
    await session.beginLiveSession()

Without it, two failures compound. `didEnterRiding` stays false, so on host-end `content` falls
through to `endedLobbySurface` and tears down the HUD **mid-recording** — recording discarded,
summary lost, the exact ROH-81 failure D7 quotes itself preventing. And `beginLiveSession()` never
runs, so the crew never appears at all.

The single-`if` in `content` is unchanged: `.riding` and "rode, then ended" stay in one structural
branch. *Reviewers confirmed the fork's condition is safe*: `route` is `private(set)` with two
writers (`GroupRideSession.swift:145,178`), both of which run before `phase` leaves `.idle`, so it
cannot flip mid-ride and the `_ConditionalContent` branch is stable across `.riding → .ended`.

### D7.2 — `RideMapView`'s peer layer is a larger change than revision 1 admitted

Revision 1 said peers "return by composing the surviving `PeerAnnotations`," implying a small
addition. `PeerAnnotations` needs a `PeerFrame`, which only `PeerAnnotationDriver.frame(now:project:)`
produces, which needs a `project` closure over a live `MapProxy`, a `MapReader`, a `TimelineView`
clock, and `updateSet` wiring on `onAppear`/`onChange` — mirroring `NavigateHUDView.swift:285-323`.
ROH-105 D1 removed **all** of those from `RideMapView` by name, not just the four value parameters.
Only `peers`/`selfUserID`/`nameMap`/`selfProgress` genuinely stay deleted; ribbon splitting also
stays deleted, being route-based.

**`ribbonPieces` must be memoised before the `TimelineView` goes in.** `shouldAnimate` is true
whenever any peer is riding, so `RideMapView.body` re-evaluates ~30×/s for the whole crew ride,
and it contains `TrackRibbon.pieces(segments:)` — which copies every point of every segment — plus
an annotation group that maps them all again into `CLLocationCoordinate2D`
(`RideMapView.swift:32,82`). On navigate the equivalent polyline is a static route. On Explore it
is the **growing recorded track**: a two-hour ride at 1 Hz is ~7,200 points copied twice, 30 times
a second, on the MainActor, while recording. Cost grows with ride duration, so a five-minute device
pass sees nothing and hour two is a thermal problem. This is ROH-115's measurement, promoted from
"worth measuring" to a prerequisite.

`RideMapView.swift:6-9` ("solo by construction: group rides run through `NavigateHUDView`")
becomes false and is rewritten. ROH-105 named a stale doc comment on this exact type as its
reusable lesson.

### D7.3 — `CrewChrome` extraction

The crew chrome is an extension of `NavigateHUDView` reading `groupSession`,
`coordinator.stats.distanceMeters`, `settings.units` and `endRide()`. Three of those do not
transfer:

- **Self position.** D8.5 gives `PeerDistance` a coordinate-based mode, so `CrewChrome` needs
  `selfCoordinate: Coordinate?` on Explore where navigate passes a scalar. On Explore the only
  self coordinate is `gems?.riderCoordinate` — an optional on a lazily-built optional store. **The
  nil window before first fix must render "locating", never a default `(0,0)`**, which would put
  the crew 8,000 km away and pin every arrow to the rim.
- **`endRide()` differs.** Navigate's tears down guidance, stops speech and deactivates the audio
  session; Explore's is `coordinator.finish()`. The chrome takes an injected `onEndOwnRide`, and
  `finishOwnRideIfEnded`'s one-runloop deferral moves with it.
- **Confirmation collision.** `CrewChrome` owns the host/member confirmation. Explore already has
  `.alert("End ride?", isPresented: $showEndConfirm)` with two independent triggers (D8.1). Two
  presentations armed on the same view in the same tick — SwiftUI drops one silently, and which one
  it drops decides whether the crew is left. **One presentation source, selected by
  `groupSession != nil`.**

*Revision 2 corrects a description.* Revision 1 called the extracted piece a "roster button."
There is no button: `GroupRosterSheet` is an inline draggable panel whose only tap target is a
36 × 5 pt grab handle (`GroupRosterSheet.swift:66-71`). That is not a mid-ride target with gloves
on a vibrating mount, and it needs enlarging as part of this change since D4 relies on the roster
for `.awaiting` and dropped riders.

### D7.4 — `groupSink` attaches at `.task`, never at `init`

`RideSessionCoordinator.start` is guarded `guard !recorder.isRecording else { return .started }`
(`:149`), so a sink not supplied at the first `start` can never attach. Wiring
`groupSession?.locationSink` into the `State(initialValue:)` coordinator in `RideHUDView.init`
would capture the first init's value and silently fail. **The rider would publish no position:
their own wheel works perfectly while they are invisible on everyone else's** — symmetric-looking,
and unit-testable nowhere. `NavigateHUDView` gets this right at `.task` time
(`NavigateHUDView.swift:237`); Explore's `.task` currently passes `discoverySink:` and no
`groupSink:`, and both are defaulted-nil parameters on the same call, so omitting one compiles
clean and ships dead — the failure mode ROH-105 documented.

Adding `var groupSession: GroupRideSession? = nil` to the struct is otherwise safe: `@State`
identity is positional and the solo call site (`AuraApp.swift:108`) stays `RideHUDView()`.

### D7.5 — Placement

*Revision 2 corrects revision 1, which placed the wheel in an occupied slot.* Bottom-leading,
above the instrument panel, is exactly where `GroupRosterSheet` already sits on navigate
(`NavigateHUDView+Cockpit.swift:81-89`), and Explore's `ControlCluster` is taller than navigate's
(it keeps mark-spot). Three elements do not fit that row on an iPhone SE, against the known 29 pt
overspill at `RideHUDView.swift:303-311`.

The wheel goes **top-leading, below the back button**, and the top-overlay stack gains an explicit
arbiter — which it needs regardless, because `CrewChrome`'s toasts and status pills have no home on
Explore. Navigate tucks them under its turn card; Explore has no turn card, and already stacks the
gem peek card and the mark-spot toast on the same `.padding(.top, 60)` point
(`RideHUDView.swift:107,119`), with the detour overlay above. D8.4 keeps gems on, so without an
arbiter "Marcus left" draws under a gem card.

**Arbiter order (highest first):** detour turn card → crew membership toast → mark-spot toast →
gem peek card. Crew status pills (ending/reconnecting/end-failed) sit with the wheel, not in the
transient stack. Sizes are a device measurement.

## D8 — Behaviour

### D8.1 — Every exit from the cockpit must leave the crew

Revision 1 addressed one of three. All three raise the same alert and all three end in
`coordinator.finish()`:

- `ControlCluster(onEndRide:)` (`RideHUDView.swift:294`)
- `backTapped`'s above-floor branch (`:350`)
- the alert's own "End ride" button (`:137`)

**Sequence today:** rider on an Explore crew ride taps End → `coordinator.finish()` →
`finishedRide` → `router.showRideSummary` collapses the path → `GroupRideFlowView` leaves the stack
→ its `@State` session is released **at `phase == .riding`**. `leave()` was never called. The
server still lists the rider; they hold one of the 8 cap slots for the ride's life; peers see them
ghost then drop. `RideSession.stop()` never runs, so `subscription?.cancel()` never runs.

`NavigateHUDView` forks the End tap at `onEndTapped()` (`:334`). Explore gets the equivalent, and
it covers all three triggers via the single presentation source required by D7.3.

### D8.2 — Leaving must be observed to land

D8's one word "first" was load-bearing and unexamined. `leave()` → `finishRide(.memberLeave)` is
the **fire-and-forget** branch (`GroupRideSession.swift:379-416`): no re-entrancy guard, no
`pendingEnd`, and on timeout or throw it records *nothing at all*. Then `popToRoot()` destroys the
session and the evidence. Two back taps inside the 4 s `endTimeout` fire two concurrent
`leaveRide` calls and two pops. And if the leave is scoped to a `.task`, `withTimeout` propagates
cancellation into the operation (`Timeout.swift:8,46`), so tearing the view down kills the network
call mid-flight and the bare `catch` swallows it.

A crew-exit leave therefore uses the **waited-on** path (`.memberEnd` semantics: re-entrancy guard,
pending latch, retry) and runs in an unstructured `Task` that outlives the view. The rider is not
popped until it lands or fails visibly.

### D8.3 — Discarding with a live crew, and the silent host handoff

The discard path is one tap on the top-left chevron with no confirmation, plus an edge swipe
(`.swipeBackEnabled(canDiscard)`), and it is armed for the entire pre-roll huddle — everyone
stationary, below the 25 m floor — which on an open ride is the longest it will ever be.

`leave_ride` promotes the earliest joiner to host **silently**
(`0018_ride_ended_broadcast.sql:24-38`). So a host discarding during the huddle is dropped from
their own crew, lands on Home with no way back — the join code existed only on the lobby screen,
and nothing re-surfaces a code you created — while Priya becomes host and learns it from a 2.5 s
"Jamie left" chip. `reconcileFromStatus` then flips her `isHost` on the next foreground, and her
End control silently changes meaning from "leave the crew" to "end the ride for everyone."

This change adds: a confirmation when discarding with a live crew ("Leave the crew and discard this
ride?"); an explicit, non-transient handoff notice to a promoted host; and — because the host has
no way back — the join code surfaced somewhere outside the lobby. The last is the minimum;
re-entry is otherwise impossible.

### D8.4 — Gems stay on

Discovery is what Explore is for, and a crew has no more reason to suppress it than a solo rider.
`GemDiscoveryStore.isSuppressed` stays unwired, and the comment at `RideHUDView.swift:33-36`
claiming it exists for this surface is deleted — this design is the decision that retires it. The
cost is the top-overlay contention D7.5 arbitrates.

### D8.5 — `progressMeters` means something different, and four consumers read it

Revision 1 said "Navigate reads it; Explore ignores it." False — three shared helpers plus
`PeerDistance` read it, and the Explore path reuses all of them:

| Consumer | On an open ride |
| --- | --- |
| `GroupRosterViewData.rows` sort (`:29-35`) | orders the crew by **personal odometer**; whoever started earliest sits top all ride |
| `GroupMapDots` 8-rider trim (`:28`) | keeps "the leader (furthest along)" — an arbitrary rider survives |
| `PeerAnnotations.leaderID` (`:78,123`) | pins a persistent name tag to the biggest odometer |
| `PeerDistance.label` | "0.4 mi ahead" of someone who may be behind you |

On an open ride `progressMeters` is **a different quantity wearing the same name**. Each consumer
is told which it is: the roster sorts by straight-line distance, the trim keeps the **nearest**,
the leader tag is suppressed entirely (there is no leader on an open ride), and `PeerDistance`
takes a coordinate-based mode.

*Revision 2 corrects revision 1's characterisation of that last one.* Revision 1 called it "a mode
of one function," implying a flag. `PeerDistance.label(selfProgress:peer:isImperial:)` is a
formatter over a scalar; straight-line distance needs self's **coordinate**, which no caller on
that path has. It is a new input, a new signature, and a changed call graph up through
`GroupRosterViewData` and `CrewChrome`.

### D8.6 — The lobby must name the ride kind

D2.5's structural reuse is an engineering win and a guest-facing defect. The lobby is a guest's
only pre-ride surface, and after this change it renders identically whether they are about to be
navigated 8 km to a café or turned loose. Every crew ride that exists today has a destination, so
that is the expectation they arrive with.

One line under the header: "Open ride — no destination" or "Heading to Blue Bottle · 8 km".

### D8.7 — A guest who pockets the phone

There is no group-ride push anywhere in this codebase and ROH-15 is out of scope, so a guest who
locks their phone in the lobby has nothing on the lock screen. The lobby's liveness is a `.task` on
a foreground view; the only recovery is `GroupRideFlowView`'s `scenePhase` reconcile (`:32-36`). So
when they next look, the session reconciles to `.riding`, the cockpit mounts, and `RideHUDView`'s
`.task` **auto-starts recording right then** — their ride begins wherever they happen to be, with a
straight-line jump from the meeting point or several minutes missing.

Open rides make this likelier than route rides, since there is no "we roll at 10:00" structure.
This change does not add push (that is ROH-15), but it does stop the silent mis-start: entering
`.riding` from a background reconcile shows a "Ride started — start recording?" confirmation rather
than auto-starting. Naming it here so ROH-15 inherits the requirement rather than rediscovering it.

### D8.8 — Host end below the discard floor

`finishOwnRideIfEnded` calls `coordinator.finish()` unconditionally, which saves and pushes a
summary. Explore is the one HUD with a discard floor, precisely because a very short ride is not
worth a summary. A host ending twenty seconds after start would hand every guest a summary for
40 m. On this HUD the equivalent respects `RideBackOutGate.canDiscard`: below the floor the ride is
discarded and the rider returns Home.

### D8.9 — A join link tapped while riding

`AppRouter.handle(url:)` opens `guard !isRideActive` and **silently returns** (`:42`). The rider
taps, nothing happens, no explanation exists anywhere in the path. Given that "let's link up" is
usually said by people already riding, this is the most likely first contact with the feature.

The full fix — joining a crew without ending your ride — is **out of scope**, and D10 says why. In
this change the link stops vanishing: the code is stashed and surfaced with an explanation ("You're
recording a ride — join Jamie's crew when you finish?"), offered again on the ride summary.

## D9 — Why not navigate, and what the rider is told

The wheel would work on a navigate crew ride and is excluded. Navigate's roster already answers
"where is everyone" in the terms that matter there, and that HUD carries ROH-63 (nested
`NavigationStack` crash), ROH-81 (`@State` destroyed by a phase-driven rebuild), and a top-overlay
ordering bug that took a device pass to find. Adding a persistent overlay there in the same change
compounds two individually-manageable risks.

*Revision 2 adds the rider-facing half.* Riders do not think "Explore group ride" versus "navigate
group ride" — they think "group ride," and the wheel's absence on Saturday's destination ride will
read as a bug. Worse, the two rosters will say "0.4 mi ahead" (along-route) and "0.4 mi away"
(straight-line) in the same visual shape with different meanings. The roster header names which it
is showing, on both ride kinds. That is the minimum until the wheel ships on both.

## D10 — Mid-ride join is out of scope, and why

Filed as its own issue rather than absorbed here.

It is not a router change. `RideSessionCoordinator.start` early-returns once recording (`:149`),
and `groupSink` is only ever passed *to* `start` — so there is **no way to attach a group session
to a live recording today**. Mid-ride join needs a new coordinator entry point plus an answer to
what happens to the ride already being recorded (adopt it into the crew, or end and restart,
losing the split). That is a design of its own.

The `guard !isRideActive` is also deliberate: it stops a deep link yanking a recording rider out of
their ride. Removing it without the above does exactly that.

D8.9 fixes the silence in the meantime. The capability follows.

## Verification

**AuraCore:** bearing math against known pairs; fixed-ring radius mapping at the ring boundaries
and beyond 5 km; the radial-only declutter preserving bearing exactly; `RiderColorLatch` stability
across join, leave and rejoin, and self-exclusion; `PeerDistance` coordinate mode leaving route-ride
output unchanged; the roster sort, trim and leader-tag behaviour on an open ride (D8.5).

**AuraKit:** open-ride create; join with a nil route reaching `.lobby`; join with a present but
undecodable route still reaching `.routeUnavailable` **and** leaving the ride.

**Decoder (the test revision 1 lacked):** a JSON payload with `"route": null` through the real
`GroupRideRow`, asserting `routeData()` yields nil. This is the one that would have caught D2.1,
and it cannot run against the in-memory fake.

**pgTAP:** `create_ride` with `p_route` omitted, through the RPC rather than a direct insert;
joining a route-less ride; the client-capability gate rejecting an old client (D2.4).

**Device, two phones.** Per the repo rule, and specifically:

- The wheel points at the other phone. A 90° frame error compiles perfectly and passes every unit
  test, because the tests assert the math and the bug is in the frame.
- Heading staleness: start a detour mid-ride and confirm the wheel falls back to north-up rather
  than freezing at a plausible wrong offset (D4.4/D6).
- The crew stopped together (radial declutter, no bearing corruption) and spread across two rings.
- iPhone SE layout, against the known-tight vertical budget and the new top-overlay arbiter.
- A mid-ride join: no colour reshuffle, on both the wheel and the map dots (D5).
- All three cockpit exits leave the crew (D8.1), and a discard during the huddle warns first (D8.3).
- **Hour two.** The `TimelineView` × growing-track cost in D7.2 is invisible in a five-minute pass.

**The D1 kill criterion.** If the wheel does not beat an edge-of-viewport chevron from a bar mount,
it is cut and the destination-free ride ships without it.

## Out of scope

Mid-ride join (D10). Group-aware Live Activity (ROH-15), whose absence D8.7 partially mitigates.
The navigate wheel (D9). Changing how `progressMeters` is computed or transmitted — only how it is
interpreted. The route preview's "Ride together" entry, which keeps its current behaviour.
