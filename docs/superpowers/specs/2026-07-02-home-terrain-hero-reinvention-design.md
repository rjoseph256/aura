# Interface & Feel — Chunk 1: Home & dashboard reinvention

**Date:** 2026-07-02
**Status:** Revised after adversarial spec review (two reviewers: product/UX and iOS/Mapbox).
Pending final user sign-off.
**Linear:** ROH-43 (epic: Interface & Feel)
**Depends on:** the locked Chunk 0 direction
(`docs/superpowers/specs/2026-07-02-interface-and-feel-visual-direction-design.md`) and,
as a hard predecessor, the custom Mapbox terrain style (ROH-6).

## Goal

Rebuild Home to do three jobs: get a rider moving fast, motivate them, and be a beautiful
terrain-forward first impression. The layout is rethought, and it is the first surface to
carry the locked Terrain direction, whose rule is that the identity lives in the map.

Today's Home (`Aura/Sources/Plan/PlanView.swift`) is a flat-background column with no map
and no terrain. This chunk makes the terrain the surface.

## Decisions from review (read these first)

The adversarial review changed four load-bearing things. They are decisions now, not open
questions:

1. **The backdrop is a non-interactive rendered terrain image, not a live map.** A live
   Mapbox map on Home would mean two Metal renderers the moment a route preview is pushed
   (Home's, retained beneath, plus the preview's), which regresses the single-hoisted-map
   goal (ROH-7) that `RootView` already protects, and it would fight the pull-up sheet's
   drag gestures. So Home renders a cached terrain image (see Backdrop below). This keeps one
   live map in the app, frees the sheet gestures, and makes contrast and VoiceOver tractable.
2. **Primary action is planning a destination.** The "Where to?" destination entry is the
   single emphasized launch action. Explore (start a no-destination ride) and Join a ride are
   quiet secondaries. There is exactly one dominant launch element, not three co-equal CTAs.
3. **Motivation is always visible, never gesture-gated.** An always-visible motivational hook
   (a specific sentence with a number, not just a ring) rides in the sheet's peek header. The
   sheet's default detent is peek, showing that hook plus the last ride.
4. **ROH-6 is a hard predecessor.** Home cannot hit its "real styled terrain" gate until the
   terrain style ships.

## The layout: Terrain hero canvas

- **Backdrop.** A non-interactive, muted terrain image framed on the rider's area, with top
  and bottom scrims so floating content stays legible. Rendered by a new
  `TerrainSnapshotProvider` (Mapbox `Snapshotter` to a cached `UIImage`, keyed on the rider's
  coordinate, with a curated default region when location is unavailable, a placeholder while
  rendering, and Reduce-Transparency awareness). It is not a live `Map`, so it never pans and
  never adds a second renderer. Exposed to VoiceOver as one ignored element under a single
  labeled wrapper ("Map of your area, [place]").
- **Top: identity.** Greeting plus a small "Aura" wordmark, non-interactive. Nothing tappable
  lives in the top corners (reachability).
- **Primary launch: "Where to?"** The emphasized destination entry, in the reachable lower
  band. It is the one dominant launch action (lime-accented). Tapping it expands the search
  overlay (see Search overlay below).
- **Secondary launch: Explore and Join a ride.** Quiet secondary controls near the primary,
  visually demoted (no lime fill; lime stays on the primary and the route line). Explore
  starts a no-destination ride; Join a ride opens the join flow.
- **Motivation hook (always visible).** In the sheet's peek header: a specific sentence with a
  number ("2 rides to your weekly goal", "18.4 mi last ride, Tue") paired with a compact
  progress ring. This is the motivation job, and it renders with no gesture.
- **Pull-up sheet: dashboard depth.** A draggable sheet with detents (peek, half, full). Peek
  shows the motivation hook plus the last-ride card (the terrain-embossed mini card that
  foreshadows the Chunk 3 summary medal). Half and full reveal recents and saved places.

## Component decomposition

