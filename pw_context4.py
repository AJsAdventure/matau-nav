#!/usr/bin/env python3
"""Find consumption sites (params) for metadata / obs tile / pilot chart / stored-route.
Pi-only, read-only."""
from __future__ import annotations
import re
import predictwind_server as P
P.MIN_REQUEST_GAP_S = 2.5
PW = P._pw
CDN = "https://cdn.predictwind.com"
BASE = P.PW_BASE

SRC = [
 CDN+"/static/CACHE/rollup/shared-observations-CpVg_j2d.system.js",
 CDN+"/static/CACHE/rollup/shared-grib-metadata-CVSgYZUw.system.js",
 CDN+"/static/CACHE/rollup/shared-forecastAtlas-CfftgUAL.system.js",
 CDN+"/static/CACHE/rollup/shared-atlas-CgG5Ytjs.system.js",
 CDN+"/static/javascript/atlas.js",
 CDN+"/static/javascript/atlas-dependencies-rolledup.js",
 CDN+"/static/CACHE/js/output.0a7e7ff69519.js",
 CDN+"/static/CACHE/js/output.133bc75fd610.js",
 CDN+"/static/CACHE/js/output.2947d77a32fe.js",
 BASE+"/local-knowledge/pilot-chart-only/",   # HTML: find its script + data attrs
]
NEEDLES = [
 "atlasMetadata", "MetadataUrl", "metadataUrl", "loadGribIndex", "gribIndexUrl",
 "observationsTileUrl", "OBSERVATIONS_TILE_URL", "obsTile", "tileUrlTemplate",
 "pilotData", "pilotTile", "pilot-chart", "pilotChart", "pilot_data",
 "stored-route", "storedRoute", "routeMode", "/atlas/metadata",
 "high-res-current", "getMetadata", "fetchMetadata",
]
WIN = 220
out, seen = [], set()
for url in SRC:
    PW._rate_limit()
    try:
        r = PW._session.get(url, timeout=60, headers={"Accept":"*/*","Referer":BASE+"/"})
        txt = r.text if r.ok else ""
    except Exception as e:
        txt=""; out.append(f"ERR {url}: {e}")
    out.append(f"\n{'#'*80}\n# {url.replace(CDN,'').replace(BASE,'')} ({len(txt)} chars)\n{'#'*80}")
    for n in NEEDLES:
        c=0
        for m in re.finditer(re.escape(n), txt):
            if c>=2: break
            s=max(0,m.start()-WIN); e=min(len(txt),m.end()+WIN)
            ctx=re.sub(r"\s+"," ",txt[s:e])
            if ctx[:80] in seen: continue
            seen.add(ctx[:80]); c+=1
            out.append(f"  «{n}» …{ctx}…")
open("/home/pi/pw_context4.txt","w").write("\n".join(out))
print("done",len(out))
