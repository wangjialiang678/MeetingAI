#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="$(swift build --show-bin-path)/MeetingAI"
LOG_FILE="${TMPDIR:-/tmp}/meetingai-toggle-smoke.log"

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
sleep 6

ax_query() {
  osascript "$@" 2>/dev/null
}

ax_query -e 'tell application "System Events" to tell process "MeetingAI" to set frontmost to true' >/dev/null

WINDOW_COUNT=0
for _ in $(seq 1 10); do
  WINDOW_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of windows' || echo "0")
  if [ "${WINDOW_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ "${WINDOW_COUNT:-0}" -lt 1 ] 2>/dev/null; then
  echo "MEETING_TOGGLE_SMOKE: FAIL no accessible windows"
  exit 1
fi

ax_query -e 'tell application "System Events" to tell process "MeetingAI" to click button 2 of group 1 of window 1' >/dev/null

STARTED=0
for _ in $(seq 1 8); do
  UI_DUMP=$(ax_query \
    -e 'tell application "System Events" to tell process "MeetingAI" to return {name of every UI element of group 1 of window 1, count of buttons of group 1 of window 1}')
  if grep -q '录音中' <<<"$UI_DUMP" && grep -q ', 3$' <<<"$UI_DUMP"; then
    STARTED=1
    break
  fi
  sleep 1
done

if [ "$STARTED" -ne 1 ]; then
  echo "MEETING_TOGGLE_SMOKE: FAIL recording state did not appear"
  echo "$UI_DUMP"
  exit 1
fi

ax_query -e 'tell application "System Events" to tell process "MeetingAI" to click button 3 of group 1 of window 1' >/dev/null

STOPPED=0
for _ in $(seq 1 8); do
  UI_DUMP=$(ax_query \
    -e 'tell application "System Events" to tell process "MeetingAI" to return {name of every UI element of group 1 of window 1, count of buttons of group 1 of window 1}')
  if ! grep -q '录音中' <<<"$UI_DUMP" && grep -q ', 2$' <<<"$UI_DUMP"; then
    STOPPED=1
    break
  fi
  sleep 1
done

if [ "$STOPPED" -ne 1 ]; then
  echo "MEETING_TOGGLE_SMOKE: FAIL recording state did not clear"
  echo "$UI_DUMP"
  exit 1
fi

echo "MEETING_TOGGLE_SMOKE: PASS windows=${WINDOW_COUNT}"
