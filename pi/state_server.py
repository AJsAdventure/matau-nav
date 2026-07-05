#!/usr/bin/env python3
"""
Matau state server — runs on the Pi alongside SignalK.

Single source of truth for tactical state shared across all phones:

  • AIS subscription to aisstream.io (one WebSocket for the whole boat).
  • CPA/TCPA + guard-zone evaluation per target.
  • MOB state (Man Overboard) — persists across reboots.
  • Active route + leg index — Pi auto-advances on arrival.

Phones poll /state and PUT mutations. The Pi is canonical; phones cache
locally for offline display.

Config:  /etc/matau/state.json  (key shown below; overridable via env)
Persisted state:  /var/lib/matau/state.json

Install dependency:
    sudo pip3 install websocket-client

HTTP API
--------
GET    /state            → full bundle {ts, connected, ais.targets, mob, route, alarm}
GET    /health           → {ok, ais_connected, target_count, mob, has_route}
PUT    /mob              → body {lat, lon, t?}   (t defaults to now)
DELETE /mob              → clear MOB
PUT    /route            → body {name?, waypoints:[{name,lat,lon,arrivalRadiusNm?}], legIndex?}
DELETE /route            → clear route
POST   /route/advance    → bump legIndex by 1 (skip current waypoint)
PUT    /config           → body {ais_stream_api_key?, ais_range_nm?, cpa_threshold_nm?, ...}
GET    /config           → current (non-secret) tunables
"""

from __future__ import annotations

import datetime as dt
import http.server
import json
import math
import os
import socketserver
import threading
import time
import traceback
import urllib.request
from pathlib import Path
from typing import Any, Optional

try:
    import websocket          # pip3 install websocket-client
except ImportError:
    websocket = None

# --- Paths / config ---------------------------------------------------------

CONFIG_PATH = Path(os.environ.get("MATAU_CONFIG", "/etc/matau/state.json"))
STATE_PATH  = Path(os.environ.get("MATAU_STATE",  "/var/lib/matau/state.json"))
HTTP_PORT   = int(os.environ.get("HTTP_PORT", "10114"))

DEFAULT_CONFIG = {
    "signalk_url":          "http://127.0.0.1:3000",
    "anchor_daemon_url":    "http://127.0.0.1:10112",
    "ais_stream_api_key":   "",
    "ais_range_nm":         20.0,
    "cpa_threshold_nm":     0.5,
    "tcpa_threshold_min":   10.0,
    "guard_zone_enabled":   False,
    "guard_zone_radius_nm": 1.0,
}

cfg_lock = threading.Lock()
config: dict[str, Any] = DEFAULT_CONFIG.copy()

_last_cfg_mtime: float = 0.0

def load_config() -> bool:
    """Reload config from disk if mtime changed. Returns True if anything changed."""
    global _last_cfg_mtime
    try:
        if not CONFIG_PATH.exists(): return False
        m = CONFIG_PATH.stat().st_mtime
        if m == _last_cfg_mtime: return False
        with CONFIG_PATH.open() as f:
            d = json.load(f)
        with cfg_lock:
            old_key   = config.get("ais_stream_api_key", "")
            old_range = config.get("ais_range_nm", 0)
            config.update({k: d.get(k, v) for k, v in DEFAULT_CONFIG.items()})
            ais_changed = (config["ais_stream_api_key"] != old_key or
                           config["ais_range_nm"]       != old_range)
        _last_cfg_mtime = m
        print(f"config reloaded from {CONFIG_PATH} "
              f"(key configured: {bool(config['ais_stream_api_key'])}, "
              f"range: {config['ais_range_nm']}nm)")
        return ais_changed
    except Exception as e:
        print("config load error:", e)
        return False

def config_watcher_loop():
    """Reload /etc/matau/state.json whenever its mtime changes. Lets the user
    paste in an AIS key with `nano /etc/matau/state.json` and have it picked
    up within ~5 s, no systemctl restart needed."""
    while True:
        try:
            if load_config():
                # AIS key changed — drop the current ws so ais_loop reconnects
                # with the new key on its next iteration.
                global _ws_force_reconnect
                _ws_force_reconnect = True
        except Exception as e:
            print("config watcher error:", e)
        time.sleep(5)

def save_config() -> None:
    try:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with CONFIG_PATH.open("w") as f:
            json.dump(config, f, indent=2)
    except Exception as e:
        print("config save error:", e)

# --- Persistent boat state --------------------------------------------------

state_lock = threading.Lock()
state: dict[str, Any] = {
    "mob":   None,                     # {"lat":..., "lon":..., "t":...} or None
    "route": None,                     # {"name":..., "waypoints":[...], "legIndex":...}
    # Note: autopilot state lives in SignalK directly. The SeaTalk plugin
    # publishes `steering.autopilot.state` ("auto"/"wind"/"standby") and
    # `steering.autopilot.target.headingMagnetic` straight off the bus — so
    # we just poll those (see signalk_loop). No local mirror needed; this
    # means physical button presses on the ST8002 are reflected too.
}

