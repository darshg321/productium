#!/usr/bin/env bash
# Connects Productium Dev on a USB iPhone to the Productium server: pushes the key from .claude-server.key (git-ignored)
# as a file the app moves into its Keychain and deletes, then checks the connection.
#   scripts/test/connect-server.sh [--wifi]
# Productium Dev must be open.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${1:-}" = "--wifi" ] && { export WIFI=1; shift; }
NET=""; [ -n "${WIFI:-}" ] && NET="--mobdev2"
P="uvx pymobiledevice3"
bundle=$($P apps list $NET 2>/dev/null | python3 -c 'import json,sys; ids=[k for k in json.load(sys.stdin) if "productium.dev" in k]; print(ids[0] if ids else "")')
[ -n "$bundle" ] || { echo "Productium Dev isn't installed"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tr -d '[:space:]' < .claude-server.key > "$tmp/server-key.txt"
$P apps push $NET "$bundle" "$tmp/server-key.txt" Documents/test/server-key.txt >/dev/null
printf 'server\nwait 1\ntab settings\nshot server\n' > "$tmp/cmds.txt"
scripts/test/device.sh "$tmp/cmds.txt"
