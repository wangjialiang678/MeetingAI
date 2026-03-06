#!/bin/bash
# 工作流未完成时阻止退出，自动继续
set -e

WORKFLOW_STATE=".claude/workflow/workflow-state.json"
FORCE_STOP="/tmp/FORCE_STOP"

# 强制停止检查
if [ -f "$FORCE_STOP" ]; then
  rm -f "$FORCE_STOP"
  exit 0
fi

# 工作流状态检查
if [ -f "$WORKFLOW_STATE" ]; then
  PHASE=$(python3 -c "import sys,json; print(json.load(open('$WORKFLOW_STATE')).get('phase',''))" 2>/dev/null || echo "")

  if [ "$PHASE" != "" ] && [ "$PHASE" != "completed" ] && [ "$PHASE" != "stopped" ]; then
    cat <<HOOK_EOF
{"decision":"block","reason":"[auto-dev] 工作流 Phase $PHASE 未完成，继续执行..."}
HOOK_EOF
    exit 2
  fi
fi

exit 0
