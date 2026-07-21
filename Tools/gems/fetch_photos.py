#!/usr/bin/env python3
"""Authoring-time gem photo sourcer (Wikimedia Commons). NOT part of the build.

For each curated Tier-3 hero (QUERIES) and each curated Tier-2 target (TIER2_QUERIES)
in gems.json, searches Commons for an image, accepts only freely-licensed files
(PD / CC0 / CC BY / CC BY-SA, never NC/ND), downloads it into the Aura app target's
asset catalog as gem-<slug>, records the source+license+author in PHOTO_LICENSES.md,
and writes photo/attribution back into gems.tsv. Tier-2 uses a leaner width than Tier-3
to bound bundle growth.

Best-effort: a gem with no clearly-licensed image is skipped (ships photoless).
Usage: python3 fetch_photos.py   (rate-limited). Re-run safe for cleanly-completed runs:
it skips any imageset that already exists, so shipped photos and their credit rows are left
untouched. If a run is interrupted mid-loop, delete any imageset that was written without a
matching PHOTO_LICENSES.md row before re-running (the skip is keyed on imageset existence).
"""
import csv, html, json, re, sys, time, urllib.parse, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
GEMS_JSON = ROOT / "AuraCore/Sources/AuraKit/Resources/gems.json"
TSV = HERE / "gems.tsv"
CATALOG = ROOT / "Aura/Resources/GemPhotos.xcassets"
LICENSES_MD = HERE / "PHOTO_LICENSES.md"
UA = "aura-gem-authoring/1.0 (https://linear.app/rohun; dev contact)"
API = "https://commons.wikimedia.org/w/api.php"

# Per-gem Commons search terms (more precise than the display name alone).
QUERIES = {
    "grandview-overlook": "Pittsburgh skyline from Mount Washington",
    "west-end-overlook": "West End Overlook Pittsburgh",
    "randyland": "Randyland Pittsburgh",
    "canton-avenue": "Canton Avenue Pittsburgh",
    "cathedral-of-learning": "Cathedral of Learning",
    "carrie-blast-furnaces": "Carrie Furnace",
    "st-anthony-chapel": "St. Anthony Chapel Pittsburgh",
    "allegheny-cemetery": "Allegheny Cemetery Pittsburgh",
    "frick-park": "Frick Park Pittsburgh",
    "highland-park": "Highland Park Pittsburgh reservoir",
    "riverview-park": "Allegheny Observatory Pittsburgh",
    "hot-metal-bridge": "Hot Metal Bridge Pittsburgh",
}

# Curated Tier-2 photo targets — the most-reachable "reveal" spots. Photos are best-effort:
# a slug with no clearly-licensed Commons image just ships photoless. Tier-2 photos are
# fetched at a leaner width than Tier-3 (see TIER2_WIDTH) to keep the app bundle small.
TIER2_QUERIES = {
    "phipps-conservatory": "Phipps Conservatory Pittsburgh",
    "duquesne-incline": "Duquesne Incline",
    "monongahela-incline": "Monongahela Incline Pittsburgh",
    "andy-warhol-museum": "Andy Warhol Museum Pittsburgh",
    "pnc-park": "PNC Park Pittsburgh",
    "station-square": "Station Square Pittsburgh",
    "fort-pitt-block-house": "Fort Pitt Block House",
    "heinz-hall": "Heinz Hall Pittsburgh",
    "mexican-war-streets": "Mexican War Streets Pittsburgh",
    "gulf-tower": "Gulf Tower Pittsburgh",
    "union-station-rotunda": "Union Station Pittsburgh rotunda",
    "heinz-chapel": "Heinz Memorial Chapel",
    "smithfield-street-bridge": "Smithfield Street Bridge Pittsburgh",
    "roberto-clemente-bridge": "Roberto Clemente Bridge",
    "national-aviary": "National Aviary Pittsburgh",
    "mattress-factory": "Mattress Factory Pittsburgh",
}

