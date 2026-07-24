#!/usr/bin/env bash
# Build the working tree and install the app to /Applications.
#
# Encapsulates the fragile parts of a dev install so they happen the same
# way every time: manual Developer ID signing (ad-hoc and personal-team
# development certs are refused registration in the Accessibility pane, and
# an unstable signature strands TCC grants), designated-requirement
# comparison so TCC records are reset only when the signature actually
# changes, and a staged atomic replace so a half-copied bundle is never live.
#
# Works in any wvlen macapps repo: the app name comes from the repo's sole
# .xcodeproj (generated from project.yml when needed) and the bundle ID from
# the built app's Info.plist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd -P)"
cd "$REPO_ROOT"

fail() { echo "try-it: $*" >&2; exit 1; }

# All wvlen apps sign with the wvlen LLC Developer ID team. A repo can
# override via DEVELOPMENT_TEAM in Configuration/*.xcconfig or project.yml.
DEFAULT_TEAM="93W5N4LQL7"
# `|| true` keeps set -e/pipefail from killing the script when a repo lacks
# project.yml or xcconfig files — the fallback team covers that case.
TEAM_ID="$({ grep -h "DEVELOPMENT_TEAM" Configuration/*.xcconfig project.yml 2>/dev/null || true; } \
    | head -1 | sed 's/.*[=:][[:space:]]*//' | tr -d '";' | tr -d '[:space:]')"
TEAM_ID="${TEAM_ID:-$DEFAULT_TEAM}"

# nix-darwin exports a C toolchain (LD, CC, SDKROOT, nix DEVELOPER_DIR) that
# breaks xcodebuild link steps; run it in a scrubbed environment.
xcb() {
    env -i \
        HOME="$HOME" \
        USER="$USER" \
        LOGNAME="${LOGNAME:-$USER}" \
        TERM="${TERM:-xterm-256color}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        xcodebuild "$@"
}

shopt -s nullglob
projects=( *.xcodeproj )
if [[ -f project.yml && ( ${#projects[@]} -eq 0 || project.yml -nt "${projects[0]}/project.pbxproj" ) ]]; then
    echo "Generating Xcode project from project.yml..."
    if command -v mise >/dev/null && [[ -f mise.toml ]]; then
        mise exec -- xcodegen generate
    else
        xcodegen generate
    fi
    projects=( *.xcodeproj )
fi
[[ ${#projects[@]} -eq 1 ]] || fail "expected exactly one .xcodeproj in $REPO_ROOT, found ${#projects[@]}"
APP_NAME="$(basename "${projects[0]}" .xcodeproj)"
BUILT_APP="build/Build/Products/Release/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

echo "Building $APP_NAME (Release, Developer ID, team $TEAM_ID)..."
# Explicit template keeps mktemp portable across BSD and GNU (nix) variants.
build_log="$(mktemp "${TMPDIR:-/tmp}/try-it-build.XXXXXX")"
# The team is passed explicitly: SPM package targets do not inherit
# Configuration/Local.xcconfig, and manual signing without a team fails on
# their resource bundles.
xcb -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath build build \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
    "CODE_SIGN_IDENTITY=Developer ID Application" \
    "OTHER_CODE_SIGN_FLAGS=--timestamp" >"$build_log" 2>&1 \
    || { tail -40 "$build_log" >&2; fail "build failed; installed copy left untouched (full log: $build_log)"; }

[[ -d "$BUILT_APP" ]] || fail "no app produced at $BUILT_APP"
signing_info="$(codesign -dvvv "$BUILT_APP" 2>&1)"
grep -q "^Authority=Developer ID Application" <<<"$signing_info" \
    || fail "build is not Developer ID signed; the Accessibility pane would refuse to register it"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$BUILT_APP/Contents/Info.plist")"

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
    # SIGTERM can wedge an instance half-exited (stuck in an at-exit
    # barrier) where it still owns its socket but never answers.
    if pgrep -x "$APP_NAME" >/dev/null; then
        pkill -9 -x "$APP_NAME" || true
        sleep 1
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
    for service in Accessibility PostEvent Microphone ScreenCapture; do
        tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    echo "Re-grant the app's permissions in System Settings → Privacy & Security (add with + if unlisted)."
fi

codesign --verify --strict "$INSTALL_PATH"
open "$INSTALL_PATH"
for _ in $(seq 50); do pgrep -x "$APP_NAME" >/dev/null && break; sleep 0.1; done
pgrep -x "$APP_NAME" >/dev/null || fail "$APP_NAME did not launch"
echo "Installed and launched $INSTALL_PATH"
