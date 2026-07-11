#!/usr/bin/env python3
"""
Matau Pi daemon — autopilot control + boat-side anchor watch
Listens on :10112  |  writes NMEA $STALK sentences to SeaTalk bridge

Anchor watch (v2): the Pi is the watcher that never sleeps. Armed from the
app (POST /anchor/arm), it monitors position + GPS freshness from
state_server (:10114) and drives a GPIO buzzer so a drag alarm sounds on the
BOAT even when every phone is asleep and the Mac is closed.

Buzzer: set MATAU_BUZZER_GPIO=<BCM pin> in the systemd unit environment once
the hardware is wired (active piezo on that pin + GND). Without it, alarms
are state-only (app still sees them via /status) and each would-be beep is
logged — the full watch logic runs either way, so the groundwork is testable
before the buzzer arrives.

HTTP API
--------
POST /autopilot/<cmd>        auto|standby|plus1|minus1|plus10|minus10|
                             wind_mode|wind_auto|compass_auto
POST /anchor/arm             {"lat":…, "lon":…, "radius_m":…, "delay_s":30}
POST /anchor/disarm
POST /anchor/silence         {"minutes":10}  — buzzer off, watch stays armed
GET  /status                 PiStatus shape the app decodes (see AnchorPiService)
"""

import json
import os
import threading
import time
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from math import atan2, cos, radians, sin, sqrt
from pathlib import Path

# By-id path, NEVER /dev/ttyUSBn: the ttyUSB numbering is assigned in
# enumeration order and is not stable across boots/replugs on this Pi. With
# the number hardcoded, a swapped enumeration would send autopilot keystrokes
# into the GPS adapter instead of the SeaTalk bridge.
SERIAL = os.environ.get(
    "MATAU_SEATALK_SERIAL",
    "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A987ZTP5-if00-port0")

STATE_URL     = os.environ.get("MATAU_STATE_URL", "http://127.0.0.1:10114/state")
SIGNALK_URL   = os.environ.get("SIGNALK_URL", "http://127.0.0.1:3000")
BUZZER_GPIO   = os.environ.get("MATAU_BUZZER_GPIO", "").strip()
ANCHOR_FILE   = Path(os.environ.get("MATAU_ANCHOR_FILE", "/var/lib/matau/anchor.json"))

POLL_S            = 5.0     # anchor monitor cadence
FIX_MAX_AGE_S     = 90.0    # older fix = no usable position
GPS_LOSS_AFTER_S  = 120.0   # continuous no-position before gps_loss alarm
DEFAULT_DELAY_S   = 30.0    # breach must persist this long before dragging alarm

# Verified keystroke bytes captured from physical ST8002 buttons.
# Key byte + bitwise-complement byte, attribute 0x41.
AUTOPILOT_CMDS = {
    "auto":      b"$STALK,86,41,01,FE*48\r\n",   # Engage heading AUTO
    "standby":   b"$STALK,86,41,02,FD*4A\r\n",   # STANDBY
    "plus1":     b"$STALK,86,41,07,F8*33\r\n",   # +1 degree
    "minus1":    b"$STALK,86,41,05,FA*48\r\n",   # -1 degree
    "plus10":    b"$STALK,86,41,08,F7*33\r\n",   # +10 degrees
    "minus10":   b"$STALK,86,41,06,F9*33\r\n",   # -10 degrees
    "wind_mode": b"$STALK,86,41,23,DC*4C\r\n",   # Toggle wind/compass mode
}

_serial_lock = threading.Lock()