def load_state() -> None:
    try:
        if STATE_PATH.exists():
            with STATE_PATH.open() as f:
                d = json.load(f)
            with state_lock:
                state["mob"]   = d.get("mob")
                state["route"] = d.get("route")
    except Exception as e:
        print("state load error:", e)

def save_state() -> None:
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        with state_lock:
            d = {"mob": state["mob"], "route": state["route"]}
        with STATE_PATH.open("w") as f:
            json.dump(d, f)
    except Exception as e:
        print("state save error:", e)

# --- SignalK polling --------------------------------------------------------

nav_lock = threading.Lock()
nav = {
    "lat": None, "lon": None,
    "cog": 0.0, "sog": 0.0, "heading": 0.0,
    "twd": None, "tws": 0.0,
    # Full instrument set — /state is the single boat-state source for all
    # other Pi services (history, tracks) AND the phones; only this server
    # talks to SignalK. Units are display units (kn / deg / m / °C).
    "stw": 0.0, "twa": None, "awa": None, "aws": 0.0,
    "depth": 0.0, "wtemp": None, "rudder": None,
    "ts": 0,
    # GPS fix provenance — fix_ts is SignalK's timestamp for the position
    # value (epoch seconds), NOT the time we polled it. A frozen GPS keeps
    # its old fix_ts, so consumers can detect stale fixes via vessel.fixAge.
    "fix_ts": None,
    "pos_source": None,
    # Autopilot — sourced from SignalK `steering.autopilot.*`.
    "ap_mode": None,                # string: "auto", "standby", "wind", "route", "off", or None
    "ap_engaged": False,
    "ap_target_heading_deg": None,  # degrees, derived from radians
    # Waypoint-autopilot (managed by this server, not SignalK)
    "waypoint_mode":   False,
    "waypoint_target": None,        # {"lat": ..., "lon": ...} when waypoint_mode active
}

def _fetch_value(path: str):
    """Fetch /value for a SignalK path. Returns the unwrapped scalar (Number/String)
    or None if the path is missing or the server is unreachable."""
    url = f"{config['signalk_url']}/signalk/v1/api/vessels/self/{path}/value"
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None

def _fetch_position():
    """Fetch position from SignalK WITH the fix timestamp and source.
    Uses the full object (not /value) because `timestamp` is when SignalK
    last received a position delta — a dead GPS leaves it frozen, which is
    exactly the staleness signal we need. Returns (lat, lon, fix_epoch, source);
    Nones on failure."""
    url = f"{config['signalk_url']}/signalk/v1/api/vessels/self/navigation/position"
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            p = json.loads(r.read().decode())
        v = p.get("value") or {}
        fix_ts = None
        ts = p.get("timestamp")
        if isinstance(ts, str):
            try:
                fix_ts = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except Exception:
                fix_ts = None
        return v.get("latitude"), v.get("longitude"), fix_ts, p.get("$source")
    except Exception:
        return None, None, None, None

def signalk_loop():
    while True:
        try:
            lat, lon, fix_ts, pos_source = _fetch_position()
            cog = _fetch_value("navigation/courseOverGroundTrue")
            sog = _fetch_value("navigation/speedOverGround")
            hdg = _fetch_value("navigation/headingMagnetic")
            twa = _fetch_value("environment/wind/angleTrueWater")
            tws = _fetch_value("environment/wind/speedTrue")
            stw    = _fetch_value("navigation/speedThroughWater")
            awa    = _fetch_value("environment/wind/angleApparent")
            aws    = _fetch_value("environment/wind/speedApparent")
            depth  = _fetch_value("environment/depth/belowTransducer")
            wtemp  = _fetch_value("environment/water/temperature")
            rudder = _fetch_value("steering/rudderAngle")
            ap_state  = _fetch_value("steering/autopilot/state")
            ap_target = _fetch_value("steering/autopilot/target/headingMagnetic")
            # Some autopilot drivers use the "true" target instead — fall back.
            if not isinstance(ap_target, (int, float)):
                ap_target = _fetch_value("steering/autopilot/target/headingTrue")
            with nav_lock:
                if lat is not None: nav["lat"] = lat
                if lon is not None: nav["lon"] = lon
                if fix_ts is not None: nav["fix_ts"] = fix_ts
                if pos_source is not None: nav["pos_source"] = pos_source
                if isinstance(cog, (int, float)): nav["cog"] = math.degrees(cog)
                if isinstance(sog, (int, float)): nav["sog"] = sog * 1.94384
                if isinstance(hdg, (int, float)):
                    nav["heading"] = math.degrees(hdg)
                    if isinstance(twa, (int, float)):
                        twd = (math.degrees(hdg) + math.degrees(twa)) % 360
                        nav["twd"] = twd
                if isinstance(tws, (int, float)): nav["tws"] = tws * 1.94384
                if isinstance(twa, (int, float)): nav["twa"] = math.degrees(twa)
                if isinstance(stw, (int, float)): nav["stw"] = stw * 1.94384
                if isinstance(awa, (int, float)): nav["awa"] = math.degrees(awa)
                if isinstance(aws, (int, float)): nav["aws"] = aws * 1.94384
                if isinstance(depth, (int, float)): nav["depth"] = depth
                if isinstance(wtemp, (int, float)): nav["wtemp"] = wtemp - 273.15
                if isinstance(rudder, (int, float)): nav["rudder"] = math.degrees(rudder)
                if isinstance(ap_state, str):
                    nav["ap_mode"]    = ap_state
                    nav["ap_engaged"] = ap_state.lower() not in ("standby", "off", "")
                if isinstance(ap_target, (int, float)):
                    nav["ap_target_heading_deg"] = math.degrees(ap_target) % 360
                nav["ts"] = time.time()
        except Exception as e:
            print("signalk error:", e)
        time.sleep(2)

