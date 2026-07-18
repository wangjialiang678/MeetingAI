#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source scripts/lib/real-meeting-smoke-funasr.sh

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meetingai-funasr-outcome.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

EVENT_LOG="$TMP_DIR/session.events.log"

cat >"$EVENT_LOG" <<'LOG'
{"chunks":2,"event":"diarization_chunks_finalized"}
{"chunkIndex":0,"event":"diarization_task_completed"}
LOG

OUTCOME="$(funasr_outcome_from_logs "$EVENT_LOG")"
if [ "$OUTCOME" != "not_observed" ]; then
  echo "expected not_observed while only one of two chunks completed, got $OUTCOME" >&2
  exit 1
fi

cat >>"$EVENT_LOG" <<'LOG'
{"chunkIndex":1,"event":"diarization_task_failed","error":"failed"}
LOG

OUTCOME="$(funasr_outcome_from_logs "$EVENT_LOG")"
if [ "$OUTCOME" != "failed" ]; then
  echo "expected failed to override partial completion, got $OUTCOME" >&2
  exit 1
fi

cat >"$EVENT_LOG" <<'LOG'
{"chunks":2,"event":"diarization_chunks_finalized"}
{"chunkIndex":0,"event":"diarization_task_completed"}
{"chunkIndex":1,"event":"diarization_task_completed"}
LOG

OUTCOME="$(funasr_outcome_from_logs "$EVENT_LOG")"
if [ "$OUTCOME" != "completed" ]; then
  echo "expected completed only after all finalized chunks completed, got $OUTCOME" >&2
  exit 1
fi

echo "Fun-ASR real smoke outcome tests PASS"
