#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/real-meeting-smoke-funasr.sh
source scripts/lib/real-meeting-smoke-funasr.sh

DURATION_SECONDS="${1:-90}"
ANALYSIS_WAIT_SECONDS="${2:-75}"
ANALYSIS_BACKEND="${MEETINGAI_ANALYSIS_BACKEND:-http}"
DIARIZATION_CHUNK_SECONDS="${MEETINGAI_SMOKE_DIARIZATION_CHUNK_SECONDS:-2}"
REQUIRE_FUNASR_DIARIZATION="${MEETINGAI_REQUIRE_FUNASR_DIARIZATION:-0}"
FUNASR_WAIT_SECONDS="${MEETINGAI_FUNASR_WAIT_SECONDS:-240}"
RUN_ID="real-smoke-$(date +%F-%H-%M-%S)"
LOG_DIR="docs/runtime-logs/$RUN_ID"
SESSIONS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meetingai-real-smoke-sessions.XXXXXX")"
APP_LOG="$LOG_DIR/app-stdout.log"
BRIDGE_LOG="$HOME/Library/Logs/MeetingAI-bridge.log"

APP_PID=""
LOG_STREAM_PID=""
BRIDGE_TAIL_PID=""

cleanup() {
  STATUS=$?
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
  exit "$STATUS"
}

trap cleanup EXIT

mkdir -p "$LOG_DIR"

secret_present() {
  NAME="$1"
  if [ -n "${!NAME:-}" ]; then
    return 0
  fi
  grep -q "^${NAME}=" "$HOME/.claude/api-vault.env" 2>/dev/null
}

{
  echo "run_id=$RUN_ID"
  echo "started_at=$(date)"
  echo "duration_seconds=$DURATION_SECONDS"
  echo "analysis_wait_seconds=$ANALYSIS_WAIT_SECONDS"
  echo "analysis_backend=$ANALYSIS_BACKEND"
  echo "diarization_chunk_seconds=$DIARIZATION_CHUNK_SECONDS"
  echo "require_funasr_diarization=$REQUIRE_FUNASR_DIARIZATION"
  echo "funasr_wait_seconds=$FUNASR_WAIT_SECONDS"
  echo "log_dir=$LOG_DIR"
  echo "sessions_dir=$SESSIONS_DIR"
  echo "dashscope_key_present=$(secret_present DASHSCOPE_API_KEY && echo yes || echo no)"
  echo "qwen_key_present=$(secret_present QWEN_API_KEY && echo yes || echo no)"
  echo "oss_access_key_present=$(secret_present OSS_ACCESS_KEY_ID && echo yes || echo no)"
  echo "oss_secret_present=$(secret_present OSS_ACCESS_KEY_SECRET && echo yes || echo no)"
  echo "oss_bucket_env_present=$([ -n "${MEETINGAI_DIARIZATION_UPLOAD_BUCKET:-}" ] && echo yes || echo no)"
} >"$LOG_DIR/manifest.txt"

if ! secret_present DASHSCOPE_API_KEY; then
  echo "REAL_MEETING_SMOKE: BLOCKED missing DASHSCOPE_API_KEY"
  exit 2
fi

if ! secret_present QWEN_API_KEY; then
  echo "REAL_MEETING_SMOKE: BLOCKED missing QWEN_API_KEY"
  exit 2
fi

if [ "$REQUIRE_FUNASR_DIARIZATION" = "1" ]; then
  if ! secret_present OSS_ACCESS_KEY_ID; then
    echo "REAL_MEETING_SMOKE: BLOCKED missing OSS_ACCESS_KEY_ID for Fun-ASR smoke"
    exit 2
  fi
  if ! secret_present OSS_ACCESS_KEY_SECRET; then
    echo "REAL_MEETING_SMOKE: BLOCKED missing OSS_ACCESS_KEY_SECRET for Fun-ASR smoke"
    exit 2
  fi
fi

if ! osascript -e 'tell application "System Events" to return UI elements enabled' >/dev/null 2>&1; then
  echo "REAL_MEETING_SMOKE: BLOCKED Accessibility automation unavailable"
  exit 2
fi

swift build
BIN="$(swift build --show-bin-path)/MeetingAI"

log stream --style compact --predicate 'subsystem == "MeetingAI"' >"$LOG_DIR/unified.log" 2>&1 &
LOG_STREAM_PID=$!

