#!/usr/bin/env bash
# Listen-only diagnostic, run as MouseController.app. Logs to logs/diagnostic-<timestamp>.log.
# Usage: scripts/diagnose.sh [seconds]
source "$(dirname "$0")/common.sh"
LOG="$LOG_DIR/diagnostic-$(timestamp).log"
echo "Logging to $LOG"
run_as_app "$LOG" diagnose --timeout "${1:-45}"
echo
echo "=== Summary: extra mouse buttons seen ==="
grep -oE 'otherMouseDown buttonNumber=[0-9]+' "$LOG" | sort | uniq -c || echo "(none)"
echo "=== All mouse events seen ==="
grep -oE 'CGEVENT [a-zA-Z]+' "$LOG" | sort | uniq -c || echo "(none: see the ERROR/WARN lines above)"
echo "=== HID button/consumer presses ==="
grep -E 'page=(Button|Consumer).*value=[1-9]' "$LOG" | sed -E 's/.*HID +//' | sort | uniq -c || echo "(none / HID layer not permitted)"
