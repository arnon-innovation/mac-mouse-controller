#!/usr/bin/env bash
# Swap Previous/Next desktop buttons in config/config.json (backup kept) and reload if running.
source "$(dirname "$0")/common.sh"
"$(cli_bin)" swap --config "$CONFIG"
if is_loaded; then launchctl kill SIGHUP "$DOMAIN/$LABEL" && echo "Reloaded running controller."; fi