# --- AIS WebSocket ---------------------------------------------------------

ais_lock = threading.Lock()
ais_targets: dict[int, dict[str, Any]] = {}     # mmsi -> target dict
ais_connected = False
last_bbox_lat: Optional[float] = None
last_bbox_lon: Optional[float] = None
# Set by config_watcher_loop when the AIS key changes — forces ais_loop to
# tear down the current WebSocket and reconnect with the new key.
_ws_force_reconnect = False
_ais_msg_count = 0

def _bbox_around(lat: float, lon: float, nm: float):
    d_lat = nm / 60.0
    d_lon = nm / (60.0 * max(0.1, math.cos(math.radians(lat))))
    return [[lat - d_lat, lon - d_lon], [lat + d_lat, lon + d_lon]]

def _build_subscription(lat: float, lon: float, nm: float) -> str:
    return json.dumps({
        "APIKey": config["ais_stream_api_key"],
        "BoundingBoxes": [_bbox_around(lat, lon, nm)],
        "FilterMessageTypes": [
            "PositionReport", "ShipStaticData",
            "StandardClassBPositionReport", "ExtendedClassBPositionReport",
        ],
    })

def _ais_apply(msg: dict[str, Any]) -> None:
    meta = msg.get("MetaData") or {}
    mmsi = meta.get("MMSI")
    if not isinstance(mmsi, int): return
    now = time.time()
    t = ais_targets.get(mmsi, {
        "mmsi": mmsi,
        "name": None, "callSign": None, "shipType": None,
        "lat": 0.0, "lon": 0.0,
        "cog": 0.0, "sog": 0.0, "heading": None,
        "length": None, "beam": None, "draft": None,
        "destination": None,
        "cpaNm": None, "tcpaMin": None, "danger": False,
    })
    # Source priority: the boat's own receiver (src "local") sees a target
    # directly and with lower latency than the shore feed. While its data is
    # fresh, aisstream may only ENRICH statics (name/dims), never move the
    # target — two writers fighting over kinematics makes targets jitter.
    local_fresh = t.get("src") == "local" and now - t.get("lastUpdate", 0) < 15
    if isinstance(meta.get("ShipName"), str):
        nm = meta["ShipName"].strip()
        if nm: t["name"] = nm
    if not local_fresh:
        if isinstance(meta.get("latitude"),  (int, float)): t["lat"] = float(meta["latitude"])
        if isinstance(meta.get("longitude"), (int, float)): t["lon"] = float(meta["longitude"])

    msg_type = msg.get("MessageType") or ""
    body = (msg.get("Message") or {}).get(msg_type) or {}
    if not local_fresh:
        if isinstance(body.get("Latitude"),  (int, float)): t["lat"] = float(body["Latitude"])
        if isinstance(body.get("Longitude"), (int, float)): t["lon"] = float(body["Longitude"])
        if isinstance(body.get("Cog"), (int, float)): t["cog"] = float(body["Cog"])
        if isinstance(body.get("Sog"), (int, float)): t["sog"] = float(body["Sog"])
        h = body.get("TrueHeading")
        if isinstance(h, (int, float)) and h < 360: t["heading"] = float(h)
    if msg_type == "ShipStaticData":
        if isinstance(body.get("Type"), int): t["shipType"] = body["Type"]
        for k_src, k_dst in (("CallSign", "callSign"), ("Destination", "destination")):
            v = body.get(k_src)
            if isinstance(v, str): t[k_dst] = v.strip()
        dim = body.get("Dimension") or {}
        a = dim.get("A") or 0; b = dim.get("B") or 0
        c = dim.get("C") or 0; d = dim.get("D") or 0
        if (a + b) > 0: t["length"] = a + b
        if (c + d) > 0: t["beam"]   = c + d
        v = body.get("MaximumStaticDraught")
        if isinstance(v, (int, float)): t["draft"] = float(v)
    if not local_fresh:
        t["lastUpdate"] = now
        t["src"] = "net"
    if -90 <= t["lat"] <= 90 and -180 <= t["lon"] <= 180:
        ais_targets[mmsi] = t

