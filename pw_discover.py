#!/usr/bin/env python3
"""
PredictWind endpoint DISCOVERY — runs ON THE PI ONLY.

Mines the web app's own HTML pages + JS bundles (fetched through the Pi's
authenticated session, exactly as a browser loads its own assets) and extracts
every URL/endpoint pattern the front-end references.  This is far safer and more
complete than blind URL guessing: we only fetch resources the app itself serves,
and we never mutate anything.

SAFETY:
  * Reuses predictwind_server._pw (same rate limiter / session / CSRF).
  * Serial, DISCOVER_GAP_S between calls.
  * Read-only.  Fetches HTML app shells + their JS/CSS assets only.

Output: /home/pi/pw_discover.json
"""
from __future__ import annotations
import json, re, sys, time
import predictwind_server as P

DISCOVER_GAP_S = 3.0
P.MIN_REQUEST_GAP_S = DISCOVER_GAP_S
PW = P._pw
BASE = P.PW_BASE

# App "shell" pages a logged-in user visits.  Each pulls in its own JS bundles.
PAGES = [
    "/",
    "/table/",
    "/graph/",
    "/map/",
    "/maps/",
    "/local-knowledge/",
    "/local-knowledge/ais-data-only/",
    "/atlas/",
    "/atlas/sailRouter/",
    "/atlas/sailPlanner/",
    "/atlas/weatherRouting/",
    "/gps/",
    "/tracking/",
    "/settings/",
    "/account/",
    "/profile/",
    "/forecast/",
    "/observations/",
    "/tides/",
]

# Patterns that look like a backend endpoint reference inside JS/HTML.
# We collect quoted strings and template pieces that contain a path.
PATH_RE = re.compile(r'["\'`]((?:/|(?:https?://[^"\'`]*?))[A-Za-z0-9_\-./]{1,120})["\'`]')
AJAX_URL_RE = re.compile(r'url\s*:\s*["\'`]([^"\'`]+)["\'`]')
FETCH_RE = re.compile(r'(?:fetch|\$j?\.(?:get|post|ajax|getJSON))\s*\(\s*["\'`]([^"\'`]+)["\'`]')
SCRIPT_SRC_RE = re.compile(r'<script[^>]+src=["\']([^"\']+)["\']', re.I)

# Keep only paths that plausibly hit the Django backend (not static images/fonts).
INTERESTING = re.compile(
    r'(atlas|local-knowledge|table|settings|location|gps|track|tide|observ|'
    r'account|profile|user|api|forecast|sail|polar|route|ais|boat|gmdss|'
    r'grib|warning|passage|poi|contributor|favourite|subscription|alert|alarm|'
    r'datahub|position|twilight|updateStatus|overview|export|recent|stored|hub)',
    re.I)
# Reject obvious static assets.
STATIC = re.compile(r'\.(png|jpg|jpeg|gif|svg|woff2?|ttf|eot|ico|css|map|mp4|webp)(\?|$)', re.I)

RESULTS = {"pages": {}, "scripts": {}, "endpoints": {}}


def fetch(path, is_asset=False):
    PW._rate_limit()
    url = path if path.startswith("http") else BASE + path
    hdrs = {"Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
            "Referer": BASE + "/"}
    try:
        r = PW._session.get(url, headers=hdrs, timeout=30)
        return r
    except Exception as e:
        print(f"  ERR {path}: {e}")
        return None


def harvest(text, source):
    found = set()
    for rx in (PATH_RE, AJAX_URL_RE, FETCH_RE):
        for m in rx.finditer(text):
            u = m.group(1)
            if STATIC.search(u):
                continue
            if not INTERESTING.search(u):
                continue
            # Normalise absolute same-origin URLs to path
            if u.startswith("http"):
                if "predictwind.com" not in u:
                    continue
                u = "/" + u.split("/", 3)[-1] if u.count("/") >= 3 else u
            found.add(u.split("?")[0].split("#")[0])
    for u in found:
        RESULTS["endpoints"].setdefault(u, []).append(source)
    return found


def main():
    print(f"DISCOVER start gap={DISCOVER_GAP_S}s")
    script_urls = set()
    for pg in PAGES:
        r = fetch(pg)
        if r is None:
            continue
        info = {"status": r.status_code, "len": len(r.content),
                "ct": r.headers.get("Content-Type", ""), "final": r.url}
        RESULTS["pages"][pg] = info
        print(f"  [{r.status_code}] {pg:<32} {len(r.content):>8}b -> {r.url}")
        if r.ok and "html" in info["ct"]:
            f = harvest(r.text, pg)
            for m in SCRIPT_SRC_RE.finditer(r.text):
                s = m.group(1)
                if s.startswith("//"):
                    s = "https:" + s
                script_urls.add(s)
            print(f"        {len(f)} endpoint refs, {len(script_urls)} scripts so far")

    # Fetch same-origin JS bundles and harvest endpoints from them.
    same = [s for s in script_urls
            if s.startswith("/") or "predictwind.com" in s]
    print(f"\n  fetching {len(same)} same-origin script bundles…")
    for s in sorted(same):
        r = fetch(s, is_asset=True)
        if r is None or not r.ok:
            RESULTS["scripts"][s] = {"status": r.status_code if r else "ERR"}
            continue
        f = harvest(r.text, s)
        RESULTS["scripts"][s] = {"status": r.status_code, "len": len(r.content),
                                 "endpoints_found": len(f)}
        print(f"  [{r.status_code}] {s[-60:]:<60} {len(r.content):>8}b  +{len(f)} eps")

    with open("/home/pi/pw_discover.json", "w") as fh:
        json.dump(RESULTS, fh, indent=2, default=str)
    print(f"\nDISCOVER done: {len(RESULTS['endpoints'])} unique endpoint refs")
    for u in sorted(RESULTS["endpoints"]):
        print("   ", u)


if __name__ == "__main__":
    main()
