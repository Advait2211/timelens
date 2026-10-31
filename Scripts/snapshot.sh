#!/bin/bash
# Debug: renders one dashboard page off screen (demo data) and saves a PNG.
# Usage: Scripts/snapshot.sh <section> <out.png> [height] [route]   (SNAPSHOT_LIGHT=1 for light mode)
#        Scripts/snapshot.sh window <out.png> [section]          the real dashboard window
set -euo pipefail
cd "$(dirname "$0")/.."
SECTION=$1; OUT=$2; HEIGHT=${3:-3000}; ROUTE=${4:-}
ID_FILE="$(mktemp -t timelens-snapshot)"
rm -f "$ID_FILE"
# Only stop an earlier demo copy, never the real, tracking one.
pkill -f "TimeLens --demo-data" 2>/dev/null || true
sleep 0.5
build/TimeLens.app/Contents/MacOS/TimeLens --demo-data --snapshot "$SECTION" "$ID_FILE" "$HEIGHT" $ROUTE >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 40); do [ -s "$ID_FILE" ] && break; sleep 0.25; done
screencapture -x -o -l "$(cat "$ID_FILE")" "$OUT"
kill $PID 2>/dev/null || true
rm -f "$ID_FILE"
echo "$OUT"