def ais_loop():
    global ais_connected, last_bbox_lat, last_bbox_lon, _ws_force_reconnect, _ais_msg_count
    if websocket is None:
        print("websocket-client not installed; AIS disabled")
        return
    while True:
        if not config["ais_stream_api_key"]:
            time.sleep(10); continue
        with nav_lock:
            lat = nav["lat"]; lon = nav["lon"]
        if lat is None or lon is None:
            time.sleep(5); continue
        last_bbox_lat, last_bbox_lon = lat, lon
        url = "wss://stream.aisstream.io/v0/stream"
        try:
            _ais_msg_count = 0
            ws = websocket.create_connection(url, timeout=15)
            # After the handshake we don't want a 15-s timeout on recv(): in
            # quiet AIS areas (open sea, single ship within range) it can be
            # minutes between messages and we'd churn the connection. Use a
            # long heartbeat timeout instead, just so we periodically loop
            # back to check the reconnect flag.
            ws.settimeout(120)
            sub = _build_subscription(lat, lon, float(config["ais_range_nm"]))
            ws.send(sub)
            ais_connected = True
            print(f"AIS connected (bbox around {lat:.3f},{lon:.3f} ±{config['ais_range_nm']}nm)")
            last_bbox_check = time.time()
            while True:
                if _ws_force_reconnect:
                    _ws_force_reconnect = False
                    print("AIS reconnecting (config changed)")
                    break
                try:
                    raw = ws.recv()
                except websocket.WebSocketTimeoutException:
                    # No message in the heartbeat window — totally fine in
                    # quiet waters. Continue the loop so we can check
                    # _ws_force_reconnect and bbox-update timer.
                    continue
                if not raw: break
                try:
                    msg = json.loads(raw)
                except Exception:
                    continue
                _ais_msg_count += 1
                # Log only the first message after each connect — confirms
                # data is flowing without spamming the journal.
                if _ais_msg_count == 1:
                    md = (msg.get("MetaData") or {})
                    print(f"AIS receiving — first MMSI {md.get('MMSI')} at "
                          f"{md.get('latitude')},{md.get('longitude')}")
                with ais_lock:
                    _ais_apply(msg)

                # Re-subscribe if vessel has moved meaningfully (every 30s check)
                now = time.time()
                if now - last_bbox_check > 30:
                    last_bbox_check = now
                    with nav_lock:
                        clat, clon = nav["lat"], nav["lon"]
                    if clat is not None and clon is not None:
                        if (abs(clat - last_bbox_lat) > 0.05 or
                            abs(clon - last_bbox_lon) > 0.05):
                            last_bbox_lat, last_bbox_lon = clat, clon
                            try:
                                ws.send(_build_subscription(clat, clon, float(config["ais_range_nm"])))
                            except Exception:
                                break
        except Exception as e:
            print("AIS error:", e)
        finally:
            ais_connected = False
            print("AIS disconnected, reconnecting in 5s")
            time.sleep(5)

_self_urn_cache: dict[str, Any] = {"urn": None, "t": 0.0}

def _signalk_self_urn():
    """The self vessel's URN key in /vessels — SignalK does NOT key it "self".
    Without this filter the boat becomes its own AIS target the moment the
    AIS650 (which also reports own ship) is plugged in → CPA 0 alarms."""
    now = time.time()
    if _self_urn_cache["urn"] and now - _self_urn_cache["t"] < 300:
        return _self_urn_cache["urn"]
    try:
        with urllib.request.urlopen(f"{config['signalk_url']}/signalk/v1/api/self", timeout=3) as r:
            urn = json.loads(r.read().decode())
        if isinstance(urn, str):
            _self_urn_cache["urn"] = urn.split("vessels.", 1)[-1]
            _self_urn_cache["t"] = now
    except Exception:
        pass
    return _self_urn_cache["urn"]

