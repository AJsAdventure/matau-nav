# Matau Nav

A custom sailing navigation system for the catamaran *Matau*. A Raspberry Pi on the boat runs the data layer; a shared SwiftUI codebase builds an **iPhone app** and a **native macOS chart-plotter app**; an Apple Watch acts as a helm-side remote.

## Repository layout

| Path | What |
|------|------|
| `pi/` | Everything that runs on the boat's Raspberry Pi: SignalK-adjacent Python services (state, tracks, history, autopilot daemon + anchor watch, PredictWind proxy) |
| `pi/deploy/` | Deployable bundle: patched services, GPS/clock watchdogs, systemd units, `deploy.sh`, Pi→iCloud backup (`backup-pi.sh`), disaster-recovery guide (`RESTORE.md`) |
| `MatauNav/` | Shared SwiftUI source — builds both the iOS app (`MatauNav` scheme) and the macOS app (`MatauNavMac` scheme, sidebar UI + menu-bar agent) |
| `MatauNavWatch/` | Apple Watch companion (WatchConnectivity remote, no networking of its own) |
| `project.yml` | XcodeGen project definition (`xcodegen generate` after adding files) |

Not in the repo (deliberately): chart GeoTIFFs (licensed), instrument manuals (copyright), Pi backups (credentials), personal track exports.

---

## System overview

```
Boat hardware (NMEA 2000 / SeaTalk)
        │
        ▼
  Raspberry Pi  ─────────────────────────────────────────┐
  ┌─────────────────────────────────────────────────────┐│
  │  SignalK  (port 3000)   ← NMEA TCP input            ││
  │  state_server.py (port 10114)  ← AIS + route + MOB ││
  │  track_server.py (port 10113)  ← GPS track log      ││
  └─────────────────────────────────────────────────────┘│
        │  Wi-Fi / Tailscale (matau.local)               │
        ▼                                                 │
   iPhone app  (MatauNav)                                 │
   ┌──────────────────────────────────────────────────┐  │
   │  SignalKService   ← polls SignalK /api  (500 ms)  │  │
   │  PiStateService   ← polls /state       (2 s)      │  │
   │  TrackService     ← fetches /tracks    (on demand)│  │
   │  AnchorWatchService  ← CoreLocation geofence      │  │
   └────────────────────┬─────────────────────────────┘  │
          WatchConnectivity                               │
        ▼                                                 │
   Apple Watch app  (MatauNavWatch)                       │
   ┌──────────────────────────────────────────────────┐  │
   │  WatchPiClient  ← receives mirrored state        │  │
   │  AutopilotWatchView  ← helm remote               │  │
   └──────────────────────────────────────────────────┘  │
                                                          │
  aisstream.io WebSocket  ──────────────────────────────┘
  (one connection on the Pi for all phones)
```

---

## Raspberry Pi — data layer

The Pi runs three Python servers as systemd services alongside **SignalK**.

### SignalK (`port 3000`)
Open-source marine data hub. Reads NMEA sentences from the instruments (wind, speed, depth, heading, GPS, rudder) via a TCP input and exposes them on a REST API (`/signalk/v1/api/vessels/self/…`). The iPhone polls this endpoint every 500 ms. The Pi also writes autopilot commands here (`steering/autopilot/…`).

### `state_server.py` (`port 10114`)
The tactical state server — the single source of truth for anything that must be shared across all phones or persist across reboots.

