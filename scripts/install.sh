#!/usr/bin/env bash
# Build Relay (Release, arm64) and install it to /Applications as the canonical app.
#
# Global hotkeys, microphone and accessibility grants (TCC) are keyed to the bundle id plus the
# code signature, so daily-use Relay (dev.relaymac.Relay) always runs from /Applications. Xcode
# Debug builds are a SEPARATE app ("Relay Debug", dev.relaymac.Relay.debug) with their own grants,
# settings and support dir; this script never touches a running Relay Debug.
# See README "Build & setup".
#
# Env:
#   RELAY_NO_LAUNCH=1     do not relaunch Relay after installing
#   RELAY_DERIVED_DATA    derived-data directory (default: /tmp/relay-build)
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="dev.relaymac.Relay"
# Both Debug and Release executables are named "Relay", so match the installed bundle's full
# executable path. A bare `pgrep -x Relay` would also kill a running Relay Debug.
RELEASE_EXECUTABLE="/Applications/Relay.app/Contents/MacOS/Relay"
SIGNING_IDENTITY="Relay Local Development"
DEST="/Applications/Relay.app"
STAGING="/Applications/Relay.app.new"
BACKUP="/Applications/Relay.app.old"
DERIVED="${RELAY_DERIVED_DATA:-/tmp/relay-build}"

die() {
  echo "error: $*" >&2
  exit 1
}

# --- Preflight -------------------------------------------------------------------------------
command -v xcodegen >/dev/null 2>&1 \
  || die "xcodegen not found. Install it with: brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 \
  || die "xcodebuild not found. Install Xcode 26+ and run: sudo xcode-select -s /Applications/Xcode.app"
# Capture first, then grep the variable: piping `security` straight into `grep -q` under
# pipefail can report a false "missing" when grep exits early and security gets SIGPIPE.
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
grep -qF "\"${SIGNING_IDENTITY}\"" <<<"$identities" \
  || die "code-signing identity \"${SIGNING_IDENTITY}\" not found in your keychain. See README \"Build & setup\" step 2."

# --- Build (the running app is untouched until this succeeds) ---------------------------------
xcodegen generate
xcodebuild -scheme Relay -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=YES build
APP="$DERIVED/Build/Products/Release/Relay.app"
[[ -d "$APP" ]] || die "build succeeded but $APP is missing"

# --- Stage next to the destination so the final mv is a same-volume rename --------------------
rm -rf "$STAGING"
ditto "$APP" "$STAGING"
codesign --verify --strict "$STAGING" || die "staged app failed code-signature verification"

# --- Quit the running Relay --------------------------------------------------------------------
wait_for_exit() {
  local tries="$1"
  local i
  for ((i = 0; i < tries; i++)); do
    pgrep -f "^${RELEASE_EXECUTABLE}" >/dev/null || return 0
    sleep 0.1
  done
  return 1
}

if pgrep -f "^${RELEASE_EXECUTABLE}" >/dev/null; then
  echo "Quitting running Relay..."
  # Guarded by pgrep: `tell application id` would otherwise LAUNCH Relay if it isn't running.
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  if ! wait_for_exit 50; then
    pkill -f "^${RELEASE_EXECUTABLE}" || true
    wait_for_exit 30 || die "Relay is still running; quit it manually and re-run. New build left at $STAGING"
  fi
fi

# --- Atomic swap: old bundle is removed only after the new one is in place ---------------------
rm -rf "$BACKUP"
if [[ -e "$DEST" ]]; then
  mv "$DEST" "$BACKUP" || die "could not move old install aside; new build left at $STAGING"
fi
if ! mv "$STAGING" "$DEST"; then
  if [[ -e "$BACKUP" ]]; then
    mv "$BACKUP" "$DEST"
  fi
  die "could not move $STAGING into place; previous install restored"
fi
rm -rf "$BACKUP"
echo "Installed $DEST"

# --- Relaunch: the app refreshes ~/Library/Application Support/Relay/bin/RelayHook on launch ---
if [[ "${RELAY_NO_LAUNCH:-0}" != "1" ]]; then
  open "$DEST"
  echo "Relaunched Relay"
fi
