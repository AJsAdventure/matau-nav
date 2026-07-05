#!/usr/bin/env python3
"""
PredictWind JS CONTEXT extractor — runs ON THE PI ONLY.
Fetches the app's SystemJS rollup modules (public static CDN assets) and prints
the minified code AROUND each endpoint/keyword so we can learn the exact params,
HTTP method, and URL construction the front-end uses.  Read-only, serial.
Output: /home/pi/pw_context.txt
"""
from __future__ import annotations
import re, sys, time
import predictwind_server as P

P.MIN_REQUEST_GAP_S = 2.0
PW = P._pw
CDN = "https://cdn.predictwind.com"

MODULES = [
 "/static/CACHE/rollup/shared-observations-CpVg_j2d.system.js",
 "/static/CACHE/rollup/shared-tidalAPI-C7HvQ8-j.system.js",
 "/static/CACHE/rollup/shared-grib-metadata-CVSgYZUw.system.js",
 "/static/CACHE/rollup/shared-globalGrib-PjTCyCLQ.system.js",
 "/static/CACHE/rollup/shared-gmdssGraphics-C0LKvXk3.system.js",
 "/static/CACHE/rollup/shared-gmdssGlobal-CeolLQrX.system.js",
 "/static/CACHE/rollup/shared-track-display-A9jXlJXW.system.js",
 "/static/CACHE/rollup/shared-showGPSMarker-Bw9EOAzv.system.js",
 "/static/CACHE/rollup/shared-export-DtKc0ss1.system.js",
 "/static/CACHE/rollup/shared-map-forecast-options-vh9OIEkv.system.js",
 "/static/CACHE/rollup/shared-forecastAtlas-CfftgUAL.system.js",
 "/static/CACHE/rollup/shared-atlas-CgG5Ytjs.system.js",
 "/static/CACHE/rollup/shared-location-markers-owynshYr.system.js",
 "/static/javascript/atlas.js",
 "/static/javascript/atlas-dependencies-rolledup.js",
]

# Endpoint / keyword needles to locate.  For each hit, print surrounding context.
NEEDLES = [
 "/observations", "observations/tile", "/alerts", "alerts/manage",
 "/atlas/metadata", "atlas/grib/loaded", "high-res-current-domains",
 "/atlas/hindcast", "hindcast", "powerPlanner", "routerPrefs",
 "routerHubBasePolar", "boatPolar", "boatDimensions", "saveWaypoints",
 "waypointsExport", "waypointsImport", "gribtile", "/tracking", "tracking/yb",
 "pilot-chart", "datahub", "recent-plans", "high-res-current",
 "tidal", "/overview", "gmdss", "getGrib", "grib/loaded", "sail-crossover",
]


def fetch(path):
    PW._rate_limit()
    try:
        r = PW._session.get(CDN + path, timeout=40,
                            headers={"Accept": "*/*", "Referer": P.PW_BASE + "/"})
        return r.text if r.ok else None, (r.status_code if r else None)
    except Exception as e:
        return None, str(e)


def main():
    out = []
    seen = set()
    for mod in MODULES:
        txt, st = fetch(mod)
        hdr = f"\n{'='*90}\nMODULE {mod}  (status={st}, {len(txt) if txt else 0} chars)\n{'='*90}"
        out.append(hdr)
        print(hdr)
        if not txt:
            continue
        for needle in NEEDLES:
            for m in re.finditer(re.escape(needle), txt):
                s = max(0, m.start() - 90)
                e = min(len(txt), m.end() + 90)
                ctx = txt[s:e].replace("\n", " ")
                key = (needle, ctx[:60])
                if key in seen:
                    continue
                seen.add(key)
                line = f"  «{needle}»  …{ctx}…"
                out.append(line)
    with open("/home/pi/pw_context.txt", "w") as f:
        f.write("\n".join(out))
    print(f"\nWROTE /home/pi/pw_context.txt  ({len(out)} lines)")


if __name__ == "__main__":
    main()
