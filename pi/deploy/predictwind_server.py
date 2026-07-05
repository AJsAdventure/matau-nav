#!/usr/bin/env python3
"""
PredictWind proxy server — runs on the Pi alongside SignalK.

SECURITY MODEL — read before modifying
---------------------------------------
PredictWind bans accounts that show simultaneous sessions from multiple IP
addresses. To prevent this:

  1. THE PI IS THE ONLY CLIENT.  Never authenticate to PredictWind from any
     other device (Mac, phone, browser) while this server is running or has
     an active session on disk.  Even opening forecast.predictwind.com in a
     browser while the Pi session is active will trigger the ban.

  2. ONE SESSION, LONG-LIVED.  Credentials are saved once in
     /etc/matau/predictwind.json.  The session cookie lives in
     /var/lib/matau/predictwind_session.json and survives reboots.  The
     server only re-authenticates when a 403 is received (session expired,
     typically after 2 weeks).

  3. NO RAPID MUTATIONS.  Location adds/deletes are expensive and suspicious.
     /location/set skips the PredictWind API entirely if "Pi Location" already
     exists within REUSE_RADIUS_DEG of the requested coordinates.

  4. RATE LIMITING.  A minimum of MIN_REQUEST_GAP_S seconds is enforced
     between successive outbound PredictWind API calls.

HTTP API
--------
GET  /health                 → {ok, authenticated, email}
POST /credentials            → body {email, password} — save new creds and re-auth
GET  /status                 → detailed auth status + account info
GET  /forecast/{locationId}  → PredictWind 7-day forecast table
GET  /forecast/vessel        → read vessel GPS, reuse/create Pi Location, return forecast
GET  /ais                           → AIS targets; query: south,west,north,east[,zoom,age]
GET  /ais/vessel                    → commercial AIS + community boats in 50NM around vessel
GET  /community-boats               → all PredictWind community boat positions
GET  /local-knowledge/vessel        → POIs, passages, community boats in 50NM around vessel
GET  /locations                     → known saved locations for this account
GET  /overview/{locationId}         → daily weather summary
GET  /twilight/{locationId}         → sunrise/sunset times
POST /location/set                  → body {name, lat, lon} — smart upsert (reuses if close)
DELETE /location/{id}               → delete a saved PredictWind location
POST /routing/vessel                → body {goal_lat, goal_lon, polar?, optimise?, timezone?}
POST /departure-planning/vessel     → body {goal_lat, goal_lon, polar?, timezone?, days?}

Ports:
  10115 — this server (PredictWind)
  10114 — state_server.py (AIS/route/MOB)
  10112 — anchor daemon

Install:
  sudo pip3 install requests
"""

from __future__ import annotations

import http.server
import json
import math
import os
import socketserver
import threading
import time
import traceback
import urllib.parse
from pathlib import Path
from typing import Any

try:
    import requests
    from requests import Session
except ImportError:
    print("ERROR: requests not installed — sudo pip3 install requests")
    requests = None
    Session = None

# ---------------------------------------------------------------------------
# Config / paths
# ---------------------------------------------------------------------------

CONFIG_PATH  = Path(os.environ.get("MATAU_PW_CONFIG",  "/etc/matau/predictwind.json"))
SESSION_PATH = Path(os.environ.get("MATAU_PW_SESSION", "/var/lib/matau/predictwind_session.json"))
HTTP_PORT    = int(os.environ.get("PW_PORT", "10115"))
PW_BASE      = "https://forecast.predictwind.com"
USER_AGENT   = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# PredictWind login form uses "username" for the email field (Django auth backend)
PW_USERNAME_FIELD = "username"

# --- Security / rate-limit knobs ----------------------------------------
# Minimum seconds between successive outbound PredictWind API calls.
# PredictWind monitors for bot-like rapid request bursts.
MIN_REQUEST_GAP_S = 2.0

# If an existing "Pi Location" is within this many degrees of the requested
# coordinates, reuse it instead of deleting + recreating.  At latitude 36°
# one degree ≈ 90 km — 0.05° ≈ 4.5 km, well within any forecast resolution.
REUSE_RADIUS_DEG = 0.05

# --- Anchor-detection auto-relocate -------------------------------------
# The Pi Location is NOT moved while the boat is sailing.  A background monitor
# watches SOG + GPS from state_server (:10114); only once the boat has been
# confidently anchored (low SOG, stable position) for ANCHOR_SETTLE_S does it
# relocate the Pi Location to the new anchorage and fetch a fresh forecast.
# This keeps PredictWind mutations rare (≈ one per new overnight anchorage).
ANCHOR_SOG_MAX_KN     = float(os.environ.get("PW_ANCHOR_SOG_MAX",  "0.7"))   # below = "not moving"
ANCHOR_SETTLE_S       = int(os.environ.get("PW_ANCHOR_SETTLE_S", "3600"))    # 1 h settled before relocating
ANCHOR_POLL_S         = int(os.environ.get("PW_ANCHOR_POLL_S",   "120"))     # how often to sample state
ANCHOR_DRIFT_DEG      = 0.01    # ~1.1 km: must stay within this to count as the same settled spot
RELOCATE_MIN_MOVE_DEG = 0.03    # ~3.3 km: only relocate if the anchorage is this far from the current Pi Location

# GPS staleness guards. state_server exposes vessel.fixAge (seconds since the
# last real position delta in SignalK). A dead GPS leaves lat/lon frozen at
# the last fix — acting on that silently pinned the forecast to an old
# anchorage for days (2026-07-03 incident). Absent fixAge (old state_server)
# keeps the previous permissive behaviour.
FIX_MAX_AGE_MONITOR_S = float(os.environ.get("PW_FIX_MAX_AGE_S",     "90"))   # anchor monitor: ignore older fixes
FIX_MAX_AGE_REQUEST_S = float(os.environ.get("PW_FIX_MAX_AGE_REQ_S", "600"))  # request handlers: 503 if older

# In-memory cache of the last known "Pi Location" id + coords.  Survives
# server restarts via the session file (id is re-discovered from the table
# page on first use if cache is cold).
_pi_location_cache: dict = {}   # {id, lat, lon}
_last_request_time: float = 0.0
_rate_limit_lock = threading.Lock()

# ---------------------------------------------------------------------------
# PredictWind session manager
# ---------------------------------------------------------------------------

