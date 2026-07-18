#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="$(swift build --show-bin-path)/MeetingAI"
LOG_FILE="${TMPDIR:-/tmp}/meetingai-launch-smoke.log"

pkill -x MeetingAI >/dev/null 2>&1 || true
sleep 1

"$BIN" >"$LOG_FILE" 2>&1 &
APP_PID=$!

cleanup() {
  if ps -p "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
sleep 3

if ps -p "$APP_PID" >/dev/null 2>&1; then
  echo "APP_LAUNCH_SMOKE: PASS (pid=$APP_PID)"
  exit 0
fi

echo "APP_LAUNCH_SMOKE: FAIL"
cat "$LOG_FILE" || true
exit 1
