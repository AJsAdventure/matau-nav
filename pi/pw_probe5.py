#!/usr/bin/env python3
"""
Round 5 — make the discovered endpoints USABLE: decode data formats + confirm the
GRIB-tile pipeline end-to-end. Pi-only, read-only, serial. NO computations submitted.
Output: stdout + /home/pi/pw_probe5.txt
"""
from __future__ import annotations
import json, re, time, urllib.parse
import predictwind_server as P
P.MIN_REQUEST_GAP_S = 3.0
PW = P._pw; B = P.PW_BASE; CDN = "https://cdn.predictwind.com"
LIVE = 3772676   # Sporades (live)
OUT = []
def log(*a):
    s = " ".join(str(x) for x in a); print(s); OUT.append(s)

def gj(p, par=None, ref=None):
    PW._rate_limit()
    r = PW._session.get(B+p, params=par, timeout=45,
        headers={"Referer": ref or B+"/", "X-Requested-With":"XMLHttpRequest",
                 "Accept":"application/json,*/*"})
    return r

def graw(url, ref=None, acc="*/*"):
    PW._rate_limit()
    r = PW._session.get(url, timeout=45, headers={"Referer": ref or B+"/", "Accept":acc})
    return r

# ---------------------------------------------------------------- GRIB pipeline
log("\n=== 1. GRIB-tile pipeline (metadata -> real gribKey -> actual tile) ===")
m = gj("/atlas/metadata", {"ma": LIVE}, ref=B+"/atlas/").json()
gi = m.get("GRIBIndex", {})
log(f"GRIBIndex entries: {len(gi)}")
if gi:
    k0 = next(iter(gi)); e0 = gi[k0]
    log("first key:", k0)
    log("  source/label/units/layerName:", e0.get("source"), "/", e0.get("label"), "/", e0.get("units"), "/", e0.get("layerName"))
    log("  displays:", e0.get("displays"))
    auth = e0.get("auth", {})
    log("  auth keys:", list(auth))
    # auth[var] is the actual signed tile URL (or prefix). Fetch one directly.
    for var in ("Wind", "Pressure", "Rain"):
        if var in auth:
            u = auth[var]
            full = u if u.startswith("http") else (CDN + u if u.startswith("/") else B + "/" + u)
            r = graw(full, ref=B+"/atlas/")
            log(f"  auth[{var}] -> {r.status_code} {len(r.content)}b ct={r.headers.get('Content-Type','')[:22]} magic={r.content[:8].hex()}")
            log(f"     url: {u[:120]}")
            break

# ---------------------------------------------------------------- lightning decode
log("\n=== 2. Lightning strike tuple decode ===")
lt = gj("/lightning-tile.json", ref=B+"/atlas/").json()
strikes = lt.get("strikes", [])
log(f"buckets: {len(strikes)}  bucket0 strikes: {len(strikes[0]) if strikes else 0}")
if strikes and strikes[0]:
    for s in strikes[0][:4]:
        log("  raw tuple:", s)
    # heuristic: guess lat/lon scaling from ranges
    import statistics
    cols = list(zip(*[s for s in strikes[0] if len(s)==5]))
    for i,c in enumerate(cols):
        log(f"  col{i}: min={min(c)} max={max(c)}")

# ---------------------------------------------------------------- obs decode
log("\n=== 3. Observation encoding decode (find a populated tile) ===")
found=False
for la,lo in [(37.084,25.153),(35.9,14.5),(43.3,5.4),(50.9,-1.4),(40.6,14.3)]:
    x,y = P.lat_lon_to_tile(la,lo,10)
    r = gj(f"/observations/tile/10/{x}/{y}.json", {"t":int(time.time()*1000)}, ref=B+"/observations/")
    if r.status_code==200 and r.content:
        j=r.json(); tracks=j.get("tracks",{})
        if tracks:
            found=True
            log(f"tile z10/{x}/{y} ({la},{lo}): {len(tracks)} tracks, updated={j.get('updated')}")
            tid=next(iter(tracks)); t=tracks[tid]
            log(f"  id={tid}  t(descriptor)={t.get('t')}")
            log(f"  latest l={t.get('l')}")
            log(f"  history s (first 2 samples)={'|'.join(t.get('s','').split('|')[:2])}")
            # decode one sample: epoch+lat+lon dDIR sSPD tTEMP pPRESS
            samp=t.get('l','')
            mm=re.match(r'(\d+)([+-]\d+)([+-]\d+)(?:d(\d+))?(?:s(\d+))?(?:t(\d+))?(?:p(\d+))?', samp)
            if mm: log("  decoded latest:", {"epoch":mm.group(1),"lat_raw":mm.group(2),"lon_raw":mm.group(3),"dir":mm.group(4),"spd":mm.group(5),"temp":mm.group(6),"press":mm.group(7)})
            break
if not found: log("  no populated obs tile found among probes (likely sparse/night)")

# ---------------------------------------------------------------- power planner paths
log("\n=== 4. Power planner endpoint existence (GET; 405=exists POST-only, 404=absent) ===")
for p in ("/atlas/powerPlanner/submit","/atlas/powerPlanner/finished","/atlas/powerPlanner/results"):
    r = gj(p, ref=B+"/atlas/powerPlanner/")
    log(f"  {p} -> {r.status_code} {len(r.content)}b")

# ---------------------------------------------------------------- localtime param
log("\n=== 5. /localtime param (times list) ===")
now=int(time.time())
for par in ({"lat":37.08,"lon":25.15},{"lat":37.08,"lon":25.15,"times":now},{"lat":37.08,"lon":25.15,"times":f"{now},{now+3600}"}):
    r=gj("/localtime", par, ref=B+"/atlas/sailRouter/")
    log(f"  params={par} -> {r.status_code} {r.text[:120]}")

# ---------------------------------------------------------------- pilot chart params (from JS)
log("\n=== 6. Pilot-chart param hunt (JS + probes) ===")
# find the LK/pilot module: grep atlas.js + deps for pilot fetch construction
for src in [CDN+"/static/javascript/atlas-dependencies-rolledup.js"]:
    txt = graw(src, ref=B+"/").text
    for kw in ["pilot-chart-data","pilot-chart-rose","pilotData","pilotTile","pilot_data","pilotChart"]:
        for mm in list(re.finditer(re.escape(kw),txt))[:2]:
            s=max(0,mm.start()-90); e=min(len(txt),mm.end()+130)
            log(f"  [{kw}] …"+re.sub(r'\s+',' ',txt[s:e])+"…")
# probe a few plausible param forms
for par in ({"month":7},{"month":7,"sw":"30,10","ne":"46,20"},{"lat":36,"lon":15,"month":7},{"c":205032}):
    r=gj("/pilot-chart-data.json", par, ref=B+"/local-knowledge/pilot-chart-only/")
    log(f"  pilot-chart-data {par} -> {r.status_code} {len(r.content)}b {r.text[:80] if r.status_code==200 else ''}")

# ---------------------------------------------------------------- gmdss detail id form
log("\n=== 7. gmdss-get-warning-details id form (from JS) ===")
for src in [CDN+"/static/CACHE/rollup/shared-gmdssGraphics-C0LKvXk3.system.js"]:
    txt = graw(src, ref=B+"/").text
    i = txt.find("gmdss-get-warning-details")
    if i>=0: log("  ctx:", re.sub(r'\s+',' ',txt[max(0,i-260):i+120]))

open("/home/pi/pw_probe5.txt","w").write("\n".join(OUT))
log("\ndone")