def signalk_ais_loop():
    """Pull AIS targets from SignalK's vessels list (decoded from AIS650 USB).
    Runs alongside the aisstream.io loop — local targets take priority."""
    while True:
        try:
            url = f"{config['signalk_url']}/signalk/v1/api/vessels/"
            with urllib.request.urlopen(url, timeout=4) as r:
                vessels = json.loads(r.read().decode())
            now = time.time()
            self_urn = _signalk_self_urn()
            own = vessels.get(self_urn) if self_urn else None
            own_mmsi = None
            if isinstance(own, dict) and own.get("mmsi"):
                try:
                    own_mmsi = int(str(own["mmsi"]).rsplit(":", 1)[-1])
                except (ValueError, TypeError):
                    pass
            with ais_lock:
                for vessel_key, vessel in vessels.items():
                    if vessel_key == "self" or (self_urn and vessel_key == self_urn):
                        continue
                    if not isinstance(vessel, dict):
                        continue
                    mmsi_raw = vessel.get("mmsi")
                    if not mmsi_raw:
                        continue
                    try:
                        mmsi = int(str(mmsi_raw).replace("urn:mrn:imo:mmsi:", "").replace("urn:mrn:mmsi:", ""))
                    except (ValueError, TypeError):
                        continue
                    if own_mmsi is not None and mmsi == own_mmsi:
                        continue
                    nav_v = vessel.get("navigation") or {}
                    pos_obj = nav_v.get("position") or {}
                    pos = pos_obj.get("value") or {}
                    lat = pos.get("latitude")
                    lon = pos.get("longitude")
                    if lat is None or lon is None:
                        continue
                    # Freshness from SignalK's OWN timestamp: SignalK remembers
                    # a vessel's last position forever, so stamping "now" here
                    # would keep long-gone targets alive on the chart forever.
                    fix_ts = None
                    ts_raw = pos_obj.get("timestamp")
                    if isinstance(ts_raw, str):
                        try:
                            fix_ts = dt.datetime.fromisoformat(ts_raw.replace("Z", "+00:00")).timestamp()
                        except ValueError:
                            fix_ts = None
                    if fix_ts is None or now - fix_ts > 600:
                        continue

                    def _val(d, *keys):
                        for k in keys:
                            if isinstance(d, dict):
                                d = d.get(k)
                            else:
                                return None
                        return d.get("value") if isinstance(d, dict) else None

                    cog_r   = _val(nav_v, "courseOverGroundTrue")
                    sog_ms  = _val(nav_v, "speedOverGround")
                    hdg_r   = _val(nav_v, "headingTrue")
                    name_d  = vessel.get("name")
                    name    = name_d.get("value") if isinstance(name_d, dict) else name_d

                    t = ais_targets.get(mmsi, {
                        "mmsi": mmsi, "name": None, "callSign": None, "shipType": None,
                        "lat": 0.0, "lon": 0.0, "cog": 0.0, "sog": 0.0, "heading": None,
                        "length": None, "beam": None, "draft": None, "destination": None,
                        "cpaNm": None, "tcpaMin": None, "danger": False,
                    })
                    t["lat"] = float(lat)
                    t["lon"] = float(lon)
                    if isinstance(cog_r, (int, float)): t["cog"] = math.degrees(cog_r) % 360
                    if isinstance(sog_ms, (int, float)): t["sog"] = sog_ms * 1.94384
                    if isinstance(hdg_r, (int, float)): t["heading"] = math.degrees(hdg_r) % 360
                    if isinstance(name, str) and name.strip(): t["name"] = name.strip()
                    t["lastUpdate"] = fix_ts
                    t["src"] = "local"
                    ais_targets[mmsi] = t
        except Exception as e:
            print("signalk AIS loop error:", e)
        time.sleep(5)


def prune_loop():
    while True:
        cutoff = time.time() - 600        # 10 min stale
        with ais_lock:
            for mmsi in list(ais_targets.keys()):
                if ais_targets[mmsi].get("lastUpdate", 0) < cutoff:
                    del ais_targets[mmsi]
        time.sleep(30)

# --- CPA / TCPA / Guard zone / Route advance --------------------------------

def haversine_nm(lat1, lon1, lat2, lon2) -> float:
    R = 3440.065
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

def cpa(our_lat, our_lon, our_cog, our_sog, them) -> tuple[float, float]:
    nm_lat = 60.0
    nm_lon = 60.0 * math.cos(math.radians(our_lat))
    rx = (them["lon"] - our_lon) * nm_lon
    ry = (them["lat"] - our_lat) * nm_lat
    ovx = our_sog * math.sin(math.radians(our_cog))
    ovy = our_sog * math.cos(math.radians(our_cog))
    tvx = them["sog"] * math.sin(math.radians(them["cog"]))
    tvy = them["sog"] * math.cos(math.radians(them["cog"]))
    vx, vy = tvx - ovx, tvy - ovy
    vsq = vx*vx + vy*vy
    if vsq < 1e-6:
        return math.sqrt(rx*rx + ry*ry), 0.0
    t_hr = -(rx*vx + ry*vy) / vsq
    cx = rx + vx * t_hr
    cy = ry + vy * t_hr
    return math.sqrt(cx*cx + cy*cy), t_hr * 60.0

