# Curated gem dataset — ROH-58 design

**Status:** approved (brainstorming) → writing plan
**Issue:** [ROH-58](https://linear.app/rohun/issue/ROH-58) · Project: Product & Release
**Depends on / builds on:** ROH-52 nearby-gems surface (engine, tiers, cards, seen-memory — all shipping on placeholders today)

## Problem

The nearby-gems surface ships riding on an 8-entry Pittsburgh placeholder seed
(`AuraCore/Sources/AuraKit/Resources/gems.json`), there only to exercise the tiers.
Every entry carries a decode-ignored `"placeholder": true` marker. The surface is only
as good as its content; this replaces the seed with a real, researched dataset.

## Goal

Replace the placeholder seed with a researched **Pittsburgh-core dataset (~150–200 gems)**,
authored through a reviewable pipeline, with deliberate tiering, accurate coordinates,
hand-written `why` copy, and freely-licensed photos on the Tier-3 standouts.

**Out of scope (this pass):** expansion metros (follow-up tickets), a full photo pass for
Tier-1/2, a GUI content tool, arrival-detection wiring itself (only the radius values get a look).

## The Gem schema (existing, for reference)

`AuraCore/Sources/AuraCore/Gems/Gem.swift`:

- `id: String` — stable, source-namespaced `curated:<slug>`. **Load-bearing** for the seen-set.
- `name`, `coordinate {latitude, longitude}`.
- `category: GemCategory` — `viewpoint, water, park, cafe, mural, climb, historic, landmark`.
- `tier: GemTier` — `pin(1)`, `card(2)`, `cardHaptic(3)`.
- `source: GemSource` — always `curated` here.
- `photoAsset: String?` — asset-catalog name, rendered by `UIImage(named:)`; skipped when absent.
- `why: String?` — one-sentence editorial blurb.

Loader `CuratedGemProvider.decode` is lenient: each element decoded independently, malformed
entries dropped (never fatal). `GemCategory.defaultTier` auto-assigns tiers but the seed sets
tier explicitly per entry; we keep doing that (defaultTier is not used for authoring).

## 1. Authoring pipeline — `Tools/gems/`

Decision: **checked-in resolved coordinates**. The TSV is the reviewable source of truth;
`gems.json` is a pure, deterministic build artifact. Geocoding is an *authoring-time* step,
never a build step.

- **`gems.tsv`** — human source of truth. Tab-separated columns:
  `slug, name, category, tier, why, photo, attribution, lat, lon, query`
  - `slug` → emitted id is `curated:<slug>`. `query` is the geocoding string (name + locality);
    kept in the source so re-geocoding is reproducible. `photo`/`attribution` blank for non-photo gems.
- **`geocode.py`** — authoring aid, run by hand. For rows missing `lat/lon`, queries Nominatim
  (`User-Agent: aura-gem-authoring`, rate-limited ~1.1s/req, results cached to
  `geocode_cache.json`), writes coordinates back into the TSV. Prints anything it could not
  resolve (hallucination / typo filter). Not part of the build.
- **`build_gems.py`** — deterministic, **no network**. Reads `gems.tsv`, validates, emits
  `AuraCore/Sources/AuraKit/Resources/gems.json` (compact but stable key order). Exits non-zero
  and names the offending row on any of:
  - duplicate `slug` / malformed id
  - unknown `category` (not in the 8) or `tier` ∉ {1,2,3}
  - `lat`/`lon` empty or outside the Pittsburgh-core bbox (approx lat 40.30–40.55, lon −80.20 to −79.80) — river/typo guard
  - empty `why`
  - a `photo` value present with no `attribution` (attribution required unless explicitly `PD`)
- **`README.md`** — how to add a gem, re-geocode, regenerate, and the bbox/validation rules.

The generated `gems.json` no longer carries `"placeholder"`.

## 2. Schema change — `photoAttribution` (the one reviewed code change)

- Add `public let photoAttribution: String?` to `Gem`, optional and decode-tolerant, defaulted
  to `nil` in `init` **after** existing params so all current call sites and the existing JSON
  keep compiling/decoding unchanged.
- `GemDetailSheet`: when a photo renders and `photoAttribution` is non-nil, show a small caption
  credit line under the image (secondary text, e.g. `Photo: <attribution>`).
- This field + the loader + the generator get an **independent adversarial review** (refuting
  stance) before merge. The content list itself does not need that gate.

## 3. Content — ~150–200 Pittsburgh gems

- Coverage: city neighborhoods (Downtown, Strip, Lawrenceville, Bloomfield, Shadyside, Oakland,
  Squirrel Hill, South Side, Mt. Washington, North Side, Polish Hill, Troy Hill, East Liberty,
  Highland Park, Bloomfield, West End, Southside Slopes, etc.) + riverfront/trail corridors
  (Three Rivers Heritage Trail, GAP terminus, Eliza Furnace / Jail Trail, riverfront parks).
- Categories spread across all 8; deduped against each other (curated is the editorial standout
  layer, not an exhaustive OSM dump — the live OSM provider covers breadth).
- Coordinates resolved via Nominatim; the geocoder doubles as a hallucination filter.
- **Explicit per-gem tier**, per the approved rubric:
  - **Tier-3 (card + haptic): rare, ~10–15% (~20–30 gems).** Only "stop the ride" places — the
    signature overlooks, the icons, the best single mural/landmark per district. A haptic is an
    interruption; it must be earned.
  - **Tier-2 (peek card): majority, ~55–60%.** Worth a glance and a detour.
  - **Tier-1 (quiet pin): ~25–30%.** On the map if you look; no proactive surfacing.
- `why`: one concrete sentence each, in the established seed voice ("Where the three rivers meet.").
  Humanizer-clean — no "hidden gem / nestled / vibrant / boasts / a testament to", no rule-of-three
  filler, varied sentence structure across entries.
- **Preserve `curated:grandview-overlook`** (a real Tier-3 gem; also keeps the pinned unit test valid).

## 4. Photos — Tier-3 only

- Freely-licensed Wikimedia Commons images for the signature Tier-3 gems. License verified per
  image (prefer PD/CC0; CC-BY / CC-BY-SA acceptable with attribution).
- Added to a **new asset catalog in the Aura app target** (`Aura/…`, where `UIImage(named:)`
  resolves — AuraKit resources are not on the app's image path). `photoAsset` names match the
  catalog; `photoAttribution` set for every non-PD image.
- Not every Tier-3 needs a photo if no acceptable-license image exists — the sheet degrades
  gracefully. Missing photos are acceptable; wrong licenses are not.

## 5. `arrivalRadiusMeters` — light documented adjustment

`GemCategory.arrivalRadiusMeters` values were implementer-invented. At cycling speed (~7 m/s at
15 mph) a sub-25m radius is easy to blow past between GPS fixes. Adjust:

- mural/landmark: 30 → **38 m** (still pinpoint, but survives one missed fix)
- viewpoint: 70 → **80 m** (overlooks are approached from a distance)
- keep water/historic 45, cafe 40, park/climb 70

Add a comment explaining the cycling-speed rationale. No arrival-detection wiring in this pass.

## 6. Verification

- Run `build_gems.py`; confirm entry count and validation pass.
- Update `CuratedGemProvider` header note (drop the "placeholder starter content" language).
- Update `CuratedGemProviderTests` (count expectation; keep grandview + all-curated assertions).
- Build AuraKit package (Swift 6, macOS host — no iOS-only APIs touched).
- Sim smoke: launch, confirm gems surface as pins/cards on the map near a Pittsburgh location.

## Risks / mitigations

- **Wrong coordinates (pin in the river).** → bbox validator + Nominatim resolution + Tier-3 spot-check.
- **Hallucinated places / wrong facts in copy.** → geocode filter; keep `why` factual and short; spot-check.
- **Photo licensing.** → per-image license verification; attribution field; skip rather than guess.
- **Haptic fatigue from over-tiering.** → hard Tier-3 cap in the rubric, explicit per-gem tier.
- **Breaking the seen-set.** → ids are `curated:<slug>`, stable; grandview id preserved.
