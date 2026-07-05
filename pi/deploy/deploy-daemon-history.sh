#!/bin/bash
# Matau Pi deploy, part 2: matau-daemon (autopilot) + matau-history.
#
# RUN deploy.sh FIRST: the new matau_history reads the extended /state vessel
# block that deploy.sh ships — deploying this alone gives all-None history.
#
# SEPARATE from deploy.sh on purpose — restarting matau-daemon resets its
# in-memory guess of the autopilot's wind/compass mode. If the autopilot is
# ENGAGED IN WIND MODE when you run this, the next "wind auto" press from the
# app would toggle the ST8002 to compass mode first. Run this while the
# autopilot is in STANDBY (or at anchor).
#
# What it fixes:
#   * matau_daemon.py — SeaTalk serial port referenced by stable by-id path
#     instead of /dev/ttyUSB0 (ttyUSB numbers are NOT stable; a swapped
#     enumeration would steer autopilot keystrokes into the GPS adapter).
#   * matau_history.py — collector thread can no longer die silently and
#     freeze /history while the service looks healthy.
set -euo pipefail
cd "$(dirname "$0")"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "== backups =="
ssh matau "cp /home/pi/matau_daemon.py /home/pi/matau_daemon.py.bak.$STAMP && \
           cp /home/pi/matau_history.py /home/pi/matau_history.py.bak.$STAMP && echo ok"

echo "== copy + compile check =="
scp -q matau_daemon.py matau:/home/pi/matau_daemon.py
scp -q matau_history.py matau:/home/pi/matau_history.py
scp -q test_daemon_anchor.py matau-daemon-dropin.conf matau_daemon.py matau:/tmp/
ssh matau "python3 -m py_compile /home/pi/matau_daemon.py /home/pi/matau_history.py && \
           test -e /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A987ZTP5-if00-port0 && echo 'compile ok, FTDI by-id present'"

echo "== anchor state-machine tests ON THE PI (gate before restart) =="
ssh matau "cd /tmp && python3 test_daemon_anchor.py"

echo "== install daemon drop-in (buzzer env placeholder + After=matau-state) =="
ssh matau "sudo install -d /etc/systemd/system/matau-daemon.service.d && \
           sudo install -m 644 /tmp/matau-daemon-dropin.conf /etc/systemd/system/matau-daemon.service.d/10-matau.conf && \
           sudo systemctl daemon-reload"

echo "== restart =="
ssh matau "sudo systemctl restart matau-daemon matau-history"

echo "== verify =="
ssh matau '
  sleep 2
  systemctl is-active matau-daemon matau-history
  curl -s -m 5 localhost:10112/status | head -c 200; echo
  curl -s -m 5 localhost:3001/history | head -c 120; echo
'
echo "DONE — rollback: restore *.bak.$STAMP and restart both units"