- **Always-mounted container** (`PlanView` reworked, or a new `HomeView`): owns the backdrop,
  the floating launch band, the search overlay, the sheet, and all state and subscriptions.
- **New views:** `TerrainSnapshotProvider` and a `HomeBackdrop` that shows its image;
  `WeeklyGlance` (the motivation hook: sentence plus compact ring); `HomeSheet` (draggable,
  detented) hosting the last-ride, recents, and saved content; and a `SearchOverlay` container
  (see below).
- **Reuse, restyled:** `DestinationSearchView`'s field and results (rehosted, see below),
  `LastRideCard` (restyled into the embossed mini card, drawn with the map-free `RouteThumbnail`
  Canvas, not a live map), `SavedPlaceRow`, `RecentRow`, and `CTAButtonStyle`.
- **Unchanged data model wiring:** `RideStore.summaries()`, `SavedPlacesStore`, `AppRouter`
  routing and recents. See State ownership for how it is kept intact.

## Search overlay (not "unchanged")

The current `DestinationSearchView` is a field plus an inline results list, and today
PlanView hides its dashboard when the query is non-empty. As a floating primary in this
layout, it becomes an explicit expand/collapse container:

- A collapsed "Where to?" affordance in the launch band.
- On tap: focus the field (`@FocusState`), dim the backdrop under a scrim, and present results
  as an overlay above the sheet with correct z-order.
- Explicit keyboard avoidance for a field that is not pinned to the bottom (measure the
  keyboard, inset the results).
- Expanding search suppresses or hides the sheet so results and sheet content never stack.
- On pick or dismiss: clear the query, collapse, un-dim, and restore the sheet.

The field's search behavior is reused; the layout and the expand/collapse state machine are new.

## State ownership (keep the wiring intact)

The reviewer flagged real breakage risk in re-decomposing PlanView. Rules:

- `.task { loadRides() }` and `.onChange(of: rideStore.syncRevision)` live on the
  always-mounted container, never on a detent-conditional subview, so a CloudKit-merged ride
  still refreshes the glance and last-ride while the sheet is at peek.
- All `@State` (`query`, `summaries`, `showJoinRide`, `renameTarget`, `renameText`) is hoisted
  to the container and passed down as bindings.
- The Join flow is presented from the container or pushed on the nav stack, not from inside the
  drag sheet (two nested sheet concepts conflict).
- The rename alert is anchored on the container, since the rows that trigger it now live in the
  sheet.
- Verification: after a simulated `syncRevision` bump, the glance and last-ride update with the
  sheet at peek.

## The Explore rename

Rename the no-destination mode from "Free ride" to "Explore" across every user-facing string,
landed atomically. The in-ride copy is unambiguous about recording: the pre-start HUD reads
"Start ride" (or "Ready to ride"), not "Start exploring"; "Explore" labels the mode on Home
and in history, but the moment a ride is recording, the copy says so.

The inventory is grep-driven, not a hand list (the hand list already missed one). Change every
literal "Free ride" / "Free Ride" and every string derived from `.freeRide`:

- Home CTA (`PlanView`): "Explore".
- Pre-start HUD (`RideHUDView.swift:70`): "Start ride".
- History (`HistoryView`): the ride-kind label and the empty-state copy.
- Last-ride card: both the kind label and the hardcoded title fallback (`LastRideCard.swift:81`).
- Live Activity: any label derived from `RideActivityAttributes` `.freeRide`, and the share card
  if it surfaces the term.

Internal identifiers stay frozen: the `.freeRide` enum cases, the persisted `Ride.Kind` raw
value "freeRide" (read back with `?? .freeRide` in `RideMapper`), the `aura://` deep link, and
`AppRoute`. The acceptance test greps that no user-facing surface renders "Free ride".

## States

