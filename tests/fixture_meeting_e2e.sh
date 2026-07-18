#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PID=""
SESSIONS_DIR=""
LOG_FILE="${TMPDIR:-/tmp}/meetingai-fixture-e2e.log"

cleanup() {
  STATUS=$?
  set +e
  if [ "$STATUS" -ne 0 ]; then
    echo "FIXTURE_MEETING_E2E: FAIL unexpected exit status $STATUS"
    if [ -f "$LOG_FILE" ]; then
      echo "--- app log tail ---"
      tail -n 80 "$LOG_FILE"
    fi
    if [ -d "$SESSIONS_DIR" ]; then
      echo "--- session files ---"
      find "$SESSIONS_DIR" -maxdepth 1 -type f -print
    fi
  fi
  if [ -n "$APP_PID" ] && ps -p "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  exit "$STATUS"
}

trap cleanup EXIT

BIN="$(swift build --show-bin-path)/MeetingAI"
SESSIONS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meetingai-fixture-sessions.XXXXXX")"

pkill -x MeetingAI >/dev/null 2>&1 || true
sleep 1

MEETINGAI_UI_FIXTURE=1 MEETINGAI_SESSIONS_DIR="$SESSIONS_DIR" "$BIN" >"$LOG_FILE" 2>&1 &
APP_PID=$!
sleep 3

ax_query() {
  osascript "$@" 2>/dev/null
}

ax_script() {
  osascript 2>/dev/null
}

topbar_button_count() {
  ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return role of every UI element of group 1 of window 1' \
    | tr ',' '\n' \
    | grep -c 'AXButton' || true
}

click_topbar_button() {
  local button_index="$1"
  ax_script >/dev/null <<APPLESCRIPT
tell application "System Events"
  tell process "MeetingAI"
    set buttonElements to {}
    repeat with candidate in UI elements of group 1 of window 1
      try
        if role of candidate is "AXButton" then set end of buttonElements to candidate
      end try
    end repeat
    if (count of buttonElements) < $button_index then error "topbar button index not available"
    click item $button_index of buttonElements
  end tell
end tell
APPLESCRIPT
}

FRONTMOST_READY=0
for _ in $(seq 1 10); do
  if ! ps -p "$APP_PID" >/dev/null 2>&1; then
    echo "FIXTURE_MEETING_E2E: FAIL app process exited before UI became available"
    exit 1
  fi
  if ax_query -e 'tell application "System Events" to tell process "MeetingAI" to set frontmost to true' >/dev/null; then
    FRONTMOST_READY=1
    break
  fi
  sleep 1
done

if [ "$FRONTMOST_READY" -ne 1 ]; then
  echo "FIXTURE_MEETING_E2E: FAIL app process not visible to System Events"
  exit 1
fi

