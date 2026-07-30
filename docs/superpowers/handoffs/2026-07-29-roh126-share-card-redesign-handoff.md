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
2. ~~Adversarial spec review, round 1~~ — done: skeptic, product, and architecture
   reviewers all returned REVISE. Convergent blockers: (a) a Snapshotter style-load
   timeout yields a *blank successful* raster, not `nil`, so rev 1's offline fallback
   never fired; (b) the rev-1 band needed ~286 pt in a 220 pt budget (Saira Condensed
   line height is 1.57× point size — measure, don't assume); (c) `start()` had no
   timeout → permanently dead Share after backgrounding; (d) fixed `Aura ride.png`
   filename + async window → wrong-ride share from History; (e) no cancellation;
   (f) NaN camera propagation; (g) `scaledToFill` could crop Mapbox attribution;
   (h) orchestration untestable in the view body (repo pattern is a protocol seam,
   see `TerrainSnapshotRendering`); (i) stroke width was specified 3× too thick (the
   overlay CGContext is already in points).
3. **Spec revision 2 written and committed** — key changes: fallback-card-first with
   upgrade-in-place (Share enables instantly, map card swaps in when the raster is
   accepted); a measured 240 pt map / 210 pt band budget with a 44 pt hero; an
   acceptance pipeline (gate timeout → `nil` before `start()`, bounded `start()` with
   `cancel()`, camera validation, non-blank variance backstop, cache only accepted
   rasters via `TerrainSnapshotDiskCache`); per-ride+generation temp filenames with a
   sweep; `ShareMapRasterProviding` protocol seam; one shared style-resolution helper
   (Home refactored onto it).
4. ~~Adversarial spec review, round 2~~ — done: REVISE ×3, but the rev-2 core held
   (band budget re-measured correct from the shipped TTFs; fallback-first kills the
   dead button). Decisive new findings: the SDK composites our route stroke into the
   returned raster *before* the completion, so a variance check could never see
   blankness (fix: capture-only overlay handler, acceptance on bare map interior
   excluding the bottom chrome strip, composite the route ourselves — which also
   enables a dark casing under the mint for light basemaps); `Snapshotter` inherits
   callback-driven `StyleManager.load(mapStyle:completion:)`, eliminating the
   event-race gate and any new style helper; the specced `withTaskCancellationHandler`
   shape doesn't compile under Swift 6 (non-Sendable Snapshotter — hop `cancel()` via
   `Task { @MainActor … }` and use a resolve-once latch); the sweep deleted the open
   sheet's file (fix: per-ride *directories*, clean leaf filename, sweep on summary
   entry only, other rides only); cache key needs a route-content hash + authored
   style version, and reads need `UIImage(data:scale: 3)` or cache hits center-crop;
   prefetch the raster at ride end; hero 48 fits (44 was unforced); stats numerals
   stay Saira; upgrade swap must never nil a working shareImage; single-flight the
   pipeline; layout budget enforced as a package test, not a preview.
5. **Spec revision 3 written and committed** — adopts all of the above.
6. **Adversarial spec review, round 3 (delta verification, 2 reviewers) — IN FLIGHT
   when this was last updated.** This is the loop's third and final iteration; if it
   returns REVISE on anything structural, surface to Andrew rather than iterating
   further.
5. `superpowers:writing-plans` → bite-sized TDD plan.
6. Adversarial plan review (2+ reviewers, refuting stance). Fix before executing.
7. `superpowers:subagent-driven-development` — fresh implementer + reviewer per task.
8. Whole-branch review on the most capable model before finishing.
9. Prose deliverables (PR body, issue updates) through `humanizer`.

Also done: warm `xcodebuild build` of the untouched worktree passed (project generated
via `cd Aura && xcodegen generate`; DerivedData at `Aura/DerivedData` is warm). A
separate task chip was spawned for the latent Home bug the review found
(`MapboxTerrainSnapshotter` caches blank rasters to disk on gate timeout).

## Design

**The spec (revision 2) is the single source of truth** — read it in full rather than
this summary: map field exactly 360×240 pt (one constant shared by snapshot request and
view, no `scaledToFill` so attribution can't be cropped), readout band 210 pt with a
measured budget (44 pt Saira hero ≈ 69 pt line box), fallback-card-first share flow with
upgrade-in-place, a strict raster acceptance pipeline, per-ride temp filenames,
`ShareMapRasterProviding` seam, pure package-tested helpers in AuraKit (coordinate
hygiene/decimation, camera validation, non-blank variance), 5 pt **unscaled** route
stroke in the overlay handler. `ShareCardContent` (AuraCore) is unchanged.

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
