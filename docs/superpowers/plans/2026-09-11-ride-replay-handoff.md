# Ride Replay — execution handoff

**For:** a fresh session picking up execution of ride replay (ROH-239).
**Written:** 2026-09-11, at the end of the brainstorm / spec-gate / plan-gate session.
**Status at handoff:** design PO-approved in chat; spec v2.1 (3-reviewer adversarial gate,
reconciled); plan v2 (2-reviewer adversarial gate, reconciled; the skeptic compiled and ran
the pure layer in a scratch package, the architect type-checked the app layer against the
SDK). **Implementation NOT started — Task 1 is yours.** Execution mode: subagent-driven
(the repo's pipeline step 5), then one whole-branch review on the most capable model (step 6)
before merge.

## Read these first, in order

1. `docs/superpowers/plans/2026-09-11-ride-replay.md` — the 12-task plan. Its header names
   the required sub-skill and the Global Constraints every task inherits. Tasks 1–7 carry
   the full Swift source and Swift Testing suites; Tasks 8–11 carry the full SwiftUI source;
   Task 12 is the orchestrator's simulator pass, board, and PR. The reconciliation log at the
   bottom says what the plan reviewers found and what changed.
2. `docs/superpowers/specs/2026-09-11-ride-replay-design.md` — spec v2.1. §0 says what the
   spec gate changed; every **(v2.1)** mark is a rule the plan gate changed. The plan cites
   it as D1…D11 and §4.N.
3. `CLAUDE.md` at repo root — pipeline, verification tiers, board rules, and the reviewer
   discipline (Agent-tool-less reviewer types, implementers told not to spawn).

## What is already decided — do not relitigate

- **Entry is one line in `RideSummaryView`** (`.replayEntry(ride:)` on `StaticRouteMap`,
  line 76), presenting a `.fullScreenCover`. The map stays inert; the pill is a real
  `Button`. No `AppRoute` change, no History-row entry in this slice (named follow-up).
- **Holds, not pauses.** Every stop the rider remembers — pause gap, stationary run ≥ 45 s,
  lost-signal leg ≥ 30 s — is a hold with the same treatment. This was the product review's
  headline finding against v1 and is the feature's reason to exist.
- **Time model: 120×, floor 10 s, cap 45 s** (spec D2). The PO approved 15/60 in v1; the
  product review tightened both ends and the PO has not objected. These are two `Config`
  values. If the PO wants 15/60 back, change `Config` and the four duration tests, nothing else.
- **Rendering is a `MapViewAnnotation` inside a `TimelineView`** over a GeoJSON source +
  `LineLayer` route (the `NavigateHUDView` structure). v1's projected overlay was refuted by
  three reviewers; the SDK returns a `(-1, -1)` sentinel off-screen and `proxy.map` is nil
  on the first pass. Do not go back.
- **Playback fraction is derived from an anchor**, never accumulated in a body, and **every
  playback event takes the live `Date()` from its handler**, never a `TimelineView` date.
  The architect showed a paused schedule's frozen date makes Play start the ride from
  wherever the rider hesitated to. This is a Global Constraint and has a test
  (`playAfterALongPauseStartsAtZero`).
- **Reduce Motion keeps the glide** (peer-dot precedent); only the bearing snaps to 45°, the
  recenter snaps, entrance fades are off. No stepped playback.
- **The DEBUG seed only writes to the in-memory store.** The persistent store mirrors to the
  developer's real iCloud. `-auraSeedLongRide` must be paired with `-auraInMemoryRideStore`.
- **`SyntheticRide` lives in the library under `#if DEBUG`**, a stated deviation from spec §6
  v2, because the seed needs it.
- **Speed is a trailing window that never crosses a hold; bearing is the course over that
  same window.** Both in the pure layer (spec D5.1, D9 v2.1).

## PO gates during execution

- **Strip color and z-order (spec D6, `AuraTheme.replayHoldStrip` at 0.28 white, drawn above
  the silhouette):** PO eyeball on the simulator pass before merge. The spec gate found the
  v1 value invisible; v2.1's number is a reviewer's estimate, not a PO decision.
- **Whole-branch review (pipeline step 6)** before merge, on the most capable model.
- **The queued device Verification issue** (spec §9: 3-hour ride memory, marker smoothness
  at 60 Hz and under pinch) is filed at Task 12 and does not block merge.

## Board state (Linear, team ROH)

| Issue | Project | State | Notes |
|---|---|---|---|
| ROH-239 | Summary & Map Polish | In Progress | The feature. Move to In Review when the PR is up, Done after merge + PO eyeball. |
| (to file at Task 12) | Device Verification | — | `Verification` label; title per spec §9. |

Watch for Linear auto-completing ROH-239 from a PR reference before the whole-branch review
has run — revert if it does (memory: `linear-pr-merge-autocompletes-issues`).

## Environment facts you need

- **Worktree/branch:** `claude/ride-playback-scrubber-18c5f0`, checked out in the worktree at
  `.claude/worktrees/group-ride-ux-issues-aa5005` (the directory name is inherited; the
  branch is right). Base is `main` at `1b75948`. Docs commits: `5092efe` (spec v1),
  `6684112` (spec v2), `68b2fc2` (plan v1), `d374e28` (plan v2 + spec v2.1).
  Nothing else is on the branch. Execution can continue here.
- **Mapbox token:** `Aura/Resources/MapboxAccessToken` is gitignored and **already present
  in this worktree**. A new worktree needs it copied from the main checkout.
- **Xcode project is generated:** `cd Aura && xcodegen generate` after any file add. The
  `.xcodeproj` is gitignored. `xcodegen` is at `/opt/homebrew/bin/xcodegen`.
- **Simulator:** iPhone 17, UDID `D221B3C5-13DE-482F-B0FD-017B305EC31B` (shutdown at
  handoff). Bundle id `com.rohunjoseph.aura`.
- **Builds/tests:** delegate builds to the `apple-platform-build-tools:builder` agent;
  `swift test --no-parallel --filter <Suite>` runs in `AuraCore/` (prints TWO totals, both
  must be green; one `swift test` at a time on this machine); SwiftLint from the repo root,
  `swiftlint lint --strict --quiet`. The `TaskCompleted` gate lints + runs the package suite;
  it does **not** build the app, so the plan's compile-error loop (Global Constraints) is the
  only thing that catches an app-target error before CI.
- **Hot files (an open device-verification queue is editing them):** `NavigateHUDView.swift`,
  `RideMapView.swift`, `RideSummaryView.swift` (+`ShareUpgrade`), the group-ride crew files.
  PR #141 (riding puck on both HUDs, held for a device heading check) touches the two HUD
  files. The plan touches `RideSummaryView.swift` by one line and nothing else on that list.
- **Reviewer discipline:** per-task reviews use the checked-in `review-skeptic` /
  `review-product` / `review-architecture` agents or `Explore` (no Agent tool), so grandchild
  subagents are structurally impossible. Implementers get the full task text, run their own
  `swift test --filter` and lint, and do not build or spawn.

## Known traps the reviewers named (so the implementer does not rediscover them)

- `ReplayTimeline` is split across two files on purpose (`type_body_length` 250 under
  `--strict`). Keep sampling in the extension.
- `typealias F` fails `type_name`; the plan uses `Fixtures`.
- Fixture distances use the haversine sphere (6 371 000 m), not 111 320 m/°; tolerances are
  0.01 m. Do not "fix" a failing tolerance by widening it.
- Span search is on `fractionStart`, not seconds; that is what makes hold ranges half-open.
- `ReplaySilhouette` takes `.equatable()` at its call site, never inside its own body.
- Rail-mode ZStack needs an explicit `.frame(width:height:alignment:)` or the hit area is
  32 pt short.
- `viewport.isIdle` is the SDK's write-back on any idle, not only a gesture (spec §10).
- The leg into a stationary run joins it: 60 jitter points are 59 legs, plus that leg, so the fixture yields a 60 s hold (spec §4.4).

## Suggested opening for the implementer session

1. Read the three files above. Confirm `git log --oneline -5` shows the docs commits and a
   clean tree.
2. Announce the sub-skill (`superpowers:subagent-driven-development`), move nothing on the
   board yet (ROH-239 is already In Progress).
3. Dispatch Task 1's implementer with the task text verbatim plus the Global Constraints.
   Review with an Agent-tool-less reviewer. Continue task by task; the orchestrator builds
   after Tasks 8, 9, 10, 11.
4. Task 12 is the orchestrator's own: simulator pass, evidence under `docs/evidence/roh-239/`,
   Verification issue, PR with `Verification: Tier 1`, then the whole-branch review before
   merge.
