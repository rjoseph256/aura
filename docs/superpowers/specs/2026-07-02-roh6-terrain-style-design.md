# ROH-6 — Aura custom terrain style (Home backdrop)

**Status:** approved (brainstorming), 2026-07-02
**Epic:** Interface & Feel (Chunk 0 direction locked). Predecessor of ROH-43 (Home), already shipped on the dark fallback.
**Spec it realizes:** `docs/superpowers/specs/2026-07-02-interface-and-feel-visual-direction-design.md` ("the map is the terrain").

## Goal

Give Aura its own map paint job — a charcoal-green, hill-shaded, lime-headroom terrain style — so the Home backdrop reads as *Aura* instead of a generic Mapbox preset. The custom style is the identity carrier the locked Chunk 0 direction depends on.

## Scope

- **In:** the **Home terrain backdrop** style (what `MapboxTerrainSnapshotter` renders today, behind the Chunk 1 Home). Authored so it can be reused for the live ride map later.
- **Out:** switching the in-ride map (`RideHUD`/`Navigate`, driven by `settings.mapStyle`) to this style — a follow-on once the look is proven on Home. No 3D terrain, no parallax/drift (the Chunk 0 static mandate).

## Decision: where the style lives

The style lives **in the app's code as a bundled JSON file**, not in a Mapbox online account. Rationale:

- **Autonomous.** It renders with the existing read-only public token (which already grants read of Mapbox's vector tiles + terrain-elevation data). No `styles:write` token, no Studio login. (Confirmed: the account is `rohunjoseph`, the public token is default-public scope, and there is no `styles:write` token available.)
- **Version-controlled + reproducible.** The style is reviewed, diffed, and backed up with the rest of the code; a change is a normal commit, and CI/other worktrees get it for free.
- **Tight iteration.** The look is tuned by editing the file and checking on-device, no round-trip through a website.

The trade-off accepted: no Mapbox Studio visual editor for later slider-tweaking. If that is wanted down the line, the same JSON can be uploaded to a Studio account without reworking the app.

## The look (from the locked Chunk 0 direction)

| Layer | Treatment |
|---|---|
| Land / base | Deep charcoal-green (Aura's charcoal-green base), so map and app read as one surface. |
| Relief | Subtle hillshade from Mapbox terrain-elevation data — the city's hills read, tuned legible in bright sun, not muddy. Flat 2D, fully static. |
| Water | Darker slate/teal. |
| Parks / green | A slightly distinct muted tone — present but quiet. |
| Roads | Low-contrast greys, thin; majors a touch lighter. Enough to read a place, not a bright road map. |
| Labels | Restrained, atmospheric — place/neighborhood names, muted (sits behind Home chrome). |
| Signal headroom | Nothing above uses lime `#C8FA4B` or amber, so the route line and Chunk 3 peer-dots pop and never collide. |

Exact per-layer color/opacity values are derived from `AuraPalette` during implementation and, where they are taste calls, chosen on-device (see Verification). The palette values are pinned in the plan, not here.

## Architecture

- **Bundled asset:** a style JSON in the app target (e.g. `Aura/Resources/AuraTerrainStyle.json`), built on Mapbox's standard vector source (`mapbox.mapbox-streets-v8`) and terrain-elevation source (`mapbox.mapbox-terrain-dem-v1`) for hillshade. Both read with the existing public token.
- **Snapshotter seam:** `MapboxTerrainSnapshotter` loads the style from the bundled JSON (MapboxMaps `styleJSON`) instead of a `mapbox://` URI. If the JSON is missing or fails to load, it falls back to the current dark preset so Home never breaks.
- **`TerrainStyle` (pure, AuraKit):** reworked so "the authored Aura style is active" is a real signal rather than a fictional `mapbox://styles/aura/` URI prefix. It exposes the fallback preset and a version string; the app bridges the bundled JSON. `isCustom` becomes "the authored style is in use," not a URI-prefix check.
- **Cache versioning:** the snapshot disk-cache key incorporates a **style version**, so bumping the style invalidates stale cached snapshot images (otherwise a restyle would show old pictures).

Each unit keeps its current boundary: `TerrainStyle` stays pure and CI-testable (no MapboxMaps import); the JSON and the SDK bridge live in the app target.

## Testing

- **Pure (AuraKit, CI):** `TerrainStyle` resolution + the reworked `isCustom`/active-style signal + the style-version threading into the cache key.
- **Asset validity:** a test that the bundled style JSON parses and declares the expected sources/layers (so a malformed edit fails in CI, not silently on-device).
- **Device (the real gate):** render on the phone; confirm bright-sun sub-second glance legibility; confirm lime route headroom; pick relief-intensity + label-density from on-device variants.

## Verification

Device-first (the standing rule for this epic). Render **2–3 variants** on the real iPhone — e.g. subtle vs pronounced relief, and label density — and pick, rather than shipping a single guessed version. The fallback path is verified by confirming Home still renders if the bundled JSON is absent.

## Risks

- **Hillshade legibility vs mud.** Relief that's too strong turns the dark base muddy and kills route contrast. Mitigation: tune on-device against the sub-second-glance bar; keep relief subtle by default.
- **`styleJSON` snapshotter support.** The plan confirms MapboxMaps v11 `Snapshotter` renders a JSON style before committing to the seam; the dark-preset fallback covers any load failure at runtime.
- **Label overload behind chrome.** Too many labels compete with the Home band. Mitigation: atmospheric label density, chosen on-device.