Responsibilities:
- **AIS** — one WebSocket to [aisstream.io](https://aisstream.io) per boat; computes **CPA/TCPA** and guard-zone evaluation for every target, then serves pre-processed results to phones via `GET /state`.
- **MOB** (Man Overboard) — persisted to `/var/lib/matau/state.json`; survives Pi reboots.
- **Route management** — stores active route + leg index; auto-advances on waypoint arrival.
- **Autopilot broker** — receives commands from any phone or the watch and issues them to SignalK, then mirrors engagement state back on the next poll so all devices stay in sync.

Key endpoints:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/state` | Full bundle: AIS targets, MOB, route, autopilot |
| `GET` | `/health` | Quick health check |
| `PUT` | `/mob` | Set MOB position |
| `DELETE` | `/mob` | Clear MOB |
| `PUT/DELETE` | `/route` | Set or clear active route |
| `POST` | `/route/advance` | Skip to next waypoint |
| `POST` | `/autopilot/<cmd>` | Autopilot commands |
| `PUT/GET` | `/config` | Tunable thresholds (CPA, guard zone, AIS range) |

### `track_server.py` (`port 10113`)
Polls SignalK every 2 s for position/SOG/COG. Appends fixes to daily gzip-NDJSON files in `/var/lib/matau/tracks/`. The iPhone's Chart tab fetches these on demand to draw the historical GPS trail. Tracks auto-prune after 180 days.

### `matau_daemon.py` (`port 10112`) — in `pi/deploy/`
Autopilot keystroke writer (verified `$STALK` sentences to the SeaTalk bridge via a stable by-id serial path) **plus the boat-side anchor watch**: armed from the app, it monitors position + GPS freshness from `/state`, debounces breaches, latches a dragging alarm through GPS outages, and drives a GPIO buzzer (`MATAU_BUZZER_GPIO`) so the drag alarm sounds on the boat even with every phone asleep. Armed state survives reboots. The state machine is pure and unit-tested (`test_daemon_anchor.py`, also run on the Pi as a deploy gate).

### `matau_history.py` (`port 3001`) — in `pi/deploy/`
Rolling 60-minute instrument ring buffer (5 s samples) so the apps can restore sparkline history after a relaunch. Thin `/state` consumer.

### `predictwind_server.py` (`port 10115`)
Authenticated PredictWind proxy: forecasts, commercial AIS overlay, community boats, sail routing, and an anchor-detection monitor that relocates the forecast location only once the boat has demonstrably settled at a new anchorage. Credentials live only on the Pi (`/etc/matau/`).

### Watchdogs & self-healing — in `pi/deploy/`
- `matau_gps_watchdog.py` (2 min timer) — detects a silently-stalled USB GPS (even hidden behind SignalK source-failover) and revives it with a targeted USB deauthorize/reauthorize; also journals under-voltage flag transitions.
- `matau_gpsclock.py` (5 min timer) — steps the system clock from GPS when NTP is unreachable offshore (staleness logic everywhere depends on an honest clock).
- BCM hardware watchdog — reboots the Pi if the kernel itself hangs.

### `nmea_server.py` (dev tool, `port 10111`)
A simulation server that generates realistic NMEA sentences (heading, wind, speed, depth, GPS) for development without a real boat. SignalK connects to it as a TCP client.

---

## iPhone app — `MatauNav`

Built with **SwiftUI + Swift Observation** (iOS 17+). Five tabs:

| Tab | View | Purpose |
|-----|------|---------|
| Autopilot | `AutopilotView` | Wind rose, heading, engage/adjust autopilot |
| Chart | `ChartView` / `ChartMapView` | OSM tiles + nautical chart overlay + AIS targets + track. **Sail / Anchor mode toggle** (see below) |
| Instruments | `InstrumentsView` | Live instrument gauges with dampening & sparklines |
| Setup | `SetupView` | SignalK host, Pi URLs, ntfy push config |

### Chart — Sail vs Anchor mode

The Chart tab carries a **Sail ⇄ Anchor** segmented toggle (top centre, `settings.chartMode`). The whole chart re-skins around it:

- **Sail mode** — moving-boat display: COG predictor, laylines, active route + ETA, wind ribbon, set & drift, AIS with CPA collision alarms.
- **Anchor mode** — a calm, dedicated anchor watch. Sailing overlays are suppressed; the chart shows the **swing circle** (hard alarm radius) with an **inner warning ring**, the **swing breadcrumb fan**, the wind-sector, and a rode line from anchor to boat. The bottom **anchor console** gives glanceable readouts (distance/bearing to anchor, max swing, depth + trend, wind + shift, scope ratio, GPS source, battery) and a HOLDING / WARNING / DRAGGING status. AIS stays on — another boat dragging toward you matters at anchor.

Anchor mode is independent of whether the hook is down: enter it to *plan* (check **Safe Tonight?**, eyeball the spot) before tapping **Drop Anchor**.

### Key services

**`SignalKService`**
Polls the SignalK REST API at 500 ms. Holds all live instrument values (heading, wind, speed, depth, temperature, rudder, position). Also issues autopilot commands directly to SignalK when needed. GPS outlier rejection rejects position jumps > 0.003° (≈ 330 m) to handle multi-source GPS switching artefacts.

**`PiStateService`**
Polls `state_server.py /state` every 2 s. Owns AIS targets, MOB state, active route, and autopilot mode. The Pi is canonical for these — the phone caches and renders, but all mutations go through PUT/DELETE calls to the Pi so every phone on the boat stays consistent.

**`TrackService`**
Fetches historical GPS tracks from `track_server.py` for display on the chart.

**`AnchorWatchService`**
The on-phone anchor watch, built for reliability (the #1 thing cruisers want — no false alarms, never sleeps through a drag):
- **Phone GPS as a redundant watcher** — while anchored it runs CoreLocation in the background (`UIBackgroundModes: location`), so the alarm keeps working with the screen off and even if the boat Wi-Fi / SignalK feed drops. `bestFix` picks the freshest of the boat feed and the phone's own GPS.
- **Debounced drag detection** — the vessel must stay outside the alarm radius for `anchorAlarmDelay` seconds before the drag alarm fires, rejecting momentary GPS wander. A `CLCircularRegion` geofence is the coarse backstop for when the app is fully killed.
- **Holding-state classification** — HOLDING / WARNING (inside the warn ring) / DRAGGING, plus a plain-language swing diagnosis, max-observed swing, and an auto-learned "tighten to observed swing" suggestion.
- **Loud, mute-bypassing alarm** — drag and GPS-loss alarms drive `AlarmPlayer` (a looping tone on the `.playback` audio session, kept alive by `UIBackgroundModes: audio`) plus a critical-sound notification. Wind/shift/depth/battery alarms are notification-only so a gust doesn't blast a siren.
- **Extra alarms** — GPS-signal-loss (losing the fix *fires* rather than going silent) and low-phone-battery.
- Re-arms itself automatically if the app relaunches while still anchored. Optionally delegates to a Pi-side anchor daemon (`AnchorPiService`) and sends push via **ntfy**.

**`AnchorForecast` + `SafeTonightSheet`**
Turns the PredictWind forecast for the anchor position into a single glanceable **CALM / WATCH / ROUGH** verdict for the hours ahead — peak wind, gusts, and how far the wind direction sweeps overnight — answering "is it going to be a rough night on the hook?" before you commit.

**`PhoneWatchBridge`**
WatchConnectivity phone side. Pushes a state snapshot (heading, SOG, TWS, TWA, rudder, autopilot state) to the watch every second via `applicationContext` (cached) and `sendMessage` (live when watch is foreground). Receives autopilot commands from the watch and forwards them to `PiStateService`.

**`AppSettings`**
`@Observable` store persisted to `UserDefaults`. Holds host config, anchor parameters, instrument display preferences, route/waypoint state, and night-mode flag.

### Night mode
Applied as a `colorMultiply(.red)` modifier on the root view — white text becomes red, dark backgrounds stay dark. Synced to system dark-mode on launch; user can override.

---

## Apple Watch app — `MatauNavWatch`

A thin remote with **zero networking**. All data comes from the phone via WatchConnectivity.

**`WatchSessionBridge`**
WCSession delegate. Receives state pushes from the phone (`applicationContext` + live `sendMessage`). Sends autopilot commands back as `sendMessage` (with reply) when the phone is reachable, or `transferUserInfo` (queued delivery) when it isn't.

**`WatchPiClient`**
`@Observable` state store. Applies incoming state dicts, applies optimistic local updates on commands (so the UI moves instantly before the round-trip completes), and routes commands through `WatchSessionBridge`.

**`AutopilotWatchView`**
The single watch screen. Shows a wind rose (`WindRoseWatch`), SOG + TWS readout, and autopilot engage/adjust buttons. Commands: `compass_auto`, `wind_auto`, `standby`, `±1°`, `±10°`.

---

## Data flow — autopilot command from the watch

```
Watch button tap
  → WatchPiClient.sendCommand("plus10")      optimistic UI update
  → WatchSessionBridge.sendCommand("plus10") WatchConnectivity
  → PhoneWatchBridge.handle(command:)        phone receives
  → PiStateService.sendAutopilotCommand()    POST /autopilot/plus10
  → state_server.py                          issues to SignalK
  → SignalK                                  drives hardware
  → PiStateService polls /state              canonical truth comes back
  → PhoneWatchBridge pushes snapshot         WatchConnectivity
  → WatchPiClient.apply()                    watch UI reconciles
```

---

## Technologies

| Layer | Technology |
|-------|-----------|
| Pi OS | Raspberry Pi OS (Linux) |
| Marine data hub | [SignalK](https://signalk.org) |
| Pi services | Python 3, stdlib only (`http.server`, `threading`, `gzip`) |
| AIS data | [aisstream.io](https://aisstream.io) WebSocket |
| Push notifications | [ntfy](https://ntfy.sh) (self-hosted or cloud) |
| Remote access | [Tailscale](https://tailscale.com) |
| iPhone / Watch | Swift 6, SwiftUI, Swift Observation (`@Observable`) |
| Maps | OpenStreetMap tiles + custom nautical chart TIF overlays |
| Watch connectivity | Apple WatchConnectivity framework |
| Anchor geofencing | CoreLocation `CLCircularRegion` |
| Xcode project | XcodeGen (`project.yml`) |

---

## Port reference

| Port | Service | Protocol |
|------|---------|---------|
| 3000 | SignalK (REST + WebSocket) | HTTP/WS |
| 3001 | Instrument history buffer | HTTP REST |
| 10110 | SignalK NMEA output | TCP |
| 10111 | NMEA demo server (dev only) | TCP (NMEA sentences) |
| 10112 | Autopilot daemon + anchor watch | HTTP REST |
| 10113 | Track server | HTTP REST |
| 10114 | State server | HTTP REST |
| 10115 | PredictWind proxy | HTTP REST |
