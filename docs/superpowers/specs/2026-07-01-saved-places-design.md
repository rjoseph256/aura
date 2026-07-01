# Saved places: design

**Goal:** A rider saves a destination once (Home or a favorite) and from then on
reaches it in two taps from the plan screen, on every device signed into their
iCloud account. This closes one of the two v1-spec promises that never shipped
(spec section 1: "Saved places (e.g., Home, favorite breweries/trailheads)";
section 7 default: "Destination search: Mapbox POI search + saved places +
drop-pin").

**Status:** approved design (built autonomously, revised through a three-reviewer
adversarial pass), ready to plan.

## Context

The 2026-07-01 roadmap consolidation surfaced saved places as unbuilt v1 debt.
It is scheduled ahead of the group-ride polish tail because it does not depend
on the pending two-device verification, and ahead of the share card because it
touches the daily plan-a-ride loop rather than the post-ride moment.

The architecture is the usual three compiled layers plus the widget extension
(untouched here): pure `AuraCore`, observable `AuraKit` (both build on the macOS
CI host), and the `Aura` app target with the Mapbox implementations.

### Current state, confirmed in code

- `Place` (`AuraCore/Sources/AuraCore/Models/Place.swift`) is `Identifiable,
  Codable, Equatable, Sendable` with `id: UUID`, `name`, `coordinate`,
  `category` (`.brewery/.trailhead/.address/.custom`), and a dormant
  `isSaved: Bool` that nothing ever sets true. Every search pick and every
  `aura://preview` deep link mints a `Place` with a fresh `UUID`
  (`DestinationSearchView.swift:145-172`, `DeepLink.swift:43-45`), so identity
  for "is this already saved" can never rest on `Place.id` alone.
- Destination search (`Aura/Sources/Plan/DestinationSearchView.swift`) is the
  Mapbox `PlaceAutocomplete` SDK, unabstracted, instantiated in exactly one
  place (`PlanView.swift:30`). It renders nothing below the field when the
  query is empty (`if !query.isEmpty`, line 69) and fetches Mapbox only at two
  or more characters (line 108); there is no focus tracking. `PlanView` shows
  the dashboard exactly when the query is empty (line 36), so at empty query
  the dashboard is already on screen below the field.
- The coordinate a pick carries comes from either `suggestion.coordinate` or
  the network-resolved `resolved.coordinate` for the same POI on different
  days, and `Coordinate` is bitwise-`Equatable` `Double`s. This repo already
  removed one Double-equality correlation as fragile (the `RouteRanker`
  `sourceIndex` fix, PR #16).
- Recents (`Aura/Sources/App/AppRouter.swift`) are `[Place]` JSON in
  `UserDefaults`, most-recent-first, de-duped by name+coordinate, capped at 8,
  device-local. Every pick, saved or not, flows through `router.remember`, so
  a frequently used saved place will also sit near the top of Recents.
  `PlanView` renders recents as `RecentRow`s in a `surface` group with
  `Radius.lg` and hairline dividers inside a `ScrollView`+`VStack` (not a
  `List`, so `.swipeActions` are unavailable); the section hides when empty.
  The join and free-ride CTAs are pinned outside the ScrollView and never
  move; the scroll order above them is weekly ring, last-ride card, Recents.
- Ride persistence is SwiftData: `RideRecord` behind the frozen V1→V2
  `RideMigrationPlan`, in a container configured with
  `cloudKitDatabase: .private("iCloud.com.rohunjoseph.aura")`
  (`RideStore.swift:49`). The iCloud-sync work (PR #21) left two facts this
  design leans on: a container-wide `NSPersistentStoreRemoteChange` observer
  bumps `syncRevision` so stores refetch after a CloudKit import, and the
  CloudKit development-schema push and production promotion are still pending
  on the device-verify list, so the dev schema is still freely mutable.
- `RoutePreviewView` receives the `Place`; its header (destination name over
  "Choose a route", lines 99-107) accommodates a trailing control.
- `DeepLink.parse` already covers `aura://preview?lat=&lng=&name=`, so a saved
  place is URL-addressable today with no parser change.
- Design system: rows on `surface` in `Radius.lg` groups, `AuraTheme` roles,
  SF Pro Rounded chrome type, accent spent only on action and state, and every
  leading icon in search results and recents is already accent-tinted, so tint
  alone carries no provenance (PRODUCT.md / DESIGN.md).

## Decisions

Settled autonomously, then revised through the adversarial review (the section
after the decisions records what the review changed). Grounded in the
`impeccable` product register (consistency over surprise, no modal in the hot
path, accent for state only), the `swiftdata` and `cloudkit` skills for the
persistence rules, and the HIG rule that a context menu must never be the only
path to an action.

1. **Persist as a `SavedPlaceRecord` in the existing CloudKit-mirrored
   SwiftData container.** Saved places are user-created content, and the
   container shipped three days ago exists precisely to sync such content
   per-record: CloudKit merges at record granularity, so two devices editing
   different places both win, deletions propagate instead of resurrecting,
   and there is no whole-list conflict to reason about. The model follows the
   CloudKit-compatibility rules the rides already obey: every attribute has a
   default, no `@Attribute(.unique)`, no relationships: `id: UUID`, `name:
   String`, `subtitle: String?` (the search result's address line, for
   provenance in lists), `latitude`/`longitude: Double`, `categoryRaw:
   String`, `kindRaw: String` (`home`/`favorite`), `savedAt: Date`. The
   schema grows a `RideSchemaV3` listing both models with a lightweight
   V2→V3 stage; V1 and V2 stay frozen. Because the CloudKit dev-schema push
   is still pending, `CD_SavedPlaceRecord` folds into the same dashboard
   round already on the verify list; no extra ceremony. Rejected: the iCloud
   KVS seam (the first draft's choice): the review showed whole-list
   last-writer-wins cannot keep an old device from clobbering a newer list,
   initial-sync would silently destroy a just-saved Home, the
   `UserDefaults` mirror leaks one account's places into another, and the
   seam lacks an `accountChange` reason code, five patches to approximate
   what per-record sync gives outright. Rejected: `UserDefaults` only (the
   recents pattern), which forfeits sync, and sync is half the point of
   "Home". Account changes and offline operation inherit the ride-store
   posture verbatim: local data is retained, the mirror idles without an
   account.
2. **`SavedPlace` is a pure value type; all invariants are pure logic.** In
   `AuraCore`: `SavedPlace` (`id`, `name`, `subtitle?`, `coordinate`,
   `category: Place.Category`, `kind`, `savedAt`) converts to/from `Place`
   (setting `isSaved: true` on the way out) and maps to/from the record in
   `AuraKit`. `SavedPlacesLogic` owns the rules, each a pure function over
   `[SavedPlace]`: `add` (cap 50, refuse beyond), `remove`, `rename`,
   `setHome` (demotes the previous Home to a favorite with `savedAt`
   refreshed to now, so it surfaces at the top of favorites rather than
   vanishing into date order), and `reconciled(_:)`, the read-side pass that
   makes CloudKit merge artifacts invisible: de-dup by `id` (the
   backup-restore double, same guard the rides use), collapse
   coordinate-duplicates keeping the newest save's name, and if a merge
   produced two Homes, read the newest `savedAt` as Home and the rest as
   favorites. Nothing writes back at read time; reconciliation only shapes
   what the UI sees, and the next genuine mutation persists the reconciled
   list.
3. **Place identity is rounded coordinates, never raw `Double` equality.**
   `isSaved(place:)` and all de-duplication match by `id` when one is shared
   and otherwise by coordinates rounded to 5 decimal places (~1.1 m), a pure
   `SavedPlaceKey` in `AuraCore`. This is the lesson of the `RouteRanker`
   fix applied in advance: the two Mapbox code paths that can produce a
   coordinate for the same POI are not guaranteed bit-identical. Collapsing
   two genuinely distinct POIs that share a rounded coordinate (one rooftop,
   two tenants) is accepted and made legible: the collapse keeps the newest
   save's name and subtitle, so the list always shows what the rider last
   saved.
4. **The store follows the ride-store shape.** `SavedPlacesStore` in
   `AuraKit`: `@MainActor @Observable`, constructed over the same
   `ModelContainer` the app already builds, exposing `places` (reconciled,
   Home first then `savedAt` descending), `isSaved(_:)`, and the mutations,
   each running through `SavedPlacesLogic` before touching the context. It
   refetches on `NSPersistentStoreRemoteChange` with its own observer in the
   exact shape `RideStore` uses, so a CloudKit import refreshes the dashboard
   without coupling the two stores. Unit tests run it over an in-memory
   container, the pattern the migration tests set, including a posted
   remote-change notification proving the refetch.
5. **Saving is one tap on the route preview; Home is offered in the moment.**
   A star toggle (44 pt hit target, `accent` when saved, `textSecondary`
   outline when not, one VoiceOver element with label "Save place" and value
   "Saved"/"Not saved") joins the preview header beside the destination
   name. Tap saves instantly as a favorite named after the place, no sheet;
   a transient inline confirmation appears under the header for a few
   seconds: "Saved" with a "Set as Home" action, so the feature's headline
   concept is discoverable exactly once per save, at zero cost to the
   pre-ride flow. Tapping the star again removes the place. Setting a new
   Home confirms inline with "Previous Home kept as a favorite" when one
   existed.
6. **The dashboard gets a Saved section with a visible management
   affordance.** The section sits directly under the weekly ring block,
   above the last-ride card, so Home really is two taps from launch without
   scrolling on small phones. Same visual vocabulary as Recents (one
   `surface` group, hairline dividers): each `SavedPlaceRow` shows
   `house.fill` (Home, pinned first) or `star.fill`, a title, and the
   subtitle address line. The Home row's title is the literal word "Home"
   with the place's name in the subtitle, so the concept is legible at a
   glance. Tap pushes `.preview(place)`. A trailing ellipsis button opens a
   menu: Rename (alert with a text field), Set as Home / Remove Home,
   Delete; a long-press context menu carries the same items as a shortcut,
   and the row exposes them as VoiceOver custom actions. Swipe-to-delete is
   dropped: the dashboard group is a `ScrollView`+`VStack`, not a `List`,
   so `.swipeActions` do not apply, and the menu already covers deletion
   with two visible paths. The section hides when empty, matching Recents.
7. **Search pins saved matches while typing; there is no empty-query saved
   group.** The first draft put a Saved group in the results overlay before
   the rider types; the review showed that overlay does not exist: at empty
   query the dashboard, which now carries the Saved section, is already on
   screen below the field, so the group would double-render the same rows.
   Instead: from the first typed character, a pure matcher pins up to 3
   saved matches under a small "Saved" section header (the header carries
   the provenance; icon tint cannot, since every icon is already lime),
   each row showing title and subtitle so a saved place is never less
   identifiable than the Mapbox row below it. The matcher is
   case- and diacritic-insensitive substring over name and subtitle, and
   the literal query "home" (prefix match) always matches the Home place
   regardless of its stored name. At one character, saved matches appear
   alone (Mapbox fetches at two or more, an existing behavior kept
   deliberately). Picking a saved row goes through the existing
   `onPick(Place)` with the saved id and `isSaved: true`.
8. **Recents hide what Saved already shows.** Because every pick flows
   through `router.remember`, a used Home would otherwise sit in Recents on
   every dashboard visit, an adjacent duplicate that reads as a bug. The
   rendered Recents list filters out entries matching `isSaved` (by the D3
   key); `AppRouter`'s stored recents stay untouched, so unsaving a place
   restores its recent row.
9. **Out of scope.** Drop-pin saving (drop-pin itself never shipped),
   reordering, widget changes, new deep links, richer metadata (notes,
   photos: the record gains columns additively if ever needed), and any KVS
   involvement.

## What the adversarial review changed

Three independent reviewers (code-claims, platform semantics with the
`cloudkit` skill loaded, product/UX) attacked the first draft. Confirmed
findings that reshaped it:

- Persistence flipped from an iCloud-KVS envelope to a `SavedPlaceRecord` in
  the CloudKit container (platform F1/F3/F4/F5: the KVS version-freeze
  guarantee is unachievable under last-writer-wins, initial sync destroys
  user-created data under the settings precedent, the mirror leaks across
  account changes, and the claimed SwiftData blocker — an extra dashboard
  round — was factually wrong since the schema push is already pending).
- The empty-query Saved group was cut (code F2 / UX C1: the overlay it
  assumed does not exist; the dashboard already shows Saved at empty query).
- The ellipsis menu and the post-save "Set as Home" moment were added, and
  swipe-to-delete cut (UX M1: context menu as the only path violates the
  HIG and buries Home; code F3: `.swipeActions` need a `List` this layout
  does not have).
- Identity moved to rounded coordinates (code F4 / UX M2), the "Saved"
  header replaced star-tint provenance and rows gained subtitles (UX
  M3/M5), Home renders as "Home" (UX M5), coordinate collapses adopt the
  newest name (UX M6), rendered Recents filter saved places (UX M4), the
  star got an explicit 44 pt target and VO custom actions (UX M7), the
  Saved section moved above the last-ride card (UX m1), and demotion
  refreshes `savedAt` with confirmation copy (UX m3).

## Error and edge handling

- **No iCloud account:** SwiftData operates local-first; the mirror idles,
  exactly the ride-history posture. Nothing to build.
- **Account change:** local records are retained (the documented ride-store
  behavior from PR #21); saved places follow it with no new policy.
- **CloudKit merge artifacts:** duplicate ids, coordinate doubles, or two
  Homes are absorbed by `reconciled(_:)` at read time (D2).
- **Cap reached:** the star tap alerts "Saved places is full. Remove one to
  save another." Nothing is evicted silently.
- **Rename to empty:** saving an empty or whitespace-only name is a no-op,
  guarded in `SavedPlacesLogic.rename` and unit-tested (SwiftUI alert buttons
  cannot disable on live text-field state, so the guard lives in the logic).

## Testing

- `AuraCore`: `SavedPlacesLogic` invariants (cap, single Home,
  demote-refreshes-savedAt, rounded-key de-dup, collapse-adopts-newest-name,
  rename, remove, reconcile of id-doubles and two-Home merges),
  `SavedPlaceKey` rounding, matcher behavior (case/diacritics, subtitle
  matching, "home" kind matching, cap of 3, one-character queries),
  `SavedPlace`↔`Place` conversion.
- `AuraKit`: `SavedPlacesStore` over an in-memory container: mutation →
  fetch round-trip, reconciled ordering (Home first), `isSaved` lookup by id
  and by rounded coordinate, refetch on a posted remote-change
  notification. Plus the two
  schema-invariant guard tests the iCloud review asked for, extended to
  cover `SavedPlaceRecord` (every attribute defaulted; no `.unique`, no
  relationships) so a CloudKit-incompatible column change fails package CI.
- App target: verified on the iPhone 17 / iOS 26 simulator through the
  accessibility tree per house convention: star toggle and the post-save
  Home moment on preview, Saved section rows, ellipsis menu and context
  menu parity, search pinning from one character, Recents filtering,
  Dynamic Type and VoiceOver composition on the new rows. One `AuraUITests`
  case (save from preview → appears on dashboard) extends the suite; it
  runs locally, since the UI-test CI job is still deferred.

## Done-bar and device-verify tail

Done means: package suites green, app builds, SwiftLint `--strict` clean, the
simulator pass above, and the ROADMAP unbuilt-v1-promises line updated. The
device tail folds into the existing two-device CloudKit verification
milestone: the dev-schema push now also creates `CD_SavedPlaceRecord`, and the
two-device session adds one check, a place saved on device A appearing on
device B (and a deletion propagating, not resurrecting).
