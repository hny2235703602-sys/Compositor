#!/bin/sh
# Builds a self-contained Compositor.app, signed locally, and copies it to the Desktop.
# Not notarized and not for distribution. The assistant's network helper is a second
# executable in the bundle so a crash there does not take the editor with it.
set -eu
cd "$(dirname "$0")/.."
DD="${COMPOSITOR_DD:-/Users/apple/Compositor-dd2}"
xcodebuild -project Compositor.xcodeproj -scheme Compositor -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES
APP="$DD/Build/Products/Release/Compositor.app"
if ! { test -x "$APP/Contents/MacOS/Compositor" && test -d "$APP/Contents/Resources"; }; then
  echo "Compositor.app at $APP is not a complete build" >&2
  exit 1
fi
HELPER="$APP/Contents/MacOS/AIPanelWorker"
test -x "$HELPER" || { echo "AIPanelWorker missing from bundle"; exit 1; }
codesign --force --sign - --entitlements Config/Compositor.entitlements "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -q 'com.apple.security.network.client'
DEST="$HOME/Desktop/Compositor.app"
[ -d "$DEST" ] && mv "$DEST" "$DEST.bak-$(date +%s)"
ditto "$APP" "$DEST"
echo "Packaged $DEST"