TIER3_WIDTH = 1600   # Tier-3 photos are the full-size hero reveal.
TIER2_WIDTH = 1000   # Tier-2 photos are leaner to bound bundle growth.

# Accept if any of these appear in LicenseShortName; reject if any NEG appears.
POS = ("cc0", "public domain", "cc by")
NEG = ("nc", "nd", "non-commercial", "noncommercial", "fair use", "no known copyright")

def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()

def _api(params):
    return json.loads(_get(API + "?" + urllib.parse.urlencode(params)))

def _strip(s):
    # Drop HTML, then neutralize characters that would break the markdown credit table or
    # the tab-separated gems.tsv on the round-trip (Commons Artist fields are free-form and
    # can carry pipes, <br>-newlines, or tabs).
    t = re.sub(r"<[^>]+>", "", html.unescape(s or ""))
    return re.sub(r"\s+", " ", t.replace("|", "/").replace("\t", " ")).strip()

def license_ok(short):
    s = (short or "").lower()
    if not s or any(n in s for n in NEG):
        return False
    return any(p in s for p in POS)

def is_public_domain(short):
    s = (short or "").lower()
    return "cc0" in s or "public domain" in s

def find_image(query, urlwidth=TIER3_WIDTH, used=frozenset()):
    """Return (thumburl, filepage, license_short, artist, width) for the first acceptable file.

    `used` is a set of Commons file-page URLs already assigned to another gem; such hits are
    skipped so two gems whose queries collide on the same popular image don't ship duplicates.
    """
    data = _api({
        "action": "query", "format": "json", "generator": "search",
        "gsrsearch": query, "gsrnamespace": "6", "gsrlimit": "12",
        "prop": "imageinfo", "iiprop": "extmetadata|url|size|mime", "iiurlwidth": str(urlwidth),
    })
    time.sleep(1.0)
    pages = (data.get("query") or {}).get("pages") or {}
    # Prefer search rank (index), then larger images.
    for p in sorted(pages.values(), key=lambda p: p.get("index", 999)):
        ii = (p.get("imageinfo") or [{}])[0]
        if ii.get("mime") not in ("image/jpeg", "image/png"):
            continue
        if ii.get("descriptionurl", "") in used:   # already assigned to another gem
            continue
        meta = ii.get("extmetadata") or {}
        short = (meta.get("LicenseShortName") or {}).get("value", "")
        if not license_ok(short):
            continue
        if (ii.get("width") or 0) < 800:
            continue
        artist = _strip((meta.get("Artist") or {}).get("value", "")) or "Wikimedia Commons"
        return (ii.get("thumburl") or ii.get("url"), ii.get("descriptionurl", ""),
                short, artist, ii.get("width"))
    return None

def write_imageset(slug, img_bytes, ext):
    d = CATALOG / f"gem-{slug}.imageset"
    d.mkdir(parents=True, exist_ok=True)
    fname = f"gem-{slug}.{ext}"
    (d / fname).write_bytes(img_bytes)
    (d / "Contents.json").write_text(json.dumps({
        "images": [{"idiom": "universal", "filename": fname}],
        "info": {"version": 1, "author": "xcode"},
    }, indent=2) + "\n")

def parse_existing_audit():
    """Read the current PHOTO_LICENSES.md table so already-fetched photos keep their
    credit rows when the script is re-run (it only fetches missing imagesets)."""
    rows = {}
    if not LICENSES_MD.exists():
        return rows
    for line in LICENSES_MD.read_text().splitlines():
        cells = [c.strip() for c in line.split("|")]
        # Table body rows look like: ['', 'gem-slug', 'license', 'author', 'filepage', '']
        if len(cells) >= 6 and cells[1].startswith("gem-") and cells[1] != "gem":
            slug = cells[1][len("gem-"):]
            rows[slug] = (slug, cells[4], cells[2], cells[3])
    return rows


