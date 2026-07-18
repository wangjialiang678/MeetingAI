#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

RUN_ID="${1:-$(date +%F-%H-%M-%S)}"
LOG_DIR="docs/runtime-logs/$RUN_ID"
SESSIONS_DIR="$HOME/Library/Application Support/MeetingAI/sessions"
BRIDGE_LOG="$HOME/Library/Logs/MeetingAI-bridge.log"

mkdir -p "$LOG_DIR"

LOG_STREAM_PID=""
BRIDGE_TAIL_PID=""
APP_PID=""

cleanup() {
  set +e
  if [ -n "$LOG_STREAM_PID" ] && ps -p "$LOG_STREAM_PID" >/dev/null 2>&1; then
    kill "$LOG_STREAM_PID" >/dev/null 2>&1 || true
    wait "$LOG_STREAM_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$BRIDGE_TAIL_PID" ] && ps -p "$BRIDGE_TAIL_PID" >/dev/null 2>&1; then
    kill "$BRIDGE_TAIL_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_TAIL_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$APP_PID" ] && ps -p "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

cat >"$LOG_DIR/README.md" <<EOF
# MeetingAI Real Rehearsal $RUN_ID

Start: $(date)

Expected manual flow:
1. Start meeting in the app.
2. Speak with the real microphone for 20-30 minutes.
3. Click "立即分析" at least twice in a row once to verify rate-limit feedback.
4. Optionally interrupt network or ASR once to observe reconnect behavior.
5. End meeting in the app, then quit the app or press Ctrl-C in this terminal.

Collected files:
- unified.log: macOS unified logs for subsystem MeetingAI
- bridge.log: tail of ~/Library/Logs/MeetingAI-bridge.log
- app-stdout.log: stdout/stderr from swift run MeetingAI
- manifest.txt: run metadata and latest session file list
EOF

echo "REAL_REHEARSAL: building MeetingAI..."
swift build

echo "REAL_REHEARSAL: logs -> $LOG_DIR"
log stream --style compact --predicate 'subsystem == "MeetingAI"' >"$LOG_DIR/unified.log" 2>&1 &
LOG_STREAM_PID=$!

if [ -f "$BRIDGE_LOG" ]; then
  tail -F "$BRIDGE_LOG" >"$LOG_DIR/bridge.log" 2>&1 &
  BRIDGE_TAIL_PID=$!
else
  echo "Bridge log not found at $BRIDGE_LOG" >"$LOG_DIR/bridge.log"
fi

{
  echo "run_id=$RUN_ID"
  echo "started_at=$(date)"
  echo "log_dir=$LOG_DIR"
  echo "sessions_dir=$SESSIONS_DIR"
  echo "bridge_log=$BRIDGE_LOG"
  echo "dashscope_key_present=$(grep -q '^DASHSCOPE_API_KEY=' "$HOME/.claude/api-vault.env" 2>/dev/null && echo yes || echo no)"
  echo "qwen_key_present=$(grep -q '^QWEN_API_KEY=' "$HOME/.claude/api-vault.env" 2>/dev/null && echo yes || echo no)"
} >"$LOG_DIR/manifest.txt"

echo "REAL_REHEARSAL: launching app. End the meeting in the app before quitting."
swift run MeetingAI >"$LOG_DIR/app-stdout.log" 2>&1 &
APP_PID=$!
wait "$APP_PID" || true
APP_PID=""

{
  echo "ended_at=$(date)"
  echo ""
  echo "latest_session_files:"
  if [ -d "$SESSIONS_DIR" ]; then
    ls -t "$SESSIONS_DIR"/* 2>/dev/null | head -n 12 || true
  else
    echo "sessions directory not found"
  fi
} >>"$LOG_DIR/manifest.txt"

echo "REAL_REHEARSAL: done. Review $LOG_DIR/manifest.txt and the latest session files."
