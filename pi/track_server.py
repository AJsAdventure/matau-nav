#!/usr/bin/env python3
"""
Matau track server — runs on the Pi alongside SignalK.

Polls SignalK every 2 s for position + COG + SOG, appends to the active track
on disk, rotates tracks daily, and serves them over HTTP so the phone app's
Chart tab can show historic GPS trails.

HTTP API (the phone app expects this shape — see TrackService.swift):

  GET /tracks
      -> [{"id": "2026-05-15", "name": "2026-05-15", "points": 832,
            "start": 1763136000, "end": 1763176000}, ...]
  GET /tracks/<id>
      -> [{"lat": 35.89, "lon": 14.51, "t": 1763136000, "sog": 6.2, "cog": 047.0}, ...]
  GET /health
      -> {"ok": true, "active": "2026-05-15", "points": 832}

Files are stored as gzipped NDJSON in TRACKS_DIR; one file per UTC day. Each
line is a single point: {"lat":...,"lon":...,"t":...,"sog":...,"cog":...}.

Run with:
    python3 track_server.py
or as a systemd service (a sample unit is at the bottom of this file in a
comment).
"""

import datetime as dt
import gzip
import http.server
import json
import os
import socketserver
import threading
import time
import urllib.request
from pathlib import Path

# --- Config -----------------------------------------------------------------

SIGNALK_URL  = os.environ.get("SIGNALK_URL", "http://127.0.0.1:3000")
TRACKS_DIR   = Path(os.environ.get("TRACKS_DIR", "/var/lib/matau/tracks"))
HTTP_PORT    = int(os.environ.get("HTTP_PORT", "10113"))
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "2.0"))
MIN_MOVE_M   = float(os.environ.get("MIN_MOVE_M", "5"))      # skip duplicate fixes
KEEP_DAYS    = int(os.environ.get("KEEP_DAYS", "180"))       # auto-prune older

TRACKS_DIR.mkdir(parents=True, exist_ok=True)

# --- Utilities --------------------------------------------------------------

def day_id(ts: float) -> str:
    return dt.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d")

def track_path(day: str) -> Path:
    return TRACKS_DIR / f"{day}.ndjson.gz"

STATE_URL = os.environ.get("MATAU_STATE_URL", "http://127.0.0.1:10114/state")

def fetch_vessel():
    """Vessel block from state_server — the single SignalK client on this Pi.
    Returns {} when unreachable. Units are already kn/deg."""
    try:
        with urllib.request.urlopen(STATE_URL, timeout=3) as r:
            return (json.loads(r.read().decode()) or {}).get("vessel") or {}
    except Exception:
        return {}

def haversine_m(lat1, lon1, lat2, lon2) -> float:
    import math
    R = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

def rad_to_deg(r):
    if r is None: return None
    return r * 180.0 / 3.141592653589793

def ms_to_knots(v):
    if v is None: return None
    return v * 1.94384

# --- Recorder ---------------------------------------------------------------

state_lock = threading.Lock()
last_point = {"lat": None, "lon": None, "t": 0, "day": None, "count": 0}