if [ -f "$BRIDGE_LOG" ]; then
  tail -F "$BRIDGE_LOG" >"$LOG_DIR/bridge.log" 2>&1 &
  BRIDGE_TAIL_PID=$!
else
  echo "Bridge log not found at $BRIDGE_LOG" >"$LOG_DIR/bridge.log"
fi

pkill -x MeetingAI >/dev/null 2>&1 || true
sleep 1

if [ "$REQUIRE_FUNASR_DIARIZATION" = "1" ]; then
  MEETINGAI_ANALYSIS_BACKEND="$ANALYSIS_BACKEND" \
  MEETINGAI_DIARIZATION_CHUNK_SECONDS="$DIARIZATION_CHUNK_SECONDS" \
  MEETINGAI_DIARIZATION_PROVIDER="dashscopeFunASR" \
  MEETINGAI_DIARIZATION_UPLOAD_STORAGE="oss" \
  MEETINGAI_SESSIONS_DIR="$SESSIONS_DIR" \
  "$BIN" >"$APP_LOG" 2>&1 &
else
  MEETINGAI_ANALYSIS_BACKEND="$ANALYSIS_BACKEND" MEETINGAI_DIARIZATION_CHUNK_SECONDS="$DIARIZATION_CHUNK_SECONDS" MEETINGAI_SESSIONS_DIR="$SESSIONS_DIR" "$BIN" >"$APP_LOG" 2>&1 &
fi
APP_PID=$!
sleep 3

ax_query() {
  osascript "$@" 2>/dev/null
}

focus_app() {
  ax_query -e 'tell application "System Events" to tell process "MeetingAI" to set frontmost to true' >/dev/null
}

click_top_button() {
  NAME="$1"
  FALLBACK_INDEX="$2"
  focus_app || true
  ax_query -e "tell application \"System Events\" to tell process \"MeetingAI\" to click (first button of group 1 of window 1 whose name is \"$NAME\")" >/dev/null \
    || ax_query -e "tell application \"System Events\" to tell process \"MeetingAI\" to click button $FALLBACK_INDEX of group 1 of window 1" >/dev/null
}

click_analysis_button() {
  focus_app || true
  ax_query -e 'tell application "System Events" to tell process "MeetingAI" to click (first button of group 2 of splitter group 1 of group 1 of window 1 whose name contains "立即分析")' >/dev/null \
    || ax_query -e 'tell application "System Events" to tell process "MeetingAI" to click button 1 of group 2 of splitter group 1 of group 1 of window 1' >/dev/null
}

for _ in $(seq 1 10); do
  if focus_app; then
    break
  fi
  sleep 1
done

WINDOW_COUNT=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return count of windows' || echo "0")
if [ "${WINDOW_COUNT:-0}" -lt 1 ] 2>/dev/null; then
  echo "REAL_MEETING_SMOKE: BLOCKED no accessible MeetingAI window"
  exit 2
fi

if ! click_top_button "开始会议" 2; then
  echo "REAL_MEETING_SMOKE: BLOCKED could not click start meeting"
  tail -n 80 "$APP_LOG" || true
  exit 2
fi

RECORDING_READY=0
for _ in $(seq 1 15); do
  TOPBAR_DUMP=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 1 of window 1')
  if grep -q '录音中' <<<"$TOPBAR_DUMP"; then
    RECORDING_READY=1
    break
  fi
  sleep 1
done

if [ "$RECORDING_READY" -ne 1 ]; then
  echo "REAL_MEETING_SMOKE: BLOCKED recording state did not appear"
  tail -n 80 "$APP_LOG" || true
  exit 2
fi

(
  for _ in $(seq 1 6); do
    say "Meeting AI real microphone smoke test. Please transcribe this sentence for the rehearsal." >/dev/null 2>&1 || true
    sleep 3
  done
) &
SAY_PID=$!

TRANSCRIPT_READY=0
for _ in $(seq 1 "$DURATION_SECONDS"); do
  TRANSCRIPT_DUMP=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 1 of splitter group 1 of group 1 of window 1' || true)
  if ! grep -q '0 条' <<<"$TRANSCRIPT_DUMP" && ! grep -q '等待录音开始' <<<"$TRANSCRIPT_DUMP"; then
    TRANSCRIPT_READY=1
    break
  fi
  EVENT_LOG_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.events.log' | head -n 1)
  if [ -n "$EVENT_LOG_PATH" ] && grep -q '"event":"transcript_' "$EVENT_LOG_PATH"; then
    TRANSCRIPT_READY=1
    break
  fi
  sleep 1
