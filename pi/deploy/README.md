# Pi stability deploy bundle (2026-07-05)

Staged fixes from the stability audit. Nothing here touches SignalK itself.

## How to deploy

```bash
# 1. Main bundle — run any time:
bash pi/deploy/deploy.sh

# 2. Autopilot daemon + history server — run while the AUTOPILOT IS IN
#    STANDBY (restart resets the daemon's in-memory wind/compass mode guess):
bash pi/deploy/deploy-daemon-history.sh
```

Both scripts: back up every file they replace (`*.bak.<timestamp>`), compile-check
on the Pi **before** restarting anything, restart only matau-* services, then
verify endpoints and print the results.

## What deploy.sh ships

| Change | Why |
|---|---|
| `state_server.py`: `/state` vessel block gains `fixAge` + `posSource` | A dead GPS leaves lat/lon frozen with no way for consumers to tell — fixAge comes from SignalK's own delta timestamp, which freezes with the GPS (root cause of the Jul-3 frozen-forecast incident) |
| `predictwind_server.py`: rejects fixes older than 90 s (anchor monitor) / 10 min (forecast handlers, returns a clear 503); re-auths when PW serves a login page with HTTP 200 | Stops stale GPS silently pinning the forecast to an old anchorage; closes the one stale-session shape the 403/302 handler misses |
| `track_server.py`: corrupt-line / truncated-gzip tolerant reads | One crash mid-write no longer loses a whole day's track |
| `matau_gps_watchdog.py` + systemd timer (2 min) | Auto-revives the PL2303 USB GPS via targeted deauth/reauth when its fix goes stale or a failover to SeaTalk persists ≥4 min (sourcePriorities HIDES the dead source — verified). 15-min cooldown; never touches the FTDI. Also journals `vcgencmd get_throttled` transitions = evidence for the undervoltage fix |
| `matau-wifi-powersave.service` | wlan0 power save OFF, persisted (classic Pi drops-off-network cause; wlan0 is the Pi's only network path) |
| Disables `nmea-demo.service` | Running since May with its SignalK provider disabled — dead weight |

## What deploy-daemon-history.sh ships

| Change | Why |
|---|---|
| `matau_daemon.py`: SeaTalk serial via `/dev/serial/by-id/...FTDI...` | Was hardcoded `/dev/ttyUSB0`; ttyUSB numbering is enumeration-order — a swap would send autopilot keystrokes into the GPS adapter |
| `matau_history.py`: collector thread exception guard | An unexpected payload could kill the thread silently, freezing `/history` while the service looked healthy |

## Rollback

```bash
ssh matau
cp /opt/matau/state_server.py.bak.<STAMP> /opt/matau/state_server.py   # etc.
sudo systemctl restart matau-state matau-predictwind matau-tracks
# watchdog: sudo systemctl disable --now matau-gps-watchdog.timer
```

The app works unchanged against the old servers (`fixAge` is additive), so a
partial rollback is safe.

## Note on repo vs Pi state_server

The repo's `state_server.py` contains an UNDEPLOYED waypoint-autopilot feature.
`pi/deploy/state_server.py` is the LIVE Pi version + the fixAge fix only —
deploying it does NOT ship waypoint mode. Both copies carry the fixAge fix, so
whenever waypoint mode is deliberately shipped, nothing here is lost.
