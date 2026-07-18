#!/bin/bash
set -e

WORKFLOW_STATE=".Codex/workflow/workflow-state.json"
FORCE_STOP="/tmp/FORCE_STOP"

if [ -f "$FORCE_STOP" ]; then
  rm -f "$FORCE_STOP"
  exit 0
fi

if [ ! -f "$WORKFLOW_STATE" ]; then
  exit 0
fi

PHASE=$(python3 - <<'PY'
import json, pathlib
path = pathlib.Path(".Codex/workflow/workflow-state.json")
try:
    data = json.loads(path.read_text())
    print(data.get("phase", ""))
except Exception:
    print("")
PY
)

if [ -n "$PHASE" ] && [ "$PHASE" != "completed" ] && [ "$PHASE" != "stopped" ]; then
  cat <<EOF
{"decision":"block","reason":"[auto-dev] workflow phase '$PHASE' is still active"}
EOF
  exit 2
fi

exit 0
