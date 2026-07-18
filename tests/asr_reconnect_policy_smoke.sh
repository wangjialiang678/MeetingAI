#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="Sources/MeetingViewModel.swift"

check() {
  local name="$1"
  local pattern="$2"
  if grep -q "$pattern" "$SOURCE"; then
    echo "[PASS] $name"
  else
    echo "[FAIL] $name"
    echo "Missing pattern: $pattern"
    exit 1
  fi
}

check "single reconnect task state" "asrReconnectTask"
check "reconnect dedupe event" "asr_reconnect_deduplicated"
check "reconnect backoff state" "asrReconnectBackoffSeconds"
check "reconnect give-up event" "asr_reconnect_give_up"
check "backoff doubles with cap" "min(asrReconnectBackoffSeconds \\* 2"
check "stale client callback guard" "asrClientGeneration == generation"

echo "ASR_RECONNECT_POLICY_SMOKE: PASS"
