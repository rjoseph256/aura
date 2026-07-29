# ROH-126 handoff — shareable ride card redesign

A session picking this up should have the repo's mandated toolset installed:
`all-ios-skills` (swift-concurrency, swiftui skills), `humanizer`, and the
`apple-platform-build-tools` builder subagent. The session that produced this handoff
lacked all three and compensated by reading the vendored MapboxMaps source directly.

## Task

Redesign the shareable post-ride image (the PNG behind the summary screen's **Share**
button). Two defects, reported by Andrew:

1. The distance sits in an **opaque tile on top of the route map**, blocking part of it.
2. The **map background is missing** — the shared image shows only the bare route
   polyline on a flat background, unlike the summary screen's real map.

## Tracking

- **Linear:** [ROH-126](https://linear.app/rohun/issue/ROH-126/redesign-shareable-post-ride-card-real-map-background-distance-off-the)
  — team Rohun, project **Interface & Feel**, assigned to **Andrew (adaws96)**, status
  **In Progress**. Move to **In Review** when the PR is up; Rohun reviews the PR.
- **Branch/worktree:** `claude/post-ride-shareable-redesign-54df82` in
  `.claude/worktrees/pluging-a6fcc0`.
- **Spec (written, committed):**
  `docs/superpowers/specs/2026-07-29-roh126-share-card-redesign-design.md`

## Pipeline position (per CLAUDE.md, all gates required)

1. ~~Brainstorm / settle intent~~ — done (defects and direction fixed by the user's report).
2. **Adversarial spec review — IN FLIGHT when this handoff was written.** Three
   independent reviewers (`review-skeptic`, `review-product`, `review-architecture`)
   were dispatched against the spec with refuting stances. If their findings are not
   reconciled into the spec yet, re-run this gate rather than trusting it happened.
3. `superpowers:writing-plans` → bite-sized TDD plan.
4. Adversarial plan review (2+ reviewers, refuting stance). Fix before executing.
5. `superpowers:subagent-driven-development` — fresh implementer + reviewer per task.
6. Whole-branch review on the most capable model before finishing.
7. Prose deliverables (PR body, issue updates) through `humanizer`.

## Design (see the spec for full detail)

- New `ShareMapSnapshotter` (app target, `Aura/Sources/Ride/ShareCard/`): async
  `MapboxMaps.Snapshotter` render of the card's map field — rider's map style resolved
  exactly as `MapStyle+Mapbox.swift` does, camera via `snapshotter.camera(for:padding:)`
  clamped to zoom ≤ 16, route segments stroked per-segment in `start(overlayHandler:)`
  using `pointForCoordinate` + `AuraTheme.routeUIColor`. Style-load timeout gate copied
  from `MapboxTerrainSnapshotter` (including its continuation-leak fix). Returns
  `UIImage?`; `nil` on any failure.
- `ShareCardView` gains `mapImage: UIImage?`. Map variant: raster full-bleed on top
  (~230 pt of the 360×450 card), **nothing drawn over it** (Mapbox attribution is
  composited bottom of the raster by the SDK and must stay legible). All text moves to
  the readout band below: context line, distance hero, elevation sparkline + climbed,
  moving time row with the AURA wordmark trailing on the same row. Fallback variant
  (route, no raster): today's `RouteThumbnail` look minus the opaque tile. No-route
  variant unchanged.
- `RideCardRenderer.make(content, mapImage:)` stays sync/@MainActor;
  `RideSummaryView`'s `.task` awaits the snapshot first, then renders. Share button
  stays disabled until the PNG exists (unchanged behavior; snapshot always resolves via
  timeout → fallback).
- `ShareCardContent` (AuraCore) is unchanged — keeps its package unit tests green.

## Facts a new session should not re-derive

- `MapboxMaps.Snapshotter` API verified in the vendored checkout
  (`~/Library/Developer/Xcode/DerivedData/Aura-azsaihmsynvaxnejgfibjvhvtytd/SourcePackages/checkouts/mapbox-maps-ios/Sources/MapboxMaps/Snapshot/Snapshotter.swift`):
  `camera(for:padding:bearing:pitch:)` exists; `start(overlayHandler:completion:)` hands
  a `SnapshotOverlay` with `context`, `scale`, `pointForCoordinate`; the SDK composites
  the Mapbox logo + attribution onto the returned image itself.
- The old "the Mapbox map cannot render offscreen" comment in `ShareCardView.swift`
  refers to live `Map` views under `ImageRenderer`; `Snapshotter` is the sanctioned
  offscreen path and is already used by `Aura/Sources/Home/MapboxTerrainSnapshotter.swift`
  (study its traps: style-load gate, 6 s timeout, strong-capture of the snapshotter in
  the completion so the continuation can't leak).
- App project is XcodeGen: `cd Aura && xcodegen generate` before `xcodebuild`. The
  gitignored `Aura/Resources/MapboxAccessToken` was already copied into this worktree
  from the main checkout. The full app build is ~13 min; the `.claude/agent-gate.sh`
  TaskCompleted hook runs lint + the AuraCore package suite only.
- **Device verification path** (required — UI is verified by looking, not asserted):
  launch the app in the simulator with
  `-auraDidCompleteOnboarding YES -auraSimulatedRide golden -auraSimulatedRideMultiplier 30 -auraInMemoryRideStore`
  (the ROH-92 golden-ride harness; see `Aura/UITests/RideE2EUITests.swift` and
  `scripts/golden-ride.sh`), ride to completion, end the ride, and on the summary let
  the share render finish, then pull `tmp/Aura ride.png` from the app container
  (`xcrun simctl get_app_container <udid> com.rohunjoseph.aura data`) and inspect the
  PNG. Verify `auraTerrain` and `standard` styles, plus a no-network run for the
  fallback card.

## Key files

| File | Role |
|---|---|
| `Aura/Sources/Ride/ShareCard/ShareCardView.swift` | The card (redesign target) |
| `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift` | ImageRenderer → PNG |
| `Aura/Sources/Ride/RideSummaryView.swift` | Caller; `.task` builds the share image |
| `Aura/Sources/Home/MapboxTerrainSnapshotter.swift` | Existing Snapshotter pattern |
| `Aura/Sources/Ride/StaticRouteMap.swift` | Summary map to visually match |
| `Aura/Sources/Theme/MapStyle+Mapbox.swift` | Style resolution to mirror |
| `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift` | Pure content (unchanged) |

## Wrap-up checklist

- PR to `main` with `humanizer`-passed body; link ROH-126.
- Move ROH-126 to **In Review**, note the PR link on the issue; Rohun reviews.
- Do not mark Done until merged and device-verified.
