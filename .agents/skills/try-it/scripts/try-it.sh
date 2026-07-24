#!/bin/bash
# Build the working tree and install it as /Applications/Pace.app.
#
# Encapsulates the fragile parts of a dev install so they happen the same
# way every time: manual Developer ID signing (required for the app to be
# registerable in the Accessibility pane), designated-requirement comparison
# so TCC records are reset only when the signature actually changes, and a
# staged atomic replace so a half-copied bundle is never live.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd -P)"
cd "$REPO_ROOT"

APP_NAME="Pace"
BUNDLE_ID="llc.wvlen.Pace"
INSTALL_PATH="/Applications/$APP_NAME.app"
BUILT_APP="build/Build/Products/Release/$APP_NAME.app"
# The wvlen team has no Apple Development certificate, so automatic signing
# silently falls back to a personal-team development cert — and macOS shows
# the Accessibility consent dialog for such builds yet never registers them
# in the Accessibility list. Signing is pinned to Developer ID.
TEAM_ID="93W5N4LQL7"

fail() { echo "error: $*" >&2; exit 1; }

# nix-darwin exports toolchain variables that break xcodebuild.
unset LD CC SDKROOT DEVELOPER_DIR 2>/dev/null || true

if [[ ! -d "$APP_NAME.xcodeproj" || "project.yml" -nt "$APP_NAME.xcodeproj/project.pbxproj" ]]; then
    xcodegen generate
fi

echo "Building $APP_NAME (Release, Developer ID)..."
# Explicit template keeps mktemp portable across BSD and GNU (nix) variants.
build_log="$(mktemp "${TMPDIR:-/tmp}/pace-try-it-build.XXXXXX")"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath build build \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
    "CODE_SIGN_IDENTITY=Developer ID Application" \
    "OTHER_CODE_SIGN_FLAGS=--timestamp" >"$build_log" 2>&1 \
    || { tail -40 "$build_log" >&2; fail "build failed; installed copy left untouched (full log: $build_log)"; }

signing_info="$(codesign -dvvv "$BUILT_APP" 2>&1)"
grep -q "^Authority=Developer ID Application" <<<"$signing_info" \
    || fail "build is not Developer ID signed; the Accessibility pane would refuse to register it"

old_requirement="$(codesign -d -r- "$INSTALL_PATH" 2>/dev/null || true)"
new_requirement="$(codesign -d -r- "$BUILT_APP" 2>/dev/null || true)"

if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Closing the running $APP_NAME app..."
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
    if pgrep -x "$APP_NAME" >/dev/null; then
        pkill -TERM -x "$APP_NAME" || true
        for _ in $(seq 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
    fi
    pgrep -x "$APP_NAME" >/dev/null && fail "could not stop the running $APP_NAME app"
fi

echo "Installing $APP_NAME in /Applications..."
staging_dir="$(mktemp -d "/Applications/.$APP_NAME-install.XXXXXX")"
ditto "$BUILT_APP" "$staging_dir/$APP_NAME.app"
rm -rf "$INSTALL_PATH"
mv "$staging_dir/$APP_NAME.app" "$INSTALL_PATH"
rmdir "$staging_dir"

# macOS binds permission grants (TCC) to the code signature; a record left
# by a differently signed copy silently blocks new permission prompts.
# Same-signature updates keep their grants and must not be reset.
if [[ -n "$old_requirement" && "$old_requirement" != "$new_requirement" ]]; then
    echo "Code signature changed; clearing stale permission records for $BUNDLE_ID..."
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset PostEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Re-grant Accessibility in System Settings → Privacy & Security → Accessibility (add with + if unlisted)."
fi

codesign --verify --strict "$INSTALL_PATH"
open "$INSTALL_PATH"
for _ in $(seq 50); do pgrep -x "$APP_NAME" >/dev/null && break; sleep 0.1; done
pgrep -x "$APP_NAME" >/dev/null || fail "$APP_NAME did not launch"
echo "Installed and launched $INSTALL_PATH"
