#!/bin/sh
# Build a Compositor.app this Mac can open, and put it on the Desktop.
# The signature is ad-hoc: not notarized, and not something to give to another Mac.
# Someone else clones the repo and runs this script on their own machine.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
dd="${COMPOSITOR_DD:-$root/DerivedData}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required. Install it, then run this script again." >&2
  exit 1
fi

xcodebuild -project Compositor.xcodeproj -scheme Compositor \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -derivedDataPath "$dd" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build

app="$dd/Build/Products/Release/Compositor.app"
test -x "$app/Contents/MacOS/Compositor" || { echo "The build did not produce Compositor." >&2; exit 1; }
test -x "$app/Contents/MacOS/AIPanelWorker" || { echo "AIPanelWorker is missing from the bundle." >&2; exit 1; }
test -f "$app/Contents/Resources/Looks.json" || { echo "Looks.json is missing from the bundle." >&2; exit 1; }
test -f "$app/Contents/Resources/Knowledge.json" || { echo "Knowledge.json is missing from the bundle." >&2; exit 1; }

# Release turns on the hardened runtime. An ad-hoc signature has no team, so
# dyld then refuses to load Sparkle. Sign again without that flag. Sandbox and
# network access stay in the entitlements file. Nothing is copied yet.
codesign --force --sign - --timestamp=none \
  --entitlements Config/Compositor.entitlements "$app"
codesign --verify --deep --strict "$app"
codesign -d --entitlements - "$app" 2>&1 | grep -q 'com.apple.security.network.client'

log=$(mktemp)
"$app/Contents/MacOS/Compositor" >"$log" 2>&1 &
pid=$!
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then
  echo "The app quit at launch:" >&2
  cat "$log" >&2
  rm -f "$log"
  exit 1
fi
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
rm -f "$log"

dest="$HOME/Desktop/Compositor.app"
if [ -d "$dest" ]; then
  bak="$dest.bak-$(date +%s)"
  mv "$dest" "$bak"
  echo "Moved the previous app to $bak"
fi
ditto "$app" "$dest"
echo "Packaged $dest"
open "$dest"