WINDOW_COUNT=0
for _ in $(seq 1 10); do
  WINDOW_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of windows' || echo "0")
  if [ "${WINDOW_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ "${WINDOW_COUNT:-0}" -lt 1 ] 2>/dev/null; then
  echo "FIXTURE_MEETING_E2E: FAIL no accessible windows"
  exit 1
fi

UI_DUMP=$(ax_query \
  -e 'tell application "System Events" to tell process "MeetingAI" to return {role of every UI element of group 1 of window 1, name of every UI element of group 1 of window 1}')
ACTION_BUTTON_COUNT=$(topbar_button_count)

if ! grep -q '会议 AI 助手' <<<"$UI_DUMP"; then
  echo "FIXTURE_MEETING_E2E: FAIL main title not found"
  echo "$UI_DUMP"
  exit 1
fi

if ! grep -q '模式' <<<"$UI_DUMP"; then
  echo "FIXTURE_MEETING_E2E: FAIL mode label not found"
  echo "$UI_DUMP"
  exit 1
fi

if [ "${ACTION_BUTTON_COUNT:-0}" -lt 2 ] 2>/dev/null; then
  echo "FIXTURE_MEETING_E2E: FAIL expected at least two top-level action buttons before meeting start"
  echo "$UI_DUMP"
  echo "buttons=$ACTION_BUTTON_COUNT"
  exit 1
fi

click_topbar_button 1

SETTINGS_SHEET_COUNT=0
for _ in $(seq 1 5); do
  SETTINGS_SHEET_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of sheets of window 1' || echo "0")
  if [ "${SETTINGS_SHEET_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ "${SETTINGS_SHEET_COUNT:-0}" -lt 1 ] 2>/dev/null; then
  echo "FIXTURE_MEETING_E2E: FAIL settings sheet did not appear"
  exit 1
fi

ax_query -e 'tell application "System Events" to key code 53' >/dev/null
sleep 1

SETTINGS_SHEET_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of sheets of window 1' || echo "0")
if [ "${SETTINGS_SHEET_COUNT:-0}" -ne 0 ] 2>/dev/null; then
  echo "FIXTURE_MEETING_E2E: FAIL settings sheet did not close"
  exit 1
fi

click_topbar_button 2

RECORDING_READY=0
for _ in $(seq 1 8); do
  TOPBAR_DUMP=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 1 of window 1')
  RECORDING_BUTTON_COUNT=$(topbar_button_count)
  if grep -q '录音中' <<<"$TOPBAR_DUMP" && [ "${RECORDING_BUTTON_COUNT:-0}" -ge 3 ] 2>/dev/null; then
    RECORDING_READY=1
    break
  fi
  sleep 1
done

if [ "$RECORDING_READY" -ne 1 ]; then
  echo "FIXTURE_MEETING_E2E: FAIL recording state did not appear"
  echo "$TOPBAR_DUMP"
  exit 1
fi

TRANSCRIPT_READY=0
for _ in $(seq 1 12); do
  TRANSCRIPT_DUMP=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 1 of splitter group 1 of group 1 of window 1')
  if grep -qE '3 段|3 条' <<<"$TRANSCRIPT_DUMP"; then
    TRANSCRIPT_READY=1
    break
  fi
  sleep 1
done

if [ "$TRANSCRIPT_READY" -ne 1 ]; then
  echo "FIXTURE_MEETING_E2E: FAIL transcript fixture did not appear"
  echo "$TRANSCRIPT_DUMP"
  exit 1
fi

ax_query -e 'tell application "System Events" to tell process "MeetingAI" to click button 1 of group 2 of splitter group 1 of group 1 of window 1' >/dev/null

ANALYSIS_READY=0
for _ in $(seq 1 12); do
  INSIGHT_DUMP=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 2 of splitter group 1 of group 1 of window 1')
  if grep -q '2 条' <<<"$INSIGHT_DUMP"; then
    ANALYSIS_READY=1
    break
  fi
  sleep 1
done

if [ "$ANALYSIS_READY" -ne 1 ]; then
  echo "FIXTURE_MEETING_E2E: FAIL analysis card count did not increase"
  echo "$INSIGHT_DUMP"
  exit 1
fi

if ! grep -q '后端：' <<<"$INSIGHT_DUMP" || ! grep -q '最近一次：' <<<"$INSIGHT_DUMP"; then
  echo "FIXTURE_MEETING_E2E: FAIL backend status not visible in insight pane"
  echo "$INSIGHT_DUMP"
  exit 1
fi

ax_query -e 'tell application "System Events" to tell process "MeetingAI" to click button 1 of group 2 of splitter group 1 of group 1 of window 1' >/dev/null

RATE_LIMIT_READY=0
for _ in $(seq 1 8); do
  INSIGHT_DUMP=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 2 of splitter group 1 of group 1 of window 1')
  if grep -q '3 条' <<<"$INSIGHT_DUMP"; then
    RATE_LIMIT_READY=1
    break
  fi
  sleep 1
done

if [ "$RATE_LIMIT_READY" -ne 1 ]; then
  echo "FIXTURE_MEETING_E2E: FAIL manual analysis rate-limit feedback did not appear"
  echo "$INSIGHT_DUMP"
  exit 1
fi

click_topbar_button 3
sleep 2

STOPPED_DUMP=$(ax_query \
  -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 1 of window 1')
if grep -q '录音中' <<<"$STOPPED_DUMP"; then
  echo "FIXTURE_MEETING_E2E: FAIL recording state did not clear"
  echo "$STOPPED_DUMP"
  exit 1
fi

TXT_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.txt' | wc -l | tr -d ' ')
MP3_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.mp3' | wc -l | tr -d ' ')
AI_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.ai.md' | wc -l | tr -d ' ')
EVENT_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.events.log' | wc -l | tr -d ' ')
TRANSCRIPT_MD_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.transcript.md' | wc -l | tr -d ' ')
AI_LOG_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.ai.md' | head -n 1)
EVENT_LOG_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.events.log' | head -n 1)
TRANSCRIPT_MD_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.transcript.md' | head -n 1)

if [ "$TXT_COUNT" -lt 1 ] || [ "$MP3_COUNT" -lt 1 ] || [ "$AI_COUNT" -lt 1 ] || [ "$EVENT_COUNT" -lt 1 ] || [ "$TRANSCRIPT_MD_COUNT" -lt 1 ]; then
  echo "FIXTURE_MEETING_E2E: FAIL missing session artifacts txt=$TXT_COUNT mp3=$MP3_COUNT ai=$AI_COUNT events=$EVENT_COUNT transcript_md=$TRANSCRIPT_MD_COUNT"
  find "$SESSIONS_DIR" -maxdepth 1 -type f -print
  exit 1
fi

if ! grep -q '测试洞察' "$AI_LOG_PATH"; then
  echo "FIXTURE_MEETING_E2E: FAIL fixture insight missing from AI log"
  cat "$AI_LOG_PATH"
  exit 1
fi

if ! grep -q '最近一次：' "$AI_LOG_PATH"; then
  echo "FIXTURE_MEETING_E2E: FAIL execution status missing from AI log"
  cat "$AI_LOG_PATH"
  exit 1
fi

if ! grep -q '秒后再试' "$AI_LOG_PATH"; then
  echo "FIXTURE_MEETING_E2E: FAIL manual analysis rate-limit feedback missing from AI log"
  cat "$AI_LOG_PATH"
  exit 1
fi

if ! grep -q '"event":"meeting_started"' "$EVENT_LOG_PATH" || ! grep -q '"event":"meeting_stopped"' "$EVENT_LOG_PATH"; then
  echo "FIXTURE_MEETING_E2E: FAIL meeting lifecycle missing from event log"
  cat "$EVENT_LOG_PATH"
  exit 1
fi

if ! grep -q '"reason":"min_interval"' "$EVENT_LOG_PATH" || ! grep -q '"source":"manual"' "$EVENT_LOG_PATH"; then
  echo "FIXTURE_MEETING_E2E: FAIL manual analysis rate-limit event missing from event log"
  cat "$EVENT_LOG_PATH"
  exit 1
fi

FINAL_EVENT_COUNT=$(grep -c '"event":"transcript_final"' "$EVENT_LOG_PATH" || true)
if [ "$FINAL_EVENT_COUNT" -lt 3 ] || ! grep -q '"fixture":true' "$EVENT_LOG_PATH"; then
  echo "FIXTURE_MEETING_E2E: FAIL transcript/config events missing from event log"
  cat "$EVENT_LOG_PATH"
  exit 1
fi

if ! grep -q '## 逐条记录' "$TRANSCRIPT_MD_PATH" \
  || ! grep -q '最终：3' "$TRANSCRIPT_MD_PATH" \
  || ! grep -q '提问者在描述企业家私董会' "$TRANSCRIPT_MD_PATH" \
  || ! grep -q '讨论聚焦在主持流程' "$TRANSCRIPT_MD_PATH" \
  || ! grep -q '现场希望 AI 只在必要时提醒盲点' "$TRANSCRIPT_MD_PATH"; then
  echo "FIXTURE_MEETING_E2E: FAIL transcript markdown content incomplete"
  cat "$TRANSCRIPT_MD_PATH"
  exit 1
fi

echo "FIXTURE_MEETING_E2E: PASS windows=${WINDOW_COUNT}, txt=${TXT_COUNT}, mp3=${MP3_COUNT}, ai=${AI_COUNT}, events=${EVENT_COUNT}, transcript_md=${TRANSCRIPT_MD_COUNT}"
