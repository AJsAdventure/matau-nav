#!/usr/bin/env python3
"""
PredictWind API probe harness — runs ON THE PI ONLY.

SAFETY MODEL (read before touching):
  * Reuses predictwind_server.PredictWindSession singleton (`_pw`) so every
    outbound call goes through the SAME proven rate limiter, CSRF handling and
    stale-session re-auth that the production proxy uses.
  * Bumps the inter-request gap to PROBE_GAP_S (default 4.0s) — more
    conservative than production — to stay well under any bot-detection
    threshold.  All calls are strictly SERIAL.
  * The Pi is the only authenticated PredictWind client.  Never run any other
    PredictWind client (browser, Mac, phone) while this is running.
  * NO account mutations: never creates or deletes locations.  Reuses the
    existing "Pi Location".  Routing/planning use ad-hoc waypoints, which the
    website does routinely.

Usage:
  python3 pw_probe.py <phase> [phase ...]
  phases: check forecast locations ais lk atlas grib route plan all-safe

Output:
  /home/pi/pw_probe_<phase>.json   — machine-readable findings
  stdout                            — human-readable progress
"""
from __future__ import annotations

import json
import math
import sys
import time
import traceback

import predictwind_server as P

# --- Conservative exploration rate limit (override the module default) -------
PROBE_GAP_S = 4.0
P.MIN_REQUEST_GAP_S = PROBE_GAP_S

PW = P._pw
BASE = P.PW_BASE

# Greek-waters anchors for all geographic probes (neutral, realistic).
PI_LOC_ID = 3756396          # "Milos" — a live, current saved location
ELAFONISOS = (36.5036, 22.969)
# A short, realistic Greek-waters passage for routing tests:
ROUTE_START = (36.5036, 22.969)    # Elafonisos
ROUTE_END   = (36.7330, 24.4190)   # Milos (~75 nm NE)

RESULTS: list[dict] = []


# --------------------------------------------------------------------------- #
# Shape summariser — compact, readable description of any JSON structure
# --------------------------------------------------------------------------- #
def summarize(obj, depth: int = 0, max_depth: int = 4, max_keys: int = 40,
              max_list: int = 3):
    if depth >= max_depth:
        return f"<{type(obj).__name__}>"
    if isinstance(obj, dict):
        out = {}
        for i, (k, v) in enumerate(obj.items()):
            if i >= max_keys:
                out["…(+%d keys)" % (len(obj) - max_keys)] = ""
                break
            out[str(k)] = summarize(v, depth + 1, max_depth, max_keys, max_list)
        return out
    if isinstance(obj, list):
        n = len(obj)
        head = [summarize(x, depth + 1, max_depth, max_keys, max_list)
                for x in obj[:max_list]]
        return {"__list_len__": n, "__sample__": head}
    if isinstance(obj, str):
        return obj if len(obj) <= 80 else obj[:80] + "…"
    return obj


# --------------------------------------------------------------------------- #
# Low-level request helpers — go through PW's rate limiter + session
# --------------------------------------------------------------------------- #
def _record(rec: dict):
    RESULTS.append(rec)
    status = rec.get("status")
    flag = "OK " if rec.get("ok") else "ERR"
    print(f"  [{flag}] {rec['method']:4} {rec['path']:<55} "
          f"-> {status} {rec.get('content_type','')[:25]} "
          f"{rec.get('length','?')}b {rec.get('elapsed_s','?')}s")
    if rec.get("note"):
        print(f"         note: {rec['note']}")
    return rec


def get(path: str, params: dict | None = None, referer: str | None = None,
        accept: str = "application/json, text/javascript, */*; q=0.01",
        xhr: bool = True, raw: bool = False, retry: bool = True,
        note: str = "") -> dict:
    """Rate-limited authenticated GET that records full metadata + shape."""
    PW._rate_limit()
    hdrs = {"Accept": accept, "Referer": referer or BASE}
    if xhr:
        hdrs["X-Requested-With"] = "XMLHttpRequest"
    rec = {"method": "GET", "path": path, "params": params or {},
           "referer": referer or BASE, "note": note}
    t0 = time.time()
    try:
        r = PW._session.get(f"{BASE}{path}", params=params, headers=hdrs, timeout=25)
        rec["elapsed_s"] = round(time.time() - t0, 2)
        rec["status"] = r.status_code
        rec["ok"] = r.ok
        rec["content_type"] = r.headers.get("Content-Type", "")
        rec["length"] = len(r.content)
        rec["final_url"] = r.url
        # Re-auth once on 403 / login redirect
        if (r.status_code in (403, 302) or "login" in r.url.lower()) and retry:
            rec["note"] = (rec.get("note", "") + " [403/redirect -> re-auth+retry]").strip()
            print("  ... 403/redirect, re-authenticating once")
            if PW.login():
                return get(path, params, referer, accept, xhr, raw, retry=False, note=note)
        if raw:
            rec["raw_magic"] = r.content[:16].hex()
            rec["sample"] = r.text[:200] if "text" in rec["content_type"] or "json" in rec["content_type"] else "<binary>"
        else:
            ct = rec["content_type"]
            if "json" in ct or r.text.strip()[:1] in ("{", "["):
                try:
                    data = r.json()
                    rec["json_shape"] = summarize(data)
                    # NOTE: bare {"status":"OK"} on /table/ma/ is NOT a stale
                    # session — re-auth does not change it.  Do not re-login here.
                    if isinstance(data, dict) and data.get("status") == "OK" and "data" not in data:
                        rec["note"] = (rec.get("note", "") + " [bare status:OK — needs warming]").strip()
                except Exception as e:
                    rec["json_error"] = str(e)
                    rec["sample"] = r.text[:300]
            else:
                rec["sample"] = r.text[:300]
    except Exception as e:
        rec["elapsed_s"] = round(time.time() - t0, 2)
        rec["ok"] = False
        rec["error"] = str(e)
    return _record(rec)


