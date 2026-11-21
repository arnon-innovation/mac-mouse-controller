#!/usr/bin/env bash
# KILL SWITCH: stop the controller immediately. Mouse returns to stock behavior.
# Stays stopped (also across login) until scripts/enable.sh.
source "$(dirname "$0")/common.sh"
if is_loaded; then
  launchctl bootout "$DOMAIN/$LABEL" && echo "Controller stopped."
else
  echo "Controller was not running."
fi
# Belt and braces: any manually started instance too.
pkill -TERM -f "mouse-controller run" 2>/dev/null && echo "Stopped manual instance(s)." || true
# Keep it off at next login as well.
[ -f "$PLIST" ] && mv "$PLIST" "$PLIST.disabled" && echo "LaunchAgent parked at $PLIST.disabled"
exit 0