def main():
    gems = json.loads(GEMS_JSON.read_text())
    by_slug = {g["id"].split(":", 1)[1]: g for g in gems}
    # Targets = curated Tier-3 (full width) + curated Tier-2 (leaner). Only slugs that
    # exist in gems.json at the expected tier are considered.
    targets = []   # (slug, query, width)
    for slug, q in QUERIES.items():
        if by_slug.get(slug, {}).get("tier") == 3:
            targets.append((slug, q, TIER3_WIDTH))
    for slug, q in TIER2_QUERIES.items():
        if by_slug.get(slug, {}).get("tier") == 2:
            targets.append((slug, q, TIER2_WIDTH))

    CATALOG.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_text(json.dumps(
        {"info": {"version": 1, "author": "xcode"}}, indent=2) + "\n")

    results = {}   # slug -> attribution string (or "PD") for freshly-fetched photos
    audit = []     # (slug, filepage, license_short, artist) for freshly-fetched photos
    # Commons file pages already assigned to a gem — seeded from existing credits so a fresh
    # fetch never re-uses a photo a prior run (or another gem this run) already claimed.
    used = {r[1] for r in parse_existing_audit().values() if r[1]}
    for slug, q, width in targets:
        if (CATALOG / f"gem-{slug}.imageset").exists():
            print(f"keep {slug}: imageset already present"); continue
        try:
            hit = find_image(q, urlwidth=width, used=used)
        except Exception as e:
            print(f"skip {slug}: api error {e}", file=sys.stderr); continue
        if not hit:
            print(f"skip {slug}: no acceptable-license image", file=sys.stderr); continue
        thumb, filepage, short, artist, srcwidth = hit
        used.add(filepage)
        try:
            img = _get(thumb); time.sleep(0.5)
        except Exception as e:
            print(f"skip {slug}: download error {e}", file=sys.stderr); continue
        ext = "png" if thumb.lower().split("?")[0].endswith(".png") else "jpg"
        write_imageset(slug, img, ext)
        attribution = "PD" if is_public_domain(short) else f"{artist} / {short} via Wikimedia Commons"
        results[slug] = attribution
        audit.append((slug, filepage, short, artist))
        print(f"ok   {slug}: {short} — {artist}")

    # Write attribution + photo back into the TSV.
    lines = TSV.read_text().rstrip("\n").split("\n")
    F = lines[0].split("\t"); out = [lines[0]]
    for l in lines[1:]:
        vals = l.split("\t")
        vals += [""] * (len(F) - len(vals))   # tolerate a short row (dropped trailing empty col)
        d = dict(zip(F, vals))
        if d["slug"] in results:
            d["photo"] = f"gem-{d['slug']}"
            d["attribution"] = results[d["slug"]]
        out.append("\t".join(d.get(f, "") for f in F))
    TSV.write_text("\n".join(out) + "\n")

    # Audit file. Merge freshly-fetched rows over any preserved rows for imagesets that
    # still exist, so re-running (which skips already-downloaded photos) never drops credits.
    merged = {r[0]: r for r in parse_existing_audit().values()
              if (CATALOG / f"gem-{r[0]}.imageset").exists()}
    merged.update({slug: (slug, filepage, short, artist) for slug, filepage, short, artist in audit})
    md = ["# Curated gem photo licenses",
          "",
          "Sourced from Wikimedia Commons by `fetch_photos.py` (Tier-3 heroes + a curated Tier-2",
          "set). Only PD / CC0 / CC BY / CC BY-SA accepted (never NC/ND). `attribution` in",
          "`gems.tsv` renders as a credit line under the photo (public-domain images use `PD` and",
          "render no credit).",
          "", "| gem | license | author | Commons file page |", "|---|---|---|---|"]
    for slug, filepage, short, artist in sorted(merged.values()):
        md.append(f"| gem-{slug} | {short} | {artist} | {filepage} |")
    md.append("")
    LICENSES_MD.write_text("\n".join(md))
    print(f"\n{len(results)} new photo(s) fetched; {len(merged)} gems now have a licensed photo.")

if __name__ == "__main__":
    sys.exit(main())
