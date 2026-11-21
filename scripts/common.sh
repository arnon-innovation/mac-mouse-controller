# shellcheck shell=bash
# Shared paths for all scripts. Source, don't execute.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.arnon.mouse-controller"
APP_NAME="MouseController.app"
BUILD_APP="$PROJECT_DIR/build/$APP_NAME"
INSTALL_APP="$HOME/Applications/$APP_NAME"
INSTALLED_BIN="$INSTALL_APP/Contents/MacOS/mouse-controller"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="${MOUSE_CONTROLLER_CONFIG:-$PROJECT_DIR/config/config.json}"
LOG_DIR="$PROJECT_DIR/logs"
CONTROLLER_LOG="$LOG_DIR/controller.log"
DOMAIN="gui/$(id -u)"

timestamp() { date +%Y%m%d-%H%M%S; }

backup_if_exists() {
  local target="$1"
  if [ -e "$target" ]; then
    local dest="$target.bak-$(timestamp)"
    cp -R "$target" "$dest"
    echo "Backed up $target -> $dest"
  fi
}

is_loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# Binary to use for CLI commands: installed app if present, else a fresh debug build.
cli_bin() {
  if [ -x "$INSTALLED_BIN" ]; then echo "$INSTALLED_BIN"; return; fi
  (cd "$PROJECT_DIR" && swift build -q >/dev/null) && echo "$PROJECT_DIR/.build/debug/mouse-controller"
}

# Run a CLI command *as MouseController.app* (via `open`), so macOS attributes the
# Input Monitoring / Accessibility request to the app, not to the terminal (ISSUE-009).
# Output goes to $log, which is streamed to this terminal while the command runs.
# Usage: run_as_app LOGFILE command [args...]
run_as_app() {
  local log="$1"; shift
  local app="$INSTALL_APP"
  [ -d "$app" ] || app="$BUILD_APP"
  [ -d "$app" ] || { "$PROJECT_DIR/scripts/build.sh" >/dev/null; app="$BUILD_APP"; }
  mkdir -p "$(dirname "$log")"; : > "$log"
  open -W -n "$app" --args "$@" --log "$log" &
  local opid=$!
  tail -n +1 -f "$log" &
  local tpid=$!
  wait "$opid"
  sleep 0.5
  { kill "$tpid" && wait "$tpid"; } 2>/dev/null || true
}
