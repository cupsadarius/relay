#!/usr/bin/env bash
# Build Relay (Release, arm64) and install it to /Applications as the canonical app.
#
# Global hotkeys, microphone and accessibility grants (TCC) are keyed to the bundle id plus the
# code signature, so daily-use Relay (dev.relaymac.Relay) always runs from /Applications. Xcode
# Debug builds are a SEPARATE app ("Relay Debug", dev.relaymac.Relay.debug) with their own grants,
# settings and support dir; this script never touches a running Relay Debug.
# See README "Build & setup".
#
# `xcodegen generate` below rewrites the tracked Relay.xcodeproj to match project.yml. If that
# leaves a diff, commit the regenerated project alongside whatever changed project.yml.
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
# `.` is a regex metacharacter (matches any char), so escape it before using RELEASE_EXECUTABLE in
# a pgrep/pkill -f pattern — otherwise "Relay.app" would also match "RelayXapp". Anchored on the
# right with "( |$)" so a longer path that merely starts with this one doesn't also match.
RELEASE_EXECUTABLE_PATTERN="^${RELEASE_EXECUTABLE//./\\.}( |\$)"
SIGNING_IDENTITY="Relay Local Development"
DEST="/Applications/Relay.app"
STAGING="/Applications/Relay.app.new"
BACKUP="/Applications/Relay.app.old"
DERIVED="${RELAY_DERIVED_DATA:-/tmp/relay-build}"

die() {
  echo "error: $*" >&2
  exit 1
}

# Verification-stage failure: the staged copy is worthless, so remove it before dying (unlike the
# later failure paths, which intentionally leave a good $STAGING behind for the user to recover).
die_and_clean_staging() {
  rm -rf "$STAGING"
  die "$*"
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
ditto "$APP" "$STAGING" || die_and_clean_staging "ditto failed while staging the build"

codesign --verify --deep --strict "$STAGING" \
  || die_and_clean_staging "staged app failed code-signature verification"

# Belt and suspenders on top of --verify: confirm the signature is actually OURS, and that ditto
# staged the app we think it did, before this build gets anywhere near /Applications.
signing_info="$(codesign -dvv "$STAGING" 2>&1 || true)"
grep -qF "Authority=${SIGNING_IDENTITY}" <<<"$signing_info" \
  || die_and_clean_staging "staged app is not signed by \"${SIGNING_IDENTITY}\" (codesign -dvv: $(grep '^Authority=' <<<"$signing_info" | head -1 || echo 'no Authority line'))"

staged_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$STAGING/Contents/Info.plist" 2>/dev/null || true)"
[[ "$staged_bundle_id" == "$BUNDLE_ID" ]] \
  || die_and_clean_staging "staged app has bundle id \"${staged_bundle_id}\", expected \"${BUNDLE_ID}\""

# --- Quit the running Relay --------------------------------------------------------------------
wait_for_exit() {
  local tries="$1"
  local i
  for ((i = 0; i < tries; i++)); do
    pgrep -f "$RELEASE_EXECUTABLE_PATTERN" >/dev/null || return 0
    sleep 0.1
  done
  return 1
}

if pgrep -f "$RELEASE_EXECUTABLE_PATTERN" >/dev/null; then
  echo "Quitting running Relay..."
  # Guarded by pgrep: `tell application id` would otherwise LAUNCH Relay if it isn't running.
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  if ! wait_for_exit 50; then
    pkill -f "$RELEASE_EXECUTABLE_PATTERN" || true
    wait_for_exit 30 || die "Relay is still running; quit it manually and re-run. New build left at $STAGING"
  fi
fi

# --- Atomic swap: old bundle is removed only after the new one is in place ---------------------
# Safety net for a crash or signal (not just an ordinary `mv` failure, which the manual rollback
# below already handles) landing between the two `mv`s: if $DEST ends up missing while $BACKUP
# still exists, put the old app back. Disarmed once the swap commits.
restore() {
  [[ ! -e "$DEST" && -e "$BACKUP" ]] && mv "$BACKUP" "$DEST"
}
trap restore EXIT INT TERM

rm -rf "$BACKUP"
if [[ -e "$DEST" ]]; then
  mv "$DEST" "$BACKUP" || die "could not move old install aside; new build left at $STAGING"
fi
if ! mv "$STAGING" "$DEST"; then
  if [[ -e "$BACKUP" ]]; then
    mv "$BACKUP" "$DEST" || die "rollback failed: old app at $BACKUP, new build at $STAGING; move one to $DEST by hand"
  fi
  die "could not move $STAGING into place; previous install restored"
fi
rm -rf "$BACKUP"
trap - EXIT INT TERM
echo "Installed $DEST"

# --- Relaunch: the app refreshes ~/Library/Application Support/Relay/bin/RelayHook on launch ---
if [[ "${RELAY_NO_LAUNCH:-0}" != "1" ]]; then
  open "$DEST"
  echo "Relaunched Relay"
fi
