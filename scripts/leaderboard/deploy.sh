#!/usr/bin/env bash
# Deploys the leaderboard Worker (free plan) and tells the app where it is.
#   1. npx wrangler login        (once, opens the browser)
#   2. ./deploy.sh
# Creates the KV namespace on the first run, deploys, then sets the repo variable LEADERBOARD_URL so CI builds the
# app with this server as the default for new groups.
set -euo pipefail
cd "$(dirname "$0")"
W="npx --yes wrangler@4"
if ! grep -q 'binding = "BOARD"' wrangler.toml; then
  # Non-interactive (CI=1, no stdin) so wrangler doesn't stop to ask about editing the config itself.
  out=$(CI=1 $W kv namespace create BOARD </dev/null 2>&1) || { echo "$out"; exit 1; }
  id=$(echo "$out" | grep -oE '[0-9a-f]{32}' | head -1)
  [ -n "$id" ] || { echo "$out"; echo "couldn't read the KV namespace id"; exit 1; }
  printf '\n[[kv_namespaces]]\nbinding = "BOARD"\nid = "%s"\n' "$id" >> wrangler.toml
  echo "KV namespace $id"
fi
node test.mjs
out=$($W deploy 2>&1 | tee /dev/stderr)
url=$(echo "$out" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1)
[ -n "$url" ] || { echo "deployed, but no workers.dev URL found in the output"; exit 1; }
echo "Leaderboard: $url"
if command -v gh >/dev/null; then gh variable set LEADERBOARD_URL --body "$url" && echo "repo variable LEADERBOARD_URL set"; fi
