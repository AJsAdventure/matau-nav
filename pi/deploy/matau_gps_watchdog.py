#!/usr/bin/env python3
"""Matau GPS watchdog — revives a silently-stalled PL2303 USB GPS.

The Prolific PL2303 adapter has a recurring failure mode: the USB read pipe
halts (`pl2303 ttyUSBx: urb stopped: -32`) while the device stays enumerated
and SignalK keeps the port open — no bytes flow, no error is raised, and the
boat silently runs on the SeaTalk fallback (or nothing). The proven recovery
is a targeted deauthorize/reauthorize of ONLY the PL2303 via sysfs, which
produces a clean disconnect that SignalK's serialport provider handles by
reopening the port (verified 2026-07-04, SignalK 2.23.0).

Detection has to work through sourcePriorities, which HIDES the losing
source: navigation.position exposes no per-source `values` map on this
server (verified 2026-07-05), only the winning `$source` + `timestamp`.
So the health inference is:

  * $source is USB-GPS.* and timestamp fresh      -> healthy, clear state
  * $source is USB-GPS.* and timestamp > STALE_S  -> all sources dead;
        if the PL2303 is enumerated, reset it (harmless if the fault is
        elsewhere — the cooldown stops flapping)
  * $source is NOT USB-GPS.* (SeaTalk won the failover) for two consecutive
        runs (> FAILOVER_CONFIRM_S) -> the USB GPS has been silent long
        enough that priorities dropped it; reset the PL2303

Run from a systemd timer every 2 minutes. Never touches the FTDI/SeaTalk
adapter. Exits 0 always (a watchdog that crash-loops its own timer helps
nobody); actions go to the journal.
"""

import json
import pathlib
import sys
import time
import urllib.request
from datetime import datetime, timezone

SIGNALK_POS_URL = "http://127.0.0.1:3000/signalk/v1/api/vessels/self/navigation/position"
USB_SOURCE_PREFIX = "USB-GPS"      # SignalK $source label for the USB GPS provider
PROLIFIC_VENDOR = "067b"           # PL2303 idVendor; the only Prolific device aboard
STALE_S = 300                      # winning fix older than this => nothing is delivering
FAILOVER_CONFIRM_S = 240           # SeaTalk must hold primary this long before we act
COOLDOWN_S = 900                   # min seconds between resets
RESET_STAMP = pathlib.Path("/run/matau-gps-watchdog.reset")
FAILOVER_STAMP = pathlib.Path("/run/matau-gps-watchdog.failover")
THROTTLE_STATE = pathlib.Path("/run/matau-gps-watchdog.throttled")


def log(msg: str) -> None:
    print(f"matau-gps-watchdog: {msg}", flush=True)


def read_position() -> tuple[str | None, float | None]:
    """(winning $source, age of its timestamp in seconds), Nones if unknown."""
    try:
        with urllib.request.urlopen(SIGNALK_POS_URL, timeout=5) as r:
            p = json.loads(r.read().decode())
    except Exception as e:
        log(f"SignalK unreachable ({e}) — nothing to do")
        return None, None
    src = p.get("$source")
    ts = p.get("timestamp")
    age = None
    if isinstance(ts, str):
        try:
            fix = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            age = (datetime.now(timezone.utc) - fix).total_seconds()
        except ValueError:
            pass
    return (src if isinstance(src, str) else None), age


def find_prolific_sysfs() -> pathlib.Path | None:
    """Locate the PL2303's USB device dir dynamically (its port moves)."""
    for dev in pathlib.Path("/sys/bus/usb/devices").iterdir():
        vid = dev / "idVendor"
        try:
            if vid.exists() and vid.read_text().strip() == PROLIFIC_VENDOR:
                return dev
        except OSError:
            continue
    return None


def cooldown_active() -> bool:
    try:
        return time.time() - RESET_STAMP.stat().st_mtime < COOLDOWN_S
    except FileNotFoundError:
        return False


def failover_age_s() -> float:
    """Seconds since we first saw a non-USB source winning (0 = just now)."""
    try:
        return time.time() - FAILOVER_STAMP.stat().st_mtime
    except FileNotFoundError:
        FAILOVER_STAMP.touch()
        return 0.0


def clear_failover() -> None:
    try:
        FAILOVER_STAMP.unlink()
    except FileNotFoundError:
        pass


def reset_device(dev: pathlib.Path, why: str) -> None:
    if cooldown_active():
        log(f"{why} — but a reset ran <{COOLDOWN_S}s ago, waiting")
        return
    dev_auth = dev / "authorized"
    log(f"{why} — resetting PL2303 at {dev.name} (deauthorize/reauthorize)")
    try:
        dev_auth.write_text("0")
        time.sleep(3)
        dev_auth.write_text("1")
        RESET_STAMP.touch()
        log("reset done; SignalK should reattach within seconds")
    except OSError as e:
        log(f"reset FAILED: {e}")


def log_throttle_transitions() -> None:
    """Journal a line whenever the Pi's throttle/undervoltage flags CHANGE.

    Piggybacks on this 2-min timer to give a timeline for the chronic
    0x50005 undervoltage (bit0 = undervolt now, bit2 = throttled now,
    bits 16/18 = occurred since boot) — the evidence for whether a power
    supply / cable change actually fixed it. Logs transitions only, so the
    journal isn't spammed while the state is steady.
    """
    try:
        import subprocess
        out = subprocess.run(["vcgencmd", "get_throttled"], capture_output=True,
                             text=True, timeout=5).stdout.strip()
        current = out.split("=", 1)[-1] if "=" in out else out
        previous = THROTTLE_STATE.read_text().strip() if THROTTLE_STATE.exists() else None
        if current and current != previous:
            live = int(current, 16) & 0x5      # under-voltage / throttled RIGHT NOW
            log(f"power: throttled flags {previous or 'unknown'} -> {current}"
                + (" (UNDER-VOLTAGE/THROTTLING ACTIVE)" if live else " (live flags clear)"))
            THROTTLE_STATE.write_text(current)
    except Exception:
        pass  # advisory only — never let telemetry break the GPS watchdog


def main() -> int:
    log_throttle_transitions()
    src, age = read_position()
    if src is None:
        return 0

    if src.startswith(USB_SOURCE_PREFIX):
        clear_failover()
        if age is not None and age > STALE_S:
            dev = find_prolific_sysfs()
            if dev is None:
                log(f"position {age:.0f}s stale but no Prolific adapter enumerated — unplugged?")
                return 0
            reset_device(dev, f"USB-GPS fix is {age:.0f}s old (no source delivering)")
        return 0

    # A non-USB source is winning: the USB GPS has been silent past the
    # sourcePriorities timeout. Confirm across two runs before acting so a
    # momentary blip (or a deliberate USB unplug + fast replug) isn't punished.
    held = failover_age_s()
    if held < FAILOVER_CONFIRM_S:
        log(f"failover active (source {src}, held {held:.0f}s) — confirming before reset")
        return 0
    dev = find_prolific_sysfs()
    if dev is None:
        log(f"failover to {src} but no Prolific adapter enumerated — USB GPS unplugged; standing down")
        clear_failover()
        return 0
    reset_device(dev, f"failover to {src} held {held:.0f}s (USB GPS silent)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
