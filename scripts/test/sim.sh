#!/usr/bin/env bash
# Runs a test script against the dev build on a CI iOS simulator and downloads what it saw.
#   scripts/test/sim.sh                        # scripts/test/smoke.txt
#   scripts/test/sim.sh my-script.txt          # a local command file (sent inline)
#   REF=main scripts/test/sim.sh               # another branch (default: dev)
# Output: test-runs/<time>/ (shots/*.png, dumps/*.txt + state.json, results.txt, app.log, crash reports, build.log)
set -euo pipefail
cd "$(dirname "$0")/../.."
REF=${REF:-dev}
args=(-f tz="${TZ_NAME:-America/Toronto}")
if [ -n "${1:-}" ]; then args+=(-f commands="$(cat "$1")"); else args+=(-f file=scripts/test/smoke.txt); fi
before=$(gh run list -w ui-test.yml -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo 0)
gh workflow run ui-test.yml --ref "$REF" "${args[@]}"
for _ in $(seq 1 30); do
  id=$(gh run list -w ui-test.yml -L 1 --json databaseId -q '.[0].databaseId')
  [ "$id" != "$before" ] && break
  sleep 3
done
echo "run $id: $(gh run view "$id" --json url -q .url)"
gh run watch "$id" --interval 20 >/dev/null || true
out="test-runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
gh run download "$id" -n ui-test -D "$out"
echo "== $(gh run view "$id" --json conclusion -q .conclusion)  →  $out"
cat "$out/out/results.txt" 2>/dev/null || echo "(no results.txt: see $out/out/app.log and $out/build.log)"
