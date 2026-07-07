# Curated gem authoring pipeline

The curated gems shown in the Explore / nearby-gems surface come from this folder.
`gems.tsv` is the source of truth; `gems.json` is a generated build artifact.

**Do not hand-edit `AuraCore/Sources/AuraKit/Resources/gems.json`.** Edit `gems.tsv`
and regenerate.

## Workflow

1. Edit `gems.tsv` (one row per gem). Leave `lat`/`lon` blank for new rows; fill `query`
   with a geocodable string like `"<name>, <neighborhood>, Pittsburgh, PA"`.
2. Resolve coordinates:
   ```
   python3 geocode.py
   ```
   This fills blank `lat`/`lon` from Nominatim (rate-limited ~1.1s/request, cached in
   `geocode_cache.json`) and prints any rows it could not resolve. Fix their `query` (or
   hand-enter verified coordinates) and re-run until nothing is unresolved.
3. Validate and generate:
   ```
   python3 build_gems.py
   ```
   This writes `AuraCore/Sources/AuraKit/Resources/gems.json`. It is deterministic and
   network-free — re-running on an unchanged TSV produces byte-identical output.

## TSV columns

`slug  name  category  tier  why  photo  attribution  lat  lon  query` (tab-separated).

- **slug** — `^[a-z0-9-]+$`. The emitted id is `curated:<slug>`. **Id stability is
  load-bearing** for the seen-set: never rename an existing slug.
- **category** — one of `viewpoint, water, park, cafe, mural, climb, historic, landmark`.
- **tier** — `1` quiet map pin, `2` peek card, `3` peek card **plus a haptic buzz** as you
  approach. Set it deliberately per gem (never by category default).
- **why** — one concrete, fact-checkable sentence (see style guide below).
- **photo** / **attribution** — see Photos below. Both blank for gems without a photo.
- **lat** / **lon** — filled by `geocode.py`.
- **query** — the geocoding string. Kept in the source so re-geocoding is reproducible.

## Validation rules (enforced by `build_gems.py`, fatal unless noted)

- slug malformed or duplicated
- unknown category, or tier not in {1,2,3}
- `lat`/`lon` empty or outside the Pittsburgh-core bbox (lat 40.30–40.55, lon −80.20 to −79.80)
- empty `why`
- any field containing a raw tab or newline
- `photo` set without `attribution`
- `photo` value not equal to `gem-<slug>`
- two **Tier-3** gems within **1.5 km** of each other (haptic-clustering guard)
- **warning (non-fatal):** any two gems within 25 m — the runtime `CompositeGemProvider`
  dedupe (25 m) may collapse them; nudge one apart or accept knowingly.

## Tiering

Tier-3 is rare and earned (~12–20 total): only "stop the ride" icons — the signature
overlooks, the inclines, the world-famous climbs, the best single mural/landmark per
district. A haptic interrupts the ride, so it must be worth it, and the 1.5 km spacing rule
keeps a dense-core ride from buzzing constantly. Tier-2 is the majority (worth a glance and
a detour); Tier-1 is quiet filler.

## Curated vs. live

The live OpenStreetMap layer already surfaces parks, cafes, viewpoints, artwork, and
historic tags for free. Curated is the **narrative** layer: include a place when its story
or the non-obvious `why` is the value OSM can't convey, not to re-list what OSM covers.
Cafes are mostly excluded (the live layer has them); parks are destination/iconic only.

## `why` style guide

One fact-checkable sentence. Prefer plain `is`/`are` and active verbs. **Banned:** marketing
adjectives (stunning, iconic, vibrant, hidden, must-see, breathtaking), "nestled", "boasts",
"a testament to", "hidden gem", and rule-of-three lists. Vary the openings — across any 20
consecutive rows, no two `why` sentences should start with the same word or follow the same
grammatical template.

## Photos (Tier-3 only, this pass)

Photos come from freely-licensed Wikimedia Commons images for the signature Tier-3 gems.
Record each image's source URL and license in `PHOTO_LICENSES.md`. Set `photo=gem-<slug>`
and `attribution=<Author> / <License> via Wikimedia Commons` (or `PD` for public-domain/CC0,
which renders no credit line). `fetch_photos.py` writes this format automatically.

**Photo assets MUST belong to the Aura app target** (`Aura/Resources/GemPhotos.xcassets`),
named exactly `gem-<slug>` — never AuraCore/AuraKit. `GemDetailSheet` calls `UIImage(named:)`
with no bundle argument, which searches `Bundle.main` only; an asset in a package target
resolves to `nil` and the photo **silently** won't render. Verify: Xcode → Aura target →
Build Phases → Copy Bundle Resources.

Tier-1/2 gems are photoless this pass (a deliberate v1 choice — photos are the Tier-3
"reveal moment"). The detail sheet degrades gracefully when a photo is absent.