def post(path: str, data: dict, referer: str | None = None,
         allow_redirects: bool = True, raw: bool = False,
         note: str = "") -> dict:
    """Rate-limited authenticated POST (form-encoded, CSRF) with metadata."""
    PW._rate_limit()
    csrf = PW._cookie("csrftoken")
    payload = dict(data)
    payload["csrfmiddlewaretoken"] = csrf
    hdrs = {
        "X-CSRFToken": csrf,
        "Referer": referer or BASE,
        "Origin": BASE,
        "Content-Type": "application/x-www-form-urlencoded",
    }
    rec = {"method": "POST", "path": path, "params": {k: (v[:40] if isinstance(v, str) else v) for k, v in data.items()},
           "referer": referer or BASE, "note": note}
    t0 = time.time()
    try:
        r = PW._session.post(f"{BASE}{path}", data=payload, headers=hdrs,
                             allow_redirects=allow_redirects, timeout=40)
        rec["elapsed_s"] = round(time.time() - t0, 2)
        rec["status"] = r.status_code
        rec["ok"] = r.ok
        rec["content_type"] = r.headers.get("Content-Type", "")
        rec["length"] = len(r.content)
        rec["final_url"] = r.url
        rec["location_header"] = r.headers.get("Location", "")
        rec["content_disposition"] = r.headers.get("Content-Disposition", "")
        if raw:
            rec["raw_magic"] = r.content[:16].hex()
            rec["sample"] = r.text[:200]
        else:
            ct = rec["content_type"]
            if "json" in ct or r.text.strip()[:1] in ("{", "["):
                try:
                    rec["json_shape"] = summarize(r.json())
                except Exception as e:
                    rec["json_error"] = str(e)
                    rec["sample"] = r.text[:300]
            else:
                rec["sample"] = r.text[:300]
    except Exception as e:
        rec["elapsed_s"] = round(time.time() - t0, 2)
        rec["ok"] = False
        rec["error"] = str(e)
    return _record(rec)


# --------------------------------------------------------------------------- #
# PHASES
# --------------------------------------------------------------------------- #
def phase_check():
    print("\n=== PHASE: check (session validity + forecast table) ===")
    print(f"  authenticated(local cookie)={PW.authenticated} email={PW.email}")
    get(f"/table/ma/{PI_LOC_ID}.json", referer=f"{BASE}/table/",
        note="primary forecast table; triggers stale-session re-auth if needed")


def _extract_locations_from_table_html(text: str) -> list[dict]:
    """Pull saved locations from the /table/ HTML page.

    Current format: <a ... data-id="3756396" ...>Milos</a> (server-rendered
    dropdown).  Returns [{id, name}].
    """
    import re
    locs = []
    for m in re.finditer(r'data-id="(\d+)"[^>]*>\s*([^<]+?)\s*</a>', text):
        locs.append({"id": int(m.group(1)), "name": m.group(2).strip()})
    return locs


