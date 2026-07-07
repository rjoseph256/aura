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