def cpa_loop():
    while True:
        try:
            with nav_lock:
                lat, lon, cog, sog = nav["lat"], nav["lon"], nav["cog"], nav["sog"]
            if lat is not None and lon is not None:
                guard_on = bool(config["guard_zone_enabled"])
                guard_r  = float(config["guard_zone_radius_nm"])
                cpa_n    = float(config["cpa_threshold_nm"])
                cpa_m    = float(config["tcpa_threshold_min"])
                with ais_lock:
                    for t in ais_targets.values():
                        cn, tm = cpa(lat, lon, cog, sog, t)
                        t["cpaNm"]   = round(cn, 3)
                        t["tcpaMin"] = round(tm, 1)
                        danger = tm >= 0 and cn <= cpa_n and tm <= cpa_m
                        if guard_on:
                            d = haversine_nm(lat, lon, t["lat"], t["lon"])
                            if d <= guard_r:
                                danger = True
                        t["danger"] = danger
        except Exception as e:
            print("cpa error:", e)
        time.sleep(3)

# --- Bearing helper ---------------------------------------------------------

def _bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Initial bearing (degrees, 0–360) from (lat1,lon1) to (lat2,lon2)."""
    la1, lo1, la2, lo2 = map(math.radians, [lat1, lon1, lat2, lon2])
    dlo = lo2 - lo1
    x = math.sin(dlo) * math.cos(la2)
    y = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dlo)
    return math.degrees(math.atan2(x, y)) % 360

# --- Autopilot command broker ----------------------------------------------
#
# The Pi-side autopilot driver (matau_daemon.py on :10112) executes the actual
# button-press commands over SeaTalk. The autopilot then publishes its
# engagement state back into SignalK via the SeaTalk-NMEA plugin — so we don't
# track state ourselves. We just forward the command and let SignalK become
# the truth on the next signalk_loop tick.

def _forward_to_anchor_daemon(cmd: str) -> bool:
    url = f"{config['anchor_daemon_url'].rstrip('/')}/autopilot/{cmd}"
    try:
        req = urllib.request.Request(url, method="POST")
        with urllib.request.urlopen(req, timeout=4) as r:
            return r.status == 200
    except Exception as e:
        print(f"anchor daemon {cmd} error:", e)
        return False

def route_advance_loop():
    """Auto-advance the active route's legIndex when within arrivalRadius."""
    while True:
        try:
            with nav_lock:
                lat, lon = nav["lat"], nav["lon"]
            if lat is not None and lon is not None:
                with state_lock:
                    r = state["route"]
                    if r and isinstance(r.get("waypoints"), list):
                        legs = r["waypoints"]
                        idx  = int(r.get("legIndex", 0))
                        if 0 <= idx < len(legs):
                            wp = legs[idx]
                            arrival_nm = float(wp.get("arrivalRadiusNm", 0.05))
                            d = haversine_nm(lat, lon, wp["lat"], wp["lon"])
                            if d <= arrival_nm:
                                r["legIndex"] = idx + 1
                                if r["legIndex"] >= len(legs):
                                    state["route"] = None    # finished
                                save_state()
        except Exception as e:
            print("route advance error:", e)
        time.sleep(2)

# --- HTTP handlers ----------------------------------------------------------

def waypoint_loop():
    """Continuously steer the autopilot toward the active route waypoint.
    Wakes every 10 s, computes bearing error, and nudges the AP heading with
    plus1/plus10/minus1/minus10 button-press commands."""
    while True:
        try:
            with nav_lock:
                wm      = nav.get("waypoint_mode", False)
                engaged = bool(nav.get("ap_engaged", False))
                if wm and not engaged:
                    nav["waypoint_mode"]   = False
                    nav["waypoint_target"] = None
                    wm = False

            if wm:
                with nav_lock:
                    lat    = nav["lat"]
                    lon    = nav["lon"]
                    ap_tgt = nav.get("ap_target_heading_deg")
                    wt     = nav.get("waypoint_target")

                if lat is not None and lon is not None and ap_tgt is not None and wt:
                    ctw = _bearing(lat, lon, wt["lat"], wt["lon"])
                    err = ((ctw - ap_tgt) + 180) % 360 - 180  # −180…+180; + = stbd
                    if abs(err) >= 10:
                        _forward_to_anchor_daemon("plus10" if err > 0 else "minus10")
                    elif abs(err) >= 2:
                        _forward_to_anchor_daemon("plus1"  if err > 0 else "minus1")
        except Exception as e:
            print("waypoint_loop error:", e)
        time.sleep(10)