class PredictWindSession:
    def __init__(self):
        self._lock = threading.Lock()
        self._session: Any = None  # requests.Session
        self._email: str = ""
        self._password: str = ""
        self._authenticated: bool = False
        self._last_auth_attempt: float = 0
        self._auth_error: str = ""
        self._init_session()
        self._load_config()
        # Try to restore saved cookies — clear first to prevent duplicates
        if SESSION_PATH.exists():
            try:
                self._session.cookies.clear()
                cookies = self._dedup_cookies(json.loads(SESSION_PATH.read_text()))
                self._session.cookies.update(cookies)
                print(f"[PW] Loaded saved session cookies from {SESSION_PATH}")
                self._authenticated = bool(cookies.get("sessionid"))
            except Exception as e:
                print(f"[PW] Could not load saved cookies: {e}")

    def _init_session(self):
        if Session is None:
            return
        self._session = Session()
        self._session.headers.update({
            "User-Agent":      USER_AGENT,
            "Accept":          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        })
        pass  # cookie dedup is handled via _cookie() helper

    @staticmethod
    def _dedup_cookies(raw: dict) -> dict:
        """Keep only the last value for any duplicated cookie name."""
        return dict(raw)

    def _cookie(self, name: str) -> str:
        """Safely read a cookie, returning the last value if duplicates exist.

        requests.cookies.RequestsCookieJar.get() raises CookieConflictError
        when the same cookie name appears more than once (which happens because
        PredictWind sends a new csrftoken on almost every response).  Iterating
        the jar directly is always safe.
        """
        values = [c.value for c in self._session.cookies if c.name == name]
        return values[-1] if values else ""

    def _clean_cookies(self):
        """Remove duplicate cookies from the jar, keeping the last value for each name."""
        seen: dict[str, str] = {}
        for c in list(self._session.cookies):
            seen[c.name] = c.value
        self._session.cookies.clear()
        for name, value in seen.items():
            self._session.cookies.set(name, value)

    def _load_config(self):
        if CONFIG_PATH.exists():
            try:
                cfg = json.loads(CONFIG_PATH.read_text())
                self._email    = cfg.get("email", "")
                self._password = cfg.get("password", "")
                print(f"[PW] Loaded credentials for {self._email}")
            except Exception as e:
                print(f"[PW] Could not load config: {e}")

    def save_credentials(self, email: str, password: str):
        self._email    = email
        self._password = password
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        data = json.dumps({"email": email, "password": password})
        CONFIG_PATH.write_text(data)
        CONFIG_PATH.chmod(0o600)
        print(f"[PW] Saved credentials for {email}")

    def login(self) -> bool:
        if not self._email or not self._password:
            self._auth_error = "No credentials configured"
            return False
        if Session is None:
            self._auth_error = "requests library not available"
            return False

        now = time.time()
        if now - self._last_auth_attempt < 10:
            return False  # rate-limit re-auth attempts
        self._last_auth_attempt = now

        try:
            print(f"[PW] Authenticating as {self._email}...")
            # Clear all cookies before fresh auth — prevents duplicate csrftoken
            # that accumulates across multiple Set-Cookie responses.
            self._session.cookies.clear()
            _last_request_time = 0.0   # reset rate limiter so login isn't delayed

            # Step 1: GET login page to receive CSRF token
            r = self._session.get(f"{PW_BASE}/login/", timeout=15)
            # Extract CSRF from form body (more reliable than cookie on first request)
            import re as _re
            m = _re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', r.text)
            csrf = m.group(1) if m else self._cookie("csrftoken")

            if not csrf:
                self._auth_error = "Could not get CSRF token from login page"
                print(f"[PW] {self._auth_error}")
                return False

            # Step 2: POST credentials
            # Field name: "username" (PredictWind uses Django's auth backend;
            # the HTML <input> has name="username" even though it accepts email)
            resp = self._session.post(
                f"{PW_BASE}/login/",
                data={
                    PW_USERNAME_FIELD:      self._email,
                    "password":             self._password,
                    "csrfmiddlewaretoken":  csrf,
                    "next":                 "",
                },
                headers={
                    "X-CSRFToken":  csrf,
                    "Referer":      f"{PW_BASE}/login/",
                    "Origin":       PW_BASE,
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                allow_redirects=True,
                timeout=15,
            )

            # Check if we received a sessionid cookie
            sessionid = self._cookie("sessionid")
            if sessionid:
                self._authenticated = True
                self._auth_error = ""
                # Persist cookies
                SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
                self._clean_cookies()   # flush duplicates that built up during login
                clean = self._dedup_cookies(dict(self._session.cookies))
                SESSION_PATH.write_text(json.dumps(clean))
                SESSION_PATH.chmod(0o600)
                print(f"[PW] Authenticated successfully, sessionid={sessionid[:12]}...")
                return True
            else:
                self._authenticated = False
                self._auth_error = f"Login failed — no sessionid cookie (HTTP {resp.status_code})"
                print(f"[PW] {self._auth_error}")
                return False

        except Exception as e:
            self._authenticated = False
            self._auth_error = str(e)
            print(f"[PW] Login error: {e}")
            return False

    @staticmethod
    def _rate_limit():
        """Block until MIN_REQUEST_GAP_S has elapsed since the last outbound call."""
        global _last_request_time
        with _rate_limit_lock:
            elapsed = time.time() - _last_request_time
            if elapsed < MIN_REQUEST_GAP_S:
                time.sleep(MIN_REQUEST_GAP_S - elapsed)
            _last_request_time = time.time()

    def post_form(self, path: str, data: dict, referer: str | None = None,
                  retry: bool = True) -> dict:
        """POST a form-encoded request with CSRF token, auto-retrying on 403."""
        if Session is None:
            return {"error": "requests library not available"}
        self._rate_limit()
        try:
            csrf = self._cookie("csrftoken")
            if not csrf:
                return {"error": "No CSRF token — not authenticated"}
            payload = dict(data)
            payload["csrfmiddlewaretoken"] = csrf
            url = f"{PW_BASE}{path}"
            hdrs = {
                "X-CSRFToken": csrf,
                "Referer":     referer or PW_BASE,
                "Origin":      PW_BASE,
                "Content-Type": "application/x-www-form-urlencoded",
            }
            r = self._session.post(url, data=payload, headers=hdrs, timeout=20)
            if r.status_code in (403, 302) and retry:
                print(f"[PW] Got {r.status_code} on POST {path}, re-authenticating...")
                self._authenticated = False
                if self.login():
                    return self.post_form(path, data, referer, retry=False)
                return {"error": "Authentication failed after session expired"}
            # Location add returns a redirect (302) with the new location data,
            # or JSON on some endpoints.
            try:
                return r.json()
            except Exception:
                # Return status + any useful text
                return {"status_code": r.status_code, "text": r.text[:2000]}
        except Exception as e:
            return {"error": str(e)}

    def get(self, path: str, params: dict | None = None, retry: bool = True,
            referer: str | None = None) -> dict | list | None:
        """Make an authenticated GET request, auto-retrying after re-auth on 403.

        Also detects PredictWind's stale-session pattern: the forecast endpoint
        returns {"status":"OK"} (15 bytes, no data) when the session needs a
        fresh login.  On that pattern we re-authenticate once and retry.
        """
        if Session is None:
            return {"error": "requests library not available"}
        self._rate_limit()
        try:
            url = f"{PW_BASE}{path}"
            hdrs = {
                "Accept": "application/json, text/javascript, */*; q=0.01",
                "X-Requested-With": "XMLHttpRequest",
                "Referer": referer or PW_BASE,
            }
            r = self._session.get(url, params=params, headers=hdrs, timeout=20)
            if r.status_code in (403, 302) and retry:
                print(f"[PW] Got {r.status_code} on {path}, re-authenticating...")
                self._authenticated = False
                if self.login():
                    return self.get(path, params, retry=False, referer=referer)
                return {"error": "Authentication failed after session expired"}
            r.raise_for_status()
            try:
                data = r.json()
            except Exception:
                # A login page with HTTP 200 instead of JSON is the one stale-
                # session shape not caught by the 403/302 handler above. (Do
                # NOT re-auth on bare {"status":"OK"} outside /table/ma/ — that
                # means a deleted location id, and re-login doesn't fix it.)
                body = r.text[:4000].lower()
                if retry and "csrf" in body and ("login" in body or "password" in body):
                    print(f"[PW] Login page served on {path} — re-authenticating")
                    self._authenticated = False
                    if self.login():
                        return self.get(path, params, retry=False, referer=referer)
                return {"error": "Non-JSON response", "status": r.status_code, "text": r.text[:500]}

            # Stale-session detection: forecast endpoints return {"status":"OK"}
            # with no "data" key when the session cookie is no longer active.
            # Re-login and retry exactly once.
            if (retry
                    and isinstance(data, dict)
                    and data.get("status") == "OK"
                    and "data" not in data
                    and "/table/ma/" in path):
                print(f"[PW] Stale session detected on {path} — re-authenticating")
                if self.login():
                    return self.get(path, params, retry=False, referer=referer)

            return data
        except Exception as e:
            return {"error": str(e)}

    def _saved_locations(self) -> list[dict]:
        """Parse /table/ for saved locations: [{name, area_id, entry_id}].

        Each saved location renders its forecast-area id on the name anchor
        (data-id) and a SEPARATE saved-entry id on its `.delete-location` div.
        /location/delete/ requires the ENTRY id, not the area id (verified
        2026-06-23: deleting by area id 403s, by entry id 200s).
        """
        import re as _re
        self._rate_limit()
        t = self._session.get(f"{PW_BASE}/table/",
                              headers={"Accept": "text/html"}, timeout=20).text
        areas = [(m.start(), int(m.group(1)), m.group(2).strip())
                 for m in _re.finditer(r'data-id="(\d+)"[^>]*>\s*([^<]+?)\s*</a>', t)]
        entries = [(m.start(), int(m.group(1)))
                   for m in _re.finditer(r'delete-location[^>]*data-id="(\d+)"', t)]
        out = []
        for pos, area_id, name in areas:
            entry_id = next((e for ep, e in entries if ep > pos), None)
            out.append({"name": name, "area_id": area_id, "entry_id": entry_id})
        return out

    def _entry_id_for(self, area_id: int) -> int | None:
        """Resolve a forecast-area id to its deletable saved-entry id."""
        try:
            for loc in self._saved_locations():
                if loc["area_id"] == area_id:
                    return loc["entry_id"]
        except Exception as e:
            print(f"[PW] _entry_id_for({area_id}) failed: {e}")
        return None

    def delete_location(self, location_id: int) -> dict:
        """Delete a saved location.  Accepts a forecast-area id OR a saved-entry
        id; /location/delete/ needs the ENTRY id, so resolve area→entry first."""
        if Session is None:
            return {"error": "requests library not available"}
        if not self._authenticated:
            self.login()

        # Resolve to the deletable entry id (area-id 403s on /location/delete/).
        entry_id = self._entry_id_for(location_id) or location_id

        csrf = self._cookie("csrftoken")
        url = f"{PW_BASE}/location/delete/{entry_id}/"
        hdrs = {
            "X-CSRFToken": csrf,
            "Referer":     url,
            "Origin":      PW_BASE,
            "Content-Type": "application/x-www-form-urlencoded",
        }
        try:
            # First GET to confirm we own this entry (200 = yes, 403/404 = no)
            self._rate_limit()
            r_get = self._session.get(url, timeout=15)
            if r_get.status_code == 200:
                self._rate_limit()
                r_del = self._session.post(url,
                    data={"csrfmiddlewaretoken": csrf},
                    headers=hdrs, allow_redirects=True, timeout=15)
                return {"ok": True, "deleted_id": location_id,
                        "entry_id": entry_id, "status": r_del.status_code}
            else:
                return {"ok": False, "entry_id": entry_id,
                        "reason": f"HTTP {r_get.status_code} — entry not owned/found"}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    def _load_pi_location_cache(self):
        """Restore Pi Location id + coords from the config file on startup."""
        global _pi_location_cache
        try:
            cfg = json.loads(CONFIG_PATH.read_text())
            if "pi_location_id" in cfg:
                _pi_location_cache = {
                    "name": "Pi Location",
                    "id":   cfg["pi_location_id"],
                    "lat":  cfg.get("pi_location_lat", 0),
                    "lon":  cfg.get("pi_location_lon", 0),
                }
                print(f"[PW] Restored Pi Location cache: id={_pi_location_cache['id']}")
        except Exception:
            pass

    def _save_pi_location_cache(self, loc_id: int, lat: float, lon: float):
        """Persist Pi Location id + coords to config file."""
        global _pi_location_cache
        _pi_location_cache = {"name": "Pi Location", "id": loc_id, "lat": lat, "lon": lon}
        try:
            cfg = {}
            if CONFIG_PATH.exists():
                cfg = json.loads(CONFIG_PATH.read_text())
            cfg["pi_location_id"]  = loc_id
            cfg["pi_location_lat"] = lat
            cfg["pi_location_lon"] = lon
            CONFIG_PATH.write_text(json.dumps(cfg))
            CONFIG_PATH.chmod(0o600)
        except Exception as e:
            print(f"[PW] Could not save Pi Location cache: {e}")

    def set_location(self, name: str, lat: float, lon: float,
                     force_fresh: bool = False) -> dict:
        """Smart upsert for a named location.

        Strategy (minimises PredictWind API mutations to avoid abuse triggers):
          1. Check in-memory cache — if within REUSE_RADIUS_DEG, return cached id.
          2. Scan the saved locations page for an existing entry with this name.
             If found AND within REUSE_RADIUS_DEG, reuse it (no API mutations).
          3. If found but coordinates differ significantly, delete and recreate.
          4. If not found, create fresh.

        force_fresh=True skips the reuse shortcuts (steps 1 & 3): any existing
        location with this name is deleted and a brand-new one created.  Used to
        recover from an "out of date" location id whose forecast returns the bare
        {"status":"OK"} with no data (see _handle_forecast_vessel).

        Returns {ok, id, name, lat, lon, reused: bool}.
        """
        import re as _re
        global _pi_location_cache

        if not self._authenticated:
            self.login()

        # --- 0. Load persisted Pi Location id from config if cache is cold ---
        if not _pi_location_cache:
            self._load_pi_location_cache()

        # --- 1. In-memory / config cache check (fastest path, zero API calls) ---
        if not force_fresh and _pi_location_cache.get("name") == name:
            cached_lat = _pi_location_cache.get("lat", 999)
            cached_lon = _pi_location_cache.get("lon", 999)
            if (abs(cached_lat - lat) <= REUSE_RADIUS_DEG and
                    abs(cached_lon - lon) <= REUSE_RADIUS_DEG):
                print(f"[PW] Reusing cached '{name}' id={_pi_location_cache['id']} (no API call)")
                return {"ok": True, "id": _pi_location_cache["id"],
                        "name": name, "lat": lat, "lon": lon, "reused": True}

        # --- 2. Scan table page for an existing location with this name ---
        # The page no longer embeds coordinates (it's server-rendered HTML with
        # data-id anchors), so we can only match by name and read the area/entry
        # ids.  Coordinate-aware reuse is handled by the cache in step 1; this is
        # the cold-cache fallback.
        existing_area_id = None
        existing_entry_id = None
        try:
            for loc in self._saved_locations():
                if loc["name"] == name:
                    existing_area_id  = loc["area_id"]
                    existing_entry_id = loc["entry_id"]
                    break
        except Exception as e:
            print(f"[PW] Could not scan table page: {e}")

        # --- 3. Reuse or recreate ---
        if existing_area_id is not None:
            if not force_fresh:
                # Cache (step 1) is cold but a same-named location exists — reuse
                # it.  Preserve the location's TRUE pinned coords (config) so the
                # anchor monitor's relocate decision isn't corrupted by a transient
                # request position; only seed coords if we don't know them yet.
                # Relocation while sailing is handled solely by the anchor monitor.
                true = self._pi_location_true_coords()
                plat, plon = true if true else (lat, lon)
                print(f"[PW] Reusing existing '{name}' area_id={existing_area_id} "
                      f"(name match; pinned at {plat},{plon})")
                _pi_location_cache = {"name": name, "id": existing_area_id,
                                      "lat": plat, "lon": plon}
                self._save_pi_location_cache(existing_area_id, plat, plon)
                return {"ok": True, "id": existing_area_id, "name": name,
                        "lat": plat, "lon": plon, "reused": True}

            # force_fresh — delete the old entry (by entry id) before recreating.
            print(f"[PW] '{name}' exists (area={existing_area_id}, entry={existing_entry_id}), "
                  f"force_fresh — deleting and recreating")
            if existing_entry_id:
                self.delete_location(existing_entry_id)

        # --- 4. Create new location ---
        # Refresh CSRF from a fresh GET of the add page so the token is valid
        try:
            self._rate_limit()
            r_pre = self._session.get(f"{PW_BASE}/location/add/", timeout=15)
            if "login" in r_pre.url.lower():
                print("[PW] /location/add/ redirected to login — re-authenticating")
                self.login()
        except Exception as e:
            print(f"[PW] Warning: pre-fetch of /location/add/ failed: {e}")

        csrf = self._cookie("csrftoken")
        print(f"[PW] Creating '{name}' at ({lat},{lon}) with csrf={csrf[:12]}...")
        self._rate_limit()
        r_add = self._session.post(
            f"{PW_BASE}/location/add/",
            data={"name": name, "latitude": str(lat), "longitude": str(lon),
                  "csrfmiddlewaretoken": csrf},
            headers={
                "X-CSRFToken": csrf,
                "Referer":     f"{PW_BASE}/location/add/",
                "Origin":      PW_BASE,
                "Content-Type": "application/x-www-form-urlencoded",
            },
            allow_redirects=False, timeout=20,
        )

        # PredictWind 500s on /location/add/ when the account's saved-location
        # cap is reached (10 observed) or location mutations are throttled.  Do
        # NOT retry-hammer — surface a clear, actionable error.
        if r_add.status_code >= 500:
            print(f"[PW] /location/add/ returned HTTP {r_add.status_code} — "
                  f"location cap reached or add throttled; not retrying")
            return {"ok": False, "status": r_add.status_code,
                    "error": "location_add_rejected",
                    "detail": ("PredictWind rejected the new location (HTTP "
                               f"{r_add.status_code}). The account's saved-location "
                               "limit is likely reached — delete an unused saved "
                               "location, or reuse an existing one.")}

        location_header = r_add.headers.get("Location", "")
        new_id = None
        if r_add.status_code in (301, 302, 303) and location_header:
            m = _re.search(r"location=(\d+)|[#/](\d{6,})", location_header)
            if m:
                new_id = int(m.group(1) or m.group(2))

        # Fallback: the redirect may not carry the id — scan the table page for
        # the just-created location by name (most-recent / highest id wins).
        if not new_id:
            try:
                self._rate_limit()
                rt = self._session.get(f"{PW_BASE}/table/", timeout=20)
                ids = [int(i) for i in _re.findall(
                    r'data-id="(\d+)"[^>]*>\s*' + _re.escape(name) + r'\s*</a>', rt.text)]
                if ids:
                    new_id = max(ids)
            except Exception as e:
                print(f"[PW] table-scan id fallback failed: {e}")

        title_m = _re.search(r"<title>(.*?)</title>", r_add.text, _re.S)
        page_title = title_m.group(1).strip() if title_m else ""

        if new_id:
            self._save_pi_location_cache(new_id, lat, lon)
            return {"ok": True, "id": new_id, "name": name, "lat": lat, "lon": lon, "reused": False}
        else:
            return {"ok": False, "error": page_title or f"HTTP {r_add.status_code}",
                    "status": r_add.status_code}

    # ------------------------------------------------------------------ helpers

    @staticmethod
    def _nm_bbox(lat: float, lon: float, radius_nm: float) -> tuple[float, float, float, float]:
        """(south, west, north, east) bounding box for radius_nm around a point."""
        lat_delta = radius_nm / 60.0
        lon_delta = radius_nm / (60.0 * math.cos(math.radians(lat)))
        return lat - lat_delta, lon - lon_delta, lat + lat_delta, lon + lon_delta

    def _vessel_position(self) -> tuple[float, float]:
        """Read vessel lat/lon from state_server. Raises on failure."""
        import urllib.request as _req
        with _req.urlopen("http://127.0.0.1:10114/state", timeout=5) as r:
            state = json.loads(r.read())
        vessel = state.get("vessel", {})
        raw_lat = vessel.get("lat")
        raw_lon = vessel.get("lon")
        if raw_lat is None or raw_lon is None:
            raise ValueError(
                "No GPS fix — SignalK has no position yet. "
                "Is the boat connected to SignalK? "
                "You can pass ?lat=xx&lon=xx to override."
            )
        lat, lon = float(raw_lat), float(raw_lon)
        if lat == 0 and lon == 0:
            raise ValueError("No GPS fix — vessel position is 0,0")
        age = vessel.get("fixAge")
        if isinstance(age, (int, float)) and age > FIX_MAX_AGE_REQUEST_S:
            raise ValueError(
                f"GPS fix is stale ({age/60:.0f} min old) — refusing to use it. "
                "Check the boat GPS, or pass ?lat=xx&lon=xx to override."
            )
        return lat, lon

    def _vessel_state(self) -> tuple[float | None, float | None, float | None]:
        """Read (lat, lon, sog_kn) from state_server. Returns (None,None,None)
        if there is no usable GPS fix — used by the anchor-detection monitor,
        which must never raise."""
        import urllib.request as _req
        try:
            with _req.urlopen("http://127.0.0.1:10114/state", timeout=5) as r:
                state = json.loads(r.read())
            v = state.get("vessel", {})
            raw_lat, raw_lon, raw_sog = v.get("lat"), v.get("lon"), v.get("sog")
            if raw_lat is None or raw_lon is None:
                return None, None, None
            lat, lon = float(raw_lat), float(raw_lon)
            if lat == 0 and lon == 0:
                return None, None, None
            age = v.get("fixAge")
            if isinstance(age, (int, float)) and age > FIX_MAX_AGE_MONITOR_S:
                print(f"[PW] Anchor monitor: GPS fix is {age:.0f}s old — treating as no fix")
                return None, None, None
            return lat, lon, float(raw_sog or 0.0)
        except Exception:
            return None, None, None

    @staticmethod
    def _pi_location_true_coords() -> tuple[float, float] | None:
        """The Pi Location's real pinned position, read from the config file
        (written only on create/relocate — never on reuse).  Used by the anchor
        monitor to decide whether a new anchorage is far enough to relocate."""
        try:
            cfg = json.loads(CONFIG_PATH.read_text())
            if "pi_location_lat" in cfg and "pi_location_lon" in cfg:
                return float(cfg["pi_location_lat"]), float(cfg["pi_location_lon"])
        except Exception:
            pass
        return None

    def _get_boat_polar(self, polar_name: str) -> dict:
        """Fetch mainsail + headsail polar tables for the named polar.
        Returns {"mainsail": "...", "headsail": "..."} or {"error": ...}.
        """
        polars: dict[str, str] = {}
        for sail in ("mainsail", "headsail"):
            r = self._session.get(
                f"{PW_BASE}/sail-crossover/predefined/list",
                params={"chartType": sail},
                headers={"Referer": f"{PW_BASE}/atlas/sailRouter/"},
                timeout=15,
            )
            if not r.ok:
                return {"error": f"Could not fetch {sail} list: {r.status_code}"}
            self._rate_limit()
            r2 = self._session.get(
                f"{PW_BASE}/sail-crossover/get",
                params={"chartType": sail},
                headers={"Referer": f"{PW_BASE}/atlas/sailRouter/"},
                timeout=15,
            )
            polars[sail] = r2.text if r2.ok else ""
            self._rate_limit()
        return polars

    def _submit_route(self, start_lat: float, start_lon: float,
                      end_lat: float, end_lon: float,
                      start_dt_str: str, timezone: str,
                      polar_name: str, optimise: str = "time",
                      planner: bool = False) -> str:
        """Submit a sail route (or departure plan) and return the comma-separated route IDs.

        start_dt_str: 'YYYY-MM-DD HH:MM'  (local time in timezone)
        planner:      True  → sailPlanner (departure windows)
                      False → sailRouter  (single optimised route)
        """
        base_path = "/atlas/sailPlanner" if planner else "/atlas/sailRouter"
        csrf = self._cookie("csrftoken")

        # Fetch polar tables (two GET calls)
        polar_data = self._get_boat_polar(polar_name)

        waypoints = json.dumps([
            {"lat": start_lat, "lon": start_lon, "type": 0},
            {"lat": end_lat,   "lon": end_lon,   "type": 0},
        ])
        date_part = start_dt_str[:10]
        time_part = start_dt_str[11:16]

        self._rate_limit()
        r = self._session.post(
            f"{PW_BASE}{base_path}/submit",
            data={
                "submitAction":        "execute",
                "routerJSON":          '[{"paths":[],"weather":[]}]',
                "routerBuild":         "intel",
                "waypoints":           waypoints,
                "wasLoggedIn":         "true",
                "routerBeta":          "false",
                "startTimeStr":        start_dt_str,
                "startDate":           date_part,
                "startTime":           time_part,
                "timezone":            timezone,
                "mainsail":            polar_data.get("mainsail", ""),
                "headsail":            polar_data.get("headsail", ""),
                "optimiseFor":         optimise,
                "motoringEnabled":     "on",
                "motoringSpeed":       "4.0",
                "motoringThreshold":   "1.5",
                "tackPenalty":         "150",
                "gybePenalty":         "150",
                "boatPolarType":       "predefined",
                "selected_polar":      polar_name,
                "significantHeight":   "4.5",
                "wavePolarEnabled":    "on",
                "csrfmiddlewaretoken": csrf,
            },
            headers={
                "X-CSRFToken": csrf,
                "Referer":     f"{PW_BASE}{base_path}/",
                "Origin":      PW_BASE,
                "Content-Type": "application/x-www-form-urlencoded",
            },
            timeout=30,
        )
        if not r.ok:
            raise RuntimeError(f"Route submit failed: HTTP {r.status_code}")
        route_ids = r.text.strip()
        if not route_ids or not route_ids[0].isdigit():
            raise RuntimeError(f"Unexpected submit response: {route_ids[:200]}")
        return route_ids  # e.g. "88866121,88866122,..."

    def _poll_route(self, route_ids: str, base_path: str = "/atlas/sailRouter",
                    max_wait_s: int = 180) -> bool:
        """Poll until all route IDs are complete. Returns True on success."""
        deadline = time.time() + max_wait_s
        while time.time() < deadline:
            self._rate_limit()
            r = self._session.get(
                f"{PW_BASE}{base_path}/finished",
                params={"r": route_ids, "ts": int(time.time() * 1000)},
                headers={"Referer": f"{PW_BASE}{base_path}/"},
                timeout=15,
            )
            if r.ok:
                try:
                    data = r.json()
                    # Current PW behaviour (verified 2026-06-20): /finished returns
                    # the bare JSON literal `false` while computing and `true` when
                    # all routes are done.
                    if data is True:
                        return True
                    if data is False:
                        time.sleep(4)
                        continue
                    # Tolerate older/alternate shapes just in case.
                    if isinstance(data, dict) and data.get("finished"):
                        return True
                    if isinstance(data, list) and data and all(
                        isinstance(v, dict) and v.get("status") in ("complete", "done", True)
                        for v in data
                    ):
                        return True
                except Exception:
                    pass
            time.sleep(4)
        return False  # timed out

    def _fetch_route_results(self, route_ids: str,
                             base_path: str = "/atlas/sailRouter") -> dict:
        """Fetch route results after polling confirms completion."""
        self._rate_limit()
        r = self._session.get(
            f"{PW_BASE}{base_path}/results",
            params={"result": route_ids},
            headers={"Referer": f"{PW_BASE}{base_path}/",
                     "X-Requested-With": "XMLHttpRequest"},
            timeout=30,
        )
        r.raise_for_status()
        return r.json()

    # --- Properties ---------------------------------------------------------

    @property
    def authenticated(self) -> bool:
        return self._authenticated

    @property
    def email(self) -> str:
        return self._email

    @property
    def auth_error(self) -> str:
        return self._auth_error


# ---------------------------------------------------------------------------
# Tile math helpers
# ---------------------------------------------------------------------------

def lat_lon_to_tile(lat: float, lon: float, zoom: int = 8) -> tuple[int, int]:
    n = 2 ** zoom
    x = int((lon + 180) / 360 * n)
    lat_rad = math.radians(lat)
    y = int((1 - math.log(math.tan(lat_rad) + 1 / math.cos(lat_rad)) / math.pi) / 2 * n)
    return x, y


def tiles_for_bbox(south: float, west: float, north: float, east: float,
                   zoom: int = 8) -> list[tuple[int, int]]:
    x_min, y_max = lat_lon_to_tile(south, west, zoom)
    x_max, y_min = lat_lon_to_tile(north, east, zoom)
    return [(x, y) for x in range(x_min, x_max + 1)
            for y in range(y_min, y_max + 1)]


def parse_ais_record(v: list) -> dict | None:
    """Normalise one /local-knowledge/AIS-concise array into a dict.

    Record layout: [mmsi, lat, lon, headingDeg, type, navStatus, speedKn, src].

    IMPORTANT — latitude is returned NEGATED by PredictWind's current AIS-concise
    feed (a vessel at +37.3°N is reported as -37.3).  Longitude is correct.
    Verified 2026-06-20 against Web-Mercator tile bounds: of 37 vessels, 0 matched
    the raw latitude's tile but 35 matched the negated latitude's tile.  So we flip
    the sign here.  (boats.json community positions are NOT flipped — only this feed.)
    """
    if not isinstance(v, list) or len(v) < 3:
        return None
    try:
        lat = -float(v[1])   # <-- sign correction
        lon = float(v[2])
    except (TypeError, ValueError):
        return None
    return {
        "mmsi":    str(v[0]),
        "lat":     lat,
        "lon":     lon,
        "heading": v[3] if len(v) > 3 else 0,
        "type":    v[4] if len(v) > 4 else "",
        "status":  v[5] if len(v) > 5 else "",
        "speed":   v[6] if len(v) > 6 else 0,
        "source":  v[7] if len(v) > 7 else "",
    }


def forecast_has_data(d: Any) -> bool:
    """True if a /table/ma/{id}.json response actually carries forecast data.

    PredictWind returns a bare {"status":"OK"} (no "data") when the location id
    is deleted / "out of date" — this is NOT a stale session (re-auth does not
    fix it).  Only a live location returns data.data.ForecastTable.
    """
    return (isinstance(d, dict)
            and isinstance(d.get("data"), dict)
            and "ForecastTable" in d["data"])


# ---------------------------------------------------------------------------
# Singleton session
# ---------------------------------------------------------------------------

_pw = PredictWindSession()

# Attempt initial login at startup if credentials are present
def _startup_auth():
    if _pw.email and not _pw.authenticated:
        _pw.login()

threading.Thread(target=_startup_auth, daemon=True).start()


# ---------------------------------------------------------------------------
# Anchor-detection auto-relocate monitor
# ---------------------------------------------------------------------------
# The Pi Location is never moved while sailing.  This monitor watches SOG + GPS
# and only relocates the Pi Location once the boat has been confidently anchored
# (SOG below ANCHOR_SOG_MAX_KN and staying within ANCHOR_DRIFT_DEG of one spot)
# for ANCHOR_SETTLE_S.  Result: at most one PredictWind mutation per new
# overnight anchorage, and none at all while underway.

def _far(lat1, lon1, lat2, lon2, deg):
    """True if the two points differ by more than `deg` in lat or lon."""
    return abs(lat1 - lat2) > deg or abs(lon1 - lon2) > deg


class AnchorMonitor:
    """Pure state machine that decides when to relocate the Pi Location.

    Feed it one (now, lat, lon, sog, pi_true) sample per tick via step().
    Returns (lat, lon) to relocate to, or None.  No threads, no I/O — so it is
    fully unit-testable.  Rules:
      * making way (sog > ANCHOR_SOG_MAX_KN) or no GPS → reset the settle timer.
      * must stay within ANCHOR_DRIFT_DEG of one spot for ANCHOR_SETTLE_S.
      * then relocate, but only if that anchorage is > RELOCATE_MIN_MOVE_DEG from
        both the current Pi Location and the spot we last relocated to.
    """
    def __init__(self):
        self.settle_lat = None
        self.settle_lon = None
        self.settle_since = 0.0
        self.relocated_for = None     # (lat, lon) we last asked to relocate to

    def step(self, now, lat, lon, sog, pi_true):
        # Under way or no fix → not anchored: reset the settle window.
        if lat is None or sog is None or sog > ANCHOR_SOG_MAX_KN:
            self.settle_lat = self.settle_lon = None
            return None
        # Start or restart the settle window if we just stopped, or drifted off.
        if (self.settle_lat is None or
                _far(lat, lon, self.settle_lat, self.settle_lon, ANCHOR_DRIFT_DEG)):
            self.settle_lat, self.settle_lon, self.settle_since = lat, lon, now
            return None
        # Held the same spot — wait until we've held it long enough.
        if now - self.settle_since < ANCHOR_SETTLE_S:
            return None
        slat, slon = round(self.settle_lat, 4), round(self.settle_lon, 4)
        # Already relocated to (essentially) this anchorage? Don't repeat.
        if (self.relocated_for and
                not _far(slat, slon, self.relocated_for[0], self.relocated_for[1],
                         RELOCATE_MIN_MOVE_DEG)):
            return None
        # Pi Location already effectively here? Mark handled, don't relocate.
        if pi_true and not _far(slat, slon, pi_true[0], pi_true[1], RELOCATE_MIN_MOVE_DEG):
            self.relocated_for = (slat, slon)
            return None
        # Confidently anchored at a new spot — relocate.  Record it first so a
        # failed relocate (e.g. saved-location cap) backs off instead of hammering.
        self.relocated_for = (slat, slon)
        return (slat, slon)


def _anchor_relocate_loop():
    mon = AnchorMonitor()
    while True:
        time.sleep(ANCHOR_POLL_S)
        try:
            if not _pw.email:
                continue
            lat, lon, sog = _pw._vessel_state()
            target = mon.step(time.time(), lat, lon, sog, _pw._pi_location_true_coords())
            if target is None:
                continue
            slat, slon = target
            if not _pw.authenticated:
                _pw.login()
            print(f"[PW] anchor-monitor: anchored ≥{int(ANCHOR_SETTLE_S//60)} min at "
                  f"({slat},{slon}) — relocating Pi Location")
            res = _pw.set_location("Pi Location", slat, slon, force_fresh=True)
            if res.get("ok"):
                fc = _pw.get(f"/table/ma/{res['id']}.json", referer=f"{PW_BASE}/table/")
                print(f"[PW] anchor-monitor: Pi Location relocated to ({slat},{slon}) "
                      f"id={res['id']} forecast={'ok' if forecast_has_data(fc) else 'pending'}")
            else:
                # Likely the saved-location cap (HTTP 500) — already recorded in the
                # monitor, so it won't retry this spot until the boat moves on.
                print(f"[PW] anchor-monitor: relocate failed: "
                      f"{res.get('detail') or res.get('error')}")
        except Exception as e:
            print(f"[PW] anchor-monitor loop error: {e}")


threading.Thread(target=_anchor_relocate_loop, daemon=True).start()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[PW HTTP] {self.address_string()} - {fmt % args}")

    # ------ common helpers --------------------------------------------------

    def _send_json(self, data, status: int = 200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, message: str, status: int = 500):
        self._send_json({"error": message}, status)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def _parse_qs(self) -> dict:
        parsed = urllib.parse.urlparse(self.path)
        return dict(urllib.parse.parse_qsl(parsed.query))

    def _path(self) -> str:
        return urllib.parse.urlparse(self.path).path

    # ------ route ----------------------------------------------------------

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self._path()
        qs   = self._parse_qs()

        try:
            if path == "/health":
                self._handle_health()
            elif path == "/status":
                self._handle_status()
            elif path == "/forecast/vessel":
                self._handle_forecast_vessel(qs)
            elif path.startswith("/forecast/"):
                loc_id = path.split("/forecast/", 1)[1].rstrip("/")
                self._handle_forecast(loc_id)
            elif path == "/ais/vessel":
                self._handle_ais_vessel()
            elif path == "/ais":
                self._handle_ais(qs)
            elif path == "/community-boats":
                self._handle_community_boats()
            elif path == "/local-knowledge/vessel":
                self._handle_local_knowledge_vessel()
            elif path == "/locations":
                self._handle_locations()
            elif path.startswith("/overview/"):
                loc_id = path.split("/overview/", 1)[1].rstrip("/")
                self._handle_overview(loc_id)
            elif path.startswith("/twilight/"):
                loc_id = path.split("/twilight/", 1)[1].rstrip("/")
                self._handle_twilight(loc_id)
            else:
                self._send_error(f"Unknown path: {path}", 404)
        except Exception as e:
            traceback.print_exc()
            self._send_error(str(e))

    def do_DELETE(self):
        path = self._path()
        try:
            # DELETE /location/{id}
            if path.startswith("/location/"):
                loc_id_str = path.split("/location/", 1)[1].rstrip("/")
                if loc_id_str.isdigit():
                    self._handle_location_delete(int(loc_id_str))
                else:
                    self._send_error("Invalid location id", 400)
            else:
                self._send_error(f"Unknown path: {path}", 404)
        except Exception as e:
            traceback.print_exc()
            self._send_error(str(e))

    def do_POST(self):
        path = self._path()
        try:
            if path == "/credentials":
                self._handle_set_credentials()
            elif path == "/login":
                self._handle_login()
            elif path == "/location/add":
                self._handle_location_add()
            elif path == "/location/set":
                self._handle_location_set()
            elif path == "/routing/vessel":
                self._handle_routing_vessel()
            elif path == "/departure-planning/vessel":
                self._handle_departure_planning_vessel()
            else:
                self._send_error(f"Unknown path: {path}", 404)
        except Exception as e:
            traceback.print_exc()
            self._send_error(str(e))

    # ------ handlers -------------------------------------------------------

    def _handle_health(self):
        self._send_json({
            "ok":            True,
            "authenticated": _pw.authenticated,
            "email":         _pw.email,
        })

    def _handle_status(self):
        self._send_json({
            "authenticated": _pw.authenticated,
            "email":         _pw.email,
            "error":         _pw.auth_error,
            "base":          PW_BASE,
        })

    def _handle_set_credentials(self):
        body = self._read_body()
        email    = body.get("email", "").strip()
        password = body.get("password", "").strip()
        if not email or not password:
            return self._send_error("email and password required", 400)
        _pw.save_credentials(email, password)
        ok = _pw.login()
        self._send_json({
            "ok":            ok,
            "authenticated": _pw.authenticated,
            "email":         _pw.email,
            "error":         _pw.auth_error if not ok else "",
        })

    def _handle_login(self):
        ok = _pw.login()
        self._send_json({
            "ok":            ok,
            "authenticated": _pw.authenticated,
            "email":         _pw.email,
            "error":         _pw.auth_error if not ok else "",
        })

    def _handle_forecast(self, location_id: str):
        if not location_id:
            return self._send_error("locationId required", 400)
        if not _pw.authenticated:
            _pw.login()
        # get() auto-detects stale session and re-auths if needed
        data = _pw.get(f"/table/ma/{location_id}.json", referer=f"{PW_BASE}/table/")
        # Bare {"status":"OK"} = the location id no longer exists / is out of date.
        # We can't recreate an arbitrary id here (it isn't ours to manage), so flag
        # it clearly for the caller instead of returning a confusing empty payload.
        if not forecast_has_data(data):
            return self._send_json({
                "ok": False,
                "error": "out_of_date_location",
                "detail": (f"Location {location_id} returned no forecast data "
                           "(deleted or out of date). Use /forecast/vessel, which "
                           "recreates the Pi Location automatically."),
                "raw": data,
            })
        self._send_json(data)

    def _handle_ais(self, qs: dict):
        """Fetch AIS data for a bounding box from PredictWind tile API."""
        try:
            south = float(qs.get("south", 35.0))
            west  = float(qs.get("west",  20.0))
            north = float(qs.get("north", 38.0))
            east  = float(qs.get("east",  26.0))
            zoom  = int(qs.get("zoom",  8))
            age   = int(qs.get("age",  60))
        except (ValueError, TypeError) as e:
            return self._send_error(f"Invalid bbox params: {e}", 400)

        if not _pw.authenticated:
            _pw.login()

        tiles = tiles_for_bbox(south, west, north, east, zoom)
        all_vessels = []
        seen_mmsis: set[str] = set()

        for x, y in tiles:
            path = f"/local-knowledge/AIS-concise"
            params = {"age": age, "x": x, "y": y, "z": zoom, "kpler": ""}
            result = _pw.get(path, params=params, referer=f"{PW_BASE}/local-knowledge/ais-data-only/")
            if isinstance(result, dict) and "aisLocations" in result:
                for v in result["aisLocations"]:
                    rec = parse_ais_record(v)
                    if rec is None or rec["mmsi"] in seen_mmsis:
                        continue
                    seen_mmsis.add(rec["mmsi"])
                    all_vessels.append(rec)

        self._send_json({"vessels": all_vessels, "count": len(all_vessels)})

    def _handle_community_boats(self):
        if not _pw.authenticated:
            _pw.login()
        data = _pw.get("/local-knowledge/locations/boats.json", referer=f"{PW_BASE}/local-knowledge/")
        # Normalise: array of [last_seen, lat, lon, name]
        if isinstance(data, list):
            boats = []
            for b in data:
                if isinstance(b, list) and len(b) >= 4:
                    boats.append({
                        "lastSeen": b[0],
                        "lat":      b[1],
                        "lon":      b[2],
                        "name":     b[3],
                    })
            self._send_json({"boats": boats, "count": len(boats)})
        else:
            self._send_json(data)

    def _handle_locations(self):
        """Return the account's CURRENT saved locations, parsed live from the
        /table/ page (id = forecast-area id usable with /forecast/{id})."""
        if not _pw.authenticated:
            _pw.login()
        try:
            locs = _pw._saved_locations()
            locations = [{"name": l["name"], "id": l["area_id"],
                          "entry_id": l["entry_id"]} for l in locs]
            self._send_json({"locations": locations, "count": len(locations)})
        except Exception as e:
            self._send_error(f"Could not read saved locations: {e}")

    def _handle_overview(self, location_id: str):
        if not _pw.authenticated:
            _pw.login()
        ts = int(time.time() * 1000)
        data = _pw.get(f"/table/overviewData/{location_id}.json", params={"_": ts},
                       referer=f"{PW_BASE}/table/")
        self._send_json(data)

    def _handle_location_add(self):
        """Add a new saved location to PredictWind.
        Body: {name, lat, lon}
        Returns: {ok, location} with the server-assigned id.
        """
        body = self._read_body()
        name = str(body.get("name", "")).strip()[:15]   # PW max 15 chars
        try:
            lat = float(body["lat"])
            lon = float(body["lon"])
        except (KeyError, TypeError, ValueError) as e:
            return self._send_error(f"lat and lon required and must be numeric: {e}", 400)
        if not name:
            return self._send_error("name required", 400)
        if not _pw.authenticated:
            _pw.login()

        result = _pw.post_form(
            "/location/add/",
            {"name": name, "lat": lat, "lon": lon},
            referer=f"{PW_BASE}/table/",
        )

        # Try to extract the location id from the response.
        # PW may redirect (302) to /table/?location=<id> or return JSON.
        loc_id = None
        if isinstance(result, dict):
            loc_id = result.get("id") or result.get("location_id")
            # Check redirect URL fragment
            text = result.get("text", "")
            import re as _re2
            m = _re2.search(r'[?&]location=(\d+)', text)
            if m:
                loc_id = int(m.group(1))
            # Also try JSON in the body
            m2 = _re2.search(r'"id"\s*:\s*(\d+)', text)
            if m2 and not loc_id:
                loc_id = int(m2.group(1))

        self._send_json({
            "ok":       loc_id is not None,
            "name":     name,
            "lat":      lat,
            "lon":      lon,
            "id":       loc_id,
            "raw":      result,
        })

    def _handle_forecast_vessel(self, qs: dict | None = None):
        """GET /forecast/vessel
        1. Read vessel GPS from state_server (:10114)
        2. Set 'Pi Location' to those coordinates (deletes old one first)
        3. Fetch and return the PredictWind forecast for that location.
        Response: {ok, lat, lon, location_id, forecast: {...ForecastTable...}}
        """
        import urllib.request as _req

        # --- 1. Get vessel position (query param override or state_server) ---
        qs = qs or {}
        if "lat" in qs and "lon" in qs:
            # Manual override: GET /forecast/vessel?lat=36.5036&lon=22.969
            try:
                raw_lat = float(qs["lat"])
                raw_lon = float(qs["lon"])
            except ValueError as e:
                return self._send_error(f"Invalid lat/lon params: {e}", 400)
        else:
            try:
                raw_lat, raw_lon = _pw._vessel_position()
            except Exception as e:
                return self._send_error(str(e), 503)

        if raw_lat == 0 and raw_lon == 0:
            return self._send_error("No GPS fix — vessel position is 0,0", 503)

        # Round to 4 dp (≈11 m accuracy, avoids PredictWind precision bug at 6 dp)
        lat = round(raw_lat, 4)
        lon = round(raw_lon, 4)
        print(f"[PW] Vessel GPS: {raw_lat:.6f}, {raw_lon:.6f}  → snapped to {lat}, {lon}")

        # --- 2. Set Pi Location ---
        if not _pw.authenticated:
            _pw.login()
        loc_result = _pw.set_location("Pi Location", lat, lon)
        if not loc_result.get("ok"):
            return self._send_error(
                f"Failed to set Pi Location: {loc_result.get('error','unknown')}", 502)

        loc_id = loc_result["id"]
        action = "reused" if loc_result.get("reused") else "created"
        print(f"[PW] Pi Location {action} at ({lat}, {lon}), id={loc_id}")

        # --- 3. Fetch forecast ---
        forecast_data = _pw.get(f"/table/ma/{loc_id}.json",
                                referer=f"{PW_BASE}/table/")

        # Self-heal: a bare {"status":"OK"} (no data) means the (reused) location
        # id is out of date / was deleted on PredictWind's side.  Recreate the Pi
        # Location from scratch and retry once.  Only happens when a cached id has
        # gone stale, so it is not a rapid-mutation risk.
        if not forecast_has_data(forecast_data):
            print(f"[PW] Location {loc_id} returned no data (out of date) — "
                  f"recreating Pi Location and retrying once")
            loc_result = _pw.set_location("Pi Location", lat, lon, force_fresh=True)
            if loc_result.get("ok"):
                loc_id = loc_result["id"]
                print(f"[PW] Recreated Pi Location id={loc_id}")
                forecast_data = _pw.get(f"/table/ma/{loc_id}.json",
                                        referer=f"{PW_BASE}/table/")

        self._send_json({
            "ok":              forecast_has_data(forecast_data),
            "lat":             lat,
            "lon":             lon,
            "raw_lat":         raw_lat,
            "raw_lon":         raw_lon,
            "location_id":     loc_id,
            "location_reused": loc_result.get("reused", False),
            "forecast":        forecast_data,
        })

    def _handle_location_set(self):
        """POST /location/set — {name, lat, lon}
        Deletes any existing saved location with this name, creates a fresh one.
        Returns {ok, id, name, lat, lon}.
        """
        body = self._read_body()
        name = str(body.get("name", "")).strip()
        try:
            lat = float(body["lat"])
            lon = float(body["lon"])
        except (KeyError, TypeError, ValueError) as e:
            return self._send_error(f"lat and lon required: {e}", 400)
        if not name:
            return self._send_error("name required", 400)
        if not _pw.authenticated:
            _pw.login()
        result = _pw.set_location(name, lat, lon)
        self._send_json(result)

    def _handle_location_delete(self, location_id: int):
        """DELETE /location/{id} — remove a saved location."""
        if not _pw.authenticated:
            _pw.login()
        result = _pw.delete_location(location_id)
        self._send_json(result)

    # ------------------------------------------------------------------ #3 AIS/vessel

    def _handle_ais_vessel(self):
        """GET /ais/vessel
        Downloads commercial AIS tiles for a 50 NM square around the vessel's
        current GPS position. Also returns nearby PredictWind community boats.

        Response: {ok, vessel_lat, vessel_lon, bbox, vessels:[...], community_boats:[...]}
        """
        RADIUS_NM = 50
        if not _pw.authenticated:
            _pw.login()
        try:
            raw_lat, raw_lon = _pw._vessel_position()
        except Exception as e:
            return self._send_error(str(e), 503)

        south, west, north, east = _pw._nm_bbox(raw_lat, raw_lon, RADIUS_NM)
        print(f"[PW] AIS/vessel: bbox ({south:.3f},{west:.3f}) → ({north:.3f},{east:.3f})")

        # --- Commercial AIS tiles ---
        tiles = tiles_for_bbox(south, west, north, east, zoom=8)
        all_vessels: list[dict] = []
        seen: set[str] = set()
        for x, y in tiles:
            result = _pw.get(
                "/local-knowledge/AIS-concise",
                params={"age": 60, "x": x, "y": y, "z": 8, "kpler": ""},
                referer=f"{PW_BASE}/local-knowledge/ais-data-only/",
            )
            if isinstance(result, dict):
                for v in result.get("aisLocations", []):
                    rec = parse_ais_record(v)   # latitude already sign-corrected
                    if rec is None or rec["mmsi"] in seen:
                        continue
                    seen.add(rec["mmsi"])
                    # Filter to bbox (using corrected lat/lon)
                    if south <= rec["lat"] <= north and west <= rec["lon"] <= east:
                        all_vessels.append(rec)

        # --- Community boats (PredictWind DataHub) filtered to bbox ---
        community: list[dict] = []
        cb = _pw.get("/local-knowledge/locations/boats.json",
                     referer=f"{PW_BASE}/local-knowledge/")
        if isinstance(cb, list):
            for b in cb:
                if isinstance(b, list) and len(b) >= 4:
                    blat, blon = b[1], b[2]
                    if south <= blat <= north and west <= blon <= east:
                        community.append({"lastSeen": b[0], "lat": blat,
                                          "lon": blon, "name": b[3]})

        self._send_json({
            "ok": True,
            "vessel_lat": raw_lat, "vessel_lon": raw_lon,
            "radius_nm": RADIUS_NM,
            "bbox": {"south": south, "west": west, "north": north, "east": east},
            "vessels": all_vessels,       "vessel_count": len(all_vessels),
            "community_boats": community, "community_count": len(community),
        })

    # ------------------------------------------------------------------ #4 local-knowledge/vessel

    def _handle_local_knowledge_vessel(self):
        """GET /local-knowledge/vessel
        Downloads POIs, passages, and community boats within 50 NM of the vessel.

        POIs use PredictWind's community category system. The known category ID
        is 205032; we scan nearby IDs to capture anchorages, marinas, hazards.

        Response: {ok, vessel_lat, vessel_lon, pois:[...], passages:[...], community_boats:[...]}
        """
        RADIUS_NM = 50
        if not _pw.authenticated:
            _pw.login()
        try:
            raw_lat, raw_lon = _pw._vessel_position()
        except Exception as e:
            return self._send_error(str(e), 503)

        south, west, north, east = _pw._nm_bbox(raw_lat, raw_lon, RADIUS_NM)

        def in_bbox(lat: float, lon: float) -> bool:
            return south <= lat <= north and west <= lon <= east

        def dist_nm(lat: float, lon: float) -> float:
            dlat = (lat - raw_lat) * 60
            dlon = (lon - raw_lon) * 60 * math.cos(math.radians(raw_lat))
            return math.sqrt(dlat ** 2 + dlon ** 2)

        # --- POIs: try a range of community category IDs ---
        all_pois: list[dict] = []
        seen_poi: set = set()
        # Known category; try ±20 around it to capture standard categories
        for cat_id in range(205012, 205053, 5):
            result = _pw.get("/local-knowledge/locations/pois.json",
                             params={"c": cat_id},
                             referer=f"{PW_BASE}/local-knowledge/")
            if isinstance(result, list):
                for poi in result:
                    if not isinstance(poi, dict):
                        continue
                    pid  = poi.get("id")
                    plat = float(poi.get("lat", 0))
                    plon = float(poi.get("lon", 0))
                    if pid in seen_poi or not in_bbox(plat, plon):
                        continue
                    seen_poi.add(pid)
                    all_pois.append({
                        "id":       pid,
                        "name":     poi.get("name", ""),
                        "type":     poi.get("type", ""),
                        "lat":      plat,
                        "lon":      plon,
                        "dist_nm":  round(dist_nm(plat, plon), 1),
                        "category": cat_id,
                    })

        # --- Passages ---
        passages: list[dict] = []
        result = _pw.get("/local-knowledge/locations/loadPassages",
                         referer=f"{PW_BASE}/local-knowledge/")
        if isinstance(result, list):
            for p in result:
                if not isinstance(p, dict):
                    continue
                plat = float(p.get("lat", 0))
                plon = float(p.get("lon", 0))
                if in_bbox(plat, plon):
                    passages.append({
                        "id":      p.get("id"),
                        "name":    p.get("name", ""),
                        "lat":     plat,
                        "lon":     plon,
                        "dist_nm": round(dist_nm(plat, plon), 1),
                    })

        # --- Community boats ---
        community: list[dict] = []
        cb = _pw.get("/local-knowledge/locations/boats.json",
                     referer=f"{PW_BASE}/local-knowledge/")
        if isinstance(cb, list):
            for b in cb:
                if isinstance(b, list) and len(b) >= 4:
                    blat, blon = b[1], b[2]
                    if in_bbox(blat, blon):
                        community.append({
                            "lastSeen": b[0], "lat": blat, "lon": blon,
                            "name": b[3], "dist_nm": round(dist_nm(blat, blon), 1)
                        })

        # Sort everything by distance
        all_pois.sort(key=lambda x: x["dist_nm"])
        passages.sort(key=lambda x: x["dist_nm"])
        community.sort(key=lambda x: x["dist_nm"])

        self._send_json({
            "ok": True,
            "vessel_lat": raw_lat, "vessel_lon": raw_lon,
            "radius_nm": RADIUS_NM,
            "bbox": {"south": south, "west": west, "north": north, "east": east},
            "pois": all_pois,           "poi_count": len(all_pois),
            "passages": passages,       "passage_count": len(passages),
            "community_boats": community, "community_count": len(community),
        })

    # ------------------------------------------------------------------ #5 routing/vessel

    def _handle_routing_vessel(self):
        """POST /routing/vessel
        Weather routing from the vessel's current GPS to a goal waypoint,
        departing immediately (current UTC time).

        Request body: {
            "goal_lat": 36.5,
            "goal_lon": 23.0,
            "polar":    "Beneteau 40.7",   ← optional, falls back to config/default
            "optimise": "time"|"comfort",  ← optional, default "time"
            "timezone": "Europe/Athens"    ← optional, default "UTC"
        }
        Response: {ok, start_lat, start_lon, goal_lat, goal_lon,
                   departure_utc, route_ids, results: {...}}
        """
        import datetime as _dt
        body = self._read_body()

        try:
            goal_lat = float(body["goal_lat"])
            goal_lon = float(body["goal_lon"])
        except (KeyError, TypeError, ValueError):
            return self._send_error("goal_lat and goal_lon required", 400)

        polar    = body.get("polar")    or self._config_polar()
        optimise = body.get("optimise", "time")
        timezone = body.get("timezone", "UTC")

        if not _pw.authenticated:
            _pw.login()
        try:
            raw_lat, raw_lon = _pw._vessel_position()
        except Exception as e:
            return self._send_error(str(e), 503)

        now_utc = _dt.datetime.now(_dt.timezone.utc)
        start_str = now_utc.strftime("%Y-%m-%d %H:%M")
        print(f"[PW] Routing: ({raw_lat:.4f},{raw_lon:.4f}) → ({goal_lat},{goal_lon}) at {start_str} UTC")

        try:
            route_ids = _pw._submit_route(
                raw_lat, raw_lon, goal_lat, goal_lon,
                start_str, timezone, polar, optimise, planner=False)
            print(f"[PW] Route IDs: {route_ids}  — polling...")
            _pw._poll_route(route_ids, base_path="/atlas/sailRouter")
            results = _pw._fetch_route_results(route_ids, base_path="/atlas/sailRouter")
        except Exception as e:
            return self._send_error(f"Routing failed: {e}", 502)

        self._send_json({
            "ok": True,
            "start_lat": raw_lat, "start_lon": raw_lon,
            "goal_lat": goal_lat, "goal_lon": goal_lon,
            "departure_utc": start_str,
            "polar": polar, "optimise": optimise,
            "route_ids": route_ids,
            "results": results,
        })

    # ------------------------------------------------------------------ #6 departure-planning/vessel

    def _handle_departure_planning_vessel(self):
        """POST /departure-planning/vessel
        Runs PredictWind's Departure Planner for the next 7 days, always
        departing at 09:00 local time. Returns one routing result per day.

        Request body: {
            "goal_lat": 36.5,
            "goal_lon": 23.0,
            "polar":    "Beneteau 40.7",   ← optional
            "timezone": "Europe/Athens",   ← required for 9am local conversion
            "days":     7                  ← optional, default 7, max 10
        }
        Response: {ok, start_lat, start_lon, goal_lat, goal_lon,
                   timezone, departures: [{date, departure_utc, route_ids, results}, ...]}
        """
        import datetime as _dt

        body = self._read_body()
        try:
            goal_lat = float(body["goal_lat"])
            goal_lon = float(body["goal_lon"])
        except (KeyError, TypeError, ValueError):
            return self._send_error("goal_lat and goal_lon required", 400)

        polar    = body.get("polar")    or self._config_polar()
        timezone = body.get("timezone", "UTC")
        days     = min(int(body.get("days", 7)), 10)

        if not _pw.authenticated:
            _pw.login()
        try:
            raw_lat, raw_lon = _pw._vessel_position()
        except Exception as e:
            return self._send_error(str(e), 503)

        # Build list of departure times: next `days` days at 09:00 local
        # We approximate local time by using the UTC offset implied by timezone name
        # (full pytz not available; use a simple offset table for common zones)
        tz_offsets: dict[str, int] = {
            "UTC": 0, "Europe/Athens": 3, "Europe/London": 1,
            "Europe/Berlin": 2, "Europe/Paris": 2, "America/New_York": -4,
            "America/Chicago": -5, "America/Los_Angeles": -7,
            "Pacific/Auckland": 12, "Asia/Dubai": 4,
        }
        utc_offset_h = tz_offsets.get(timezone, 0)

        now_utc = _dt.datetime.now(_dt.timezone.utc)
        departures: list[dict] = []

        for day_offset in range(days):
            # 09:00 local = 09:00 - utc_offset_h UTC
            dep_utc_h = 9 - utc_offset_h
            dep_utc = (now_utc + _dt.timedelta(days=day_offset)).replace(
                hour=dep_utc_h % 24, minute=0, second=0, microsecond=0)
            if dep_utc < now_utc:
                dep_utc += _dt.timedelta(days=1)

            dep_str = dep_utc.strftime("%Y-%m-%d %H:%M")
            local_date = (dep_utc + _dt.timedelta(hours=utc_offset_h)).strftime("%Y-%m-%d")
            print(f"[PW] Departure plan day {day_offset+1}: {dep_str} UTC  (09:00 local {local_date})")

            try:
                route_ids = _pw._submit_route(
                    raw_lat, raw_lon, goal_lat, goal_lon,
                    dep_str, timezone, polar, "time", planner=True)
                _pw._poll_route(route_ids, base_path="/atlas/sailPlanner")
                results = _pw._fetch_route_results(route_ids, base_path="/atlas/sailPlanner")
                departures.append({
                    "date":          local_date,
                    "departure_utc": dep_str,
                    "departure_local": f"{local_date} 09:00",
                    "route_ids":     route_ids,
                    "results":       results,
                })
            except Exception as e:
                departures.append({
                    "date":          local_date,
                    "departure_utc": dep_str,
                    "error":         str(e),
                })

        self._send_json({
            "ok": True,
            "start_lat": raw_lat, "start_lon": raw_lon,
            "goal_lat": goal_lat, "goal_lon": goal_lon,
            "polar": polar, "timezone": timezone,
            "departures": departures,
        })

    def _config_polar(self) -> str:
        """Return boat polar name from config, or default."""
        try:
            cfg = json.loads(CONFIG_PATH.read_text())
            return cfg.get("polar_name", "Beneteau 40.7")
        except Exception:
            return "Beneteau 40.7"

    def _handle_twilight(self, location_id: str):
        if not _pw.authenticated:
            _pw.login()
        data = _pw.get(f"/twilightData/{location_id}", referer=f"{PW_BASE}/table/")
        self._send_json(data)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    print(f"[PW] Starting PredictWind proxy on port {HTTP_PORT}")
    if requests is None:
        print("[PW] ERROR: 'requests' library is required. Install with: sudo pip3 install requests")
        return

    server = ThreadedTCPServer(("0.0.0.0", HTTP_PORT), Handler)
    print(f"[PW] Listening on http://0.0.0.0:{HTTP_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[PW] Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
