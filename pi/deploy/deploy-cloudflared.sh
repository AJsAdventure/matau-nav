#!/usr/bin/env bash
# Install / update the Cloudflare Tunnel connector on the Pi.
#
# The tunnel publishes every boat service as https://matau-<port>.<domain>
# (the app's "Remote bridge" Setup fields), protected by a Cloudflare Access
# service token. Ingress rules, DNS records and Access policy live in the
# Cloudflare account (remotely-managed tunnel) — the Pi only runs the
# connector, so this script needs the tunnel token exactly once.
#
# Usage: ./deploy-cloudflared.sh <TUNNEL_TOKEN>     # first install / re-register
#        ./deploy-cloudflared.sh                    # update the binary only
#
# Uses the `matau` ssh alias, like the other deploy scripts.
set -euo pipefail

TOKEN="${1:-}"

echo "== install / refresh cloudflared (arm64 deb) =="
ssh matau "curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -o /tmp/cloudflared.deb \
  && sudo dpkg -i /tmp/cloudflared.deb >/dev/null \
  && cloudflared --version"

if [ -n "$TOKEN" ]; then
  echo "== register systemd service with tunnel token =="
  ssh matau "sudo cloudflared service uninstall 2>/dev/null || true; \
             sudo cloudflared service install '$TOKEN'"
fi

# The stock unit's TimeoutStartSec=15 is too tight for edge registration
# over Starlink — the service flaps into 'failed' before cloudflared
# signals readiness (observed live 2026-07-12).
echo "== relax start timeout =="
ssh matau "sudo mkdir -p /etc/systemd/system/cloudflared.service.d && \
           printf '[Service]\nTimeoutStartSec=120\n' | sudo tee /etc/systemd/system/cloudflared.service.d/10-matau.conf >/dev/null && \
           sudo systemctl daemon-reload && sudo systemctl restart cloudflared"

echo "== status =="
ssh matau "systemctl is-active cloudflared && journalctl -u cloudflared -n 5 --no-pager || true"
