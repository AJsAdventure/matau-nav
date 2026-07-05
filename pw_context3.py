#!/usr/bin/env python3
"""Scan main output.*.js bundles + app HTML for endpoint URL construction and
data-*-url attributes. Pi-only, read-only, serial."""
from __future__ import annotations
import re
import predictwind_server as P
P.MIN_REQUEST_GAP_S = 2.5
PW = P._pw
CDN = "https://cdn.predictwind.com"
BASE = P.PW_BASE

JS = [
 "/static/CACHE/js/output.0a7e7ff69519.js",
 "/static/CACHE/js/output.133bc75fd610.js",
 "/static/CACHE/js/output.2947d77a32fe.js",
 "/static/CACHE/js/output.8deb63a514ed.js",
 "/static/CACHE/js/output.dad67f5d9568.js",
]
HTML = ["/table/", "/atlas/sailRouter/", "/atlas/", "/observations/", "/maps/",
        "/tracking/", "/local-knowledge/"]

NEEDLES = [
 "atlas/metadata", "high-res-current-domains", "atlas/hindcast", "routerPrefs",
 "routerHubBasePolar", "router/boatPolar", "router/boatDimensions",
 "grib/loaded", "saveWaypoints", "waypointsExport", "waypointsImport",
 "recent-plans", "datahub-2", "powerPlanner", "gmdss-get-warning",
 "observations/tile", "/observations/user-data", "gmap/settings",
 "pilot-chart", "tracking/yb", "americascup", "upgradeRequired", "hindcast",
]
WIN = 180
out, seen = [], set()

def fetch(url):
    PW._rate_limit()
    try:
        r = PW._session.get(url, timeout=60,
                            headers={"Accept": "*/*", "Referer": BASE + "/"})
        return r.text if r.ok else "", r.status_code
    except Exception as e:
        return "", str(e)

for mod in JS:
    txt, st = fetch(CDN + mod)
    out.append(f"\n{'#'*80}\n# JS {mod} ({len(txt)} chars, {st})\n{'#'*80}")
    for needle in NEEDLES:
        c = 0
        for m in re.finditer(re.escape(needle), txt):
            if c >= 2:
                break
            s = max(0, m.start()-WIN); e = min(len(txt), m.end()+WIN)
            ctx = re.sub(r"\s+", " ", txt[s:e])
            if ctx[:70] in seen:
                continue
            seen.add(ctx[:70]); c += 1
            out.append(f"  «{needle}» …{ctx}…")

# HTML: dump data-*url and data-*="/path" attributes
DATA_RE = re.compile(r'data-([a-z0-9-]+)\s*=\s*"([^"]{1,160})"', re.I)
for pg in HTML:
    txt, st = fetch(BASE + pg)
    out.append(f"\n{'='*80}\n= HTML {pg} ({len(txt)} chars, {st})\n{'='*80}")
    attrs = {}
    for m in DATA_RE.finditer(txt):
        k, v = m.group(1), m.group(2)
        if "url" in k.lower() or v.startswith("/") or "predictwind" in v:
            attrs.setdefault(k, v)
    for k, v in sorted(attrs.items()):
        out.append(f"  data-{k} = {v}")

open("/home/pi/pw_context3.txt", "w").write("\n".join(out))
print("done", len(out), "lines")