def write_serial(sentence: bytes) -> bool:
    try:
        with _serial_lock:
            fd = os.open(SERIAL, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
            os.write(fd, sentence)
            os.close(fd)
        return True
    except Exception as e:
        print(f"[daemon] Serial write error: {e}", flush=True)
        return False


# --- Autopilot mode (read from SignalK, not guessed) -------------------------
# The old daemon tracked wind-vs-compass in a module variable — wrong after
# every restart and blind to changes made at the physical ST8002 buttons.
# SignalK decodes the real mode from the SeaTalk bus; ask it, and fall back
# to the last known answer only when SignalK is briefly unreachable.

_last_known_wind_mode = False


def ap_in_wind_mode() -> bool:
    global _last_known_wind_mode
    url = f"{SIGNALK_URL}/signalk/v1/api/vessels/self/steering/autopilot/state/value"
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            state = json.loads(r.read().decode())
        if isinstance(state, str):
            _last_known_wind_mode = "wind" in state.lower()
    except Exception:
        pass  # keep last known
    return _last_known_wind_mode


def note_wind_mode(value: bool) -> None:
    """Remember the mode we just commanded (bridges SignalK's decode lag)."""
    global _last_known_wind_mode
    _last_known_wind_mode = value


# --- Buzzer ------------------------------------------------------------------

class Buzzer:
    """GPIO buzzer with a no-op fallback until the hardware is wired.

    Pattern thread beeps 0.7 s on / 0.3 s off while `active` — an interval
    pattern is far more attention-grabbing (and power-friendly) than a
    continuous tone, and it survives a wedged GPIO call in one beat rather
    than latching the buzzer on.
    """

    def __init__(self, pin_env: str):
        self._dev = None
        self.active = False
        self._configured = False
        if pin_env:
            try:
                pin = int(pin_env)
                from gpiozero import Buzzer as GZBuzzer   # stock on Pi OS
                self._dev = GZBuzzer(pin)
                self._configured = True
                print(f"[daemon] buzzer on GPIO {pin}", flush=True)
            except Exception as e:
                print(f"[daemon] buzzer unavailable ({e}) — state-only alarms", flush=True)
        threading.Thread(target=self._pattern_loop, daemon=True).start()

    def _set(self, on: bool) -> None:
        if self._dev is None:
            return
        try:
            (self._dev.on if on else self._dev.off)()
        except Exception as e:
            print(f"[daemon] buzzer set error: {e}", flush=True)

    def _pattern_loop(self) -> None:
        was_active = False
        while True:
            if self.active:
                if not was_active and not self._configured:
                    print("[daemon] ALARM (no buzzer wired — set MATAU_BUZZER_GPIO)", flush=True)
                was_active = True
                self._set(True);  time.sleep(0.7)
                self._set(False); time.sleep(0.3)
            else:
                if was_active:
                    self._set(False)
                    was_active = False
                time.sleep(0.2)


# --- Anchor watch state machine ----------------------------------------------

def haversine_m(lat1, lon1, lat2, lon2) -> float:
    R = 6371000.0
    p1, p2 = radians(lat1), radians(lat2)
    dp = radians(lat2 - lat1)
    dl = radians(lon2 - lon1)
    a = sin(dp / 2) ** 2 + cos(p1) * cos(p2) * sin(dl / 2) ** 2
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))


class AnchorWatch:
    """Pure state machine (no I/O) — mirrors the tested AnchorMonitor pattern
    in predictwind_server. step() gets fed observations; it returns nothing
    and keeps `alarms` current. All timestamps injected for testability."""

    def __init__(self):
        self.armed = False
        self.lat = 0.0
        self.lon = 0.0
        self.radius_m = 50.0
        self.delay_s = DEFAULT_DELAY_S
        self.alarms: list[str] = []
        self.distance_m: float | None = None
        self.fix_age: float | None = None
        self._breach_since: float | None = None
        self._no_fix_since: float | None = None

    def arm(self, lat: float, lon: float, radius_m: float, delay_s: float, now: float):
        self.armed = True
        self.lat, self.lon = lat, lon
        self.radius_m = radius_m
        self.delay_s = delay_s
        self.alarms = []
        self.distance_m = None
        self._breach_since = None
        # Fresh grace window — arming must never instantly alarm on a feed
        # that is still coming up.
        self._no_fix_since = None

    def disarm(self):
        self.armed = False
        self.alarms = []
        self.distance_m = None
        self._breach_since = None
        self._no_fix_since = None

    def step(self, now: float, lat, lon, fix_age) -> None:
        if not self.armed:
            return
        self.fix_age = fix_age
        usable = (lat is not None and lon is not None
                  and not (lat == 0 and lon == 0)
                  and isinstance(fix_age, (int, float)) and fix_age <= FIX_MAX_AGE_S)

        if not usable:
            if self._no_fix_since is None:
                self._no_fix_since = now
            if now - self._no_fix_since >= GPS_LOSS_AFTER_S:
                if "gps_loss" not in self.alarms:
                    self.alarms.append("gps_loss")
            # position unknown: keep any dragging alarm latched (a drag that
            # loses GPS is MORE alarming, not less), just don't update distance
            return

        self._no_fix_since = None
        if "gps_loss" in self.alarms:
            self.alarms.remove("gps_loss")

        self.distance_m = haversine_m(self.lat, self.lon, lat, lon)
        if self.distance_m > self.radius_m:
            if self._breach_since is None:
                self._breach_since = now
            if now - self._breach_since >= self.delay_s:
                if "dragging" not in self.alarms:
                    self.alarms.append("dragging")
        else:
            self._breach_since = None
            if "dragging" in self.alarms:
                self.alarms.remove("dragging")


