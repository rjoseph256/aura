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
