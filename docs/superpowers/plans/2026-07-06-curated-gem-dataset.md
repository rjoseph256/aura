# Curated Gem Dataset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 8-entry placeholder gem seed with a researched ~150-gem Pittsburgh dataset, authored through a validating TSV→JSON pipeline, with a reviewed `photoAttribution` schema addition and Wikimedia photos on the Tier-3 standouts.

**Architecture:** A human-authored `Tools/gems/gems.tsv` is the source of truth. An authoring-time `geocode.py` resolves coordinates via Nominatim into the TSV. A deterministic, network-free `build_gems.py` validates the TSV and emits `AuraCore/Sources/AuraKit/Resources/gems.json` (the path `Package.swift` bundles via `.process`). One backward-compatible optional field (`Gem.photoAttribution`) is added and rendered in `GemDetailSheet`; a small `arrivalRadiusMeters` tweak lands with it. Photos for Tier-3 gems live in a new asset catalog in the **Aura app target**.

**Tech Stack:** Swift 6 / Swift Testing (AuraCore package, macOS-host CI), Python 3 stdlib (`unittest`, `csv`, `json`, `urllib`, `unicodedata`), Nominatim (authoring-time only), Xcode asset catalog (xcodegen-managed project).

## Global Constraints

- Gem `id` is `curated:<slug>`, `slug` matches `^[a-z0-9-]+$`. **Id stability is load-bearing** for the seen-set — never rename an existing slug.
- `build_gems.py` is **deterministic and network-free**; it writes byte-identically on re-runs (stable key order, NFC-normalized strings).
- `gems.json` output path is exactly `AuraCore/Sources/AuraKit/Resources/gems.json` — no intermediate dir, no copy step.
- Coordinates must fall inside the Pittsburgh-core bbox: **lat 40.30–40.55, lon −80.20 to −79.80**.
- Tier is **explicit per gem** (never derived from `GemCategory.defaultTier`). Tier-3 hard cap **~15–20**; **no two Tier-3 gems within 1.5 km**.
- `photoAsset` (when present) equals `gem-<slug>` exactly, and its asset catalog is a member of the **Aura app target only** (never AuraKit/AuraCore — `UIImage(named:)` searches `Bundle.main`).
- `why` copy: one fact-checkable sentence, active/present verbs, established seed voice. **Banned:** stunning, iconic, vibrant, hidden, must-see, breathtaking, nestled, boasts, "a testament to", "hidden gem", rule-of-three lists. No two `why` in any 20 consecutive entries share an opening word or grammatical template.
- No new Swift package dependencies. No iOS-only APIs in AuraCore/AuraKit (package builds on macOS host).
- Preserve `curated:grandview-overlook` at Tier-3.

---

