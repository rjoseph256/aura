# ROH-6 — Aura custom terrain style (Home backdrop)

**Status:** approved (brainstorming) + adversarial spec review reconciled, 2026-07-02
**Epic:** Interface & Feel (Chunk 0 direction locked). Predecessor of ROH-43 (Home), already shipped on the dark fallback.
**Spec it realizes:** `docs/superpowers/specs/2026-07-02-interface-and-feel-visual-direction-design.md` ("the map is the terrain").

## Goal

Give Aura its own map paint job — a charcoal-green, hill-shaded, signal-headroom terrain style — so the Home backdrop reads as *Aura* instead of a generic Mapbox preset. The custom style is the identity carrier the locked Chunk 0 direction depends on.

**Honest framing (from the spec review).** On Home the terrain is a *supporting, partly-occluded backdrop*, not the hero: the Home chrome (top scrim, the lime "Where to?" band on a near-opaque scrim, and the dashboard sheet peek) covers a large share of the screen, leaving the terrain visible mainly in the upper–middle band. The real signature moment of the epic is the Chunk 3 ride-summary "terrain medal," and the style's load-bearing home is the navigate cockpit (out of scope here). ROH-6's job is to **prove the style works and set up those surfaces** — so we invest in a correct, ownable style, not in maximizing Home hero-visibility.

## Scope

- **In:** the **Home terrain backdrop** style (what `MapboxTerrainSnapshotter` renders today, behind the Chunk 1 Home). Authored so it can be reused for the live ride map later.
- **Out:** switching the in-ride map (`RideHUD`/`Navigate`, driven by `settings.mapStyle`) to this style — a follow-on once the look is proven on Home. No 3D terrain, no parallax/drift (the Chunk 0 static mandate).

## Decision: where the style lives + how it's authored

The style lives **in the app's code as a bundled JSON file**, not in a Mapbox online account, and is authored by **repainting a fetched Mapbox base style** rather than writing one from scratch.

- **Autonomous — token scopes confirmed.** The existing default-public token returns `HTTP 200` for all reads a bundled style needs: base style JSON (`styles:read`), glyphs (`fonts:read`), sprite, vector tiles (`tiles:read`), and terrain-DEM. No `styles:write`, no Studio login. (Account is `rohunjoseph`; there is no `styles:write` token — irrelevant to this path.)
- **Author by repaint, not from scratch.** Start from a Mapbox base style's JSON (e.g. `mapbox/dark-v11` or a monochrome base, fetched via the Styles API with the public token) and repaint it to the Aura palette + add hillshade. This **inherits a valid `glyphs`/`sprite`/layer scaffold** (closing the from-scratch glyphs/sprite risk the review raised) and is far less error-prone than hand-authoring every layer.
- **Version-controlled + reproducible.** The style is reviewed, diffed, and backed up with the code; a change is a normal commit.
- **Tight iteration.** Tuned by editing the file and checking on-device, no website round-trip.

Trade-off accepted: no Mapbox Studio visual editor later. The same JSON can be uploaded to Studio if that's ever wanted, without reworking the app.

## The look (from the locked Chunk 0 direction) + review guardrails

