#!/usr/bin/env bash
# Runs the box eval against the claude-server. Key: ../../.claude-server.key (git-ignored), URL: CS_URL or the Productium server.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.local/swift/swift-6.2.1-RELEASE-ubuntu24.04/usr/bin:$PATH"
export CS_URL="${CS_URL:-https://productium.duckdns.org}"
export CS_KEY="${CS_KEY:-$(tr -d '[:space:]' < ../../.claude-server.key)}"
swift run -q H "$@" 2>&1 | grep -v -E '^(r[0-9]+ |0x|Images|Backtrace|\*\*\*|Platform|Thread|[0-9]+ \[ra\]|\s*$)'
