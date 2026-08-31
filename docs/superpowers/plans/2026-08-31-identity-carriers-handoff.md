# Identity Carriers — execution handoff

**For:** a fresh session picking up execution of the identity-carriers map-layer pass.
**Written:** 2026-08-31, at the end of the spec/plan/design-gate session.
**Status at handoff:** spec approved and gate-locked; plan adversarially reviewed by
two independent reviewers and RECONCILED (v2 — see the log at the bottom of this
file); implementation NOT started — Task 1 is yours. Execution mode: subagent-driven
(PO-confirmed).

## Read these first, in order

1. `docs/superpowers/plans/2026-08-31-identity-carriers-plan.md` — the 14-task plan you
   are executing. Its header names the required sub-skill
   (`superpowers:subagent-driven-development` — PO confirmed subagent-driven) and the
   Global Constraints every task inherits.
2. `docs/superpowers/specs/2026-08-31-identity-carriers-design.md` — the v2 spec the
   plan argues from (reconciled after a 3-reviewer adversarial gate; the plan cites it
   per task).
3. `CLAUDE.md` at repo root — the pipeline, verification tiers, and board rules all
   bind execution.

## What is already decided — do not relitigate

- **Design gate 1a is PASSED and recorded** (comment on ROH-219, commit `da9d3c9`):
  browse dot = white core 18 / ink 1.5 / mint ring 2 / wedge tip 16 / real accuracy
  ring; riding puck = **rounded triangle** 22×20, corner radius 3, ink 1.5, **mint
  edge 2.5** (PO: "bumped is the way"), canvas 32. The plan's `PuckMetrics` values ARE
  the approved design. Gate 1b (in-app render at cockpit zoom) still applies before
  the puck rolls out; iterate constants only within the `PuckMetricsTests` invariants.
- **"White = me"** — the rider marker is never accent-mint. Settled at the spec gate
  with code precedent; do not walk it back for aesthetics.
- **Traveled-dim mechanism** — paint-only `lineTrimOffset` over a dim under-layer,
  driven by SDK `fractionTraveled`, frozen while `isRerouting`. The naive
  `routeLength − distanceRemaining` split was refuted at the spec gate (three
  reviewers, independently); if an implementer proposes it, the answer is no.
- **ROH-7 stands cancelled** — no hoisting maps out of the NavigationStack while
  fixing anything here.

## Board state (Linear, team ROH, project Interface & Feel)

Parent: ROH-45 (In Progress). Children, all assigned, blockers wired:

| Issue | Workstream | Plan tasks | State to drive |
|---|---|---|---|
| ROH-218 | P0 — pin Mapbox SDKs exactly | 1 | Todo → start here |
| ROH-223 | D — ornaments/collisions | 2–4 | Todo (blocked by 218) |
| ROH-222 | C — mapChip + lint rule | 5–6 | Todo |
| ROH-219 | A1 — browse puck | 7–8 | Todo (blocked by 218; gate 1a passed, 1b pending) |
| ROH-220 | A2 — riding puck | 9 | Todo (blocked by 218+219; **merge hold**: device heading check) |
| ROH-221 | B — route line + trim | 10–13 | Todo (blocked by 218) |
| ROH-224 | queued device pass | — | Backlog; stays open until a real ride |

Move each issue Todo → In Progress → In Review → Done as its tasks run. Watch for
Linear auto-completing ROH-220/224 from PR references — revert if it does.

## Environment facts you need

- **Worktree/branch:** this session worked on `claude/premium-ui-design-audit-8f663d`
  (a `.claude/worktrees/` worktree). Docs commits: `2e11d30` (spec v1), `71eadb0`
  (spec v2), `d47a6b1` + `c9571c6` + `da9d3c9` (plan + gate-1a lock), plus the
  reconciliation commit(s) in the log below. Execution can continue on this branch or
  start per-issue branches off it — but the docs must merge to main with (or before)
  the first code PR.
- **Mapbox token:** `Aura/Resources/MapboxAccessToken` is gitignored. It is already
  present in THIS worktree; any NEW worktree needs it copied from the main checkout.
- **Xcode project is generated:** `cd Aura && xcodegen` after any file add/remove; the
  `.xcodeproj` is gitignored and may be stale or absent.
- **Simulator:** iPhone 17, UDID `D221B3C5-13DE-482F-B0FD-017B305EC31B`, already has a
  Debug build installed (pre-changes) with location granted and a Pittsburgh fix set
  (`xcrun simctl location <udid> set 40.4406,-79.9959`). Bundle id
  `com.rohunjoseph.aura`.
- **Builds/tests:** delegate builds to the `apple-platform-build-tools` builder agent;
  `swift test` runs in `AuraCore/` (prints TWO totals — both must be green); SwiftLint
  runs from the repo root. The TaskCompleted gate lints + tests automatically.
- **Reviewer discipline:** per-task reviews use Agent-tool-less types (`Explore`, or
  the checked-in `review-*` agents) so grandchild subagents are structurally
  impossible. Implementers work app-target SwiftUI directly; delegate only pure
  `swift test` runs and builds.

## PO gates during execution (from the PO, in-session)

