#!/usr/bin/env python3
"""Matau GPS clock watchdog — keeps the Pi's clock honest without internet.

Offshore there is no NTP, and every staleness decision on this boat
(vessel.fixAge, track timestamps, PredictWind anchor monitor) compares GPS
timestamps against the system clock. A drifting Pi clock slowly poisons all
of it. GPS time is on the bus already — navigation.datetime in SignalK, fed
by the USB GPS (first in sourcePriorities, per the owner's preference).

Runs from a systemd timer every 5 min:
  * NTP synchronised?           -> do nothing (NTP wins when shore is around)
  * GPS datetime fresh (<60 s)? -> if |GPS - system| > 5 s, step the clock
  * otherwise                   -> do nothing (never set the clock from a
                                   stale value — that would move time BACKWARD)

Freshness is judged by SignalK's receive-stamp vs system-now: both use the
same (possibly wrong) system clock, so their difference is a true elapsed
time regardless of absolute error.
"""

import json
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

SIGNALK_DT_URL = "http://127.0.0.1:3000/signalk/v1/api/vessels/self/navigation/datetime"
MAX_RECEIPT_AGE_S = 60.0
STEP_THRESHOLD_S = 5.0


def log(msg: str) -> None:
    print(f"matau-gpsclock: {msg}", flush=True)


def ntp_synchronised() -> bool:
    try:
        out = subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return out == "yes"
    except Exception:
        return False


def main() -> int:
    if ntp_synchronised():
        return 0

    try:
        with urllib.request.urlopen(SIGNALK_DT_URL, timeout=5) as r:
            p = json.loads(r.read().decode())
    except Exception:
        return 0   # SignalK down — nothing safe to do

    value, stamped = p.get("value"), p.get("timestamp")
    if not (isinstance(value, str) and isinstance(stamped, str)):
        return 0
    try:
        gps_time = datetime.fromisoformat(value.replace("Z", "+00:00"))
        stamped_at = datetime.fromisoformat(stamped.replace("Z", "+00:00"))
    except ValueError:
        return 0

    now = datetime.now(timezone.utc)
    receipt_age = (now - stamped_at).total_seconds()
    if not (0 <= receipt_age < MAX_RECEIPT_AGE_S):
        return 0   # stale GPS datetime — setting the clock from it moves time backward

    target = gps_time.timestamp() + receipt_age   # compensate elapsed since receipt
    offset = target - now.timestamp()
    if abs(offset) <= STEP_THRESHOLD_S:
        return 0

    try:
        subprocess.run(["date", "-u", "-s", f"@{target:.3f}"],
                       check=True, capture_output=True, timeout=5)
        log(f"no NTP — stepped clock by {offset:+.1f}s from GPS "
            f"(source {p.get('$source')})")
    except Exception as e:
        log(f"clock step FAILED: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
