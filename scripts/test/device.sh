#!/usr/bin/env bash
# Runs a test script against Productium Dev on a USB-connected iPhone and pulls what it saw.
#   scripts/test/device.sh [--wifi] [commands.txt]      # default: scripts/test/smoke.txt
# --wifi (or WIFI=1): reach the phone over the network instead of USB (same Wi-Fi; needs one USB install from this
# computer first, which turns Wi-Fi connections on: see scripts/install.sh).
# Needs: the dev build installed (Impactor; it's a separate app from your real one), the phone unlocked with
# Productium Dev open in the foreground (it reads the script within a second), and uvx (pymobiledevice3).
# Output: test-runs/device-<time>/ (shots/, dumps/, results.txt). The app's log: uvx pymobiledevice3 syslog live [--mobdev2]
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${1:-}" = "--wifi" ] && { WIFI=1; shift; }
script=${1:-scripts/test/smoke.txt}
NET=""; [ -n "${WIFI:-}" ] && NET="--mobdev2"
P="uvx pymobiledevice3"
# Signing tools may add a suffix to the bundle id: find the one installed.
bundle=$($P apps list $NET 2>/dev/null | python3 -c 'import json,sys; ids=[k for k in json.load(sys.stdin) if "productium.dev" in k]; print(ids[0] if ids else "")')
[ -n "$bundle" ] || { echo "Productium Dev isn't installed (install the dev-build release with Impactor)"; exit 1; }
echo "app: $bundle"
$P apps rm $NET "$bundle" Documents/test/results.txt >/dev/null 2>&1 || true
$P apps push $NET "$bundle" "$script" Documents/test/commands.txt
echo "Script sent. Open Productium Dev on the phone and leave it in front until this finishes."
tmp=$(mktemp -d)
for i in $(seq 1 300); do
  if $P apps pull $NET "$bundle" Documents/test/results.txt "$tmp/results.txt" >/dev/null 2>&1 && grep -q '^DONE' "$tmp/results.txt"; then break; fi
  [ $((i % 15)) -eq 0 ] && echo "…waiting ($( (wc -l < "$tmp/results.txt") 2>/dev/null || echo 0) lines done)"
  sleep 2
done
out="test-runs/device-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
$P apps pull $NET "$bundle" Documents/test "$out"
cat "$out"/results.txt 2>/dev/null || find "$out" -name results.txt -exec cat {} \;
echo "→ $out"