def append_point(lat, lon, sog, cog):
    global last_point
    t = time.time()
    if lat is None or lon is None:
        return
    with state_lock:
        if last_point["lat"] is not None:
            d = haversine_m(last_point["lat"], last_point["lon"], lat, lon)
            if d < MIN_MOVE_M and (t - last_point["t"]) < 60:
                # Stationary; still record once a minute as a heartbeat.
                return
        day = day_id(t)
        rec = {"lat": lat, "lon": lon, "t": t, "sog": sog, "cog": cog}
        with gzip.open(track_path(day), "at", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        last_point.update(lat=lat, lon=lon, t=t, day=day,
                          count=(last_point["count"] + 1) if last_point["day"] == day else 1)

def recorder_loop():
    while True:
        try:
            v = fetch_vessel()
            age = v.get("fixAge")
            # A frozen GPS keeps its last lat/lon — never extend a track with it.
            if isinstance(age, (int, float)) and age > 60:
                v = {}
            append_point(
                v.get("lat"), v.get("lon"),
                v.get("sog") if isinstance(v.get("sog"), (int, float)) else None,
                v.get("cog") if isinstance(v.get("cog"), (int, float)) else None,
            )
        except Exception as e:
            print("recorder error:", e)
        time.sleep(POLL_SECONDS)

def prune_loop():
    while True:
        try:
            cutoff = dt.date.today() - dt.timedelta(days=KEEP_DAYS)
            for p in TRACKS_DIR.glob("*.ndjson.gz"):
                try:
                    day = dt.date.fromisoformat(p.stem.replace(".ndjson", ""))
                    if day < cutoff:
                        p.unlink()
                except Exception:
                    pass
        except Exception as e:
            print("prune error:", e)
        time.sleep(3600)

# --- HTTP server ------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    # Socket timeout for each connection: without it, one client that
    # vanishes mid-request (Wi-Fi blip) leaves this handler thread blocked
    # FOREVER — threads accumulated for ~1 day until Python could not start
    # new ones and every request got connection-reset (live incident
    # 2026-07-11, 764 leaked threads on matau-state).
    timeout = 20


    def _send(self, code: int, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args, **kwargs):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path in ("", "/health"):
            return self._send(200, {
                "ok": True,
                "active": last_point["day"],
                "points": last_point["count"],
            })
        # Track files are append-only gzip; a crash mid-write leaves a corrupt
        # line or a truncated tail. Reads tolerate both — a bad line is skipped
        # and a truncated file yields every point before the damage, so one
        # crash can't take a whole day's track with it.
        if path == "/tracks":
            out = []
            for p in sorted(TRACKS_DIR.glob("*.ndjson.gz")):
                day = p.stem.replace(".ndjson", "")
                count, start, end = 0, None, None
                try:
                    with gzip.open(p, "rt", encoding="utf-8") as f:
                        for line in f:
                            try:
                                rec = json.loads(line)
                            except ValueError:
                                continue
                            count += 1
                            t = rec.get("t")
                            if start is None: start = t
                            end = t
                except Exception:
                    pass  # truncated tail — keep what was already counted
                if count:
                    out.append({"id": day, "name": day, "points": count,
                                "start": start, "end": end})
            return self._send(200, out)
        if path.startswith("/tracks/"):
            day = path.split("/", 2)[2]
            p = track_path(day)
            if not p.exists():
                return self._send(404, {"error": "not found"})
            points = []
            try:
                with gzip.open(p, "rt", encoding="utf-8") as f:
                    for line in f:
                        try:
                            points.append(json.loads(line))
                        except ValueError:
                            continue
            except Exception as e:
                if not points:
                    return self._send(500, {"error": str(e)})
                print(f"track {day}: truncated file ({e}) — serving {len(points)} points")
            return self._send(200, points)
        return self._send(404, {"error": "not found"})

class ThreadingHTTP(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

def main():
    threading.Thread(target=recorder_loop, daemon=True).start()
    threading.Thread(target=prune_loop,    daemon=True).start()
    print(f"Matau track server on :{HTTP_PORT}  (tracks in {TRACKS_DIR})")
    with ThreadingHTTP(("0.0.0.0", HTTP_PORT), Handler) as srv:
        srv.serve_forever()

if __name__ == "__main__":
    main()

# --- systemd unit (drop in /etc/systemd/system/matau-tracks.service) -------
#
# [Unit]
# Description=Matau track recorder + HTTP API
# After=network-online.target signalk.service
#
# [Service]
# Type=simple
# Environment=SIGNALK_URL=http://127.0.0.1:3000
# Environment=TRACKS_DIR=/var/lib/matau/tracks
# Environment=HTTP_PORT=10113
# ExecStart=/usr/bin/python3 /opt/matau/track_server.py
# Restart=on-failure
# User=pi
#
# [Install]
# WantedBy=multi-user.target
