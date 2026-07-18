#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="$(swift build --show-bin-path)/MeetingAI"
LOG_FILE="${TMPDIR:-/tmp}/meetingai-gui-smoke.log"

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
sleep 2

ax_query() {
  osascript "$@" 2>/dev/null
}

WINDOW_COUNT=0
for _ in $(seq 1 20); do
  ax_query -e 'tell application "System Events" to tell process "MeetingAI" to set frontmost to true' >/dev/null || true
  WINDOW_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of windows' || echo "0")
  if [ "${WINDOW_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ "${WINDOW_COUNT:-0}" -lt 1 ] 2>/dev/null; then
  echo "GUI_SMOKE: FAIL no accessible windows"
  exit 1
fi

sleep 1

UI_DUMP=$(ax_query \
  -e 'tell application "System Events" to tell process "MeetingAI" to return {role of every UI element of group 1 of window 1, name of every UI element of group 1 of window 1}')

if ! grep -q '会议 AI 助手' <<<"$UI_DUMP"; then
  echo "GUI_SMOKE: FAIL main title not found"
  echo "$UI_DUMP"
  exit 1
fi

if ! grep -q '模式' <<<"$UI_DUMP"; then
  echo "GUI_SMOKE: FAIL mode label not found"
  echo "$UI_DUMP"
  exit 1
fi

ACTION_BUTTON_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of buttons of group 1 of window 1')
if [ "${ACTION_BUTTON_COUNT:-0}" -lt 2 ] 2>/dev/null; then
  echo "GUI_SMOKE: FAIL expected at least two top-level action buttons"
  exit 1
fi

ax_query -e 'tell application "System Events" to tell process "MeetingAI" to click button 1 of group 1 of window 1' >/dev/null

SETTINGS_SHEET_COUNT=0
for _ in $(seq 1 5); do
  SETTINGS_SHEET_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of sheets of window 1' || echo "0")
  if [ "${SETTINGS_SHEET_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ "${SETTINGS_SHEET_COUNT:-0}" -lt 1 ] 2>/dev/null; then
  echo "GUI_SMOKE: FAIL settings sheet did not appear"
  exit 1
fi

echo "GUI_SMOKE: PASS windows=${WINDOW_COUNT}, actionButtons=${ACTION_BUTTON_COUNT}, settingsSheet=${SETTINGS_SHEET_COUNT}"