- **First run** is its own composition, not the populated layout with empty strings: an
  on-brand, purpose-framed location permission ask ("Aura needs your location to map your
  hills"), a deliberately beautiful curated default terrain clearly presented as a sample, and
  one unmistakable "Plan your first ride" primary. It gets its own device screenshot as an
  acceptance gate.
- **No location permission** (returning user): the backdrop uses the curated default region;
  search and the launch controls still work.
- **Searching:** the overlay behavior above.
- **Loading:** the backdrop shows its placeholder and swaps in the rendered image without a
  flash; the glance and sheet show quiet placeholders, not spinners on a bare screen.

## Motion

Reduce-Motion guarded with a fully static fallback (no residual drift), via emil-design-eng and
swiftui-animation:

- A one-time settle on the backdrop image on appear (a gentle eased scale/opacity), never a
  continuous idle parallax.
- Sheet drag with rubber-band detents.
- A staggered content reveal on first appear, consistent with the ride summary.
- The weekly ring arc-fill, retuned.

## Legibility and accessibility

- The launch controls sit on a calm, near-opaque plate, not just a gradient scrim, so the
  primary action is scannable in under a second in sunlight (contrast compliance makes text
  readable; a calm plate makes it findable). The dramatic terrain stays in the framed negative
  space where nothing competes.
- Every floating text element meets at least 4.5 to 1; the terrain is never the direct
  background of body text.
- VoiceOver sort priority: primary launch, then the motivation hook, then secondary actions,
  then the backdrop as one ignored element. The primary action comes early in traversal.
- Dynamic Type: an explicit AX5 acceptance test with the sheet at each detent, since a
  fixed-region floating layout is where reflow clips.
- Reduce Transparency and Increase Contrast: floating surfaces go opaque and scrims strengthen,
  reusing `AuraTheme.prefersOpaqueSurface()` and `mapScrim()`.

## Performance

One live map in the app is preserved: Home's backdrop is a rendered image, so pushing a route
preview still means a single live renderer, consistent with ROH-7. The snapshot render is
async and cached to disk; the settle animation is one-shot. Battery and thermals on Home stay
flat because nothing animates or renders continuously.

## Polish and craft bar (acceptance gates)

Home does not ship until it clears these. Polish is a requirement.

- The real styled terrain image (ROH-6 rendered), not a placeholder fill.
- Saira Condensed numerals for ride stats; SF Pro Rounded chrome; spacing tuned on the
  `AuraTheme` scale.
- Frosted materials that degrade honestly (opaque fallbacks), with text on opaque plates.
- Motion reads as intentional and eased, verified on device, static Reduce-Motion fallback
  confirmed.
- The signature-moment thread is visible (last-ride card foreshadows the summary medal).
- The motivation hook renders with no gesture (explicit gate).
- The primary action is identifiable in under one second on device, in sunlight (explicit gate).
- First run has its own verified composition.
- Passes the slop test: no hero-metric template, no decorative-only glass, no card grid, no
  eyebrows.
- Device-first verification on the real iPhone through the tunnel, in real light; then an
  `impeccable`-judgment critique pass, an `emil-design-eng` motion review, and the whole-branch
  review on the most capable model.

## Scope

In scope: the Home surface, the `TerrainSnapshotProvider`, the search overlay, the app-wide
Explore rename, and the states above. ROH-6 is a hard predecessor built first. Out of scope:
the navigate cockpit (Chunk 2) and the full redesign of other surfaces (Chunk 3), beyond the
rename sweep and the shared `TerrainSnapshotProvider` those chunks may reuse.

## Open questions (small, for the plan)

1. The exact form of the weekly glance ring paired with the hook sentence.
2. The `Snapshotter` cache invalidation policy (how far the rider moves before a re-render).

## Verification

- Device-first: Home on the real iPhone in bright light; terrain image plus the primary
  action legible and findable in under a second; search overlay, both secondaries, and the
  sheet detents working; Dynamic Type at AX5 and VoiceOver order confirmed; Reduce Motion and
  Reduce Transparency fallbacks confirmed; first-run composition confirmed.
- A `syncRevision` refetch test (glance and last-ride update with the sheet at peek).
- A grep-based test that no user-facing surface renders "Free ride".
- Package tests green; the app builds; SwiftLint strict.
