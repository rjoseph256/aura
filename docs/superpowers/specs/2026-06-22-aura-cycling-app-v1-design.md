# Aura (working name) — iOS Cycling App · v1 Design Spec

- **Date:** 2026-06-22
- **Status:** Approved for planning
- **Working codename:** "Aura" (placeholder — public name TBD; not committed)
- **Platform:** iOS (native)
- **Author context:** Built first for the author and a small friend group in the Pittsburgh, PA area.

---

## 1. Overview & positioning

A native iOS cycling app for getting around Pittsburgh on bike-friendly routes, with a glanceable, handlebar-mounted **RIDE-mode HUD** as its core experience. It serves two everyday uses for the initial users: **short commutes** and **fun trail/path rides with friends** — including the recurring "let's bike to an activity or a brewery" trip.

**Target rider (v1):** a blend of the everyday/commuter cyclist (A) and the recreational trail/path explorer (C) — *not* the hardcore fitness/road-training rider. The first users are the author and friends.

**Market wedge:** Existing apps each own one slice — Strava (social/segments, weak navigation), Komoot (route discovery, increasingly paywalled, no live voice), Ride with GPS (route library + live tracking, no comms), Garmin/Wahoo (hardware HUDs), Apple/Google Maps (basic cycling nav, no depth). **No one owns a HUD-first navigation experience that's pleasant for casual social riders and grows into live group rides + in-ride voice.** That is the long-term opportunity this product is architected toward.

---

## 2. Phased roadmap (context for v1 scope)

| Phase | Theme | Summary |
|-------|-------|---------|
| **1 — v1 (this spec)** | Ride with it daily | Solo: bike-aware route planning + the live RIDE-mode HUD + lightweight ride history. |
| 2 — Ride together | Create/join a ride session, shared destination nav, every rider's live location on the map. |
| 3 — Talk while riding | Walkie-talkie / push-to-talk voice within a session. |
| 4+ — Platform / dream state | Sensors (HR/power), Apple Watch, ride-type flexibility, Strava export, discovery, etc. |

**Architectural principle:** v1 is deliberately focused, but the data model and routing layer are designed so Phase 2/3 can be added without reshaping the core. A `Ride` is a first-class object that a future `RideSession` can wrap.

---

## 3. v1 scope — feature set

Two ways to ride: **Navigate** (to a destination) and **Free ride** (no destination, just cruise + record). Both end in RIDE mode and produce a ride summary.

1. **Home / Plan**
   - Map centered on the rider showing nearby bike paths & trails.
   - Search a destination: POI (e.g., breweries), address, or **drop a pin**.
   - **Saved places** (e.g., Home, favorite breweries/trailheads).
   - **Free ride** entry (start riding with no set destination).
   - Recent rides shortcut.
2. **Route preview** (Navigate flow)
   - Up to **3 bike-aware route options**: **Most paths · Fastest · Flattest**.
   - Each shows distance / estimated time / elevation gain, drawn on the map.
   - "Start RIDE" begins navigation.
   - **v1 generation note:** Mapbox Directions' cycling profile returns a primary route plus *alternatives*, not three named profiles. For v1 we request alternatives and **label/rank them post-hoc** by path-share and elevation gain to surface "Most paths" / "Fastest" / "Flattest" (some trips may yield fewer than 3 meaningfully distinct options). True profile-tuned routing arrives with the deferred Valhalla/BRouter swap. Planning should confirm this approach rather than assume native multi-profile support.
3. **RIDE mode** — the adaptive HUD (see §5).
4. **Ride summary**
   - Route/track map, distance, moving time, average & max speed, elevation gained.
   - Shareable summary card.
5. **History**
   - List of past rides (date, distance, duration) → tap into the summary.
6. **Settings**
   - Units, voice on/off, map style, **offline map region downloads**, location permissions, and required **OSM / BikePGH attribution**.

---

## 4. Architecture & stack (decided)