def phase_forecast():
    print("\n=== PHASE: forecast (with warming sequence + location discovery) ===")
    # 1) Load the table page — this is what a browser does first; it registers
    #    the current location into the session and embeds the saved-locations list.
    PW._rate_limit()
    rt = PW._session.get(f"{BASE}/table/",
                         headers={"Accept": "text/html,*/*;q=0.8",
                                  "Referer": BASE}, timeout=25)
    locs = _extract_locations_from_table_html(rt.text)
    print(f"  /table/ page: HTTP {rt.status_code}, {len(rt.content)}b, "
          f"{len(locs)} saved locations discovered")
    for l in locs:
        print(f"      - {l['id']:>8}  {l['name']}")
    _record({"method": "GET", "path": "/table/", "status": rt.status_code,
             "ok": rt.ok, "content_type": rt.headers.get("Content-Type", ""),
             "length": len(rt.content), "elapsed_s": 0,
             "note": "table page", "saved_locations": locs})

    # 2) Re-request the Pi Location forecast now the page is loaded.
    get(f"/table/ma/{PI_LOC_ID}.json", referer=f"{BASE}/table/",
        note="forecast for Pi Location AFTER warming page load")

    # 3) Poll updateStatus, then re-request — tests whether data must be warmed.
    get("/updateStatus.json", params={"ma": PI_LOC_ID, "r": 1},
        referer=f"{BASE}/table/", note="model freshness for Pi Location")

    # 4) Try the first real saved location (in case Pi Location id is dead).
    target = None
    for l in locs:
        if l["id"] != PI_LOC_ID:
            target = l
            break
    if target:
        get(f"/table/ma/{target['id']}.json", referer=f"{BASE}/table/",
            note=f"forecast for saved location '{target['name']}' ({target['id']})")
        ts = int(time.time())
        get(f"/table/overviewData/{target['id']}.json", params={"_": ts},
            referer=f"{BASE}/table/", note="daily weather summary")
        get(f"/twilightData/{target['id']}", referer=f"{BASE}/table/",
            note="sunrise/sunset")

    # 5) User settings / units.
    get("/settings/get/", params={"units": ""}, referer=f"{BASE}/table/",
        note="user unit prefs")


def phase_locations():
    print("\n=== PHASE: locations (READ-ONLY, no add/delete) ===")
    get("/location/add/", accept="text/html,*/*;q=0.8", xhr=False,
        referer=f"{BASE}/table/", note="add-location form (field names only)")
    # Saved locations list candidates
    for p in ("/location/list", "/location/list/", "/locations.json",
              "/location/getAll", "/saved-locations.json"):
        get(p, referer=f"{BASE}/table/", note="candidate saved-locations list")


def phase_ais():
    print("\n=== PHASE: ais ===")
    get("/local-knowledge/locations/boats.json",
        referer=f"{BASE}/local-knowledge/ais-data-only/",
        note="all community boats (large)")
    get("/local-knowledge/retrieve-vessel-type-filter",
        referer=f"{BASE}/local-knowledge/", note="vessel type filter prefs")
    get("/local-knowledge/get-favourite-ais-vessels",
        referer=f"{BASE}/local-knowledge/", note="favourited vessels")
    get("/local-knowledge/topContributors",
        referer=f"{BASE}/local-knowledge/", note="top AIS contributors")
    # AIS tiles around Elafonisos (a few neighbouring tiles)
    lat, lon = ELAFONISOS
    x0, y0 = P.lat_lon_to_tile(lat, lon, 8)
    for dx, dy in ((0, 0), (1, 0), (0, 1)):
        get("/local-knowledge/AIS-concise",
            params={"age": 60, "x": x0 + dx, "y": y0 + dy, "z": 8, "kpler": ""},
            referer=f"{BASE}/local-knowledge/ais-data-only/",
            note=f"commercial AIS tile ({x0+dx},{y0+dy})")


def phase_lk():
    print("\n=== PHASE: local knowledge ===")
    get("/local-knowledge/", accept="text/html,*/*;q=0.8", xhr=False,
        referer=BASE, note="LK landing page")
    get("/local-knowledge/locations/loadPassages",
        referer=f"{BASE}/local-knowledge/", note="community passages")
    # POI categories — probe a small spread of candidate category ids
    for c in (205032, 1, 2, 100, 1000):
        get("/local-knowledge/locations/pois.json", params={"c": c},
            referer=f"{BASE}/local-knowledge/", note=f"POIs category c={c}")


def phase_atlas():
    print("\n=== PHASE: atlas / routing scaffolding (read-only) ===")
    ref = f"{BASE}/atlas/sailRouter/"
    get("/atlas/routerHubPolar/", referer=ref, note="router hub polar")
    get("/atlas/routerBoundaries", referer=ref, note="routing boundaries")
    get("/atlas/gmdss-graphics", referer=ref, note="GMDSS warnings")
    get("/recent-routes.json", referer=ref, note="recent stored routes")
    for sail in ("mainsail", "headsail"):
        get("/sail-crossover/predefined/list", params={"chartType": sail},
            referer=ref, note=f"{sail} predefined polar list")
        get("/sail-crossover/get", params={"chartType": sail},
            referer=ref, note=f"{sail} current crossover")


