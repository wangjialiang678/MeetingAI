#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== MeetingAI Full Closed-Loop Batch ==="

echo ""
echo "[1/2] P0/P1 automatic baseline"
bash tests/run-p0-p1.sh

echo ""
echo "[2/2] P2 GUI workflow"
bash tests/run-p2-ui.sh

echo ""
echo "MEETINGAI_FULL_BATCH: PASS"
