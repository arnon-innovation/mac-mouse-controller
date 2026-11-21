#!/usr/bin/env bash
# Build a release binary and wrap it in a signed MouseController.app.
#
# Signing matters: macOS TCC (Accessibility / Input Monitoring) remembers a grant by the
# code signature. With an ad-hoc signature the identity is the binary hash, so EVERY
# rebuild silently loses the permission. A real certificate (e.g. "Apple Development")
# gives a stable identity, so grants survive rebuilds. See docs/ISSUES.md ISSUE-004.
#
# Override: CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build.sh
#           CODESIGN_IDENTITY=- scripts/build.sh   (ad-hoc, not recommended)
source "$(dirname "$0")/common.sh"
cd "$PROJECT_DIR"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/mouse-controller"

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS"
cp resources/Info.plist "$BUILD_APP/Contents/Info.plist"
cp "$BIN" "$BUILD_APP/Contents/MacOS/mouse-controller"

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  # First valid Apple Development / Developer ID identity, by hash (no personal data in files).
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$CODESIGN_IDENTITY" ]; then
  echo "WARNING: no signing certificate found; using ad-hoc signature."
  echo "         Permissions will need to be re-granted after every rebuild."
  CODESIGN_IDENTITY="-"
fi

codesign --force --options runtime --timestamp=none \
  --identifier "$LABEL" --sign "$CODESIGN_IDENTITY" "$BUILD_APP"
codesign --verify --strict --verbose=1 "$BUILD_APP"
echo "Built $BUILD_APP"
codesign -dr - "$BUILD_APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
