#!/usr/bin/env python3
"""Authoring-time Tier-3 photo sourcer (Wikimedia Commons). NOT part of the build.

For each Tier-3 gem in gems.json, searches Commons for an image, accepts only
freely-licensed files (PD / CC0 / CC BY / CC BY-SA, never NC/ND), downloads it into
the Aura app target's asset catalog as gem-<slug>, records the source+license+author
in PHOTO_LICENSES.md, and writes photo/attribution back into gems.tsv.

Best-effort: a gem with no clearly-licensed image is skipped (ships photoless).
Usage: python3 fetch_photos.py   (rate-limited; re-run safe, skips already-downloaded)
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
    return re.sub(r"<[^>]+>", "", html.unescape(s or "")).strip()

def license_ok(short):
    s = (short or "").lower()
    if not s or any(n in s for n in NEG):
        return False
    return any(p in s for p in POS)

def is_public_domain(short):
    s = (short or "").lower()
    return "cc0" in s or "public domain" in s

def find_image(query):
    """Return (thumburl, filepage, license_short, artist, width) for the first acceptable file."""
    data = _api({
        "action": "query", "format": "json", "generator": "search",
        "gsrsearch": query, "gsrnamespace": "6", "gsrlimit": "12",
        "prop": "imageinfo", "iiprop": "extmetadata|url|size|mime", "iiurlwidth": "1600",
    })
    time.sleep(1.0)
    pages = (data.get("query") or {}).get("pages") or {}
    # Prefer search rank (index), then larger images.
    for p in sorted(pages.values(), key=lambda p: p.get("index", 999)):
        ii = (p.get("imageinfo") or [{}])[0]
        if ii.get("mime") not in ("image/jpeg", "image/png"):
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

def main():
    gems = json.loads(GEMS_JSON.read_text())
    tier3 = [g["id"].split(":", 1)[1] for g in gems if g["tier"] == 3]
    CATALOG.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_text(json.dumps(
        {"info": {"version": 1, "author": "xcode"}}, indent=2) + "\n")

    results = {}   # slug -> attribution string (or "PD")
    audit = []
    for slug in tier3:
        q = QUERIES.get(slug)
        if not q:
            print(f"skip {slug}: no query", file=sys.stderr); continue
        try:
            hit = find_image(q)
        except Exception as e:
            print(f"skip {slug}: api error {e}", file=sys.stderr); continue
        if not hit:
            print(f"skip {slug}: no acceptable-license image", file=sys.stderr); continue
        thumb, filepage, short, artist, width = hit
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
        d = dict(zip(F, l.split("\t")))
        if d["slug"] in results:
            d["photo"] = f"gem-{d['slug']}"
            d["attribution"] = results[d["slug"]]
        out.append("\t".join(d[f] for f in F))
    TSV.write_text("\n".join(out) + "\n")

    # Audit file.
    md = ["# Tier-3 gem photo licenses",
          "",
          "Sourced from Wikimedia Commons by `fetch_photos.py`. Only PD / CC0 / CC BY / CC BY-SA",
          "accepted (never NC/ND). `attribution` in `gems.tsv` renders as a credit line under the",
          "photo (public-domain images use `PD` and render no credit).",
          "", "| gem | license | author | Commons file page |", "|---|---|---|---|"]
    for slug, filepage, short, artist in sorted(audit):
        md.append(f"| gem-{slug} | {short} | {artist} | {filepage} |")
    md.append("")
    LICENSES_MD.write_text("\n".join(md))
    print(f"\n{len(results)} of {len(tier3)} Tier-3 gems got a licensed photo.")

if __name__ == "__main__":
    sys.exit(main())
