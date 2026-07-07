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
- **`build_gems.py`** — deterministic, **no network**. Reads `gems.tsv`, validates, and writes
  **directly** to `AuraCore/Sources/AuraKit/Resources/gems.json` (the exact path `.process`
  bundles in `Package.swift:24`; no intermediate output dir, no copy step). Output uses stable
  key order and NFC-normalized strings so re-runs are byte-identical. Exits non-zero and names
  the offending row on any of:
  - duplicate `slug`, or `slug` not matching `^[a-z0-9-]+$` (guards malformed `curated:<slug>` ids)
  - unknown `category` (not in the 8) or `tier` ∉ {1,2,3}
  - `lat`/`lon` empty or outside the Pittsburgh-core bbox (approx lat 40.30–40.55, lon −80.20 to −79.80) — river/typo guard
  - empty `why`
  - a `why`/`name`/any field containing a raw tab or newline (TSV integrity; fields are strictly
    single-line, no embedded tabs — the script rejects rather than silently mis-splits)
  - photo/attribution matrix violation: `photo` present requires `attribution` non-empty
    (attribution may be the literal `PD` for public-domain/CC0, which renders no credit line)
  - **Tier-3 spacing (hard):** two Tier-3 gems within **1.5 km** of each other — prevents haptic
    clustering (see §3, reconciled finding P1)
  - **Proximity (warning, non-fatal):** any two curated gems within **25 m** — flags pairs the
    runtime `CompositeGemProvider.dedupe` (25 m) would silently collapse (reconciled finding A7);
    author nudges one apart or accepts the loss knowingly
  - Photo-name convention: any `photo` value must equal `gem-<slug>` (keeps JSON ⇄ asset-catalog
    names in lockstep; a mismatch is the #1 silent-photo-failure mode)
- **`README.md`** — how to add a gem, re-geocode, regenerate, the bbox/validation rules, the
  `why` style guide (§3), the curated-vs-live inclusion rule (§3), and the **hard requirement that
  the photo asset catalog lives in the Aura app target** (§4).

The generated `gems.json` no longer carries `"placeholder"`.

## 2. Schema change — `photoAttribution` (the one reviewed code change)

**This is a code prerequisite: it lands before / alongside content authoring, not after.** The
TSV carries an `attribution` column, so the field must exist for the JSON to round-trip.

- Add `public let photoAttribution: String?` to `Gem`, optional and decode-tolerant, defaulted
  to `nil` in `init` **after** existing params. Verified safe against every consumer:
  - Codable decodes an absent key to `nil` → the existing `gems.json` and all current tests decode
    unchanged (arch findings A4).
  - All call sites (`PersonalGemProvider`, `OSMGemMapping`, test helpers) use **named** args, so a
    trailing defaulted param compiles untouched (arch finding A5).
  - `Equatable`/`Sendable` re-synthesize to include the field. `Gem` is used only as a dict
    **value** (`[String: Gem]` in `CompositeGemProvider`), never a `Set` element or hash key, so
    equality-semantics changes are inert (arch findings A3/A9). Note this in the PR body anyway.
- **`GemDetailSheet` caption is wired in THIS pass, not deferred.** When a photo renders and
  `photoAttribution` is non-nil and ≠ `PD`, show a small secondary credit line under the image
  (e.g. `Photo: <attribution>`). Rationale: CC-BY/CC-BY-SA legally require visible attribution;
  shipping populated-but-unrendered attribution would be non-compliant (arch finding A5-product,
  compliance). `PD` renders nothing.
- This field + the loader + the generator get an **independent adversarial review** (refuting
  stance) before merge. The content list itself does not need that gate.

## 3. Content — ~150 Pittsburgh gems (hard Tier-3 cap)

- **Target ~150** (range 150–180). If natural coverage overshoots, add Tier-2/Tier-3 *depth*, not
  Tier-1 filler — Tier-1 is quiet filler, stop it at ~150 (reconciled finding P8).
- Coverage: city neighborhoods (Downtown, Strip, Lawrenceville, Bloomfield, Shadyside, Oakland,
  Squirrel Hill, South Side, Mt. Washington, North Side, Polish Hill, Troy Hill, East Liberty,
  Highland Park, West End, Southside Slopes, etc.) + riverfront/trail corridors
  (Three Rivers Heritage Trail, GAP terminus, Eliza Furnace / Jail Trail, riverfront parks).
- Coordinates resolved via Nominatim; the geocoder doubles as a hallucination filter.

**Curated-vs-live inclusion rule (reconciled finding P2).** The live OSM provider already surfaces
parks, cafes, viewpoints, artwork, and historic tags for free. Curated is the **narrative** layer —
include a place when the *why*/story/non-obvious connection is the value OSM can't convey, not to
re-list what OSM covers.
  - **Cafes: excluded as a category** except 1–2 genuinely signature spots (e.g. a historic
    coffeehouse with a story). Generic cafes are OSM's job.
  - **Parks: destination/iconic only** (Schenley, Frick, Riverview, Highland, Emerald View,
    Allegheny Commons). Skip pocket parks.
  - **Historic/landmark: include when the narrative matters**, not merely because it's named on OSM.

**Explicit per-gem tier** (set in the TSV, never derived from `defaultTier`), per the reconciled rubric:
  - **Tier-3 (card + haptic): rare, hard cap ~15–20 gems (~10%).** Only "stop the ride" icons —
    signature overlooks, the Point, Cathedral of Learning, Randyland, the inclines, the best single
    mural/landmark per district. A haptic interrupts the ride; it must be earned. **Spatial rule:
    no two Tier-3 within 1.5 km** (enforced by `build_gems.py`) so a dense-core ride doesn't buzz
    every ~90 s — the engine already single-slots and 75 s-cooldowns surfacing, but the dataset must
    not fight that budget (reconciled finding P1; engine `approachRadius=250 m`, `cooldown=75 s`).
  - **Tier-2 (peek card): majority, ~55–60%.** Worth a glance and a detour.
  - **Tier-1 (quiet pin): ~25–30%.** On the map if you look; no proactive surfacing.

**`why` style guide (reconciled finding P5)** — one concrete, fact-checkable sentence in the
established seed voice ("Where the three rivers meet."):
  - Prefer active / present-tense verbs; avoid "is known for / features / showcases".
  - **Banned:** marketing adjectives (stunning, iconic, vibrant, hidden, must-see, breathtaking),
    "nestled", "boasts", "a testament to", "hidden gem", brand-speak, and rule-of-three lists
    ("art, culture, and history").
  - **Variety rule:** across any 20 consecutive entries, no two `why` sentences open with the same
    word or follow the same grammatical template (checked during content self-review).
  - Examples — ❌ "An iconic overlook with stunning skyline views." → ✓ "The skyline lines up over
    the Mon from the top of the incline."

**Category coverage checklist (reconciled finding P6)** — at minimum, the dataset must include:
  - Viewpoints: Grandview + West End Overlook + a second Mt. Washington overlook
  - Water: the Point, riverfront access points, a fountain/lock
  - Parks: Schenley, Frick, Riverview, Highland, Emerald View
  - Murals: Randyland + Lawrenceville/Penn Ave corridor (several)
  - Climbs: Canton Ave (world's steepest), Mt. Washington ascents, a Polish Hill/Troy Hill climb
  - Historic: Mattress Factory, City of Asylum, the inclines (Duquesne, Monongahela), a mill/furnace
  - Landmarks: Cathedral of Learning, Carnegie Museums, National Aviary, the Three Sisters bridges
    (Roberto Clemente / Andy Warhol / Rachel Carson), notable public stairways
  - Cafe: 0–2 signature only

- **Preserve `curated:grandview-overlook`** at Tier-3 (a real gem; also keeps the pinned unit test valid).

## 4. Photos — Tier-3 only

- Freely-licensed Wikimedia Commons images for the signature Tier-3 gems. License verified per
  image (prefer PD/CC0; CC-BY / CC-BY-SA acceptable with attribution).
- **Hard target-membership requirement (arch finding A6, CRITICAL).** The asset catalog MUST be
  added to the **Aura app target** (`Aura/…`). `GemDetailSheet` calls `UIImage(named:)` with no
  bundle arg, which searches `Bundle.main` only — an asset catalog placed in AuraKit resolves to
  `nil` at runtime and the photo **silently** doesn't render (no error). Code-review gate: confirm
  the catalog's target membership is Aura, not AuraKit/AuraCore.
- **Naming convention:** each `photoAsset` = `gem-<slug>`, matching the TSV `photo` column and the
  asset name in the catalog exactly (arch finding A10). `build_gems.py` enforces the JSON side.
- `photoAttribution` set for every non-PD image; `PD` for public-domain/CC0.
- Not every Tier-3 needs a photo if no acceptable-license image exists — the sheet degrades
  gracefully. Missing photos are acceptable; wrong licenses are not.
- **v1 choice, documented (reconciled finding P3):** photos are Tier-3-only "reveal moments".
  Tier-1/2 detail sheets (reachable by tapping any pin) are tap-and-forget lookups and stay
  photoless this pass. Noted in the README as a deliberate v1 scope, not an oversight.

## 5. `arrivalRadiusMeters` — minimal documented adjustment

`GemCategory.arrivalRadiusMeters` values were implementer-invented. At cycling speed (~7 m/s at
15 mph) a sub-25 m radius is easy to blow past between GPS fixes. **Walked back from the original
proposal** (both reviewers, findings A1/P4): only the genuinely-risky pinpoint tier changes; the
viewpoint change is dropped.

- mural/landmark: 30 → **38 m** (still pinpoint, but survives one missed fix)
- viewpoint: **stays 70 m** — the existing test `GemTests.swift:19` locks it with an explicit
  `// unchanged` intent, and 80 m is speculative until arrival-detection can be validated on-device.
  Deferred to that milestone.
- keep water/historic 45, cafe 40, park/climb/viewpoint 70

Add a comment in `Gem.swift` explaining the cycling-speed rationale. **Tests:** the existing
`viewpoint == 70` and `cafe == 40` assertions stay green; **add** an assertion locking
`mural`/`landmark == 38` so the new value is covered. No arrival-detection wiring in this pass.

## 6. Verification

- Run `build_gems.py`; confirm entry count, Tier distribution, Tier-3 spacing (≥1.5 km), the
  25 m proximity warnings are empty/knowingly-accepted, and all validation passes.
- Unit tests: `photoAttribution` decode round-trip (present + absent); `mural`/`landmark` arrival
  radius == 38; existing `viewpoint == 70` / `cafe == 40` still green.
- Update `CuratedGemProvider` header note (drop the "placeholder starter content" language).
- Update `CuratedGemProviderTests` (count expectation; keep grandview-Tier-3 + all-curated + the
  malformed-drop assertions).
- Build AuraKit package (Swift 6, macOS host — no iOS-only APIs touched).
- Sim smoke: launch, confirm gems surface as pins/cards on the map near a Pittsburgh location, and
  a Tier-3 detail sheet shows its photo + attribution credit line.

## Reconciliation — adversarial spec review

Two independent refuting reviewers (architecture/edge-case + product/content lenses). Outcomes:

**Accepted & folded in:** deterministic output written straight to the resource path (A2); asset
catalog hard-required in the Aura app target with a review gate (A6); `gem-<slug>` photo naming
(A10); expanded `build_gems.py` validation — slug charset, NFC, no-embedded-tab, photo/attribution
matrix (A8); non-fatal 25 m proximity warning for the runtime dedupe collision (A7); attribution
UI wired **this** pass for license compliance (A9-product); Tier-3 hard cap ~15–20 + 1.5 km spacing
rule (P1); curated-vs-live inclusion rule, cafes largely excluded (P2); `why` style guide with
banned-list + variety rule (P5); category coverage checklist (P6); ~150 target with Tier-weighted
overflow rule (P8); Tier-1/2 photoless documented as a v1 choice (P3).

**Verified as non-issues (no action):** Codable absent-key → nil keeps existing JSON/tests decoding
(A4); named-arg call sites compile with a trailing defaulted param (A5); `Equatable` re-synthesis is
inert because `Gem` is never a `Set`/hash key, only a dict value (A3/A9) — noted in PR body only.

**Rejected / walked back:** the `viewpoint` 70 → 80 m change (A1/P4) — dropped; the test's
`// unchanged` intent stands and 80 m is unvalidated until on-device arrival-detection. Only
mural/landmark 30 → 38 m proceeds.

## Risks / mitigations

- **Wrong coordinates (pin in the river).** → bbox validator + Nominatim resolution + Tier-3 spot-check.
- **Hallucinated places / wrong facts in copy.** → geocode filter; keep `why` factual and short; spot-check.
- **Photo licensing.** → per-image license verification; attribution field; skip rather than guess.
- **Haptic fatigue from over-tiering.** → hard Tier-3 cap in the rubric, explicit per-gem tier.
- **Breaking the seen-set.** → ids are `curated:<slug>`, stable; grandview id preserved.
