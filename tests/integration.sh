#!/usr/bin/env bash
# Automated checks that need NO physical button presses.
# Hardware behaviour (real side buttons, actual Space switching by mouse) is covered by
# tests/MANUAL_TESTS.md and must be done by a human.
#
# Usage: tests/integration.sh            # CLI + config checks
#        tests/integration.sh --agent    # also exercise the installed LaunchAgent (reload, toggle, crash restart)
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
set +e

PASS=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
expect_exit() { # name expected_code cmd...
  local name="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  [ "$got" = "$want" ] && ok "$name (exit $got)" || bad "$name (want $want, got $got)"
}

swift build -q || { echo "build failed"; exit 1; }
BIN=.build/debug/mouse-controller
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

expect_exit "help exits 0" 0 "$BIN" help
expect_exit "unknown command exits 1" 1 "$BIN" bogus
expect_exit "example config validates" 0 "$BIN" validate --config config/config.example.json
expect_exit "run refuses unverified config" 1 "$BIN" run --config config/config.example.json
expect_exit "run fails on missing config" 1 "$BIN" run --config "$TMP/nope.json"

echo '{' > "$TMP/malformed.json"
expect_exit "malformed JSON rejected" 1 "$BIN" validate --config "$TMP/malformed.json"

sed 's/"button" : 3/"button" : 0/' config/config.example.json > "$TMP/leftclick.json"
expect_exit "mapping left click rejected" 1 "$BIN" validate --config "$TMP/leftclick.json"
out="$("$BIN" validate --config "$TMP/leftclick.json" 2>&1)"  # capture first: pipefail would report validate's exit 1
grep -q "left/right click" <<<"$out" && ok "left-click rejection message" || bad "left-click rejection message"

"$BIN" diagnose --timeout 1 --log "$TMP/d.log" >/dev/null 2>&1; rc=$?
# 0 = events received, 5 = zero events (must come with the explicit permission error, ISSUE-009)
if [ "$rc" = 0 ]; then ok "diagnose stops on timeout (events received)"
elif [ "$rc" = 5 ] && grep -qiE "no input events were received" "$TMP/d.log"; then ok "diagnose reports zero events explicitly (exit 5)"
else bad "diagnose exit code $rc"; fi
grep -q "CGEvent tap active (listen-only)" "$TMP/d.log" && ok "diagnose listen-only tap created" || bad "diagnose listen-only tap created"
grep -q "M21-Mouse" "$TMP/d.log" && ok "M21 visible to IOHID (connected now)" || echo "SKIP  M21 not currently connected"

sed 's/"verified" : false/"verified" : true/' config/config.example.json > "$TMP/swap.json"
"$BIN" swap --config "$TMP/swap.json" >/dev/null 2>&1
out="$("$BIN" swap --config "$TMP/swap.json" 2>&1)"   # swap twice -> back to original 3/4
grep -q "Previous Desktop = buttonNumber 3, Next Desktop = buttonNumber 4" <<<"$out" && ok "swap is reversible" || bad "swap is reversible: $out"
"$BIN" validate --config "$TMP/swap.json" >/dev/null 2>&1 && ok "swapped config still valid" || bad "swapped config still valid"
ls "$TMP"/swap.json.bak-* >/dev/null 2>&1 && ok "swap backs up config" || bad "swap backs up config"
expect_exit "calibrate times out with exit 3 (no presses)" 3 "$BIN" calibrate --config "$TMP/cal.json" --timeout 1
[ ! -f "$TMP/cal.json" ] && ok "calibrate timeout writes no config" || bad "calibrate timeout writes no config"

grep -qE '^[0-9]+$' <<<"$("$BIN" current-space)" && ok "current-space probe works" || bad "current-space probe works"

if [ -d "$BUILD_APP" ]; then
  codesign --verify --strict "$BUILD_APP" 2>/dev/null && ok "app bundle signature valid" || bad "app bundle signature valid"
  grep -q 'anchor apple generic' <<<"$(codesign -dr - "$BUILD_APP" 2>&1)" && ok "stable (certificate-based) designated requirement" \
    || echo "WARN  ad-hoc signature: permissions reset on every rebuild"
fi

if [ "${1:-}" = "--agent" ]; then
  echo "--- LaunchAgent checks"
  if ! is_loaded; then bad "agent loaded"; else
    ok "agent loaded"
    pid1=$(launchctl print "$DOMAIN/$LABEL" | awk '/^\tpid =/ {print $3}')
    [ -n "$pid1" ] && ok "agent running (pid $pid1)" || bad "agent running"
    grep -q "event tap active" "$CONTROLLER_LOG" && ok "agent tap active (Accessibility granted)" || bad "agent tap active (grant Accessibility to mouse-controller)"

    n0=$(grep -c "config reloaded" "$CONTROLLER_LOG")
    launchctl kill SIGHUP "$DOMAIN/$LABEL"; sleep 0.5
    [ "$(grep -c "config reloaded" "$CONTROLLER_LOG")" -gt "$n0" ] && ok "SIGHUP reload" || bad "SIGHUP reload"

    launchctl kill SIGUSR1 "$DOMAIN/$LABEL"; sleep 0.3
    grep -q DISABLED <<<"$(tail -n1 "$CONTROLLER_LOG")" && ok "SIGUSR1 pause" || bad "SIGUSR1 pause"
    launchctl kill SIGUSR1 "$DOMAIN/$LABEL"; sleep 0.3
    grep -q ENABLED <<<"$(tail -n1 "$CONTROLLER_LOG")" && ok "SIGUSR1 resume" || bad "SIGUSR1 resume"

    kill -9 "$pid1"; sleep 12
    pid2=$(launchctl print "$DOMAIN/$LABEL" | awk '/^\tpid =/ {print $3}')
    [ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && ok "crash -> launchd restart (pid $pid1 -> $pid2)" || bad "crash -> launchd restart"
  fi
fi

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
