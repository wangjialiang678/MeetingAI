#!/bin/bash
set -euo pipefail

STATUS=$(osascript -e 'tell application "System Events" to return UI elements enabled' 2>/dev/null || echo "error")

if [ "$STATUS" = "true" ]; then
  echo "UI_AUTOMATION_READY: Accessibility enabled"
  exit 0
fi

if [ "$STATUS" = "false" ]; then
  echo "UI_AUTOMATION_BLOCKED: Accessibility permissions are disabled for System Events"
  exit 2
fi

echo "UI_AUTOMATION_BLOCKED: Unable to query Accessibility permissions"
exit 2