def _autopilot_payload() -> dict[str, Any]:
    """SignalK is canonical for engagement state — the SeaTalk plugin reads it
    straight off the bus so physical button presses on the ST8002 are caught
    too. We normalise the SignalK `state` string and overlay waypoint mode."""
    with nav_lock:
        sk_mode       = nav["ap_mode"]
        sk_engaged    = bool(nav["ap_engaged"])
        sk_target     = nav["ap_target_heading_deg"]
        waypoint_mode = nav.get("waypoint_mode", False)
        if not sk_engaged:
            nav["waypoint_mode"] = False   # clear while holding lock
    if not sk_engaged:
        return {"engaged": False, "mode": "standby",
                "targetHeadingDeg": None, "lockedWindAngle": None}
    if waypoint_mode:
        mode = "waypoint"
    elif isinstance(sk_mode, str) and "wind" in sk_mode.lower():
        mode = "wind"
    else:
        mode = "compass"
    return {"engaged": True, "mode": mode,
            "targetHeadingDeg": sk_target, "lockedWindAngle": None}

def _build_state_payload() -> dict[str, Any]:
    with ais_lock:
        targets = list(ais_targets.values())
    with state_lock:
        mob   = state["mob"]
        route = state["route"]
    with nav_lock:
        n = dict(nav)
    return {
        "ts": time.time(),
        "aisConnected": ais_connected,
        "vessel": {
            "lat": n["lat"], "lon": n["lon"],
            "cog": n["cog"], "sog": n["sog"],
            "heading": n["heading"], "twd": n["twd"], "tws": n["tws"],
            "stw": n["stw"], "twa": n["twa"], "awa": n["awa"], "aws": n["aws"],
            "depth": n["depth"], "wtemp": n["wtemp"], "rudder": n["rudder"],
            # Age of the GPS fix in seconds (from SignalK's delta timestamp).
            # None until the first fix. Consumers MUST treat a large fixAge as
            # "no usable position" — lat/lon above hold the last known fix.
            "fixAge": (round(time.time() - n["fix_ts"], 1) if n.get("fix_ts") else None),
            "posSource": n.get("pos_source"),
        },
        # Autopilot truth: prefer the state we tracked through our own command
        # broker. If nothing's been commanded yet (engaged=False, mode=standby),
        # fall back to whatever SignalK reports — useful when the autopilot is
        # driven from another control surface (helm remote, MFD) that does
        # publish state back.
        "autopilot": _autopilot_payload(),
        "ais": {"targets": targets},
        "mob": mob,
        "route": route,
        "config": {
            "cpaThresholdNm":    config["cpa_threshold_nm"],
            "tcpaThresholdMin":  config["tcpa_threshold_min"],
            "guardZoneEnabled":  config["guard_zone_enabled"],
            "guardZoneRadiusNm": config["guard_zone_radius_nm"],
            "aisRangeNm":        config["ais_range_nm"],
        },
    }

