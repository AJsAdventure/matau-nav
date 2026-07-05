# Rebuilding the boat Pi from a dead SD card

Everything needed lives in `pi-backup/pi-config-<latest>.tgz` (in this iCloud
folder, written by `pi/deploy/backup-pi.sh`). Total rebuild time ≈ 1 hour.

## 1. Base OS

1. Flash **Raspberry Pi OS Lite (64-bit not required — 3B+ runs 32-bit fine)**
   with Raspberry Pi Imager. In the imager settings: hostname `Matau`,
   user `pi`, enable SSH (paste the public key from `~/.ssh/matau_key.pub`),
   WiFi SSID `Matau` + password (or restore `/etc/wpa_supplicant` from the tar).
2. Boot, then from the Mac: `ssh matau` should work (the ssh alias in
   `~/.ssh/config` points at matau.local with `~/.ssh/matau_key`, user `pi`).

## 2. Restore the backup

```bash
scp pi-backup/pi-config-<latest>.tgz matau:/tmp/
ssh matau
sudo tar xzf /tmp/pi-config-*.tgz -C /    # restores /opt/matau, /home/pi/*.py,
                                          # /etc/matau, .signalk, units, boot cfg
sudo chown -R pi:pi /opt/matau /home/pi
```

## 3. Software

```bash
sudo apt-get update
sudo apt-get install -y git python3-pip nodejs npm   # versions: see manifest in tar
sudo pip3 install requests websocket-client           # state/predictwind deps
sudo npm install -g signalk-server                    # SignalK (global install)
# SignalK plugins restore automatically from ~/.signalk on first start
```

Check `tmp/matau-manifest/` inside the tar for the exact package lists
(`dpkg-selections.txt`, `pip3-freeze.txt`, `npm-global.txt`).

## 4. Services

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now signalk matau-daemon matau-state matau-tracks \
     matau-history matau-predictwind matau-gps-watchdog.timer \
     matau-gpsclock.timer matau-wifi-powersave
```

## 5. Verify

```bash
vcgencmd get_throttled                  # power OK? want 0x0
curl -s localhost:3000/signalk/v1/api/vessels/self/navigation/position
curl -s localhost:10114/state | head -c 400   # expect vessel block + fixAge
curl -s localhost:10112/status                # daemon
curl -s localhost:10115/health                # predictwind (auth from /etc/matau)
```

Serial adapters are referenced **by-id** everywhere (survives re-flash):
- SeaTalk: `usb-FTDI_FT232R_USB_UART_A987ZTP5-if00-port0`
- USB GPS: `usb-Prolific_Technology_Inc._USB-Serial_Controller_BCA_f146B11-if00-port0`

## Notes

- **Tailscale** is NOT in the backup (its keys are machine identity):
  `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`.
- **Track history** is only in `pi-data-*.tgz` snapshots (made with
  `backup-pi.sh --data`) — restore with the same `tar xzf ... -C /`.
- GPS failover config lives in `~/.signalk/settings.json` (`sourcePriorities`:
  USB-GPS.GN → SeaTalk-NMEA.ST/II, 30 s) — restored with the tar.
