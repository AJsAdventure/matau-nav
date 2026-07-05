#!/usr/bin/env python3
"""Deterministic unit test for AnchorMonitor.step() — no threads, no network."""
import predictwind_server as P

# Use the real default thresholds
SOG_SAIL = 5.0
SOG_ANCH = 0.1
PI = (37.084, 25.153)          # current Pi Location (near Paros)
SETTLE = P.ANCHOR_SETTLE_S     # 3600
fails = []

def check(desc, got, want):
    ok = got == want
    print(f"  [{'PASS' if ok else 'FAIL'}] {desc}: got {got}, want {want}")
    if not ok:
        fails.append(desc)

# 1) Sailing never relocates
m = P.AnchorMonitor()
check("sailing → no relocate", m.step(0, 36.0, 24.0, SOG_SAIL, PI), None)
check("no GPS → no relocate",  m.step(10, None, None, None, PI), None)

# 2) Anchor at a NEW spot, far from Pi Location → relocate after settle time
m = P.AnchorMonitor()
check("just anchored → wait",     m.step(100,  36.40, 25.40, SOG_ANCH, PI), None)
check("held <1h → wait",          m.step(1000, 36.401, 25.399, SOG_ANCH, PI), None)  # within drift
check("held ≥1h far → RELOCATE",  m.step(100 + SETTLE + 1, 36.40, 25.40, SOG_ANCH, PI), (36.40, 25.40))

# 3) Staying put → no repeat relocate
check("still anchored → no repeat", m.step(100 + SETTLE + 500, 36.40, 25.40, SOG_ANCH, PI), None)

# 4) Sail away, then re-anchor at the SAME spot → still no repeat
check("sail away → reset",          m.step(100 + SETTLE + 600, 36.0, 24.0, SOG_SAIL, PI), None)
m.step(100 + SETTLE + 700, 36.40, 25.40, SOG_ANCH, PI)                                   # settle starts
check("re-anchor same spot → none", m.step(100 + 2*SETTLE + 800, 36.40, 25.40, SOG_ANCH, PI), None)

# 5) Anchor at a DIFFERENT new spot → relocate again
m.step(100 + 2*SETTLE + 900, 36.00, 23.00, SOG_ANCH, PI)                                 # settle starts
check("new anchorage → RELOCATE",
      m.step(100 + 3*SETTLE + 1000, 36.00, 23.00, SOG_ANCH, PI), (36.00, 23.00))

# 6) Anchored where the Pi Location already is → no relocate
m = P.AnchorMonitor()
near = (PI[0] + 0.002, PI[1] + 0.002)   # ~250 m away, within RELOCATE_MIN_MOVE
m.step(0, near[0], near[1], SOG_ANCH, PI)
check("anchored at existing pin → none",
      m.step(SETTLE + 10, near[0], near[1], SOG_ANCH, PI), None)

# 7) Boat keeps drifting >drift each tick → never settles, never relocates
m = P.AnchorMonitor()
relocated = None
for i in range(20):
    r = m.step(i * 300, 36.0 + i * 0.02, 25.0 + i * 0.02, SOG_ANCH, PI)  # 0.02 > drift each tick
    relocated = relocated or r
check("constant drift → never relocate", relocated, None)

print("\nRESULT:", "ALL PASS" if not fails else f"{len(fails)} FAILED: {fails}")
