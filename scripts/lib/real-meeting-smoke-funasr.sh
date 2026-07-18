#!/bin/bash

funasr_outcome_from_logs() {
  local event_log="${1:-}"
  if [ -z "$event_log" ] || [ ! -f "$event_log" ]; then
    echo "not_observed"
    return
  fi

  if grep -q '"event":"diarization_task_failed"' "$event_log"; then
    echo "failed"
    return
  fi
  if grep -q '"event":"diarization_pipeline_disabled"' "$event_log"; then
    echo "blocked"
    return
  fi

  local expected_chunks
  expected_chunks="$(
    awk '
      /"event":"diarization_chunks_finalized"/ {
        if (match($0, /"chunks":[0-9]+/)) {
          value = substr($0, RSTART + 9, RLENGTH - 9)
        }
      }
      END { print value }
    ' "$event_log"
  )"
  if [ -z "$expected_chunks" ] || [ "$expected_chunks" -lt 1 ]; then
    echo "not_observed"
    return
  fi

  local completed_chunks
  completed_chunks="$(
    awk '
      /"event":"diarization_task_completed"/ {
        if (match($0, /"chunkIndex":[0-9]+/)) {
          print substr($0, RSTART + 13, RLENGTH - 13)
        }
      }
    ' "$event_log" | sort -u | wc -l | tr -d ' '
  )"
  if [ "$completed_chunks" -ge "$expected_chunks" ]; then
    echo "completed"
  else
    echo "not_observed"
  fi
}
