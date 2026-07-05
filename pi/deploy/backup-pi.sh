#!/bin/bash
# Back up everything needed to rebuild the boat Pi from a blank SD card.
# Run FROM THE MAC: bash pi-deploy/backup-pi.sh   (add --data for track history)
#
# Snapshots land in pi-backup/ INSIDE this iCloud folder, so they sync to
# iCloud automatically — an SD-card death never means starting from zero.
# Keeps the 6 newest config snapshots. See RESTORE.md for the rebuild recipe.
set -euo pipefail
cd "$(dirname "$0")/../.."
DEST="pi-backup"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DEST"

echo "== capturing system manifests on the Pi =="
ssh matau 'sudo sh -c "
  mkdir -p /tmp/matau-manifest
  dpkg --get-selections            > /tmp/matau-manifest/dpkg-selections.txt
  pip3 list --format=freeze        > /tmp/matau-manifest/pip3-freeze.txt 2>/dev/null || true
  npm ls -g --depth=0              > /tmp/matau-manifest/npm-global.txt  2>/dev/null || true
  systemctl list-unit-files --state=enabled --no-pager > /tmp/matau-manifest/enabled-units.txt
  uname -a                         > /tmp/matau-manifest/uname.txt
  cat /proc/device-tree/model      > /tmp/matau-manifest/pi-model.txt 2>/dev/null || true
  ip addr                          > /tmp/matau-manifest/ip-addr.txt
"'

echo "== streaming config+code snapshot =="
ssh matau 'sudo tar czf - \
    --exclude=node_modules --exclude=__pycache__ --exclude="*.bak.*" \
    /opt/matau \
    /home/pi/*.py \
    /home/pi/.signalk \
    /etc/matau \
    /etc/systemd/system/matau-* \
    /etc/systemd/system/signalk.service \
    /etc/systemd/system.conf.d \
    /boot/config.txt /boot/cmdline.txt \
    /etc/wpa_supplicant \
    /etc/hostname /etc/hosts /etc/fstab \
    /tmp/matau-manifest \
    2>/dev/null' > "$DEST/pi-config-$STAMP.tgz"
ls -lh "$DEST/pi-config-$STAMP.tgz"

if [[ "${1:-}" == "--data" ]]; then
  echo "== streaming track/data snapshot (can be large) =="
  ssh matau 'sudo tar czf - /var/lib/matau 2>/dev/null' > "$DEST/pi-data-$STAMP.tgz"
  ls -lh "$DEST/pi-data-$STAMP.tgz"
fi

echo "== pruning old config snapshots (keep 6) =="
ls -t "$DEST"/pi-config-*.tgz 2>/dev/null | tail -n +7 | xargs -I{} rm -v {} || true

echo "DONE — snapshot synced to iCloud with this folder. Restore guide: pi-deploy/RESTORE.md"
