#!/bin/bash
# P0+P1 自动化闭环测试脚本
set -e
cd "$(dirname "$0")/.."

echo "=== P0: Build Tests ==="

echo "[P0-1] Go asr-bridge build..."
(cd asr-bridge && go build -o bin/asr-bridge .) && echo "PASS" || { echo "FAIL"; exit 1; }

echo "[P0-2] Swift build..."
swift build 2>&1 && echo "PASS" || { echo "FAIL"; exit 1; }

echo ""
echo "=== P1: Code Correctness ==="
FAIL=0

check() {
  if eval "$2"; then
    echo "[PASS] $1"
  else
    echo "[FAIL] $1"
    FAIL=1
  fi
}

check "P1-1 no refine route"        "! grep -q 'refine' asr-bridge/main.go"
check "P1-2 no transcribe-sync"     "! grep -q 'transcribe-sync' asr-bridge/main.go"
check "P1-3 api-vault.env path"     "grep -q 'api-vault.env' asr-bridge/env.go"
check "P1-4 go.mod module name"     "grep -q 'meetingai/asr-bridge' asr-bridge/go.mod"
check "P1-5 ASRServerManager path"  "grep -q 'asr-bridge' Sources/ASRServerManager.swift"
check "P1-6 health endpoint"        "grep -q '/health' Sources/ASRServerManager.swift"
check "P1-7 /v1/stream endpoint"    "grep -q '/v1/stream' Sources/ASRClient.swift"
check "P1-8 base64 audio"           "grep -q 'base64EncodedString' Sources/ASRClient.swift"
check "P1-9 port 18089"             "grep -q '18089' Sources/Config.swift"

echo ""
if [ $FAIL -eq 0 ]; then
  echo "All P0+P1 PASSED"
  exit 0
else
  echo "Some P1 checks FAILED"
  exit 1
fi