watch = AnchorWatch()
watch_lock = threading.Lock()
buzzer = Buzzer(BUZZER_GPIO)
_silenced_until = 0.0
_last_vessel: dict = {}


def _save_anchor():
    try:
        ANCHOR_FILE.parent.mkdir(parents=True, exist_ok=True)
        ANCHOR_FILE.write_text(json.dumps({
            "armed": watch.armed, "lat": watch.lat, "lon": watch.lon,
            "radius_m": watch.radius_m, "delay_s": watch.delay_s,
        }))
    except OSError as e:
        print(f"[daemon] anchor state save failed: {e}", flush=True)


def _load_anchor():
    try:
        d = json.loads(ANCHOR_FILE.read_text())
        if d.get("armed"):
            watch.arm(float(d["lat"]), float(d["lon"]),
                      float(d.get("radius_m", 50)), float(d.get("delay_s", DEFAULT_DELAY_S)),
                      time.time())
            print(f"[daemon] anchor watch re-armed from disk "
                  f"({watch.lat:.5f},{watch.lon:.5f} r={watch.radius_m:.0f}m)", flush=True)
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"[daemon] anchor state load failed: {e}", flush=True)


def _fetch_vessel() -> dict:
    try:
        with urllib.request.urlopen(STATE_URL, timeout=4) as r:
            return (json.loads(r.read().decode()) or {}).get("vessel") or {}
    except Exception:
        return {}


def anchor_loop():
    global _last_vessel
    while True:
        try:
            v = _fetch_vessel()
            _last_vessel = v
            with watch_lock:
                watch.step(time.time(), v.get("lat"), v.get("lon"), v.get("fixAge"))
                alarming = watch.armed and bool(watch.alarms)
            buzzer.active = alarming and time.time() >= _silenced_until
        except Exception as e:
            print(f"[daemon] anchor loop error: {e}", flush=True)
        time.sleep(POLL_S)


