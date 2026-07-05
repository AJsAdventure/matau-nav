#!/usr/bin/env python3
"""Round 3: nail /atlas/metadata params, validate corrected paths, re-confirm core.
Pi-only, read-only, serial."""
from __future__ import annotations
import json, re, time, urllib.parse
import predictwind_server as P
P.MIN_REQUEST_GAP_S = 3.0
PW = P._pw; BASE = P.PW_BASE
R = []

def summarize(o,d=0,md=3,mk=25,ml=2):
    if d>=md: return f"<{type(o).__name__}>"
    if isinstance(o,dict):
        out={}
        for i,(k,v) in enumerate(o.items()):
            if i>=mk: out["…+%d"%(len(o)-mk)]=""; break
            out[str(k)]=summarize(v,d+1,md,mk,ml)
        return out
    if isinstance(o,list): return {"__len__":len(o),"__s__":[summarize(x,d+1,md,mk,ml) for x in o[:ml]]}
    if isinstance(o,str): return o if len(o)<=80 else o[:80]+"…"
    return o

def get(path,params=None,referer=None,xhr=True,raw=False,acc="application/json,*/*",note=""):
    PW._rate_limit()
    h={"Accept":acc,"Referer":referer or BASE+"/"}
    if xhr: h["X-Requested-With"]="XMLHttpRequest"
    rec={"path":path,"params":params or {},"note":note}
    try:
        r=PW._session.get(BASE+path if path.startswith("/") else path,params=params,headers=h,timeout=40)
        rec.update(status=r.status_code,ok=r.ok,ct=r.headers.get("Content-Type","")[:30],ln=len(r.content),final=r.url.replace(BASE,""))
        if raw: rec["magic"]=r.content[:12].hex(); rec["sample"]=r.text[:120]
        else:
            b=r.text.strip()
            if "json" in rec["ct"] or b[:1] in("{","["):
                try: rec["shape"]=summarize(r.json())
                except Exception as e: rec["err"]=str(e); rec["sample"]=r.text[:150]
            else: rec["sample"]=r.text[:150]
    except Exception as e:
        rec.update(ok=False,error=str(e))
    R.append(rec)
    print(f"  [{'OK ' if rec.get('ok') else 'ERR'}] {rec.get('status','?')} {path:<46} {rec.get('ln','?')}b {note}")
    return rec

def main():
    atlas=BASE+"/atlas/"; router=BASE+"/atlas/sailRouter/"
    print("--- /atlas/metadata param hunt ---")
    loc=871630
    get("/atlas/metadata",referer=atlas,note="bare")
    get("/atlas/metadata",params={"build":"intel"},referer=atlas,note="?build=intel")
    get("/atlas/metadata",params={"routerBuild":"intel"},referer=atlas,note="?routerBuild=intel")
    get("/atlas/metadata",params={"ma":loc},referer=atlas,note="?ma=loc")
    get("/atlas/metadata",params={"sw":"36,22","ne":"38,26"},referer=atlas,note="?sw&ne bbox")
    get("/atlas/metadata",params={"lat":37.08,"lon":25.15},referer=atlas,note="?lat&lon")

    print("--- corrected stored-route/legacy ---")
    rr=get("/recent-routes.json",referer=router,note="recent routes")
    url=None
    try:
        j=PW._session.get(BASE+"/recent-routes.json",headers={"X-Requested-With":"XMLHttpRequest","Referer":router},timeout=30).json()
        if j: url=j[0]["url"]
    except Exception as e: print("   recent parse err",e)
    if url:
        get(url,referer=router,note=f"stored-route legacy fetch")

    print("--- core re-validation ---")
    get(f"/table/ma/{loc}.json",referer=BASE+"/table/",note="forecast table live loc")
    x,y=P.lat_lon_to_tile(37.084,25.153,8)
    ais=get("/local-knowledge/AIS-concise",params={"age":60,"x":x,"y":y,"z":8,"kpler":""},
        referer=BASE+"/local-knowledge/ais-data-only/",note="commercial AIS tile (check lat sign)")
    try:
        aj=PW._session.get(BASE+"/local-knowledge/AIS-concise",params={"age":60,"x":x,"y":y,"z":8,"kpler":""},
            headers={"X-Requested-With":"XMLHttpRequest","Referer":BASE+"/local-knowledge/ais-data-only/"},timeout=30).json()
        locs=aj.get("aisLocations",[])
        if locs: print(f"   AIS sample lat={locs[0][1]} lon={locs[0][2]} (negative lat => still sign-flipped)")
        else: print("   AIS empty this tile")
    except Exception as e: print("   ais parse err",e)

    print("--- GRIB old format + GMDSS detail ---")
    now=int(time.time()); start=now-(now%21600); end=start+7*86400
    get(f"/atlas/global/gribtile/PWG_36n37n22e25e_36n23e_{start}_{end}-Wind.raw",
        acc="*/*",xhr=False,raw=True,referer=router,note="old global gribtile format")
    g=get("/atlas/gmdss-graphics",referer=router,note="gmdss graphics")
    # extract a warning id from files[] to test detail endpoint
    wid=None
    try:
        gj=PW._session.get(BASE+"/atlas/gmdss-graphics",headers={"X-Requested-With":"XMLHttpRequest","Referer":router},timeout=30).json()
        for area in gj.values():
            if isinstance(area,list):
                for it in area:
                    fs=it.get("files") if isinstance(it,dict) else None
                    if fs and fs[0]: wid=fs[0][0] if isinstance(fs[0],list) else fs[0]; break
            if wid: break
    except Exception as e: print("   gmdss parse err",e)
    print("   gmdss warning id sample:",str(wid)[:80])
    if wid:
        get(f"/gmdss-get-warning-details/{urllib.parse.quote(str(wid),safe='')}",acc="text/plain,*/*",note="gmdss warning detail")

    with open("/home/pi/pw_probe3.json","w") as f: json.dump(R,f,indent=2,default=str)
    print(f"done {len(R)} records")

if __name__=="__main__": main()
