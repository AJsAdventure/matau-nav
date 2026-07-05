#!/usr/bin/env python3
"""Round 4: sweep the remaining discovered endpoint refs for completeness.
Pi-only, read-only, serial. Fetches pages, records status, and for HTML shells
extracts their data-*-url attributes (their own sub-APIs) + inline .json/api refs."""
from __future__ import annotations
import json, re, time, predictwind_server as P
P.MIN_REQUEST_GAP_S = 3.0
PW = P._pw; BASE = P.PW_BASE
R = []
DATA_RE = re.compile(r'data-([a-z0-9-]+)\s*=\s*"([^"]{1,150})"', re.I)
JSON_RE = re.compile(r'["\'`](/[A-Za-z0-9_\-./]*?(?:\.json|/api/|alert|hindcast|power|overview)[A-Za-z0-9_\-./]*)["\'`]')

def get(path, params=None, referer=None, xhr=False, acc="text/html,application/json,*/*", note=""):
    PW._rate_limit()
    h={"Accept":acc,"Referer":referer or BASE+"/"}
    if xhr: h["X-Requested-With"]="XMLHttpRequest"
    rec={"path":path,"params":params or {},"note":note}
    try:
        r=PW._session.get(BASE+path if path.startswith("/") else path,params=params,headers=h,timeout=40)
        rec.update(status=r.status_code, ok=r.ok, ct=r.headers.get("Content-Type","")[:30], ln=len(r.content))
        body=r.text
        if "html" in rec["ct"]:
            attrs={}
            for m in DATA_RE.finditer(body):
                k,v=m.group(1),m.group(2)
                if "url" in k.lower() or v.startswith("/"): attrs.setdefault(k,v)
            rec["data_attrs"]={k:v for k,v in attrs.items() if k not in ("dsn","base-url","url-pattern")}
            title=re.search(r"<title>([^<]{0,80})",body)
            rec["title"]=title.group(1).strip() if title else ""
            rec["json_refs"]=sorted(set(JSON_RE.findall(body)))[:15]
        elif "json" in rec["ct"] or body.strip()[:1] in("{","["):
            rec["sample"]=body[:200]
        else:
            rec["sample"]=body[:120]
    except Exception as e:
        rec.update(ok=False,error=str(e))
    R.append(rec)
    print(f"[{'OK ' if rec.get('ok') else 'ERR'}] {rec.get('status','?')} {path:<26} {rec.get('ln','?')}b {rec.get('ct','')[:16]} {note}")
    if rec.get("title"): print("    title:",rec["title"])
    if rec.get("data_attrs"):
        for k,v in rec["data_attrs"].items(): print(f"    data-{k} = {v}")
    if rec.get("json_refs"): print("    json/api refs:",rec["json_refs"])
    if rec.get("sample"): print("    sample:",re.sub(r"\s+"," ",rec['sample'])[:180])
    return rec

def main():
    get("/alerts/", note="alerts landing")
    get("/alerts/manage/", note="alerts manage")
    get("/atlas/hindcast/", note="hindcast page")
    get("/atlas/powerPlanner/", note="power planner page")
    get("/overview/", note="overview page")
    get("/gmap/settings/", note="gmap settings", xhr=True, acc="application/json,*/*")
    get("/forecast-tips", note="forecast tips", xhr=True, acc="application/json,*/*")
    get("/maps/GMDSS/", note="GMDSS maps page")
    # observation detail by a real id seen in a tile earlier
    get("/observations/377232/", note="obs detail by id", xhr=True, acc="application/json,*/*")
    get("/observations/", note="observations page (re-mine)")
    with open("/home/pi/pw_probe4.json","w") as f: json.dump(R,f,indent=2,default=str)
    print("done",len(R))

if __name__=="__main__": main()
