#!/usr/bin/env python3
"""Unit tests for matau_daemon's AnchorWatch state machine (pure, no I/O)."""

import importlib.util
import os
import pathlib
import sys

os.environ["MATAU_BUZZER_GPIO"] = ""   # never touch GPIO in tests

spec = importlib.util.spec_from_file_location(
    "md", pathlib.Path(__file__).parent / "matau_daemon.py")
md = importlib.util.module_from_spec(spec)
spec.loader.exec_module(md)

PASS = 0
FAIL = 0


def check(name, got, want):
    global PASS, FAIL
    ok = got == want
    PASS += ok
    FAIL += not ok
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: got {got}, want {want}")


# ~9e-4 deg lat ≈ 100 m
LAT, LON = 37.0, 25.0
OUT_100M = LAT + 0.0009

w = md.AnchorWatch()

# 1. unarmed: step is a no-op
w.step(0, LAT, LON, 1.0)
check("unarmed no alarms", w.alarms, [])

# 2. armed, inside radius: no alarm
w.arm(LAT, LON, radius_m=50, delay_s=30, now=0)
w.step(5, LAT, LON, 1.0)
check("inside radius", w.alarms, [])

# 3. breach shorter than delay: no alarm yet
w.step(10, OUT_100M, LON, 1.0)
check("breach not confirmed yet", w.alarms, [])

# 4. breach persists past delay: dragging
w.step(45, OUT_100M, LON, 1.0)
check("dragging after delay", w.alarms, ["dragging"])

# 5. back inside: dragging clears
w.step(50, LAT, LON, 1.0)
check("dragging clears inside", w.alarms, [])

# 6. GPS bounce out/in resets debounce (no false alarm)
w.step(60, OUT_100M, LON, 1.0)
w.step(65, LAT, LON, 1.0)
w.step(70, OUT_100M, LON, 1.0)
w.step(95, OUT_100M, LON, 1.0)   # only 25 s since 70 — under the 30 s delay
check("bounce resets debounce", w.alarms, [])

# 7. stale fix: not usable, gps_loss only after GPS_LOSS_AFTER_S
w.arm(LAT, LON, 50, 30, now=100)
w.step(100, LAT, LON, 300.0)       # stale fix
check("stale fix no instant alarm", w.alarms, [])
w.step(100 + md.GPS_LOSS_AFTER_S + 1, LAT, LON, 300.0)
check("gps_loss after grace", w.alarms, ["gps_loss"])

# 8. fix returns: gps_loss clears
w.step(400, LAT, LON, 1.0)
check("gps_loss clears on fix", w.alarms, [])

# 9. dragging latches through a GPS outage
w.step(410, OUT_100M, LON, 1.0)
w.step(445, OUT_100M, LON, 1.0)
check("dragging again", w.alarms, ["dragging"])
w.step(450, None, None, None)                                  # feed dies
w.step(450 + md.GPS_LOSS_AFTER_S + 1, None, None, None)
check("drag latched + gps_loss", sorted(w.alarms), ["dragging", "gps_loss"])

# 10. (0,0) treated as no fix
w.arm(LAT, LON, 50, 30, now=1000)
w.step(1000, 0.0, 0.0, 1.0)
w.step(1000 + md.GPS_LOSS_AFTER_S + 1, 0.0, 0.0, 1.0)
check("0,0 is no fix", w.alarms, ["gps_loss"])

# 11. disarm clears everything
w.disarm()
check("disarm clears", (w.armed, w.alarms), (False, []))

# 12. arm resets stale no-fix timer (no instant gps_loss on re-arm)
w.arm(LAT, LON, 50, 30, now=2000)
w.step(2001, None, None, None)
check("re-arm grace", w.alarms, [])

print(f"\nRESULT: {'ALL PASS' if FAIL == 0 else f'{FAIL} FAILED'} ({PASS} passed)")
sys.exit(1 if FAIL else 0)