def phase_grib():
    print("\n=== PHASE: grib tiles (binary probe, single tile) ===")
    # Build a plausible tile path for Greek waters, current run.
    # Pattern: /atlas/global/gribtile/{MODEL}_{S}n{N}n{W}e{E}e_{LAT}n{LON}e_{start}_{end}-{TYPE}.raw
    now = int(time.time())
    start = now - (now % 21600)          # align to 6-hourly run
    end = start + 7 * 86400
    path = f"/atlas/global/gribtile/PWG_36n37n22e25e_36n23e_{start}_{end}-Wind.raw"
    get(path, accept="*/*", xhr=False, raw=True,
        referer=f"{BASE}/atlas/sailRouter/", note="raw GRIB wind tile (binary)")


def _run_router(planner: bool):
    label = "departure-planning (sailPlanner)" if planner else "routing (sailRouter)"
    base_path = "/atlas/sailPlanner" if planner else "/atlas/sailRouter"
    print(f"\n=== PHASE: {label} ===")
    tzname = "Europe/Athens"
    # local start ~ now + 1h
    lt = time.localtime(time.time() + 3600)
    start_dt = time.strftime("%Y-%m-%d %H:%M", lt)
    # Fetch polars (reuses proven helper, rate-limited internally)
    print("  fetching boat polars (Beneteau 40.7)…")
    try:
        polar = PW._get_boat_polar("Beneteau 40.7")
    except Exception as e:
        polar = {"error": str(e)}
    has_polar = isinstance(polar, dict) and polar.get("mainsail")
    print(f"  polar fetched: mainsail={len(polar.get('mainsail','')) if has_polar else 'ERR'} chars")
    wp = json.dumps([
        {"lat": ROUTE_START[0], "lon": ROUTE_START[1], "type": 0},
        {"lat": ROUTE_END[0],   "lon": ROUTE_END[1],   "type": 0},
    ])
    submit = post(f"{base_path}/submit", {
        "submitAction": "execute",
        "routerJSON": '[{"paths":[],"weather":[]}]',
        "routerBuild": "intel",
        "waypoints": wp,
        "wasLoggedIn": "true",
        "routerBeta": "false",
        "startTimeStr": start_dt,
        "startDate": start_dt[:10],
        "startTime": start_dt[11:16],
        "timezone": tzname,
        "mainsail": polar.get("mainsail", "") if has_polar else "",
        "headsail": polar.get("headsail", "") if has_polar else "",
        "optimiseFor": "time",
        "motoringEnabled": "on",
        "motoringSpeed": "4.0",
        "motoringThreshold": "1.5",
        "tackPenalty": "150",
        "gybePenalty": "150",
        "boatPolarType": "predefined",
        "selected_polar": "Beneteau 40.7",
        "significantHeight": "4.5",
        "wavePolarEnabled": "on",
    }, referer=f"{BASE}{base_path}/", note="route submit")
    route_ids = (submit.get("sample") or "").strip()
    # submit returns plain text ids
    if not route_ids and submit.get("ok"):
        route_ids = ""
    print(f"  route_ids = {route_ids[:120]!r}")
    if route_ids and route_ids[0].isdigit():
        # Poll a few times
        done = False
        for i in range(20):
            poll = get(f"{base_path}/finished",
                       params={"r": route_ids, "ts": int(time.time() * 1000)},
                       referer=f"{BASE}{base_path}/", note=f"poll {i+1}")
            js = poll.get("json_shape")
            if isinstance(js, dict) and (js.get("finished") or js.get("__list_len__") == 0):
                done = True
                break
            time.sleep(4)
        get(f"{base_path}/results", params={"result": route_ids},
            referer=f"{BASE}{base_path}/", note="route results (full path JSON)")
        # Export probe (GPX) — uses stored results server-side via routerJSON
        # Keep it minimal: just confirm the export endpoint shape.


def phase_route():
    _run_router(planner=False)


def phase_plan():
    _run_router(planner=True)


PHASES = {
    "check": phase_check,
    "forecast": phase_forecast,
    "locations": phase_locations,
    "ais": phase_ais,
    "lk": phase_lk,
    "atlas": phase_atlas,
    "grib": phase_grib,
    "route": phase_route,
    "plan": phase_plan,
}
SAFE_ORDER = ["check", "forecast", "locations", "ais", "lk", "atlas", "grib"]


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: pw_probe.py <phase> [phase ...]  | phases:",
              " ".join(PHASES), "| all-safe")
        return
    if args == ["all-safe"]:
        order = SAFE_ORDER
    else:
        order = args
    print(f"PROBE start  gap={PROBE_GAP_S}s  phases={order}")
    for ph in order:
        fn = PHASES.get(ph)
        if not fn:
            print(f"  unknown phase: {ph}")
            continue
        try:
            fn()
        except Exception:
            traceback.print_exc()
        # Save incrementally after each phase
        out = f"/home/pi/pw_probe_{'_'.join(order)}.json"
        with open(out, "w") as f:
            json.dump(RESULTS, f, indent=2, default=str)
        print(f"  ...saved {len(RESULTS)} records -> {out}")
    print("PROBE done")


if __name__ == "__main__":
    main()