| Layer | Treatment |
|---|---|
| Land / base | Deep charcoal-green (Aura's charcoal-green base), so map and app read as one surface. |
| Relief | Subtle hillshade from Mapbox terrain-DEM — the city's hills read. Flat 2D, fully static. |
| Water | Darker slate/teal — must be clearly distinct from land. |
| Parks / green | A slightly distinct muted tone — present but quiet. |
| Roads | Low-contrast cool greys, thin; majors a touch lighter. **No light/white road casings.** |
| Labels | Sparse and atmospheric — major place/neighborhood names only, muted. |

**Guardrails locked here (so the build can't ship muddy or colliding), values tuned on-device:**

1. **Legibility floor.** Relief must stay *distinguishable*, not muddy: land, water, and hillshade must remain visually separable, and the style must be legible at a sub-second glance in bright sun (the Chunk 0 bar). Default to *subtle* relief; the on-device variant chosen must pass this glance test. Legibility beats atmosphere (Chunk 0 Rule 1) — if subtlety makes relief vanish, the base/relief values change, not the bar.
2. **Signal-colour headroom.** The base style uses **only cool / neutral / dark tones**. It reserves the warm and bright hues — lime `#C8FA4B`, amber, white, and warm accents — for *signals* (route line, and the Chunk 3 peer-dots incl. the white "you" dot). Concretely: hillshade highlights stay cool-neutral (never warm/white), roads have no white casings, water/parks avoid warm hues. Chunk 3 pins the exact peer-dot values *against this finished style*; ROH-6's obligation is to leave those hue slots clear.
3. **Static forever.** The JSON declares **no animated or time-of-day-driven expressions** (no drift), and must stay static even if later reused for the navigate map (Chunk 0: "zero residual drift"). CI-checked (see Testing).
4. **Explicit paint.** All paint properties used (fill/line/text/hillshade opacities and colors) are set explicitly in the JSON — no reliance on omitted defaults — so the look is deterministic and reviewable.

Exact per-layer color/opacity values derive from `AuraPalette` and are finalized on-device against these guardrails; they are pinned in the plan, not here.

## Architecture (ownership made explicit per the review)

- **Bundled asset:** `Aura/Resources/AuraTerrainStyle.json` in the app target, built by repainting a Mapbox base style (vector `mapbox.mapbox-streets-v8` + terrain-DEM `mapbox.mapbox-terrain-dem-v1` + inherited glyphs/sprite).
- **Snapshotter owns the SDK bridge (`MapboxTerrainSnapshotter`, app target, impure):**
  - Loads the JSON string from the app bundle; sets `Snapshotter.styleJSON` (confirmed reachable: `StyleManager.styleJSON`, and `Snapshotter` extends `StyleManager`).
  - **Gates capture on style load:** observes `onStyleLoaded` (and existing `onMapLoadingError`) and calls `start()` only after the style + its remote sources report loaded, with a timeout. Setting `styleJSON` is a non-blocking property assignment, so an un-gated `start()` risks a blank/half-loaded snapshot.
  - **Fallback:** if the bundled JSON is missing/unparseable, or the load errors/times out, it renders with `TerrainStyle.fallbackStyleURI` (the current dark preset) via the existing `StyleURI` path, so Home never breaks.
- **`TerrainStyle` (pure, AuraKit — stays MapboxMaps-free, CI-testable):**
  - Keeps `fallbackStyleURI`; adds `styleVersion: String` (a code constant bumped when the JSON's look changes).
  - `isCustom` (currently a `mapbox://styles/aura/` prefix check with **no production caller**) is repurposed to reflect "the authored Aura style" against its real identity, and its test updated; since nothing consumes it in production this is a contained change.
- **Cache versioning:** `styleVersion` threads into the `TerrainSnapshotRequest` FNV-1a cache key (pure layer) so bumping the style invalidates stale cached snapshots. This changes the deterministic key, so the **pinned literal in `TerrainSnapshotRequestTests` (`terrain-…-s…`) is updated** as part of the change.
- **Only one production consumer of `TerrainStyle` today** (`HomeBackdrop.swift:58`, passing `styleURI`); the seam change routes it through the snapshotter's JSON-load path.

## Testing

- **Pure (AuraKit, macOS CI):** `TerrainStyle` resolution + the repurposed `isCustom` (test updated) + `styleVersion` threading into the cache key (the pinned literal test is recomputed and updated).
- **Asset validity via a CI script** (`scripts/check-terrain-style.sh`, wired into the lint job like the rename guard — because the JSON is an app-target resource that pure AuraKit can't read and there is no app unit-test bundle). It parses `AuraTerrainStyle.json` and asserts: valid JSON; required sources (`mapbox-streets-v8`, `mapbox-terrain-dem-v1`); a `hillshade` layer; `glyphs` + `sprite` present; and **no animated/time-of-day expressions** (the static guardrail). A malformed or drift-introducing edit fails CI, not silently on-device.
- **Device (the real gate):** render on the phone; confirm sub-second bright-sun legibility and signal headroom; pick relief-intensity + label-density from on-device variants; confirm the fallback renders Home when the JSON is absent.

## Verification

Device-first (the standing rule for this epic). Render **2–3 variants** on the real iPhone — subtle vs pronounced relief, and label density — and pick, rather than shipping a single guessed version. Verify the fallback path by confirming Home still renders with the bundled JSON removed.

## Risks (post-review)

- **Snapshot capture races style load.** *Mitigation:* gate `start()` on `onStyleLoaded` + timeout → fallback (above). Verified on-device.
- **Hillshade legibility vs mud.** *Mitigation:* the legibility floor guardrail; subtle default; on-device sub-second-glance check.
- **Resolved by verification:** `styleJSON` on `Snapshotter` (CONFIRMED in SDK), token scopes for styles/fonts/sprite/tiles/DEM (all `HTTP 200`), hillshade via raster-dem (CONFIRMED). Basing on a fetched Mapbox style removes the from-scratch glyphs/sprite risk.
</content>
