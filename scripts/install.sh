#!/usr/bin/env bash
# Install MouseController.app to ~/Applications and register a LaunchAgent (start at login).
# Requires a verified config (run scripts/calibrate.sh first).
source "$(dirname "$0")/common.sh"

if [ ! -f "$CONFIG" ]; then
  echo "No config at $CONFIG. Run scripts/calibrate.sh first (press your real side buttons)." >&2
  exit 1
fi

"$(dirname "$0")/build.sh"

# Validate with the freshly built binary before touching the running install.
"$BUILD_APP/Contents/MacOS/mouse-controller" validate --config "$CONFIG"
if ! grep -q '"verified" *: *true' "$CONFIG"; then
  echo "Config is not verified. Run scripts/calibrate.sh first." >&2
  exit 1
fi

if is_loaded; then
  launchctl bootout "$DOMAIN/$LABEL" || true
fi

mkdir -p "$HOME/Applications" "$LOG_DIR" "$(dirname "$PLIST")"
if [ -d "$INSTALL_APP" ]; then
  backup_if_exists "$INSTALL_APP"
  rm -rf "$INSTALL_APP"
fi
cp -R "$BUILD_APP" "$INSTALL_APP"

backup_if_exists "$PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_BIN</string>
        <string>run</string>
        <string>--config</string><string>$CONFIG</string>
        <string>--log</string><string>$CONTROLLER_LOG</string>
    </array>
    <key>RunAtLoad</key><true/>
    <!-- Restart after a crash, but NOT after a clean stop (SIGTERM / disable.sh). -->
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/launchd.err.log</string>
    <key>StandardOutPath</key><string>$LOG_DIR/launchd.out.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST"

launchctl bootstrap "$DOMAIN" "$PLIST"
echo
echo "Installed and started $LABEL."
echo "If this is the first install, macOS asks for Accessibility for 'mouse-controller'."
echo "Grant it in System Settings > Privacy & Security > Accessibility; the controller"
echo "picks it up automatically within ~5 s (no restart needed)."
echo "Status: scripts/status.sh    Kill switch: scripts/disable.sh"
