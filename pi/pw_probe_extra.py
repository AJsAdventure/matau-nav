#!/usr/bin/env python3
"""Remaining probes: route export variants + individual boat track. Read-mostly."""
import json, urllib.parse
import predictwind_server as P
P.MIN_REQUEST_GAP_S = 4.0
PW = P._pw; BASE = P.PW_BASE

sr = json.load(open("route_live.json"))
csrf = PW._cookie("csrftoken")

print("=== route export variants ===")
variants = {
    "full":         json.dumps(sr),
    "results-only": json.dumps(sr["results"]),
    "first-path":   json.dumps(sr["results"][0]["paths"][0]),
}
for name, body in variants.items():
    PW._rate_limit()
    ex = PW._session.post(f"{BASE}/atlas/routerExport/",
        data={"export_type": "GPX", "export_page": "Route", "export_source": "PWG",
              "routerJSON": body, "timezone": "Europe/Athens",
              "csrfmiddlewaretoken": csrf},
        headers={"X-CSRFToken": csrf, "Referer": f"{BASE}/atlas/sailRouter/",
                 "Origin": BASE, "Content-Type": "application/x-www-form-urlencoded"},
        timeout=30)
    ct = ex.headers.get("Content-Type", "")
    print(f"  [{name:<12}] HTTP {ex.status_code} {ct} {len(ex.content)}b "
          f"cd={ex.headers.get('Content-Disposition','')}")
    if "xml" in ct or ex.text.lstrip().startswith("<?xml") or "<gpx" in ex.text[:200]:
        print("     GPX head:", ex.text[:140].replace("\n", " "))

print("\n=== individual community boat track ===")
PW._rate_limit()
b = PW._session.get(f"{BASE}/local-knowledge/locations/boats.json",
                    headers={"Referer": f"{BASE}/local-knowledge/"}, timeout=30).json()
name = b[0][3]
print("  sample boat:", repr(name))
PW._rate_limit()
r = PW._session.get(
    f"{BASE}/local-knowledge/locations/boat/{urllib.parse.quote(name)}.json",
    headers={"Referer": f"{BASE}/local-knowledge/", "X-Requested-With": "XMLHttpRequest"},
    timeout=25)
print(f"  boat detail: HTTP {r.status_code} {r.headers.get('Content-Type','')} {len(r.content)}b")
print("   ", r.text[:400].replace("\n", " "))