Nothing visual ships in one sweep. Deliver evidence and WAIT for sign-off at:
1. **Gate 1b** — in-app puck renders (browse on Home live map; riding on both HUDs)
   before the puck spreads / merges.
2. **Gate 2** — route-line: preview stills + a location-playback recording of a
   navigate ride with one deliberate off-route deviation (reroute behavior is the
   risk; stills cannot show it).
3. **Gate 3** — chips + ornaments before/after set (navigate HUD one-frame composite,
   detour chrome, scale bar, compass, search header).
4. **Gate 4** — whole-slice before/after set with the whole-branch review.
While waiting: mark the issue blocked with a Linear comment; rebase before merge if
main moved.

## Verification tiers (bind per PR)

- ROH-220 (riding puck): Tier 2 **with merge hold** — device heading check first.
- ROH-221 trim feel + ROH-219 accuracy ring: Tier 2 queued on ROH-224, no hold.
- Everything else: Tier 1 sim-verified; screenshots/recordings in the PR. Golden-ride
  E2E never exercises the trim path (`ScriptedGuidanceSession` emits no progress) —
  every ROH-221 PR must say so.

## Reconciliation log (completed 2026-08-31 — the plan you are reading is v2)

Two independent reviewers (skeptic lens, architecture lens) reviewed plan v1; every
finding was adjudicated and the plan rewritten. If you diff plan history, v1 is dead —
do not resurrect any of its mechanisms. The load-bearing adjudications:

1. **Navigate trim moved to style primitives** (arch blocker): `PolylineAnnotationGroup`
   cannot set `lineMetrics` on its source, and `lineTrimOffset` without it is a shader
   failure that erases the bright line — not a graceful no-op. Task 13 now mirrors
   Mapbox's own vanishing-route pattern (`GeoJSONSource(lineMetrics: true)` + two
   `LineLayer`s). CI can never catch a regression here (the golden ride's scripted
   guidance emits no progress) — the gate-2 playback recording is the real check.
2. **New Task 10B** (both reviewers, independently): `GuidanceViewModel.applyProgress`
   cleared `isRerouting` on every progress tick, which made "full bright while
   rerouting" unimplementable and let a stale old-route fraction dim the new geometry.
   Fixed in AuraKit with TDD: `isRerouting` survives progress ticks; `.rerouted` nils
   the stale fraction. The pre-existing test never exercised the production
   interleaving ([.rerouting, .progress, …]) — the new ones do.
3. **SDK pin strategy rebuilt** (both): pin `MapboxNavigation` exactly (3.28.0 →
   transitively exact maps 11.28.0, the version all API checks used) + align
   `MapboxSearch`; never pin maps independently (nav exact-pins maps per release —
   independent pins can make the graph unresolvable). Package keys in project.yml are
   `MapboxMaps`/`MapboxNavigation`/`MapboxSearch`.
4. **Scale bar margins in BOTH states** (skeptic blocker): showing the bar when panned
   put it exactly where it collides. `MapOrnamentMetrics.belowTopControlMargin`
   (safe-area-relative composition, no dead `safeAreaTop` parameter) now applies on
   HUDs and preview; the sim check verifies no-collision in the panned state, not mere
   visibility. Compass hidden on HUDs only — preview untouched.
5. **Puck z-order is an explicit acceptance check** (arch, traced): the puck does not
   participate in the SwiftUI layer-order chain; Tasks 9 and 13 both verify the puck
   draws above the route, with a slot-based fallback (we own the terrain style JSON if
   slot anchors are missing).
6. **Code-block fixes**: WCAG helper arg order + bright-basemap case + honest
   threshold-band framing; GroupCrew manual strokes deleted (double-stroke);
   DetourOverlay:101 is a RoundedRectangle; Rerouting chip joins the .mapChip
   migration; HomeGlass lint exclusion dropped (inert) but its fallback fill migrates;
   browse wedge is mint-on-ink (near-black-on-near-black was invisible); v1's
   assert-nothing `bothStatesUseSquareCanvases` test deleted, two real invariants
   added; `fractionTraveled` inserted in declaration order; Task 11's `??` restructured
   to observable divergence; quantized tests use tolerance; xcodegen steps added to
   every file-creating task; ROH-220's hold is a **draft PR** (a hold needs a
   mechanism); Task 13 keeps the count>1 guard and Task 12's destination flag when
   replacing the route rendering; concrete `simctl location start` playback recipe
   replaces the "golden-ride playback" hand-wave (the harness structurally cannot
   drive trim).
7. **Rejected/reframed**: the "peer dots white=me on the map" verification step was
   unfalsifiable (self never renders as a dot — the puck IS self) — dropped; spec §10's
   logo criterion softened to "visible wherever visible today" (the bottom-leading
   placement behind the cockpit predates this slice and is out of scope); the
   HomeLocationHint hides with the header during search (deliberate widening, spec
   §6.4 v2.1, rationale recorded).

Line numbers in the plan cite HEAD at plan time — locate by symbol, not number,
especially in `NavigateHUDView.swift` (Tasks 3→9→12→13 edit it in sequence).