# --- HTTP --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    # Socket timeout for each connection: without it, one client that
    # vanishes mid-request (Wi-Fi blip) leaves this handler thread blocked
    # FOREVER — threads accumulated for ~1 day until Python could not start
    # new ones and every request got connection-reset (live incident
    # 2026-07-11, 764 leaked threads on matau-state).
    timeout = 20


    def log_message(self, fmt, *args):
        pass

    def _json(self, code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > 1_000_000:
                return {}
            return json.loads(self.rfile.read(length))
        except Exception:
            return {}

    def do_GET(self):
        if self.path in ("/status", "/health"):
            v = _last_vessel
            with watch_lock:
                # Shape matters: AnchorPiService.PiStatus decodes ok/time/
                # anchorActive/activeAlarms/lat/lon/tws/twd/depth as required
                # fields — keep them all present, always.
                payload = {
                    "ok": True,
                    "time": time.time(),
                    "anchorActive": watch.armed,
                    "activeAlarms": list(watch.alarms),
                    "lat": watch.lat if watch.armed else 0.0,
                    "lon": watch.lon if watch.armed else 0.0,
                    "tws": float(v.get("tws") or 0.0),
                    "twd": float(v.get("twd") or 0.0),
                    "depth": float(v.get("depth") or 0.0),
                    # Extras (additive — Swift Codable ignores unknown keys)
                    "radius": watch.radius_m,
                    "distance": watch.distance_m,
                    "fixAge": watch.fix_age,
                    "buzzerConfigured": buzzer._configured,
                    "silencedUntil": _silenced_until if _silenced_until > time.time() else None,
                }
            self._json(200, payload)
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        global _silenced_until
        parts = [p for p in self.path.split("/") if p]

        # ── Anchor watch ───────────────────────────────────────────────────
        if len(parts) == 2 and parts[0] == "anchor":
            cmd = parts[1]
            if cmd == "arm":
                b = self._read_body()
                try:
                    lat, lon = float(b["lat"]), float(b["lon"])
                    radius = float(b.get("radius_m", 50))
                    delay = float(b.get("delay_s", DEFAULT_DELAY_S))
                except (KeyError, TypeError, ValueError):
                    return self._json(400, {"error": "need lat, lon (+ radius_m, delay_s)"})
                with watch_lock:
                    watch.arm(lat, lon, radius, delay, time.time())
                _silenced_until = 0.0
                _save_anchor()
                print(f"[daemon] anchor ARMED {lat:.5f},{lon:.5f} r={radius:.0f}m", flush=True)
                return self._json(200, {"ok": True})
            if cmd == "disarm":
                with watch_lock:
                    watch.disarm()
                buzzer.active = False
                _save_anchor()
                print("[daemon] anchor DISARMED", flush=True)
                return self._json(200, {"ok": True})
            if cmd == "silence":
                b = self._read_body()
                minutes = float(b.get("minutes", 10))
                _silenced_until = time.time() + minutes * 60
                buzzer.active = False
                print(f"[daemon] alarm silenced {minutes:.0f} min", flush=True)
                return self._json(200, {"ok": True, "until": _silenced_until})
            return self._json(404, {"error": "unknown anchor command"})

        # ── Autopilot ──────────────────────────────────────────────────────
        if len(parts) != 2 or parts[0] != "autopilot":
            return self._json(404, {"error": "not found"})

        cmd = parts[1]

        if cmd == "wind_auto":
            if not ap_in_wind_mode():
                write_serial(AUTOPILOT_CMDS["wind_mode"])
                time.sleep(0.15)
            ok = write_serial(AUTOPILOT_CMDS["auto"])
            if ok:
                note_wind_mode(True)
            print(f"[daemon] wind_auto -> {'ok' if ok else 'FAIL'}", flush=True)
            return self._json(200 if ok else 500, {"ok": ok, "cmd": cmd})

        if cmd == "compass_auto":
            if ap_in_wind_mode():
                write_serial(AUTOPILOT_CMDS["wind_mode"])
                time.sleep(0.15)
            ok = write_serial(AUTOPILOT_CMDS["auto"])
            if ok:
                note_wind_mode(False)
            print(f"[daemon] compass_auto -> {'ok' if ok else 'FAIL'}", flush=True)
            return self._json(200 if ok else 500, {"ok": ok, "cmd": cmd})

        if cmd == "standby":
            ok = write_serial(AUTOPILOT_CMDS["standby"])
            # Mode survives standby on the ST8002 — next AUTO re-engages same mode.
            print(f"[daemon] standby -> {'ok' if ok else 'FAIL'}", flush=True)
            return self._json(200 if ok else 500, {"ok": ok, "cmd": cmd})

        if cmd in AUTOPILOT_CMDS:
            ok = write_serial(AUTOPILOT_CMDS[cmd])
            print(f"[daemon] {cmd} -> {'ok' if ok else 'FAIL'}", flush=True)
            return self._json(200 if ok else 500, {"ok": ok, "cmd": cmd})
        return self._json(400, {"error": f"unknown command: {cmd}"})


class ThreadingHTTP(ThreadingMixIn, HTTPServer):
    """One thread per request. Single-threaded, a phone with a dying Wi-Fi
    link stuck mid-/status could block an autopilot STANDBY or anchor arm
    for the length of a TCP timeout — unacceptable for the service that
    steers the boat and sounds the drag alarm."""
    daemon_threads = True
    allow_reuse_address = True


def main():
    _load_anchor()
    threading.Thread(target=anchor_loop, daemon=True).start()
    server = ThreadingHTTP(("0.0.0.0", 10112), Handler)
    print(f"[daemon] listening on :10112  serial={SERIAL}  "
          f"buzzer={'GPIO ' + BUZZER_GPIO if BUZZER_GPIO else 'not wired'}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
