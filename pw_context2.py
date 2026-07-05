#!/usr/bin/env python3
"""Wide-window context for specific URL-defining strings. Pi-only, read-only."""
from __future__ import annotations
import re
import predictwind_server as P
P.MIN_REQUEST_GAP_S = 2.0
PW = P._pw
CDN = "https://cdn.predictwind.com"

MODULES = [
 "/static/CACHE/rollup/shared-tidalAPI-C7HvQ8-j.system.js",
 "/static/CACHE/rollup/shared-observations-CpVg_j2d.system.js",
 "/static/CACHE/rollup/shared-export-DtKc0ss1.system.js",
 "/static/CACHE/rollup/shared-showGPSMarker-Bw9EOAzv.system.js",
 "/static/javascript/atlas-dependencies-rolledup.js",
 "/static/javascript/atlas.js",
]
NEEDLES = [
 "atlas/metadata", "high-res-current-domains", "/observations/tile",
 "observations/user-data", "observations/ratings", "recent-plans",
 "datahub-2", "atlas/hindcast", "routerPrefs", "routerHubBasePolar",
 "router/boatPolar", "router/boatDimensions", "grib/loaded", "saveWaypoints",
 "waypointsExport", "waypointsImport", "tide", "extremes", "datum",
 "gmdss-get-warning", "americascup", "/overview/", "forecast-map-viewed",
 "gmap/settings", "pilot-chart", "tracking/yb", "tracking/display",
 "get-favourite-ais", "retrieve-vessel-type", "topContributors", "loadPassages",
 "pois.json", "boat/", "hindcast",
]
WIN = 200
out, seen = [], set()
for mod in MODULES:
    PW._rate_limit()
    try:
        r = PW._session.get(CDN + mod, timeout=60,
                            headers={"Accept": "*/*", "Referer": P.PW_BASE + "/"})
        txt = r.text if r.ok else ""
    except Exception as e:
        txt = ""
        out.append(f"ERR {mod}: {e}")
    out.append(f"\n{'#'*80}\n# {mod} ({len(txt)} chars)\n{'#'*80}")
    for needle in NEEDLES:
        cnt = 0
        for m in re.finditer(re.escape(needle), txt):
            if cnt >= 3:
                break
            s = max(0, m.start() - WIN); e = min(len(txt), m.end() + WIN)
            ctx = re.sub(r"\s+", " ", txt[s:e])
            key = ctx[:80]
            if key in seen:
                continue
            seen.add(key); cnt += 1
            out.append(f"  «{needle}» …{ctx}…")
open("/home/pi/pw_context2.txt", "w").write("\n".join(out))
print("done", len(out), "lines")
