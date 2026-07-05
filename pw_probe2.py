#!/usr/bin/env python3
"""
PredictWind NEW-endpoint probe (round 2) — ON THE PI ONLY, read-only, serial.
Probes the endpoints discovered by JS/HTML mining. No mutations.
Output: /home/pi/pw_probe2.json  + stdout summary.
"""
from __future__ import annotations
import json, time, urllib.parse
import predictwind_server as P

P.MIN_REQUEST_GAP_S = 3.0
PW = P._pw
BASE = P.PW_BASE
RESULTS = []

# Busy-water tiles for observation/lightning probes.
CYCLADES = (37.084, 25.153)     # boat area
SOLENT   = (50.75, -1.30)       # UK south coast: dense PW station network


def summarize(o, d=0, md=4, mk=30, ml=3):
    if d >= md: return f"<{type(o).__name__}>"
    if isinstance(o, dict):
        out = {}
        for i,(k,v) in enumerate(o.items()):
            if i>=mk: out["…+%d"%(len(o)-mk)]=""; break
            out[str(k)] = summarize(v,d+1,md,mk,ml)
        return out
    if isinstance(o, list):
        return {"__len__":len(o), "__sample__":[summarize(x,d+1,md,mk,ml) for x in o[:ml]]}
    if isinstance(o, str): return o if len(o)<=90 else o[:90]+"…"
    return o


def get(path, params=None, referer=None, accept="application/json, text/javascript, */*; q=0.01",
        xhr=True, raw=False, note=""):
    PW._rate_limit()
    hdrs = {"Accept": accept, "Referer": referer or BASE+"/"}
    if xhr: hdrs["X-Requested-With"]="XMLHttpRequest"
    rec = {"path":path, "params":params or {}, "note":note}
    t0=time.time()
    try:
        r = PW._session.get(BASE+path if path.startswith("/") else path,
                            params=params, headers=hdrs, timeout=40)
        rec["status"]=r.status_code; rec["ok"]=r.ok
        rec["ct"]=r.headers.get("Content-Type","")[:40]
        rec["len"]=len(r.content); rec["elapsed"]=round(time.time()-t0,2)
        rec["final"]=r.url.replace(BASE,"")
        rec["cd"]=r.headers.get("Content-Disposition","")
        if raw:
            rec["magic"]=r.content[:16].hex()
            rec["sample"]=r.text[:160] if ("text" in rec["ct"] or "json" in rec["ct"] or "svg" in rec["ct"]) else "<binary>"
        else:
            ct=rec["ct"]
            body=r.text.strip()
            if "json" in ct or body[:1] in ("{","["):
                try: rec["shape"]=summarize(r.json())
                except Exception as e: rec["json_err"]=str(e); rec["sample"]=r.text[:200]
            else:
                rec["sample"]=r.text[:200]
    except Exception as e:
        rec["ok"]=False; rec["error"]=str(e); rec["elapsed"]=round(time.time()-t0,2)
    RESULTS.append(rec)
    flag="OK " if rec.get("ok") else "ERR"
    print(f"  [{flag}] {rec.get('status','?')} {path:<48} {rec.get('len','?')}b {rec.get('ct','')[:22]} {note}")
    if rec.get("error"): print("        error:",rec["error"])
    return rec


def main():
    print("PROBE2 start")
    atlas_ref = BASE+"/atlas/"
    router_ref = BASE+"/atlas/sailRouter/"
    obs_ref = BASE+"/observations/"

    print("\n--- Atlas / maps config ---")
    get("/atlas/metadata", referer=atlas_ref, note="grib index / model+layer config")
    get("/api/atlas/grib/loaded", referer=atlas_ref, note="grib loaded status")
    get("/atlas/high-res-current-domains.json", referer=atlas_ref, note="hi-res tidal current coverage")
    get("/atlas/routing-example-grib-metadata.json", referer=router_ref, note="example route metadata")
    get("/atlas/routerPrefs/", referer=router_ref, note="router preferences")
    get("/atlas/upgradeRequired/", referer=router_ref, note="subscription gate")
    get("/atlas/routerHubBasePolar/", referer=router_ref, note="router base polar")

    print("\n--- Boat polar / dimensions (path-param) ---")
    bn = urllib.parse.quote("Beneteau 40.7")
    get(f"/atlas/router/boatPolar/{bn}", referer=router_ref, note="boat polar by name")
    get(f"/atlas/router/boatDimensions/{bn}", referer=router_ref, note="boat dimensions by name")

    print("\n--- Lightning ---")
    get("/lightning-tile.json", referer=atlas_ref, note="lightning strikes (no params)")
    lx,ly = P.lat_lon_to_tile(*CYCLADES, 8)
    get("/lightning-tile.json", params={"x":lx,"y":ly,"z":8}, referer=atlas_ref, note="lightning tile z8 cyclades")

    print("\n--- Observations (weather stations) ---")
    for label,(la,lo) in (("cyclades",CYCLADES),("solent",SOLENT)):
        ox,oy = P.lat_lon_to_tile(la,lo,10)
        get("/observations/tile", params={"x":ox,"y":oy,"z":10}, referer=obs_ref, note=f"obs tile query {label}")
        get(f"/observations/tile/10/{ox}/{oy}", referer=obs_ref, note=f"obs tile path {label}")
    get("/observations/user-data", referer=obs_ref, note="obs user data")
    get("/observations/ratings", referer=obs_ref, note="obs ratings")

    print("\n--- Pilot charts (climatology) ---")
    get("/pilot-chart-data.json", referer=BASE+"/local-knowledge/", note="pilot chart data (no params)")
    get("/pilot-chart-rose.svg", accept="image/svg+xml,*/*", xhr=False, raw=True,
        referer=BASE+"/local-knowledge/", note="pilot chart wind rose svg")

    print("\n--- Routes / plans / misc ---")
    get("/savedCourseList", referer=router_ref, note="saved courses list")
    get("/recent-plans.json", referer=BASE+"/atlas/sailPlanner/", note="recent departure plans")
    get("/recent-routes.json", referer=router_ref, note="recent routes (revalidate)")
    get("/localtime", params={"lat":CYCLADES[0],"lon":CYCLADES[1]}, referer=router_ref, note="server localtime for coords")
    get("/api/americascupsession.json", referer=router_ref, note="americas cup session")
    get("/table/settings", referer=BASE+"/table/", note="table prefs")

    print("\n--- HTML feature pages ---")
    get("/local-knowledge/pilot-chart-only/", accept="text/html,*/*", xhr=False, note="pilot chart page")
    get("/datahub-2/", accept="text/html,*/*", xhr=False, note="datahub-2 page")
    get("/tracking/yb/", accept="text/html,*/*", xhr=False, note="YB tracking page")

    with open("/home/pi/pw_probe2.json","w") as f:
        json.dump(RESULTS,f,indent=2,default=str)
    print(f"\nPROBE2 done: {len(RESULTS)} records -> /home/pi/pw_probe2.json")


if __name__ == "__main__":
    main()
