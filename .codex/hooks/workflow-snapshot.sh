#!/bin/bash
set -e

WORKFLOW_DIR=".Codex/workflow"
SNAPSHOT_DIR="$WORKFLOW_DIR/snapshots"

if [ ! -d "$WORKFLOW_DIR" ]; then
  exit 0
fi

mkdir -p "$SNAPSHOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

for f in workflow-state.json task-pool.json; do
  if [ -f "$WORKFLOW_DIR/$f" ]; then
    cp "$WORKFLOW_DIR/$f" "$SNAPSHOT_DIR/${f%.json}_$TIMESTAMP.json"
  fi
done

exit 0
