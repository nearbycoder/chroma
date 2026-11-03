#!/usr/bin/env bash
# Captures the picker or a window, driven by a harness script, without covering the screen (Debug builds only).
#   ./Scripts/shoot.sh <backdrop.png> <output.png> "move 900 400; zoom 13"   (or "window:library", no backdrop needed: -)
set -euo pipefail
cd "$(dirname "$0")/.."
BACKDROP="$1" OUT="$2" SCRIPT="$3"
APP="build/DerivedData/Build/Products/Debug/Chroma.app/Contents/MacOS/Chroma"
LOG="$(mktemp)"
if [[ "$BACKDROP" == "-" ]]; then
  CHROMA_HARNESS="$SCRIPT" "$APP" >"$LOG" 2>&1 &
else
  CHROMA_DEMO_IMAGE="$BACKDROP" CHROMA_HARNESS="$SCRIPT" "$APP" >"$LOG" 2>&1 &
fi
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -f "$LOG"' EXIT
for _ in $(seq 1 100); do
  grep -q HARNESS_WINDOW "$LOG" && break
  sleep 0.1
done
WINDOW="$(awk '/HARNESS_WINDOW/ {print $2; exit}' "$LOG")"
[[ -n "$WINDOW" ]] || { cat "$LOG"; exit 1; }
sleep "${SETTLE:-1.2}" # let SwiftUI animations and glass settle
screencapture -x -o -l "$WINDOW" "$OUT"
echo "✓ $OUT"
