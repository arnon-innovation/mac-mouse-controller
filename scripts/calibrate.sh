#!/usr/bin/env bash
# Interactive, run as MouseController.app: press the side buttons when asked.
# Writes a verified config/config.json (existing config is backed up first).
source "$(dirname "$0")/common.sh"
run_as_app "$LOG_DIR/calibrate-$(timestamp).log" calibrate --config "$CONFIG" --timeout "${1:-60}"
grep -q '"verified" : true' "$CONFIG" 2>/dev/null && echo "OK: $CONFIG written." || echo "Config not written (see log above)."