class Handler(http.server.BaseHTTPRequestHandler):

    def _send(self, code: int, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, PUT, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0: return {}
        return json.loads(self.rfile.read(length).decode() or "{}")

    def log_message(self, *a, **k): pass

    def do_OPTIONS(self): self._send(204, {})

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        try:
            if path in ("", "/health"):
                with ais_lock:
                    n = len(ais_targets)
                return self._send(200, {
                    "ok": True,
                    "aisConnected": ais_connected,
                    "targetCount": n,
                    "mob": state["mob"],
                    "hasRoute": state["route"] is not None,
                })
            if path == "/state":
                return self._send(200, _build_state_payload())
            if path == "/config":
                c = {k: v for k, v in config.items() if k != "ais_stream_api_key"}
                c["aisKeyConfigured"] = bool(config["ais_stream_api_key"])
                return self._send(200, c)
            return self._send(404, {"error": "not found"})
        except Exception as e:
            traceback.print_exc()
            return self._send(500, {"error": str(e)})

    def do_PUT(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        try:
            data = self._read_json()
            if path == "/mob":
                lat = float(data["lat"]); lon = float(data["lon"])
                t = float(data.get("t") or time.time())
                with state_lock:
                    state["mob"] = {"lat": lat, "lon": lon, "t": t}
                save_state()
                return self._send(200, state["mob"])
            if path == "/route":
                wps = data.get("waypoints") or []
                clean = []
                for i, w in enumerate(wps):
                    clean.append({
                        "id":   w.get("id") or f"wp-{i}",
                        "name": w.get("name") or str(i + 1),
                        "lat":  float(w["lat"]), "lon": float(w["lon"]),
                        "arrivalRadiusNm": float(w.get("arrivalRadiusNm", 0.05)),
                    })
                with state_lock:
                    if clean:
                        state["route"] = {
                            "name": data.get("name") or "Route",
                            "waypoints": clean,
                            "legIndex": int(data.get("legIndex", 0)),
                        }
                    else:
                        state["route"] = None
                save_state()
                return self._send(200, state["route"] or {})
            if path == "/config":
                with cfg_lock:
                    for k in DEFAULT_CONFIG.keys():
                        if k in data: config[k] = data[k]
                save_config()
                return self._send(200, {k: v for k, v in config.items() if k != "ais_stream_api_key"})
            return self._send(404, {"error": "not found"})
        except Exception as e:
            traceback.print_exc()
            return self._send(400, {"error": str(e)})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        try:
            if path.startswith("/autopilot/"):
                cmd = path.rsplit("/", 1)[1]
                allowed = {"compass_auto", "wind_auto", "waypoint_auto", "standby",
                           "plus1", "plus10", "minus1", "minus10"}
                if cmd not in allowed:
                    return self._send(400, {"error": f"unknown autopilot command {cmd!r}"})

                if cmd == "waypoint_auto":
                    # Engage compass mode pointing at the active route's current leg
                    with state_lock:
                        r = state["route"]
                    target = None
                    if r and isinstance(r.get("waypoints"), list) and r["waypoints"]:
                        idx = int(r.get("legIndex", 0))
                        wps = r["waypoints"]
                        if idx < len(wps):
                            target = {"lat": wps[idx]["lat"], "lon": wps[idx]["lon"]}
                    if not target:
                        return self._send(400, {"error": "no active route waypoint"})
                    ok = _forward_to_anchor_daemon("compass_auto")
                    if ok:
                        with nav_lock:
                            nav["waypoint_mode"]   = True
                            nav["waypoint_target"] = target
                elif cmd == "standby":
                    with nav_lock:
                        nav["waypoint_mode"]   = False
                        nav["waypoint_target"] = None
                    ok = _forward_to_anchor_daemon("standby")
                else:
                    ok = _forward_to_anchor_daemon(cmd)

                # State will be updated by SignalK polling on the next tick
                # (1-2 s). We return the *current* payload — phones repoll fast
                # enough that the UI will catch up.
                return self._send(200 if ok else 502,
                                  {"ok": ok, "autopilot": _autopilot_payload()})
            if path == "/route/advance":
                with state_lock:
                    r = state["route"]
                    if r and isinstance(r.get("waypoints"), list):
                        r["legIndex"] = int(r.get("legIndex", 0)) + 1
                        if r["legIndex"] >= len(r["waypoints"]):
                            state["route"] = None
                save_state()
                return self._send(200, state["route"] or {})
            return self._send(404, {"error": "not found"})
        except Exception as e:
            return self._send(400, {"error": str(e)})

    def do_DELETE(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/mob":
            with state_lock: state["mob"] = None
            save_state()
            return self._send(200, {})
        if path == "/route":
            with state_lock: state["route"] = None
            save_state()
            return self._send(200, {})
        return self._send(404, {"error": "not found"})

class ThreadingHTTP(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

# --- Main -------------------------------------------------------------------

def main():
    load_config()
    load_state()
    threading.Thread(target=config_watcher_loop, daemon=True).start()
    threading.Thread(target=signalk_loop,        daemon=True).start()
    threading.Thread(target=ais_loop,            daemon=True).start()
    threading.Thread(target=signalk_ais_loop,    daemon=True).start()
    threading.Thread(target=prune_loop,          daemon=True).start()
    threading.Thread(target=cpa_loop,            daemon=True).start()
    threading.Thread(target=route_advance_loop,  daemon=True).start()
    threading.Thread(target=waypoint_loop,       daemon=True).start()
    print(f"Matau state server on :{HTTP_PORT}  (config {CONFIG_PATH}, state {STATE_PATH})")
    with ThreadingHTTP(("0.0.0.0", HTTP_PORT), Handler) as srv:
        srv.serve_forever()

if __name__ == "__main__":
    main()

# --- systemd unit (drop in /etc/systemd/system/matau-state.service) --------
#
# [Unit]
# Description=Matau state daemon (AIS, CPA, MOB, route)
# After=network-online.target signalk.service
#
# [Service]
# Type=simple
# Environment=MATAU_CONFIG=/etc/matau/state.json
# Environment=MATAU_STATE=/var/lib/matau/state.json
# Environment=HTTP_PORT=10114
# ExecStart=/usr/bin/python3 /opt/matau/state_server.py
# Restart=on-failure
# User=pi
#
# [Install]
# WantedBy=multi-user.target
#
# Initial config (sudo nano /etc/matau/state.json):
# {
#   "signalk_url": "http://127.0.0.1:3000",
#   "ais_stream_api_key": "YOUR_KEY_FROM_AISSTREAM_IO",
#   "ais_range_nm": 20.0,
#   "cpa_threshold_nm": 0.5,
#   "tcpa_threshold_min": 10.0,
#   "guard_zone_enabled": false,
#   "guard_zone_radius_nm": 1.0
# }
