#!/usr/bin/env bash
# Re-enable after scripts/disable.sh.
source "$(dirname "$0")/common.sh"
[ -f "$PLIST.disabled" ] && mv "$PLIST.disabled" "$PLIST"
[ -f "$PLIST" ] || { echo "Not installed. Run scripts/install.sh" >&2; exit 1; }
is_loaded || launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Controller enabled."