done

kill "$SAY_PID" >/dev/null 2>&1 || true
wait "$SAY_PID" >/dev/null 2>&1 || true

if [ "$TRANSCRIPT_READY" -eq 1 ]; then
  click_analysis_button || true
fi

ANALYSIS_OUTCOME="not_observed"
if [ "$TRANSCRIPT_READY" -eq 1 ]; then
  for _ in $(seq 1 "$ANALYSIS_WAIT_SECONDS"); do
    EVENT_LOG_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.events.log' | head -n 1)
    if [ -n "$EVENT_LOG_PATH" ]; then
      if grep -q '"event":"analysis_completed"' "$EVENT_LOG_PATH"; then
        ANALYSIS_OUTCOME="completed"
        break
      fi
      if grep -q '"event":"analysis_failed"' "$EVENT_LOG_PATH"; then
        ANALYSIS_OUTCOME="failed"
        break
      fi
    fi
    sleep 1
  done
fi

click_top_button "结束会议" 3 || true
STOPPED_READY=0
for _ in $(seq 1 12); do
  TOPBAR_DUMP=$(ax_query -e 'tell application "System Events" to tell process "MeetingAI" to return name of every UI element of group 1 of window 1' || true)
  if ! grep -q '录音中' <<<"$TOPBAR_DUMP"; then
    STOPPED_READY=1
    break
  fi
  sleep 1
done

if [ "$STOPPED_READY" -ne 1 ]; then
  echo "REAL_MEETING_SMOKE: FAIL recording state did not stop"
  tail -n 80 "$APP_LOG" || true
  exit 1
fi
sleep 3

FUNASR_OUTCOME="not_requested"
if [ "$REQUIRE_FUNASR_DIARIZATION" = "1" ]; then
  FUNASR_OUTCOME="not_observed"
  for _ in $(seq 1 "$FUNASR_WAIT_SECONDS"); do
    EVENT_LOG_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.events.log' | head -n 1)
    if [ -n "$EVENT_LOG_PATH" ]; then
      FUNASR_OUTCOME="$(funasr_outcome_from_logs "$EVENT_LOG_PATH")"
      if [ "$FUNASR_OUTCOME" != "not_observed" ]; then
        break
      fi
    fi
    sleep 1
  done
fi

