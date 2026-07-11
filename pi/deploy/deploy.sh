#!/bin/bash
# Matau Pi stability deploy — 2026-07-05
# Run from the Mac:  bash pi-deploy/deploy.sh
# Uses the `matau` ssh alias. Everything is backed up first; SignalK is NOT touched.
#
# What this deploys:
#   1. state_server.py     → /opt/matau/          (adds vessel.fixAge + posSource to /state)
#   2. predictwind_server.py → /opt/matau/ + /home/pi/  (stale-GPS guards: anchor monitor
#                              ignores fixes >90s old; handlers 503 on fixes >10min old)
#   3. GPS watchdog        → systemd timer, every 2 min: if the USB GPS's own SignalK
#                              timestamp is >5min old while the PL2303 is enumerated,
#                              deauth/reauth ONLY that device (proven recovery, 15min cooldown)
#   4. wlan0 power save OFF now + persisted via systemd unit
#   5. Disable the unused nmea-demo.service (its SignalK provider is disabled)
set -euo pipefail
cd "$(dirname "$0")"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "== 1/6 backups =="
# /opt/matau is root-owned; pi can overwrite existing files but not create
# new ones (backups, .git). Own the dir once — files are pi-owned already.
ssh matau "sudo chown pi:pi /opt/matau"
ssh matau "cp /opt/matau/state_server.py /opt/matau/state_server.py.bak.$STAMP && \
           cp /opt/matau/predictwind_server.py /opt/matau/predictwind_server.py.bak.$STAMP && \
           cp /home/pi/predictwind_server.py /home/pi/predictwind_server.py.bak.$STAMP && \
           cp /opt/matau/track_server.py /opt/matau/track_server.py.bak.$STAMP && echo ok"

echo "== 2/6 copy files =="
scp -q state_server.py matau:/opt/matau/state_server.py
scp -q predictwind_server.py matau:/opt/matau/predictwind_server.py
scp -q predictwind_server.py matau:/home/pi/predictwind_server.py
scp -q track_server.py matau:/opt/matau/track_server.py
scp -q matau_gps_watchdog.py matau_gpsclock.py matau:/tmp/
scp -q matau-gps-watchdog.service matau-gps-watchdog.timer matau-wifi-powersave.service \
       matau-gpsclock.service matau-gpsclock.timer 10-matau-watchdog.conf matau:/tmp/

echo "== 3/6 compile check on Pi (aborts before any restart if broken) =="
ssh matau "PYTHONPYCACHEPREFIX=/tmp/pycache python3 -m py_compile /opt/matau/state_server.py /opt/matau/predictwind_server.py /opt/matau/track_server.py /tmp/matau_gps_watchdog.py /tmp/matau_gpsclock.py && echo compile-ok"

echo "== 4/6 install watchdog + wifi units =="
ssh matau "sudo install -m 755 /tmp/matau_gps_watchdog.py /tmp/matau_gpsclock.py /usr/local/bin/ && \
           sudo install -m 644 /tmp/matau-gps-watchdog.service /tmp/matau-gps-watchdog.timer /tmp/matau-wifi-powersave.service /tmp/matau-gpsclock.service /tmp/matau-gpsclock.timer /etc/systemd/system/ && \
           sudo install -d /etc/systemd/system.conf.d && \
           sudo install -m 644 /tmp/10-matau-watchdog.conf /etc/systemd/system.conf.d/ && \
           sudo systemctl daemon-reload && sudo systemctl daemon-reexec && \
           sudo systemctl enable --now matau-gps-watchdog.timer matau-gpsclock.timer matau-wifi-powersave.service"

echo "== 5/6 restart matau services (NOT signalk) =="
ssh matau "sudo systemctl restart matau-state matau-tracks && sleep 3 && sudo systemctl restart matau-predictwind && \
           sudo systemctl disable --now nmea-demo.service 2>/dev/null; true"

echo "== 6/6 verify =="
ssh matau '
  set -e
  sleep 3
  echo "--- /state vessel block (expect fixAge + posSource):"
  curl -s -m 5 localhost:10114/state | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)[\"vessel\"], indent=2))"
  echo "--- PW health:"
  curl -s -m 5 localhost:10115/health
  echo
  echo "--- services:"
  systemctl is-active matau-state matau-predictwind signalk
  echo "--- watchdog timer:"
  systemctl list-timers matau-gps-watchdog.timer --no-pager | head -3
  echo "--- watchdog dry run (should exit 0 quietly with a live GPS):"
  sudo python3 /usr/local/bin/matau_gps_watchdog.py; echo "exit=$?"
  echo "--- wlan0 power save (expect: off):"
  /sbin/iw dev wlan0 get power_save
'
echo "== 7/7 git snapshot on the Pi =="
ssh matau '
  command -v git >/dev/null || sudo apt-get install -y git 2>/dev/null || { echo "git unavailable (no internet?) — skipping"; exit 0; }
  cd /opt/matau
  if [ ! -d .git ]; then
    git init -q && git config user.email pi@matau.local && git config user.name "Matau Pi"
    printf "__pycache__/\n*.bak.*\n*.pyc\n" > .gitignore
  fi
  git add -A && git commit -q -m "deploy '"$STAMP"'" || echo "nothing to commit"
  git log --oneline | head -3
'
echo "DONE — rollback: restore *.bak.$STAMP files (or git revert on the Pi) and restart matau-state matau-predictwind"