- **App:** Native **Swift + SwiftUI**. Chosen for best battery/sensor/background-location/CarPlay access with no cross-platform layer between the app and Core Location.
- **Map + Navigation:** **Mapbox Navigation SDK v3 for iOS** (GA). Provides map rendering, turn-by-turn, voice guidance, offline tiles, live rerouting, continuous alternatives, and CarPlay support by default. Free tier comfortably covers a friend-group user base. (Open-source alternative considered and deferred: MapLibre + maplibre-navigation-ios — free/no-lock-in but materially more engineering.)
- **Routing:** Behind a **swappable `RoutingProvider` interface**.
  - **v1:** Mapbox Directions **cycling profile** (fastest path to a working product).
  - **Future-ready:** self-hosted **Valhalla** or **BRouter** — both elevation-aware and tunable to prefer paths/trails/low-traffic streets (important for Pittsburgh's hills). **OSRM is ruled out** (only major open-source engine without elevation support).
- **Map data:** **OpenStreetMap base** + Pittsburgh's official **BikePGH** trail dataset to fill/QA local trails (GAP, Three Rivers Heritage, Montour, Eliza Furnace).
- **Storage:** **Local-first** — rides/routes/places in **SwiftData**, optional **iCloud/CloudKit** sync. No backend server in v1.
- **Future (wired for, not built):** Phase 2 backend = **Supabase** (Auth · Postgres · Realtime) for sessions + live location. Phase 3 voice = Apple **Push-to-Talk** framework (the sanctioned walkie-talkie API) + **LiveKit/WebRTC** for the audio channel.

### 4.1 Licensing constraints (must honor)
- **OSM attribution is mandatory** in the shipped app ("Map data © OpenStreetMap contributors", linked to the copyright/ODbL page).
- A rendered map is a "Produced Work" under ODbL and does **not** trigger share-alike. **However**, if OSM is merged with other data into a **distributed routing/trail database**, that derivative database inherits ODbL share-alike. **Mitigation:** keep any proprietary data isolated from the OSM-derived database, or keep that database releasable.
- **BikePGH** dataset is **CC-BY** (commercial use OK with attribution; no share-alike). Note the open data layer may lag the newest infrastructure (layer dated 2017/2019 vs. consumer map current to 2025) — treat as supplementary/QA, not sole source of truth.

---

## 5. RIDE-mode HUD spec (direction C — adaptive cockpit)

Dark, high-contrast, large-type, glanceable while handlebar-mounted in sunlight. It reprioritizes automatically rather than requiring manual mode-switching.

- **Cruising state** (default while riding, esp. open trail): map-forward; persistent **speed rail** showing current speed + distance remaining + ETA; route line; current path/street name.
- **Approaching a maneuver** (Navigate): the **turn card** surfaces and grows — large directional arrow, distance-to-turn, target street/path name — accompanied by a voice cue.
- **Free-ride state** (no destination): no turn card; shows speed, ride distance, duration, elevation, and the live track on the map.
- **Persistent controls:** recenter, mute voice, end ride.
- **Visual language:** the dark "instrument cluster" surface (the Beacon/Aura cockpit aesthetic), distinct from the warmer brand chrome elsewhere in the app.

---

## 6. Data model (extensible toward group rides)

- **`Place`** — `id`, `name`, `coordinate`, `category` (brewery / trailhead / address / custom), `isSaved`.
- **`Route`** — `id`, `origin`, `destination`, `waypoints[]`, `geometry`, `profile` (mostPaths / fastest / flattest), `distance`, `estimatedDuration`, `elevationGain`.
- **`Ride`** — `id`, `type` (navigate / freeRide), `startedAt`, `endedAt`, `track` (recorded geometry), `distance`, `movingTime`, `avgSpeed`, `maxSpeed`, `elevationGain`, optional `routeId`, optional `destinationPlaceId`.
- **Future (Phase 2, not built in v1):** `RideSession` (`id`, `hostUserId`, `participants[]`, `sharedRouteId`, `status`) and `Participant` (`userId`, `liveLocation`) — designed to wrap an existing `Ride` without reshaping it.

---

## 7. Defaults (approved)

- **Units:** imperial (mph / mi / ft).
- **Offline maps:** on; downloadable Pittsburgh region for low-signal trail areas.
- **Voice guidance:** on by default, mutable.
- **Map style:** dark (brand fit + battery).
- **Minimum iOS:** 17+ (required for SwiftData).
- **Destination search:** Mapbox POI search + saved places + drop-pin.

---

## 8. Error & edge handling

- **Weak/lost GPS on trails:** show a "GPS weak" indicator; retain last-known position; recover gracefully.
- **Off-route:** automatic reroute (Mapbox Nav) with a subtle, non-jarring cue.
- **No connectivity on trails:** v1 guarantees **offline map *display*** via downloaded region tiles, so the rider always sees the map and their position/track. **Offline *routing*** (computing a new route with no signal) is a stretch goal for v1 — Mapbox Nav SDK v3 supports it, but planning should decide whether v1 ships offline routing or only offline display + cached active-route guidance. If a route cannot be computed offline, inform the rider clearly.
- **Low battery:** optional battery-saver (dim screen, reduce map detail); follow Apple guidance — lower `desiredAccuracy` from the default `best` and stop location updates when not actively navigating.
- **Location permission denied:** clear explainer + deep link to Settings.
- **Sunlight legibility:** high-contrast dark HUD, large type (a design requirement, not an afterthought).

---

## 9. Testing approach

- **TDD throughout** (tests before implementation).
- **Unit tests:** `RoutingProvider` adapter, ride-stat math (distance/elevation aggregation), unit conversions, route-profile selection.
- **HUD snapshot tests:** across states — cruising, approaching-turn, free-ride, GPS-lost, low-battery.
- **GPX-playback harness:** feed recorded GPS tracks into the location manager to simulate rides at the desk — exercises RIDE mode without physically biking, and doubles as a dev/demo tool.

---

## 10. Out of scope for v1 (deliberate — YAGNI)

Group rides, live location sharing, in-ride voice, accounts/backend, HR/power sensors, Apple Watch, Android, social feed/discovery, Strava export. All deferred to Phase 2+.

---

## 11. Open items (not blocking v1 planning)

- **Public product name:** "Aura" is a working codename only (too crowded: Aura security app, Aura frames, Aura meditation). A dedicated naming pass (with App Store / domain / trademark checks) happens before launch. Candidates to explore live in the aurora/glow/light/flow/motion family.
- **Routing quality validation:** confirm Mapbox cycling-profile route quality on real Pittsburgh hills/trails; if insufficient, the swappable interface lets us move to self-hosted Valhalla/BRouter.
- **Brand identity build:** direction is **Aura** (deep near-black base; cyan → violet → pink aurora gradient; airy light wordmark; "flow state"). Full identity system + UI to be produced during implementation using the dedicated design skills (`brandkit`, `impeccable`).
- **Phase 2/3 infra (Supabase Realtime, Apple Push-to-Talk, LiveKit)** were not fact-verified in research — re-research before Phase 2 design.

---

## 12. Research provenance

Technical decisions in §4 (map data, routing engine, iOS stack, background-location strategy) are backed by a deep-research pass (2026-06-22): 24 sources fetched, 25 claims confirmed via 3-vote adversarial verification, 0 killed. Key sources: OSM Foundation licensing FAQ, Hochmair/Zielstra/Neis 2015 (OSM vs Google bike coverage), WPRDC/BikePGH dataset, GIS-OPS routing-engine comparison, Mapbox iOS Navigation SDK docs, Apple Energy Efficiency Guide. The real-time/voice, competitive-landscape, and naming angles did **not** produce verified claims and are treated as informed judgment / open items.
