# Group ride without a destination, and the crew compass (ROH-114) — design

Date: 2026-08-02
Issue: [ROH-114](https://linear.app/rohun/issue/ROH-114/group-ride-without-a-destination-group-explore-surface)
Status: draft, pre-review.
Related: ROH-105 (deleted the dead scaffolding this rebuilds), ROH-72 (built the rider palette
this reuses), ROH-15 (group-aware Live Activity, deliberately out of scope).

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

A host starts a crew ride with no destination. Guests join by code as they do today. Everyone
rides the Explore cockpit, sees the crew as coloured dots on the map, and sees a **crew compass**:
one wheel, one arrow per rider, each arrow's angle giving direction and its distance from the hub
giving range.

Scope is Explore only. See D9 for why navigate is excluded.

## D1 — Why a compass wheel and not just the map

The map already draws colour-coded peer dots with monograms, so the wheel has to justify itself.

It answers a question the map answers badly. To see a rider 3 km away you must zoom out until your
own position is a speck, and a rider outside the viewport is not merely small but absent — the map
gives no indication they exist off-screen. The wheel is fixed-size, always on, and never loses
anyone: a rider at 8 km pins to the rim rather than disappearing.

This justification is conditional. It holds only if the wheel is readable in a glance from a bar
mount at speed. If the device pass in Verification finds it is not, the honest outcome is to cut it
and ship the destination-free ride alone — which is independently valuable and is what ROH-114
actually asks for. The wheel is the larger and more speculative half of this change and should be
sequenced second so that failure is survivable.

## D2 — Removing the route requirement

Four mechanical changes.

**Migration.** `alter table public.rides alter column route drop not null;`. The existing
`check (pg_column_size(route) < 262144)` needs no edit: a check constraint is satisfied when its
expression is not false, and `pg_column_size` of a null jsonb is 1 in any case. Both readings pass.

**Seam.** `createRide(route: Data?)` on `GroupRideBackend`; `JoinedRide.route` becomes `Data?`.

**Session.** `GroupRideSession.create(route: Route?)`. `join(code:)` must distinguish three cases,
where today it collapses two:

| `joined.route` | Meaning | Phase |
| --- | --- | --- |
| nil | Open ride, by design | proceed (`.lobby`/`.riding`) |
| present, decodes | Route ride | proceed, as today |
| present, fails to decode | Corrupt payload | `.routeUnavailable`, leave the ride |

Collapsing rows 1 and 3 is the trap. If a decode failure silently produced an open ride, a
corrupted route would land the guest in an Explore cockpit with no destination and no error — a
data-loss bug wearing a feature's clothes. The distinction is `joined.route == nil`, checked
before the decode is attempted, and it is tested in both directions.

**Route enum.** `GroupRideEntry.create(Route?)`. Its `Hashable` conformance hashes `route?.id`;
two open-ride entries hash equal, which is correct — there is only ever one pending create.

**Untouched:** `GroupLobbyView` reads no route today. Join code, share link, live roster, and the
role-split CTA are all route-free. The lobby ships as-is, for both ride kinds. This is the single
largest de-risk in the change and was verified by reading the view, not assumed.

## D3 — Entry point

`AppRoute.groupRide(.create(nil))`, reached from a "Start a ride" secondary action on the existing
join screen (`GroupRideJoinView`). That screen is already the crew surface and already behind the
auth gate, so no new gate and no new route case.

Rejected: putting it on Home's Explore chip. That chip starts riding immediately today, and adding
a fork to it taxes every solo Explore launch — the common case — to serve the rare one.

Accepted cost: discoverability. A rider who has never opened the join screen will not find this. If
that proves to be the binding constraint after the device pass, promoting it to Home is a small
follow-up, and the reverse (demoting it from Home) would not be.

## D4 — The crew compass

Computation lives in AuraCore as `CrewCompassViewData`; the view lives in the app target. The
split follows this repo's standing rule that the app target has no unit test bundle
(`Aura/project.yml:123-124`), so anything with logic worth asserting goes in the package.

    CrewArrow {
      id: UUID, monogram: String, colorIndex: Int,
      relativeBearingDegrees: Double, distanceMeters: Double,
      normalizedRadius: Double, status: PeerStatus
    }

**Direction.** `PeerBearing.heading(from: self, to: peer)` minus device heading. This is the
convention `GuidanceController.recomputeArrow` already uses for the offline gem pointer
(`GuidanceController.swift:214-221`); up is where the rider is pointed. A second convention on the
same cockpit would be worse than either convention alone.

**Distance.** `Geo.distance`, formatted with `RideStatsFormatter.maneuverDistance` — the same
formatter the gem cards use, so units follow the rider's setting.

**Radius.** Log-scaled with a floor:

    normalizedRadius = log(1 + d / 50) / log(1 + dMax / 50)
    dMax = max(farthest visible peer, 400)

The 400 m floor is the important half. A crew stopped together at a light has a true `dMax` near
zero, and a scale that auto-ranged to it would blow a 20 m spread across the full wheel and make
the arrows swim. The floor pins the scale until the crew genuinely spreads out. Riders beyond
`dMax` pin to the rim.

**Stating the scale.** An auto-ranging wheel whose range is unstated is a lying instrument. One
faint label gives the current rim distance. `dMax` moves only when the farthest peer leaves the
current band by more than 20%, and no more than once every 5 seconds — hysteresis on both axes,
because a single unbounded rider would otherwise rescale the wheel continuously.

**Bunching.** `ClusterDeclutter` — written for colliding map dots, reused unchanged. This is the
common case, not the edge case: a crew riding together is a crew whose arrows overlap.

**Identity.** Coloured head plus monogram, styled from `PeerDotView`. Never colour alone: the
palette is five hues and the crew cap is eight (`0014_join_cap_lock.sql`), so past five riders the
monogram is the only discriminator. This is also why the palette cannot simply be widened — its
five entries are the result of a deuteranopia-distinctness constraint gated by `RiderPaletteTests`.

**Degradation.** Above five riders the wheel shows the four nearest plus a "+N" chip at the rim.
Eight arrows on one wheel is not a glanceable instrument, and silently rendering all eight would
fail D1's own justification. The roster sheet remains the complete list.

**No compass.** When heading is unavailable or uncalibrated, the wheel switches to north-up and
shows an N marker. An arrow that rotates confidently in an unknown frame is worse than one that
declares its frame.

**Dropped peers.** Ghosted at last known bearing and distance, matching the map dot treatment.
Consistency with the map matters more here than freshness, because the two are on screen together.

## D5 — Colour stability

`PeerPalette.assign` takes the current set of userIDs and de-collides by probing in sorted-UUID
order. A rider joining mid-ride whose UUID sorts early can take a slot an existing rider held,
pushing that rider to a different hue. On map dots this is a shrug. On a wheel where the rider has
spent twenty minutes learning that cyan is Marcus, it is a betrayal of the only identity cue that
works at a glance.

`RiderColorLatch`, session-owned: a rider's index is assigned on first sight and never recomputed
for the ride's duration. Joiners take the first free index; past five they wrap and rely on the
monogram. A rider who leaves and rejoins keeps their colour, because the latch is keyed by userID
and is not cleared on departure.

This also fixes the same reshuffle on today's navigate map dots. That is a real if minor bug fix
riding along, and it is called out here rather than smuggled in.

## D6 — One heading source

`CompassHeadingProvider.headings()` stores `manager` and `delegate` as instance state
(`CompassHeadingProvider.swift:30-35`) and its `onTermination` nils them
(`CompassHeadingProvider.swift:38-43`). Two concurrent `headings()` calls on one instance
therefore clobber each other: the second overwrites the first's manager, and the first stream's
termination tears down the second's.

Both the gem detour's offline pointer and the crew compass want the compass, and on an Explore
crew ride both can be live at once. Giving the wheel its own `CompassHeadingProvider()` instance
would avoid the clobber but run two `CLLocationManager`s updating heading simultaneously.

The wheel takes its heading from a single shared source that multicasts to both consumers. Whether
that is a small multicast wrapper or a fix inside `CompassHeadingProvider` is an implementation
choice for the plan; the requirement is one `CLLocationManager` and no cross-consumer teardown.

The pre-existing single-consumer assumption is a latent bug today, not one this change introduces
— nothing currently subscribes twice. It is named here because this change is what makes it
reachable.

## D7 — Hosting the crew layer on Explore

`RideHUDView` gains an optional `groupSession: GroupRideSession?`, mirroring `NavigateHUDView`.

**The crew chrome must be extracted.** Roster button, membership toasts, status pills
(ending/reconnecting/end-failed) and the end/leave alert live in
`NavigateHUDView+GroupCrew.swift` as an **extension of `NavigateHUDView`**, so none of it is
reachable from another view as written. It moves to a `CrewChrome` view/modifier both HUDs apply.
This is refactoring in service of the change, not opportunistic cleanup: without it the Explore
cockpit would need a second copy of every pill.

**Peer dots return to `RideMapView` by composing the surviving `PeerAnnotations`**, which
`NavigateHUDView` still uses. ROH-105's deleted parameters are not resurrected. Ribbon splitting
stays deleted — it is progress-along-route and has no meaning without a route.

**Container fork.** `GroupNavigateContainer` currently renders `NavigateHUDView` when
`session.route` is non-nil and `Color.clear` otherwise. That `Color.clear` branch becomes the
Explore cockpit: nil route now means open ride rather than an unreachable error state.

**Preserve the single-`if` structure in `GroupRideFlowView`.** `content` routes `.riding` and
"rode, then ended" through one structural branch, because SwiftUI gives each `switch` case its own
`_ConditionalContent` identity and splitting them destroys the HUD's `@State` on the
`.riding → .ended` transition — the ROH-81 device finding, documented at
`GroupRideFlowView.swift:39-49`. Adding a route-kind fork must not reintroduce that split. The
fork belongs *inside* the riding branch, below the phase decision.

**Placement.** Bottom-leading, above the instrument panel, opposite `ControlCluster`. The top of
this HUD is already contested by the gem peek card, the detour overlay and the mark-spot toast,
which arbitrate among themselves; the wheel is persistent and must not join a queue of transients.

Vertical budget on that HUD is already known-tight: `RideHUDView.swift:303-311` records a 29 pt
overspill that took a device pass to find, on an iPhone SE. The wheel's size is a device
measurement, not a Preview one.

## D8 — Behaviour details

**Roster distance.** `PeerDistance` gains an open-ride mode returning straight-line distance and
bearing. It does not change meaning for route rides — navigate's roster copy is untouched. The
existing along-route wording is correct there and wrong here, and one function serving both must
be told which it is rather than inferring it.

**Back-out with a crew.** The Explore back button discards a below-floor ride outright
(`RideHUDView.backTapped`). With a crew, discarding must also leave the crew, or the rider vanishes
from everyone's wheel while the server still lists them as a member. Discard routes through
`session.leave()` first.

**Gems stay on.** Discovery is what Explore is for, and a crew has no more reason to suppress it
than a solo rider. `GemDiscoveryStore.isSuppressed` stays unwired, and the comment at
`RideHUDView.swift:33-36` claiming it exists for this surface is deleted — this design is the
decision that retires it.

**`progressMeters` keeps flowing.** Navigate reads it; Explore ignores it. Removing it from the
wire for open rides would fork the transport for no gain.

**Host ends / member leaves.** Unchanged from today's model. The Explore cockpit needs the
`finishOwnRideIfEnded` equivalent, including its one-runloop deferral between the chrome dissolve
and the summary presentation.

## D9 — Why not navigate too

The wheel would work on a navigate crew ride, and it is deliberately excluded.

Navigate's roster already answers "where is everyone" in the terms that matter there — along-route
ahead and behind — so the wheel adds a second, weaker answer to a question already answered. The
navigate HUD is also the app's most failure-prone surface: ROH-63 (nested `NavigationStack` crash),
ROH-81 (`@State` destroyed by a phase-driven rebuild), and a top-overlay ordering bug that took a
device pass to find. Adding a persistent overlay there in the same change compounds two risks that
are individually manageable.

Follow-up issue, after the Explore version has been ridden.

## Verification

**AuraCore:** bearing math against known pairs; radius scaling including the floor and the
rescale hysteresis on both axes; the no-heading north-up fallback; `RiderColorLatch` stability
across join, leave and rejoin; `PeerDistance` open-ride mode leaving route-ride output unchanged.

**AuraKit:** open-ride create; join with a nil route reaching `.lobby`; join with an
undecodable-but-present route still reaching `.routeUnavailable` and leaving the ride.

**pgTAP:** the nullable-route migration; joining a route-less ride.

**Device, two phones.** Non-negotiable per the repo rule, and specifically:

- The wheel points at the other phone. A compass that is 90° out compiles perfectly and passes
  every unit test, because the tests assert the math and the bug is in the frame.
- The wheel with the crew stopped together (floor behaviour) and spread out (rescale behaviour).
- iPhone SE layout, against the known-tight vertical budget in D7.
- A mid-ride join, confirming no colour reshuffle (D5).
- Host end and member leave from the Explore cockpit.

**The D1 kill criterion.** If the wheel is not readable at a glance from a bar mount, it is cut
and the destination-free ride ships without it. Deciding that after the device pass is the intended
outcome, not a failure of the design.

## Out of scope

Group-aware Live Activity (ROH-15). The navigate wheel (D9). Widening the rider palette, which is
constrained by a colour-vision requirement rather than by taste. Any change to how `progressMeters`
is computed or transmitted.
