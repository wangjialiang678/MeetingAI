#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== P2: GUI Workflow ==="

echo "[P2-1] UI accessibility precheck..."
bash tests/ui_accessibility_precheck.sh

echo "[P2-2] Consolidated fixture workflow..."
bash tests/fixture_meeting_e2e.sh

echo ""
echo "P2 GUI workflow PASSED"