### Task 1: Add `photoAttribution` to the `Gem` model

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Gems/Gem.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GemTests.swift`

**Interfaces:**
- Consumes: existing `Gem` initializer.
- Produces: `Gem.photoAttribution: String?` (stored, optional); `init(..., photoAsset: String? = nil, why: String? = nil, photoAttribution: String? = nil)` — new param is **last** and defaulted.

- [ ] **Step 1: Write the failing test** — append to `GemTests.swift` inside `@Suite struct GemTests`:

```swift
    @Test func photoAttributionDefaultsToNilAndRoundTrips() throws {
        // Absent in JSON decodes to nil (backward-compat with existing gems.json).
        let json = #"{"id":"curated:x","name":"X","coordinate":{"latitude":40.44,"longitude":-80.0},"category":"park","tier":2,"source":"curated"}"#
        let decoded = try JSONDecoder().decode(Gem.self, from: Data(json.utf8))
        #expect(decoded.photoAttribution == nil)

        // Present round-trips.
        let gem = Gem(id: "curated:y", name: "Y",
                      coordinate: Coordinate(latitude: 40.44, longitude: -80.0),
                      category: .mural, tier: .cardHaptic, source: .curated,
                      photoAsset: "gem-y", why: "A wall.", photoAttribution: "Jane Doe, CC BY-SA 4.0")
        let data = try JSONEncoder().encode(gem)
        #expect(try JSONDecoder().decode(Gem.self, from: data).photoAttribution == "Jane Doe, CC BY-SA 4.0")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Delegate to the `apple-platform-build-tools:builder` agent: run `swift test --package-path AuraCore --filter GemTests/photoAttributionDefaultsToNilAndRoundTrips`
Expected: FAIL — `Gem` has no member `photoAttribution` (compile error).

- [ ] **Step 3: Write minimal implementation** — in `Gem.swift`, add the stored property after `why` and the init param last:

```swift
    public let photoAsset: String?
    public let why: String?
    public let photoAttribution: String?

    public init(id: String, name: String, coordinate: Coordinate,
                category: GemCategory, tier: GemTier, source: GemSource,
                photoAsset: String? = nil, why: String? = nil,
                photoAttribution: String? = nil) {
        self.id = id; self.name = name; self.coordinate = coordinate
        self.category = category; self.tier = tier; self.source = source
        self.photoAsset = photoAsset; self.why = why
        self.photoAttribution = photoAttribution
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Builder agent: `swift test --package-path AuraCore --filter GemTests`
Expected: PASS (all GemTests, including the existing round-trip and the new one).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/Gem.swift AuraCore/Tests/AuraCoreTests/GemTests.swift
git commit -m "feat(gems): add optional Gem.photoAttribution (backward-compatible)"
```

---

### Task 2: Render the photo credit line in `GemDetailSheet`

**Files:**
- Create: `AuraCore/Sources/AuraCore/Gems/GemPhotoCredit.swift`
- Modify: `Aura/Sources/Ride/GemDetailSheet.swift:29-33`
- Test: `AuraCore/Tests/AuraCoreTests/GemPhotoCreditTests.swift`

**Interfaces:**
- Consumes: `Gem.photoAttribution` (Task 1).
- Produces: `public func gemPhotoCredit(_ attribution: String?) -> String?` in AuraCore — returns `nil` for `nil`/empty, else `"Photo: <attribution>"`. (Pure, so it's unit-testable without SwiftUI. `build_gems.py` already collapses public-domain to `nil`, so any non-nil attribution should be shown.)

- [ ] **Step 1: Write the failing test** — create `GemPhotoCreditTests.swift`:

```swift
import Testing
import AuraCore

@Suite struct GemPhotoCreditTests {
    @Test func nilAndEmptyProduceNoCredit() {
        #expect(gemPhotoCredit(nil) == nil)
        #expect(gemPhotoCredit("") == nil)
        #expect(gemPhotoCredit("   ") == nil)
    }
    @Test func attributionBecomesCreditLine() {
        #expect(gemPhotoCredit("Jane Doe, CC BY-SA 4.0") == "Photo: Jane Doe, CC BY-SA 4.0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Builder agent: `swift test --package-path AuraCore --filter GemPhotoCreditTests`
Expected: FAIL — `gemPhotoCredit` not defined.

- [ ] **Step 3: Write minimal implementation** — create `GemPhotoCredit.swift`:

```swift
import Foundation

/// The credit line shown under a gem photo, or nil when none is needed.
/// `build_gems.py` collapses public-domain/CC0 to a nil attribution, so any
/// non-empty attribution here is a license that requires visible credit.
public func gemPhotoCredit(_ attribution: String?) -> String? {
    guard let attribution else { return nil }
    let trimmed = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : "Photo: \(trimmed)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Builder agent: `swift test --package-path AuraCore --filter GemPhotoCreditTests`
Expected: PASS.

- [ ] **Step 5: Wire it into the view** — in `GemDetailSheet.swift`, replace the photo block (lines 29-33) with:

```swift
            if let asset = gem.photoAsset, UIImage(named: asset) != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Image(asset).resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    if let credit = gemPhotoCredit(gem.photoAttribution) {
                        Text(credit)
                            .font(.caption2)
                            .foregroundStyle(AuraTheme.textSecondary)
                    }
                }
            }
```

- [ ] **Step 6: Build the app target to confirm it compiles**

Builder agent: build the `Aura` app scheme for the iOS simulator (discovers scheme/sim automatically).
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/GemPhotoCredit.swift AuraCore/Tests/AuraCoreTests/GemPhotoCreditTests.swift Aura/Sources/Ride/GemDetailSheet.swift
git commit -m "feat(gems): show photo attribution credit under gem detail photo"
```

---

### Task 3: Adjust `arrivalRadiusMeters` for mural/landmark

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Gems/Gem.swift` (the `arrivalRadiusMeters` switch)
- Test: `AuraCore/Tests/AuraCoreTests/GemTests.swift`

**Interfaces:**
- Consumes / Produces: `GemCategory.arrivalRadiusMeters` — mural/landmark becomes `38`; everything else unchanged (viewpoint stays 70).

- [ ] **Step 1: Write the failing test** — append to `GemTests.swift`:

```swift
    @Test func muralAndLandmarkArrivalRadiusSurvivesOneMissedFix() {
        // At ~7 m/s a sub-25m radius can be blown past between GPS fixes; 38m is the floor.
        #expect(GemCategory.mural.arrivalRadiusMeters == 38)
        #expect(GemCategory.landmark.arrivalRadiusMeters == 38)
        #expect(GemCategory.viewpoint.arrivalRadiusMeters == 70)   // deliberately unchanged this pass
    }
```

- [ ] **Step 2: Run test to verify it fails**

Builder agent: `swift test --package-path AuraCore --filter GemTests/muralAndLandmarkArrivalRadiusSurvivesOneMissedFix`
Expected: FAIL — mural/landmark currently return 30.

- [ ] **Step 3: Write minimal implementation** — in `Gem.swift`, update the `arrivalRadiusMeters` switch and add the rationale comment:

```swift
    /// How close (meters) counts as "arrived" for this kind of place.
    /// At typical cycling speed (~7 m/s / 15 mph) GPS fixes are ~1–2 s apart, so a sub-25m
    /// radius can be blown past between fixes. Pinpoint spots use 38m as the floor; diffuse
    /// spots (parks, overlooks) stay wide. Viewpoint is left at 70m until on-device
    /// arrival-detection can validate widening it.
    public var arrivalRadiusMeters: Double {
        switch self {
        case .mural, .landmark: return 38
        case .cafe: return 40
        case .water, .historic: return 45
        case .park, .viewpoint, .climb: return 70
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Builder agent: `swift test --package-path AuraCore --filter GemTests`
Expected: PASS — including existing `cafeArrivalRadiusIsForgivingForBikes` (cafe 40, viewpoint 70) and `categoryCarriesDefaultTierAndArrivalRadius` (viewpoint > cafe still holds: 70 > 40).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/Gem.swift AuraCore/Tests/AuraCoreTests/GemTests.swift
git commit -m "feat(gems): widen mural/landmark arrival radius to 38m for cycling speed"
```

---

### Task 4: Build the validating generator `build_gems.py`

**Files:**
- Create: `Tools/gems/build_gems.py`
- Create: `Tools/gems/test_build_gems.py`
- Create: `Tools/gems/gems.tsv` (header + a handful of seed rows so the generator has input to validate; full content lands in Task 6)

**Interfaces:**
- Produces (imported by tests):
  - `CATEGORIES: set[str]` — the 8 valid categories.
  - `BBOX = (40.30, 40.55, -80.20, -79.80)` (min_lat, max_lat, min_lon, max_lon).
  - `read_rows(path) -> list[dict]` — parse TSV (header row → dict per row, all string values).
  - `validate(rows) -> list[str]` — list of human-readable error strings (empty = valid). Includes Tier-3 1.5 km spacing (fatal) and 25 m proximity (prefixed `WARN:`, non-fatal — callers filter).
  - `to_gem(row) -> dict` — one TSV row → the emitted JSON object.
  - `haversine_m(lat1, lon1, lat2, lon2) -> float`.
  - `main(tsv_path, out_path) -> int` — writes JSON, returns process exit code.

TSV columns (tab-separated, first line is the header, exactly):
`slug	name	category	tier	why	photo	attribution	lat	lon	query`

- [ ] **Step 1: Write the failing tests** — create `Tools/gems/test_build_gems.py`:

```python
import unittest
from build_gems import (CATEGORIES, BBOX, validate, to_gem, haversine_m)

def row(**kw):
    base = dict(slug="a-b", name="A B", category="park", tier="2",
                why="A place.", photo="", attribution="", lat="40.44", lon="-80.00", query="A B, Pittsburgh")
    base.update(kw); return base

class ValidateTests(unittest.TestCase):
    def test_clean_rows_have_no_errors(self):
        self.assertEqual([e for e in validate([row()]) if not e.startswith("WARN:")], [])

    def test_bad_slug_charset_is_error(self):
        self.assertTrue(any("slug" in e for e in validate([row(slug="Bad Slug")])))

    def test_duplicate_slug_is_error(self):
        self.assertTrue(any("duplicate" in e.lower() for e in validate([row(slug="x"), row(slug="x")])))

    def test_unknown_category_is_error(self):
        self.assertTrue(any("category" in e for e in validate([row(category="beach")])))

    def test_bad_tier_is_error(self):
        self.assertTrue(any("tier" in e for e in validate([row(tier="4")])))

    def test_out_of_bbox_is_error(self):
        self.assertTrue(any("bbox" in e.lower() for e in validate([row(lat="41.9", lon="-87.6")])))

    def test_empty_why_is_error(self):
        self.assertTrue(any("why" in e for e in validate([row(why="")])))

    def test_embedded_tab_is_error(self):
        self.assertTrue(any("tab" in e.lower() or "newline" in e.lower() for e in validate([row(why="a\tb")])))

    def test_photo_without_attribution_is_error(self):
        self.assertTrue(any("attribution" in e for e in validate([row(photo="gem-a-b", attribution="")])))

    def test_photo_name_must_match_gem_slug(self):
        self.assertTrue(any("gem-" in e for e in validate([row(photo="wrong", attribution="PD")])))

    def test_tier3_within_1500m_is_error(self):
        r1 = row(slug="t1", tier="3", lat="40.4400", lon="-80.0000")
        r2 = row(slug="t2", tier="3", lat="40.4410", lon="-80.0000")  # ~111m apart
        self.assertTrue(any("1.5" in e or "1500" in e for e in validate([r1, r2])))

    def test_25m_proximity_is_warning_not_error(self):
        r1 = row(slug="p1", lat="40.44000", lon="-80.00000")
        r2 = row(slug="p2", lat="40.44010", lon="-80.00000")  # ~11m apart
        errs = validate([r1, r2])
        self.assertTrue(any(e.startswith("WARN:") for e in errs))
        self.assertEqual([e for e in errs if not e.startswith("WARN:")], [])

class ToGemTests(unittest.TestCase):
    def test_emits_expected_shape(self):
        g = to_gem(row(slug="the-point", category="water", tier="2", why="Where the rivers meet."))
        self.assertEqual(g["id"], "curated:the-point")
        self.assertEqual(g["source"], "curated")
        self.assertEqual(g["tier"], 2)
        self.assertEqual(g["coordinate"], {"latitude": 40.44, "longitude": -80.00})
        self.assertIsNone(g["photoAsset"])
        self.assertIsNone(g["photoAttribution"])

    def test_public_domain_collapses_to_null_attribution(self):
        g = to_gem(row(slug="a-b", photo="gem-a-b", attribution="PD"))
        self.assertEqual(g["photoAsset"], "gem-a-b")
        self.assertIsNone(g["photoAttribution"])

    def test_credited_photo_keeps_attribution(self):
        g = to_gem(row(slug="a-b", photo="gem-a-b", attribution="Jane, CC BY 4.0"))
        self.assertEqual(g["photoAttribution"], "Jane, CC BY 4.0")

class HaversineTests(unittest.TestCase):
    def test_known_distance(self):
        # ~111m per 0.001 deg latitude at this latitude.
        self.assertAlmostEqual(haversine_m(40.440, -80.0, 40.441, -80.0), 111, delta=3)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Tools/gems && python3 -m unittest test_build_gems -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'build_gems'`.

- [ ] **Step 3: Write the implementation** — create `Tools/gems/build_gems.py`:

```python
#!/usr/bin/env python3
"""Deterministic, network-free TSV -> gems.json generator. See README.md."""
import csv, json, math, sys, unicodedata
from pathlib import Path

CATEGORIES = {"viewpoint", "water", "park", "cafe", "mural", "climb", "historic", "landmark"}
BBOX = (40.30, 40.55, -80.20, -79.80)  # min_lat, max_lat, min_lon, max_lon
SLUG_RE = __import__("re").compile(r"^[a-z0-9-]+$")
DEFAULT_OUT = Path(__file__).resolve().parents[2] / "AuraCore/Sources/AuraKit/Resources/gems.json"
FIELDS = ["slug", "name", "category", "tier", "why", "photo", "attribution", "lat", "lon", "query"]

def _nfc(s): return unicodedata.normalize("NFC", s.strip())

def read_rows(path):
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        return [dict(r) for r in reader]

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2 * R * math.asin(math.sqrt(a))

def _coord(row):
    return float(row["lat"]), float(row["lon"])

def validate(rows):
    errors, seen = [], set()
    for i, r in enumerate(rows):
        tag = f"row {i+1} ({r.get('slug','?')})"
        slug = (r.get("slug") or "").strip()
        if not SLUG_RE.match(slug):
            errors.append(f"{tag}: slug must match ^[a-z0-9-]+$")
        if slug in seen:
            errors.append(f"{tag}: duplicate slug")
        seen.add(slug)
        if (r.get("category") or "").strip() not in CATEGORIES:
            errors.append(f"{tag}: unknown category '{r.get('category')}'")
        if (r.get("tier") or "").strip() not in {"1", "2", "3"}:
            errors.append(f"{tag}: tier must be 1, 2 or 3")
        for field in FIELDS:
            v = r.get(field) or ""
            if "\t" in v or "\n" in v or "\r" in v:
                errors.append(f"{tag}: field '{field}' contains a raw tab/newline")
        if not (r.get("why") or "").strip():
            errors.append(f"{tag}: why is required")
        photo = (r.get("photo") or "").strip()
        attribution = (r.get("attribution") or "").strip()
        if photo:
            if photo != f"gem-{slug}":
                errors.append(f"{tag}: photo must equal gem-<slug> (expected gem-{slug})")
            if not attribution:
                errors.append(f"{tag}: photo present requires attribution (use PD for public domain)")
        try:
            lat, lon = _coord(r)
            if not (BBOX[0] <= lat <= BBOX[1] and BBOX[2] <= lon <= BBOX[3]):
                errors.append(f"{tag}: coordinate outside Pittsburgh bbox")
        except (TypeError, ValueError):
            errors.append(f"{tag}: lat/lon missing or non-numeric (run geocode.py)")
    # Spatial rules across valid-coordinate rows.
    pts = []
    for i, r in enumerate(rows):
        try: pts.append((i, r, *_coord(r)))
        except (TypeError, ValueError): pass
    for a in range(len(pts)):
        for b in range(a+1, len(pts)):
            _, ra, la, na = pts[a]; _, rb, lb, nb = pts[b]
            d = haversine_m(la, na, lb, nb)
            if ra.get("tier") == "3" and rb.get("tier") == "3" and d < 1500:
                errors.append(f"Tier-3 spacing: {ra['slug']} and {rb['slug']} are {d:.0f}m apart (<1.5km)")
            elif d < 25:
                errors.append(f"WARN: {ra['slug']} and {rb['slug']} are {d:.0f}m apart (<25m; runtime dedupe may collapse)")
    return errors

def to_gem(row):
    photo = (row.get("photo") or "").strip() or None
    attribution = (row.get("attribution") or "").strip()
    attribution = None if attribution in ("", "PD") else _nfc(attribution)
    return {
        "id": f"curated:{row['slug'].strip()}",
        "name": _nfc(row["name"]),
        "coordinate": {"latitude": round(float(row["lat"]), 6), "longitude": round(float(row["lon"]), 6)},
        "category": row["category"].strip(),
        "tier": int(row["tier"]),
        "source": "curated",
        "photoAsset": photo,
        "why": _nfc(row["why"]),
        "photoAttribution": attribution,
    }

def main(tsv_path=None, out_path=None):
    tsv_path = Path(tsv_path or Path(__file__).with_name("gems.tsv"))
    out_path = Path(out_path or DEFAULT_OUT)
    rows = read_rows(tsv_path)
    errors = validate(rows)
    fatal = [e for e in errors if not e.startswith("WARN:")]
    for e in errors:
        print(e, file=sys.stderr)
    if fatal:
        print(f"\n{len(fatal)} error(s); gems.json not written.", file=sys.stderr)
        return 1
    gems = [to_gem(r) for r in rows]
    out_path.write_text(json.dumps(gems, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    t3 = sum(1 for g in gems if g["tier"] == 3)
    print(f"Wrote {len(gems)} gems ({t3} Tier-3) -> {out_path}")
    return 0

if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
```

- [ ] **Step 4: Create a minimal seed TSV so the generator has input** — create `Tools/gems/gems.tsv` with the header and 3 valid rows (full content is Task 6):

```
slug	name	category	tier	why	photo	attribution	lat	lon	query
grandview-overlook	Grandview overlook	viewpoint	3	The skyline lines up over the Mon from the top of the incline.			40.4392	-80.0155	Grandview Overlook, Mount Washington, Pittsburgh
point-state-park	Point State Park	water	2	Where the three rivers meet.			40.4419	-80.0089	Point State Park, Pittsburgh
randyland	Randyland	mural	3	A courtyard painted end to end in the Mexican War Streets.			40.4579	-80.0097	Randyland, Pittsburgh
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Tools/gems && python3 -m unittest test_build_gems -v`
Expected: PASS (all cases).

- [ ] **Step 6: Run the generator against the seed TSV**

Run: `cd Tools/gems && python3 build_gems.py`
Expected: `Wrote 3 gems (2 Tier-3) -> …/gems.json` and no fatal errors. (Grandview and Randyland are >1.5 km apart, so no Tier-3 spacing error.)

- [ ] **Step 7: Commit**

```bash
git add Tools/gems/build_gems.py Tools/gems/test_build_gems.py Tools/gems/gems.tsv AuraCore/Sources/AuraKit/Resources/gems.json
git commit -m "feat(gems): validating TSV->gems.json generator with unit tests"
```

---

### Task 5: Add the `geocode.py` authoring helper

**Files:**
- Create: `Tools/gems/geocode.py`
- Create: `Tools/gems/test_geocode.py`

**Interfaces:**
- Produces (imported by tests):
  - `merge_coords(rows, resolved) -> list[dict]` — pure: for rows with empty `lat`/`lon`, fill from `resolved[query]`; leave already-filled rows untouched. Returns new rows.
  - `needs_geocode(row) -> bool` — true when `lat` or `lon` is blank.
  - `geocode_query(query, cache, fetch) -> tuple[float,float] | None` — cache-first; on miss calls injected `fetch(query)`; stores result. (`fetch` is the network boundary — a `urllib` call in `main`, a stub in tests. Keeps the network out of the unit tests.)

- [ ] **Step 1: Write the failing tests** — create `Tools/gems/test_geocode.py`:

```python
import unittest
from geocode import needs_geocode, merge_coords, geocode_query

class GeocodeTests(unittest.TestCase):
    def test_needs_geocode_detects_blank_coords(self):
        self.assertTrue(needs_geocode({"lat": "", "lon": ""}))
        self.assertFalse(needs_geocode({"lat": "40.44", "lon": "-80.0"}))

    def test_merge_fills_only_blank_rows(self):
        rows = [{"slug": "a", "query": "A", "lat": "", "lon": ""},
                {"slug": "b", "query": "B", "lat": "40.4", "lon": "-80.0"}]
        out = merge_coords(rows, {"A": (40.5, -80.1)})
        self.assertEqual((out[0]["lat"], out[0]["lon"]), ("40.5", "-80.1"))
        self.assertEqual((out[1]["lat"], out[1]["lon"]), ("40.4", "-80.0"))

    def test_geocode_query_is_cache_first(self):
        calls = []
        def fetch(q): calls.append(q); return (1.0, 2.0)
        cache = {"X": [3.0, 4.0]}
        self.assertEqual(geocode_query("X", cache, fetch), (3.0, 4.0))
        self.assertEqual(calls, [])  # served from cache, no fetch
        self.assertEqual(geocode_query("Y", cache, fetch), (1.0, 2.0))
        self.assertEqual(calls, ["Y"])

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Tools/gems && python3 -m unittest test_geocode -v`
Expected: FAIL — no module `geocode`.

- [ ] **Step 3: Write the implementation** — create `Tools/gems/geocode.py`:

```python
#!/usr/bin/env python3
"""Authoring-time coordinate resolver (Nominatim). NOT part of the build.
Fills blank lat/lon in gems.tsv, caching results in geocode_cache.json.
Usage: python3 geocode.py   (rate-limited ~1.1s/request)."""
import csv, json, sys, time, urllib.parse, urllib.request
from pathlib import Path

TSV = Path(__file__).with_name("gems.tsv")
CACHE = Path(__file__).with_name("geocode_cache.json")
FIELDS = ["slug", "name", "category", "tier", "why", "photo", "attribution", "lat", "lon", "query"]
UA = "aura-gem-authoring/1.0 (https://linear.app/rohun; dev contact)"

def needs_geocode(row):
    return not (row.get("lat") or "").strip() or not (row.get("lon") or "").strip()

def geocode_query(query, cache, fetch):
    if query in cache and cache[query]:
        lat, lon = cache[query]; return (lat, lon)
    result = fetch(query)
    if result: cache[query] = [result[0], result[1]]
    return result

def _fetch(query):
    url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(
        {"q": query, "format": "json", "limit": 1})
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
    time.sleep(1.1)  # Nominatim usage policy: <=1 req/s
    if not data: return None
    return (round(float(data[0]["lat"]), 6), round(float(data[0]["lon"]), 6))

def merge_coords(rows, resolved):
    out = []
    for r in rows:
        r = dict(r)
        if needs_geocode(r) and r.get("query") in resolved:
            lat, lon = resolved[r["query"]]
            r["lat"], r["lon"] = str(lat), str(lon)
        out.append(r)
    return out

def main():
    with open(TSV, newline="", encoding="utf-8") as f:
        rows = [dict(r) for r in csv.DictReader(f, delimiter="\t")]
    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    resolved, unresolved = {}, []
    for r in rows:
        if not needs_geocode(r): continue
        q = (r.get("query") or "").strip()
        coords = geocode_query(q, cache, _fetch) if q else None
        if coords: resolved[q] = coords
        else: unresolved.append(r.get("slug", "?"))
    CACHE.write_text(json.dumps(cache, indent=2, sort_keys=True) + "\n")
    merged = merge_coords(rows, resolved)
    with open(TSV, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, delimiter="\t")
        w.writeheader()
        for r in merged: w.writerow({k: r.get(k, "") for k in FIELDS})
    print(f"Resolved {len(resolved)} rows; {len(unresolved)} unresolved: {unresolved}")

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Tools/gems && python3 -m unittest test_geocode -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tools/gems/geocode.py Tools/gems/test_geocode.py
git commit -m "feat(gems): add Nominatim geocoding helper for authoring"
```

---

### Task 6: Author the ~150-gem dataset

**Files:**
- Modify: `Tools/gems/gems.tsv` (append all researched rows)
- Create: `Tools/gems/geocode_cache.json` (produced by geocode.py)
- Create: `Tools/gems/README.md`
- Modify: `AuraCore/Sources/AuraKit/Resources/gems.json` (regenerated)
- Modify: `AuraCore/Sources/AuraKit/Gems/CuratedGemProvider.swift` (header note)
- Modify: `AuraCore/Tests/AuraKitTests/CuratedGemProviderTests.swift` (count + distribution)

**Interfaces:**
- Consumes: `build_gems.py`/`geocode.py` (Tasks 4–5), the `Gem` schema.
- Produces: the real `gems.json`.

This task is content-led; its "tests" are the generator's validation gate plus Swift assertions on the emitted dataset.

- [ ] **Step 1: Author the TSV rows.** Append rows to `gems.tsv` following the Global Constraints (voice, tiering, curated-vs-live rule) and the spec's category coverage checklist. Work neighborhood by neighborhood (Downtown, Strip, Lawrenceville, Bloomfield/Friendship, Shadyside, Oakland, Squirrel Hill, South Side + Slopes, Mt. Washington, North Side, Polish/Troy Hill, East Liberty/Highland Park, West End, riverfront/GAP/Eliza Furnace trails). Leave `lat`/`lon` blank; fill `query` with `"<name>, <neighborhood>, Pittsburgh"`. Target ~150 rows; Tier-3 ≤ 20, none within 1.5 km of another Tier-3.

- [ ] **Step 2: Resolve coordinates**

Run: `cd Tools/gems && python3 geocode.py`
Expected: `Resolved N rows; K unresolved: [...]`. For each unresolved slug, fix the `query` (more specific) or hand-enter verified coordinates, and re-run until `unresolved` is empty.

- [ ] **Step 3: Generate and validate**

Run: `cd Tools/gems && python3 build_gems.py`
Expected: `Wrote ~150 gems (≤20 Tier-3) -> …/gems.json`, zero fatal errors. Resolve every reported error (bbox, spacing, duplicate slug). Review each `WARN:` 25 m-proximity pair and nudge one apart or accept knowingly.

- [ ] **Step 4: Write the failing dataset assertions** — replace the body of `CuratedGemProviderTests.loadsAndDecodesTheBundledSeed` and add a distribution test:

```swift
    @Test func loadsAndDecodesTheRealDataset() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        #expect(gems.count >= 140)
        #expect(gems.allSatisfy { $0.source == .curated })
        #expect(gems.contains { $0.id == "curated:grandview-overlook" && $0.tier == .cardHaptic })
        #expect(Set(gems.map(\.id)).count == gems.count)   // ids unique
    }

    @Test func tierThreeIsRareAndEarned() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        let t3 = gems.filter { $0.tier == .cardHaptic }
        #expect(t3.count <= 20)
        // No two Tier-3 within 1.5km (haptic clustering guard, mirrors build_gems.py).
        for i in t3.indices { for j in t3.indices where j > i {
            #expect(Geo.distance(t3[i].coordinate, t3[j].coordinate) >= 1500)
        } }
    }
```

- [ ] **Step 5: Run to verify (fails if the dataset is too small / violates rules)**

Builder agent: `swift test --package-path AuraCore --filter CuratedGemProviderTests`
Expected: PASS once Task 6 content is complete (the `dropsMalformedEntriesRatherThanThrowing` test is unaffected). If the old `loadsAndDecodesTheBundledSeed` name remains referenced elsewhere, remove it.

- [ ] **Step 6: Update the provider header note** — in `CuratedGemProvider.swift`, replace the "placeholder starter content … Tracked on the board as ROH-58" paragraph with:

```swift
/// Loads the hand-curated gem set bundled with the package. Malformed entries are
/// dropped, never fatal — a stale or partially-bad bundle must not crash a ride.
///
/// `gems.json` is generated from `Tools/gems/gems.tsv` by `Tools/gems/build_gems.py`
/// (see `Tools/gems/README.md`). Do not hand-edit the JSON — edit the TSV and regenerate.
```

- [ ] **Step 7: Write the README** — create `Tools/gems/README.md` documenting: the TSV columns; `python3 geocode.py` then `python3 build_gems.py`; the bbox/slug/tier/spacing/photo rules; the `why` style guide (banned list + variety rule); the curated-vs-live inclusion rule; and the **hard requirement that photo assets live in the Aura app target** named `gem-<slug>`.

- [ ] **Step 8: Commit**

```bash
git add Tools/gems/gems.tsv Tools/gems/geocode_cache.json Tools/gems/README.md \
  AuraCore/Sources/AuraKit/Resources/gems.json \
  AuraCore/Sources/AuraKit/Gems/CuratedGemProvider.swift \
  AuraCore/Tests/AuraKitTests/CuratedGemProviderTests.swift
git commit -m "feat(gems): author real ~150-gem Pittsburgh curated dataset"
```

---

### Task 7: Add Tier-3 photos (asset catalog in the Aura app target)

**Files:**
- Create: `Aura/Resources/GemPhotos.xcassets/` (asset catalog + per-photo imagesets)
- Modify: `project.yml` (xcodegen — ensure the catalog is a resource of the Aura target) and regenerate the project
- Modify: `Tools/gems/gems.tsv` (set `photo`/`attribution` on gems that got an image) and regenerate `gems.json`

**Interfaces:**
- Consumes: the Tier-3 gems from Task 6; `gemPhotoCredit` (Task 2).
- Produces: `gem-<slug>` images resolvable via `UIImage(named:)` from `Bundle.main`.

- [ ] **Step 1: Source images.** For each Tier-3 gem, find a freely-licensed Wikimedia Commons image (prefer PD/CC0; CC-BY/CC-BY-SA acceptable). Record the author + license for the `attribution` column (use `PD` for public-domain/CC0). Skip any gem with no acceptable-license image — the sheet degrades gracefully. Download to a scratch dir; downscale to ≤ 1600px long edge.

- [ ] **Step 2: Build the asset catalog.** Create `Aura/Resources/GemPhotos.xcassets` with one imageset per photo named exactly `gem-<slug>`. Confirm in `project.yml` that `Aura/Resources` (or the catalog) is in the **Aura app target's** sources/resources, not AuraKit. Regenerate: `xcodegen generate` (per repo convention — the project is gitignored/regenerated).

- [ ] **Step 3: Wire attribution into the TSV and regenerate**

Set `photo=gem-<slug>` and `attribution=<credit or PD>` on each gem that got an image, then:
Run: `cd Tools/gems && python3 build_gems.py`
Expected: regenerates `gems.json` with `photoAsset`/`photoAttribution` populated; zero fatal errors (the `photo == gem-<slug>` and attribution-required checks pass).

- [ ] **Step 4: Verify target membership (the silent-failure guard).** Build the Aura app scheme (builder agent) and confirm BUILD SUCCEEDED. Confirm the catalog's target membership is Aura only.

- [ ] **Step 5: Commit**

```bash
git add Aura/Resources/GemPhotos.xcassets project.yml Tools/gems/gems.tsv AuraCore/Sources/AuraKit/Resources/gems.json
git commit -m "feat(gems): add Wikimedia photos + attribution for Tier-3 gems"
```

---

### Task 8: Full verification — build + simulator smoke

**Files:** none (verification only).

- [ ] **Step 1: Full package test suite**

Builder agent: `swift test --package-path AuraCore`
Expected: all suites PASS (Gem, GemPhotoCredit, CuratedGemProvider, Composite, engine, etc.).

- [ ] **Step 2: Python suite**

Run: `cd Tools/gems && python3 -m unittest discover -v`
Expected: all PASS.

- [ ] **Step 3: App build + simulator smoke.** Build and launch the Aura app on the iPhone simulator (builder agent for build; `ios-simulator-mcp` to launch/inspect). Start a ride near downtown Pittsburgh (sim location ~40.44, −80.00). Confirm: gems appear as pins/cards on the map; opening a Tier-3 gem's detail sheet shows its photo with a `Photo: …` credit line; a Tier-1 pin's sheet renders without a photo. Capture the accessibility tree (preferred over screenshot) to confirm gem names surface.

- [ ] **Step 4: Regeneration determinism check**

Run: `cd Tools/gems && python3 build_gems.py && git diff --exit-code AuraCore/Sources/AuraKit/Resources/gems.json`
Expected: exit 0 (no diff) — proves the build is deterministic.

- [ ] **Step 5: Commit any final fixes** (if the smoke test surfaced issues).

---

## Self-Review

**Spec coverage:**
- Pipeline (TSV source, geocode.py, deterministic build_gems.py, README) → Tasks 4, 5, 6. ✓
- `photoAttribution` schema + UI wiring this pass → Tasks 1, 2. ✓
- ~150 gems, explicit tiers, Tier-3 cap + 1.5 km spacing, curated-vs-live, voice/coverage → Task 6 + Global Constraints. ✓
- Tier-3 Wikimedia photos in Aura app target, gem-<slug> naming → Task 7. ✓
- arrivalRadiusMeters mural/landmark 30→38, viewpoint unchanged → Task 3. ✓
- Provider header + tests updated, build + sim smoke, determinism → Tasks 6, 8. ✓
- Validation holes from review (slug charset, NFC, no-tab, photo/attr matrix, 25 m warn) → Task 4. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `gemPhotoCredit(_:)`, `Gem.photoAttribution`, `build_gems.validate/to_gem/haversine_m`, `geocode.merge_coords/needs_geocode/geocode_query` are named identically where produced and consumed. `to_gem` emits keys matching the `Gem` Codable shape (`coordinate.latitude/longitude`, `photoAsset`, `photoAttribution`). ✓
