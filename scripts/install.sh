#!/usr/bin/env bash
# Build Relay (Release, arm64) and install it to /Applications as the canonical app.
# Global hotkeys/mic permissions are keyed to this stable path + signature, so always
# run daily-use Relay from /Applications — not Xcode Debug or /tmp builds.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
DERIVED="/tmp/relay-build"
xcodebuild -scheme Relay -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=YES build
APP="$DERIVED/Build/Products/Release/Relay.app"
rm -rf /Applications/Relay.app
cp -R "$APP" /Applications/Relay.app
echo "Installed /Applications/Relay.app"
