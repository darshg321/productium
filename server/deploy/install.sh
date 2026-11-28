#!/usr/bin/env bash
# Installs or updates productium-server on the Pi and the Caddy site for productium.duckdns.org.
# Run from a checkout of the repo: sudo server/deploy/install.sh   (pi-deploy runs it after each push to main)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP=/opt/productium-server
STATE=/var/lib/productium-server

id productium-server &>/dev/null || useradd --system --home-dir "$STATE" --shell /usr/sbin/nologin productium-server
install -d -o productium-server -g productium-server -m 700 "$STATE"

install -d "$APP"
rsync -a --delete --exclude .venv --exclude __pycache__ --exclude tests "$SRC/" "$APP/"
[[ -x "$APP/.venv/bin/python" ]] || python3 -m venv "$APP/.venv"
if ! cmp -s "$APP/requirements.txt" "$APP/.venv/.requirements.txt"; then
  "$APP/.venv/bin/pip" install -q --upgrade pip
  "$APP/.venv/bin/pip" install -q -r "$APP/requirements.txt"
  cp "$APP/requirements.txt" "$APP/.venv/.requirements.txt"
fi
[[ -f /etc/productium-server.env ]] || install -m 644 "$APP/deploy/productium-server.env.example" /etc/productium-server.env

install -m 644 "$APP/deploy/productium-server.service" /etc/systemd/system/productium-server.service
systemctl daemon-reload
systemctl enable productium-server >/dev/null
systemctl restart productium-server

# Caddy: the site lives in its own file; the Caddyfile only imports it.
install -m 644 "$APP/deploy/productium.caddy" /etc/caddy/productium.caddy.new
grep -q '^import /etc/caddy/productium.caddy' /etc/caddy/Caddyfile || echo 'import /etc/caddy/productium.caddy' >> /etc/caddy/Caddyfile
cp -a /etc/caddy/productium.caddy /etc/caddy/productium.caddy.old 2>/dev/null || true
mv /etc/caddy/productium.caddy.new /etc/caddy/productium.caddy
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  systemctl reload caddy
else
  echo "Caddy config invalid; keeping the old site" >&2
  [[ -f /etc/caddy/productium.caddy.old ]] && mv /etc/caddy/productium.caddy.old /etc/caddy/productium.caddy
  exit 1
fi

for _ in $(seq 1 15); do
  curl -fs --max-time 3 http://127.0.0.1:8790/health >/dev/null && { echo "productium-server is up"; exit 0; }
  sleep 1
done
echo "productium-server didn't answer" >&2
exit 1
