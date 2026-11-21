#!/usr/bin/env bash
# Stop the controller, remove the LaunchAgent and the app. Config and logs are kept.
source "$(dirname "$0")/common.sh"
if is_loaded; then launchctl bootout "$DOMAIN/$LABEL" || true; fi
[ -f "$PLIST" ] && rm -f "$PLIST" && echo "Removed $PLIST"
[ -d "$INSTALL_APP" ] && rm -rf "$INSTALL_APP" && echo "Removed $INSTALL_APP"
echo "Uninstalled. Config ($CONFIG) and logs ($LOG_DIR) were kept."
echo "Optionally remove 'mouse-controller' from System Settings > Privacy & Security > Accessibility."
