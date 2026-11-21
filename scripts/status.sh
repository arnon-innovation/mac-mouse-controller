#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
if is_loaded; then
  launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|pid|last exit code|runs) ' | head -4 || true
else
  echo "LaunchAgent not loaded."
fi
# Permission state of the *running agent* is only knowable from its own log
# (checking from this shell would report the terminal's permissions instead).
echo "--- controller permission state (from its log)"
if grep -q "event tap active" "$CONTROLLER_LOG" 2>/dev/null && \
   [ "$(grep -n 'event tap active' "$CONTROLLER_LOG" | tail -1 | cut -d: -f1)" -gt "$(grep -n 'starting;' "$CONTROLLER_LOG" | tail -1 | cut -d: -f1)" ]; then
  echo "Accessibility: GRANTED (event tap active)"
elif grep -q "Accessibility permission missing" "$CONTROLLER_LOG" 2>/dev/null; then
  echo "Accessibility: MISSING - waiting. Enable MouseController in System Settings > Privacy & Security > Accessibility"
else
  echo "unknown"
fi
echo "--- last log lines ($CONTROLLER_LOG)"
tail -n 10 "$CONTROLLER_LOG" 2>/dev/null || echo "(no log yet)"
