#!/usr/bin/env python3
"""
Matau History Buffer
Samples the boat state every 5 s and maintains a rolling 60-minute buffer.
Serves it as JSON on port 3001 so the iOS app can restore instrument
history after a crash or reconnect without losing continuity.

Reads from state_server's /state (port 10114) — the single SignalK client on
this Pi — instead of hitting SignalK with 12 REST calls per sample. The
vessel block already carries every instrument in display units (kn/deg/m/°C),
so this stays a dumb ring buffer. Wire format of /history is unchanged
(InstrumentsView.fetchPiHistory depends on it).
"""

import json, time, threading
from collections import deque
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.request import urlopen

INTERVAL    = 5          # seconds between samples
MAX_SAMPLES = 720        # 720 × 5 s = 60 min
PORT        = 3001
STATE_URL   = "http://127.0.0.1:10114/state"

# /history sample key -> /state vessel key (identical units, direct copy)
FIELDS = {
    "sog": "sog", "stw": "stw", "hdg": "heading", "cog": "cog",
    "depth": "depth", "awa": "awa", "aws": "aws", "twa": "twa",
    "tws": "tws", "twd": "twd", "wtemp": "wtemp", "rudder": "rudder",
}

# --- shared buffer ----------------------------------------------------------
lock    = threading.Lock()
buffer  = deque(maxlen=MAX_SAMPLES)

def _collect_once():
    vessel = {}
    try:
        with urlopen(STATE_URL, timeout=3) as r:
            vessel = (json.load(r) or {}).get("vessel") or {}
    except Exception:
        pass  # state_server briefly down → an all-None sample keeps the
              # timeline honest (gap visible) instead of freezing the tail

    sample = {"t": int(time.time())}
    for out_key, in_key in FIELDS.items():
        v = vessel.get(in_key)
        sample[out_key] = float(v) if isinstance(v, (int, float)) else None
    with lock:
        buffer.append(sample)

def collect():
    while True:
        try:
            _collect_once()
        except Exception as e:
            # Never let this thread die: a dead collector leaves /history
            # serving a frozen buffer while the service still looks healthy.
            print(f"history collect error: {e}", flush=True)
        time.sleep(INTERVAL)

# --- HTTP server ------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass   # silence access logs

    def do_GET(self):
        if self.path != "/history":
            self.send_response(404); self.end_headers(); return
        with lock:
            payload = json.dumps({
                "interval": INTERVAL,
                "samples":  list(buffer),
            }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

class ThreadingHTTP(ThreadingMixIn, HTTPServer):
    """One thread per request — the ~200 KB /history payload to a phone on
    weak Wi-Fi must not block other clients on the only thread."""
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    t = threading.Thread(target=collect, daemon=True)
    t.start()
    print(f"Matau history buffer listening on :{PORT}")
    ThreadingHTTP(("", PORT), Handler).serve_forever()