TXT_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.txt' | wc -l | tr -d ' ')
RECORDING_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f \( -name '*.mp3' -o -name '*.wav' \) -size +0c | wc -l | tr -d ' ')
EVENT_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.events.log' | wc -l | tr -d ' ')
TRANSCRIPT_MD_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.transcript.md' | wc -l | tr -d ' ')
AI_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.ai.md' | wc -l | tr -d ' ')
CHUNKS_LOG_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.chunks.jsonl' | wc -l | tr -d ' ')
CHUNK_WAV_COUNT=$(find "$SESSIONS_DIR" -maxdepth 2 -type f -path '*-chunks/*.wav' -size +0c | wc -l | tr -d ' ')
DIARIZED_COUNT=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.diarized.jsonl' | wc -l | tr -d ' ')
TRANSCRIPT_MD_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.transcript.md' | head -n 1)
EVENT_LOG_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.events.log' | head -n 1)
CHUNKS_LOG_PATH=$(find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.chunks.jsonl' | head -n 1)

{
  echo "ended_at=$(date)"
  echo "txt_count=$TXT_COUNT"
  echo "recording_count=$RECORDING_COUNT"
  echo "event_count=$EVENT_COUNT"
  echo "transcript_md_count=$TRANSCRIPT_MD_COUNT"
  echo "ai_count=$AI_COUNT"
  echo "chunks_log_count=$CHUNKS_LOG_COUNT"
  echo "chunk_wav_count=$CHUNK_WAV_COUNT"
  echo "diarized_count=$DIARIZED_COUNT"
  echo "transcript_ready=$TRANSCRIPT_READY"
  echo "analysis_outcome=$ANALYSIS_OUTCOME"
  echo "funasr_outcome=$FUNASR_OUTCOME"
  echo "session_files:"
  find "$SESSIONS_DIR" -maxdepth 2 -type f -print | sort
} >>"$LOG_DIR/manifest.txt"

if [ "$EVENT_COUNT" -lt 1 ] || [ "$TRANSCRIPT_MD_COUNT" -lt 1 ]; then
  echo "REAL_MEETING_SMOKE: FAIL missing session event/transcript artifacts"
  exit 1
fi

if [ "$RECORDING_COUNT" -lt 1 ]; then
  echo "REAL_MEETING_SMOKE: FAIL missing non-empty recording artifact"
  echo "logs=$LOG_DIR"
  exit 1
fi

if [ "$CHUNKS_LOG_COUNT" -lt 1 ] || [ "$CHUNK_WAV_COUNT" -lt 2 ]; then
  echo "REAL_MEETING_SMOKE: FAIL missing diarization chunk artifacts chunks_log=$CHUNKS_LOG_COUNT chunk_wav=$CHUNK_WAV_COUNT"
  echo "logs=$LOG_DIR"
  exit 1
fi

if [ "$TRANSCRIPT_READY" -ne 1 ]; then
  echo "REAL_MEETING_SMOKE: BLOCKED no real microphone transcript observed"
  echo "logs=$LOG_DIR"
  exit 2
fi

if ! grep -q '最终' "$TRANSCRIPT_MD_PATH" && ! grep -q '临时' "$TRANSCRIPT_MD_PATH"; then
  echo "REAL_MEETING_SMOKE: FAIL transcript markdown has no transcript status markers"
  exit 1
fi

if ! grep -q '"event":"meeting_started"' "$EVENT_LOG_PATH" || ! grep -q '"event":"meeting_stopped"' "$EVENT_LOG_PATH"; then
  echo "REAL_MEETING_SMOKE: FAIL lifecycle events missing"
  exit 1
fi

if ! grep -q '"event":"diarization_chunks_finalized"' "$EVENT_LOG_PATH"; then
  echo "REAL_MEETING_SMOKE: FAIL diarization chunk finalization event missing"
  exit 1
fi

if ! grep -q '"event":"chunk_created"' "$CHUNKS_LOG_PATH" || ! grep -q '"event":"chunk_waiting_for_upload"' "$CHUNKS_LOG_PATH"; then
  echo "REAL_MEETING_SMOKE: FAIL diarization chunk lifecycle records missing"
  exit 1
fi

if grep -Eq 'x-oss-signature|x-oss-credential|x-oss-security-token|OSSAccessKeyId|Authorization: Bearer|DASHSCOPE_API_KEY|OSS_ACCESS_KEY_SECRET' "$EVENT_LOG_PATH" "$CHUNKS_LOG_PATH"; then
  echo "REAL_MEETING_SMOKE: FAIL secret-like value leaked into diarization logs"
  echo "logs=$LOG_DIR"
  exit 1
fi

if [ "$ANALYSIS_OUTCOME" = "failed" ]; then
  echo "REAL_MEETING_SMOKE: FAIL AI analysis failed"
  echo "logs=$LOG_DIR"
  exit 1
fi

if [ "$ANALYSIS_OUTCOME" != "completed" ]; then
  echo "REAL_MEETING_SMOKE: FAIL AI analysis did not complete within ${ANALYSIS_WAIT_SECONDS}s"
  echo "logs=$LOG_DIR"
  exit 1
fi

if [ "$REQUIRE_FUNASR_DIARIZATION" = "1" ]; then
  if [ "$FUNASR_OUTCOME" = "blocked" ]; then
    echo "REAL_MEETING_SMOKE: BLOCKED Fun-ASR pipeline disabled by configuration"
    echo "logs=$LOG_DIR"
    exit 2
  fi
  if [ "$FUNASR_OUTCOME" = "failed" ]; then
    echo "REAL_MEETING_SMOKE: FAIL Fun-ASR diarization task failed"
    echo "logs=$LOG_DIR"
    exit 1
  fi
  if [ "$FUNASR_OUTCOME" != "completed" ] || [ "$DIARIZED_COUNT" -lt 1 ]; then
    echo "REAL_MEETING_SMOKE: FAIL Fun-ASR diarization did not complete within ${FUNASR_WAIT_SECONDS}s"
    echo "logs=$LOG_DIR"
    exit 1
  fi
  if ! grep -q '说话人分离回填' "$TRANSCRIPT_MD_PATH"; then
    echo "REAL_MEETING_SMOKE: FAIL transcript markdown missing speaker backfill"
    echo "logs=$LOG_DIR"
    exit 1
  fi
fi

echo "REAL_MEETING_SMOKE: PASS logs=$LOG_DIR sessions=$SESSIONS_DIR txt=$TXT_COUNT ai=$AI_COUNT chunks=$CHUNK_WAV_COUNT"
