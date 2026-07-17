#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/publish-release.sh [options]
  scripts/publish-release.sh /path/to/App.app [options]
  scripts/publish-release.sh --setup-notary-profile PROFILE --apple-id APPLE_ID

With no app path, the script performs the complete release workflow: archive a
universal Release build, Developer ID-sign and upload it with Xcode, wait for
notarization, export the stapled app, create a ZIP and signed/notarized DMG,
verify them, and optionally publish a GitHub Release.

An existing notarized app path skips the archive/upload/export steps.

Release options:
  --version VERSION          Assert the configured app version.
  --build BUILD              Assert the configured build number.
  --project PATH             Xcode project (default: the sole .xcodeproj here).
  --scheme NAME              Xcode scheme (default: the project's base name).
  --configuration NAME       Build configuration (default: Release).
  --team-id ID               Override TEAM_ID or the resolved DEVELOPMENT_TEAM.
  --identity IDENTITY        Override DEVELOPER_ID_APPLICATION signing identity.
  --notary-profile PROFILE   notarytool Keychain profile for the outer DMG.
  --notary-timeout SECONDS   App notarization wait limit (default: 1800).
  --output-dir PATH          Artifact directory (default: dist).
  --publish                  Create the corresponding GitHub Release.
  --repo OWNER/REPO          GitHub repository passed to gh.
  --replace-existing-release Replace assets on an existing release tag.
  --skip-dmg-notarization    Explicitly leave the signed outer DMG unnotarized.
  --allow-dirty              Allow a source build from an uncommitted tree.
                             This cannot be combined with --publish.
  --keep-work-dir            Preserve temporary archive/export files.
  --dry-run                  Run preflight and print the resolved release plan.

Credential setup:
  --setup-notary-profile PROFILE
                             Store an app-specific password in Keychain.
  --apple-id APPLE_ID        Override APPLE_ID for credential setup. The password
                             comes from APPLE_ID_PASSWORD or a secure prompt.

Environment equivalents:
  APPLE_ID, APPLE_ID_PASSWORD, DEVELOPER_ID_APPLICATION, TEAM_ID,
  NOTARY_PROFILE, NOTARY_TIMEOUT, RELEASE_OUTPUT_DIR, GH_REPO

Legacy aliases remain supported:
  DEVELOPER_IDENTITY, DEVELOPMENT_TEAM, NOTARY_APPLE_ID

For DMG notarization, export APPLE_ID, APPLE_ID_PASSWORD, and TEAM_ID, or use a
NOTARY_PROFILE stored in Keychain. APPLE_ID_PASSWORD is never printed.

The project version and build number must already be committed. --version and
--build verify those values; they never rewrite or silently override the source.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

require_value() {
    [[ $# -gt 1 ]] || fail "$1 requires a value"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

notarytool_with_auth() {
    if [[ "$NOTARY_AUTH_MODE" == "profile" ]]; then
        xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE"
    else
        xcrun notarytool "$@" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_ID_PASSWORD" \
            --team-id "$TEAM_ID"
    fi
}

load_build_settings() {
    local status

    set +e
    BUILD_SETTINGS="$(xcodebuild "${XCODE_CONTEXT[@]}" \
        -destination 'generic/platform=macOS' \
        -showBuildSettings 2>&1)"
    status=$?
    set -e

    if [[ "$status" -ne 0 ]]; then
        printf '%s\n' "$BUILD_SETTINGS" >&2
        fail "could not resolve Xcode build settings"
    fi
}

build_setting() {
    local wanted="$1"

    awk -F ' = ' -v wanted="$wanted" -v target="$SCHEME" '
        /^Build settings for action .* and target / {
            in_target = index($0, "target " target ":") > 0
            next
        }
        !in_target { next }
        {
            key = $1
            sub(/^[[:space:]]+/, "", key)
            if (key == wanted) {
                print $2
                exit
            }
        }
    ' <<< "$BUILD_SETTINGS"
}

plist_value() {
    "$PLIST_BUDDY" -c "Print :$1" "$2"
}

resolve_source_metadata() {
    load_build_settings

    [[ -n "$TEAM_ID" ]] || TEAM_ID="$(build_setting DEVELOPMENT_TEAM)"
    VERSION="$(build_setting MARKETING_VERSION)"
    BUILD_NUMBER="$(build_setting CURRENT_PROJECT_VERSION)"
    BUNDLE_ID="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
    PRODUCT_NAME="$(build_setting PRODUCT_NAME)"

    [[ -n "$TEAM_ID" ]] || fail "DEVELOPMENT_TEAM is empty; configure Configuration/Local.xcconfig or pass --team-id"
    [[ -n "$VERSION" ]] || fail "MARKETING_VERSION could not be resolved"
    [[ -n "$BUILD_NUMBER" ]] || fail "CURRENT_PROJECT_VERSION could not be resolved"
    [[ -n "$BUNDLE_ID" ]] || fail "PRODUCT_BUNDLE_IDENTIFIER could not be resolved"
    [[ -n "$PRODUCT_NAME" ]] || fail "PRODUCT_NAME could not be resolved"
}

resolve_app_metadata() {
    local app_signature

    [[ -d "$APP_PATH" ]] || fail "app not found: $APP_PATH"
    [[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "not a macOS app bundle: $APP_PATH"

    VERSION="$(plist_value CFBundleShortVersionString "$APP_PATH/Contents/Info.plist")"
    BUILD_NUMBER="$(plist_value CFBundleVersion "$APP_PATH/Contents/Info.plist")"
    BUNDLE_ID="$(plist_value CFBundleIdentifier "$APP_PATH/Contents/Info.plist")"
    PRODUCT_NAME="$(plist_value CFBundleName "$APP_PATH/Contents/Info.plist")"

    set +e
    app_signature="$(codesign -dvvv "$APP_PATH" 2>&1)"
    local status=$?
    set -e
    [[ "$status" -eq 0 ]] || {
        printf '%s\n' "$app_signature" >&2
        fail "could not read the app signature"
    }

    if [[ -z "$TEAM_ID" ]]; then
        TEAM_ID="$(awk -F= '/^TeamIdentifier=/ { print $2; exit }' <<< "$app_signature")"
    fi
    [[ -n "$TEAM_ID" ]] || fail "could not determine the app's Developer Team ID; pass --team-id"
}

find_developer_id_identity() {
    local identities

    identities="$(security find-identity -v -p codesigning)"
    awk -v team="($TEAM_ID)" '
        index($0, "Developer ID Application:") && index($0, team) {
            quote = index($0, "\"")
            if (quote > 0) {
                rest = substr($0, quote + 1)
                end = index(rest, "\"")
                if (end > 1) {
                    print substr(rest, 1, end - 1)
                    exit
                }
            }
        }
    ' <<< "$identities"
}

ensure_release_tree() {
    local dirty

    dirty="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)"
    if [[ -n "$dirty" && ( "$PUBLISH" -eq 1 || ( "$BUILD_FROM_SOURCE" -eq 1 && "$ALLOW_DIRTY" -eq 0 ) ) ]]; then
        printf '%s\n' "$dirty" >&2
        fail "the working tree must be clean; commit changes or use --allow-dirty for a non-publishing test build"
    fi
}

prepare_github_release() {
    local branch upstream upstream_commit

    command_exists gh
    gh auth status >/dev/null || fail "authenticate first with: gh auth login -h github.com"

    branch="$(git -C "$REPO_ROOT" branch --show-current)"
    [[ -n "$branch" ]] || fail "publishing from a detached HEAD is not supported"
    upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || \
        fail "the current branch has no upstream; push it before publishing"
    HEAD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    upstream_commit="$(git -C "$REPO_ROOT" rev-parse "$upstream")"
    [[ "$HEAD_COMMIT" == "$upstream_commit" ]] || \
        fail "the current branch differs from $upstream; push or pull before publishing"

    GH_ARGS=()
    if [[ -n "$GH_REPOSITORY" ]]; then
        GH_ARGS=(--repo "$GH_REPOSITORY")
    fi

    RELEASE_EXISTS=0
    if gh release view "$TAG" ${GH_ARGS[@]+"${GH_ARGS[@]}"} >/dev/null 2>&1; then
        RELEASE_EXISTS=1
        [[ "$REPLACE_EXISTING" -eq 1 ]] || \
            fail "GitHub Release $TAG already exists; bump the version or pass --replace-existing-release"
    fi
}

verify_app() {
    local actual_version actual_build actual_bundle actual_team signature_info executable architectures

    echo "Verifying exported app..."
    codesign --verify --deep --strict --verbose=4 "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --type execute --verbose=4 "$APP_PATH"

    actual_version="$(plist_value CFBundleShortVersionString "$APP_PATH/Contents/Info.plist")"
    actual_build="$(plist_value CFBundleVersion "$APP_PATH/Contents/Info.plist")"
    actual_bundle="$(plist_value CFBundleIdentifier "$APP_PATH/Contents/Info.plist")"
    executable="$(plist_value CFBundleExecutable "$APP_PATH/Contents/Info.plist")"
    signature_info="$(codesign -dvvv "$APP_PATH" 2>&1)"
    actual_team="$(awk -F= '/^TeamIdentifier=/ { print $2; exit }' <<< "$signature_info")"
    architectures="$(lipo -archs "$APP_PATH/Contents/MacOS/$executable")"

    [[ "$actual_version" == "$VERSION" ]] || fail "exported version is $actual_version, expected $VERSION"
    [[ "$actual_build" == "$BUILD_NUMBER" ]] || fail "exported build is $actual_build, expected $BUILD_NUMBER"
    [[ "$actual_bundle" == "$BUNDLE_ID" ]] || fail "exported bundle ID is $actual_bundle, expected $BUNDLE_ID"
    [[ "$actual_team" == "$TEAM_ID" ]] || fail "exported Team ID is $actual_team, expected $TEAM_ID"
    grep -q 'flags=.*runtime' <<< "$signature_info" || fail "the exported app is missing hardened runtime"

    case " $architectures " in
        *" arm64 "*) ;;
        *) fail "the exported app is missing the arm64 architecture" ;;
    esac
    case " $architectures " in
        *" x86_64 "*) ;;
        *) fail "the exported app is missing the x86_64 architecture" ;;
    esac

    echo "Verified $PRODUCT_NAME $VERSION ($BUILD_NUMBER), $architectures."
}

wait_for_notarized_export() {
    local deadline output status elapsed

    deadline=$((SECONDS + NOTARY_TIMEOUT_SECONDS))
    echo "Waiting for Apple to notarize the app..."

    while true; do
        set +e
        output="$(xcodebuild \
            -exportNotarizedApp \
            -archivePath "$ARCHIVE_PATH" \
            -exportPath "$EXPORT_PATH" 2>&1)"
        status=$?
        set -e

        if [[ "$status" -eq 0 ]]; then
            printf '%s\n' "$output"
            return
        fi

        if grep -Eq 'processing.*not ready for distribution' <<< "$output"; then
            if [[ "$SECONDS" -ge "$deadline" ]]; then
                printf '%s\n' "$output" >&2
                fail "app notarization did not finish within ${NOTARY_TIMEOUT_SECONDS}s"
            fi
            elapsed=$((NOTARY_TIMEOUT_SECONDS - (deadline - SECONDS)))
            echo "Notarization is still processing (${elapsed}s elapsed); checking again in ${NOTARY_POLL_SECONDS}s..."
            sleep "$NOTARY_POLL_SECONDS"
            continue
        fi

        printf '%s\n' "$output" >&2
        fail "Xcode could not export the notarized app"
    done
}

cleanup() {
    set +e
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        if [[ "$KEEP_WORK_DIR" -eq 1 ]]; then
            echo "Preserved release work directory: $WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
    fi
}

CALLER_PWD="$PWD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PLIST_BUDDY=/usr/libexec/PlistBuddy

APP_PATH=""
PROJECT=""
SCHEME=""
CONFIGURATION="Release"
EXPECTED_VERSION=""
EXPECTED_BUILD=""
TEAM_ID="${TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-${DEVELOPER_IDENTITY:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-${NOTARY_APPLE_ID:-}}"
APPLE_ID_PASSWORD="${APPLE_ID_PASSWORD:-}"
NOTARY_TIMEOUT_SECONDS="${NOTARY_TIMEOUT:-1800}"
NOTARY_POLL_SECONDS=20
GH_REPOSITORY="${GH_REPO:-}"
OUT_DIR="${RELEASE_OUTPUT_DIR:-dist}"
SETUP_PROFILE=""
PUBLISH=0
REPLACE_EXISTING=0
SKIP_DMG_NOTARIZATION=0
ALLOW_DIRTY=0
KEEP_WORK_DIR=0
DRY_RUN=0
BUILD_FROM_SOURCE=1
BUILD_SETTINGS=""
WORK_DIR=""
HEAD_COMMIT=""
RELEASE_EXISTS=0
NOTARY_AUTH_MODE=""
GH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            require_value "$@"
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --build)
            require_value "$@"
            EXPECTED_BUILD="$2"
            shift 2
            ;;
        --project)
            require_value "$@"
            PROJECT="$2"
            shift 2
            ;;
        --scheme)
            require_value "$@"
            SCHEME="$2"
            shift 2
            ;;
        --configuration)
            require_value "$@"
            CONFIGURATION="$2"
            shift 2
            ;;
        --team-id)
            require_value "$@"
            TEAM_ID="$2"
            shift 2
            ;;
        --identity)
            require_value "$@"
            IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            require_value "$@"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --notary-timeout)
            require_value "$@"
            NOTARY_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --output-dir)
            require_value "$@"
            OUT_DIR="$2"
            shift 2
            ;;
        --repo)
            require_value "$@"
            GH_REPOSITORY="$2"
            shift 2
            ;;
        --publish)
            PUBLISH=1
            shift
            ;;
        --replace-existing-release)
            REPLACE_EXISTING=1
            shift
            ;;
        --skip-dmg-notarization)
            SKIP_DMG_NOTARIZATION=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --keep-work-dir)
            KEEP_WORK_DIR=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --setup-notary-profile)
            require_value "$@"
            SETUP_PROFILE="$2"
            shift 2
            ;;
        --apple-id)
            require_value "$@"
            APPLE_ID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            [[ -z "$APP_PATH" ]] || fail "only one app path may be provided"
            APP_PATH="$1"
            BUILD_FROM_SOURCE=0
            shift
            ;;
    esac
done

[[ "$NOTARY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "invalid --notary-timeout: $NOTARY_TIMEOUT_SECONDS"
[[ -z "$EXPECTED_VERSION" || "$EXPECTED_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "invalid version: $EXPECTED_VERSION"
[[ -z "$EXPECTED_BUILD" || "$EXPECTED_BUILD" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "invalid build: $EXPECTED_BUILD"
[[ "$PUBLISH" -eq 0 || "$ALLOW_DIRTY" -eq 0 ]] || fail "--allow-dirty cannot be combined with --publish"
[[ "$REPLACE_EXISTING" -eq 0 || "$PUBLISH" -eq 1 ]] || fail "--replace-existing-release requires --publish"

command_exists awk
command_exists codesign
command_exists git
command_exists security
command_exists xcodebuild
command_exists xcrun
[[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found"

if [[ -z "$PROJECT" ]]; then
    PROJECT="$(cd "$REPO_ROOT" && ls -d *.xcodeproj 2>/dev/null | head -n1 || true)"
    [[ -n "$PROJECT" ]] || fail "no .xcodeproj found in $REPO_ROOT; run 'xcodegen generate' or pass --project"
fi
[[ -n "$SCHEME" ]] || SCHEME="$(basename "${PROJECT%.xcodeproj}")"

case "$PROJECT" in
    /*) PROJECT_PATH="$PROJECT" ;;
    *) PROJECT_PATH="$REPO_ROOT/$PROJECT" ;;
esac
[[ -d "$PROJECT_PATH" ]] || fail "Xcode project not found: $PROJECT_PATH"
XCODE_CONTEXT=(-project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION")

if [[ -n "$SETUP_PROFILE" ]]; then
    [[ -z "$APP_PATH" ]] || fail "credential setup cannot be combined with an app path"
    [[ "$PUBLISH" -eq 0 ]] || fail "credential setup cannot be combined with --publish"
    [[ -n "$APPLE_ID" ]] || fail "--apple-id or APPLE_ID is required for credential setup"

    resolve_source_metadata
    [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "invalid Developer Team ID: $TEAM_ID"

    echo "Notary credential setup"
    echo "  Profile: $SETUP_PROFILE"
    echo "  Apple ID: $APPLE_ID"
    echo "  Team ID:  $TEAM_ID"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Dry run complete; no credential was stored."
        exit 0
    fi

    if [[ -n "$APPLE_ID_PASSWORD" ]]; then
        echo "Using APPLE_ID_PASSWORD from the environment."
        xcrun notarytool store-credentials "$SETUP_PROFILE" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_ID_PASSWORD" \
            --team-id "$TEAM_ID"
    else
        echo "notarytool will securely prompt for an app-specific password."
        xcrun notarytool store-credentials "$SETUP_PROFILE" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID"
    fi
    echo "Stored and validated notary profile '$SETUP_PROFILE'."
    echo "Use it with: NOTARY_PROFILE='$SETUP_PROFILE' scripts/publish-release.sh --publish"
    exit 0
fi

if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
    resolve_source_metadata
else
    case "$APP_PATH" in
        /*) ;;
        *) APP_PATH="$CALLER_PWD/$APP_PATH" ;;
    esac
    APP_PARENT="$(cd "$(dirname "$APP_PATH")" && pwd -P)" || fail "app parent directory not found"
    APP_PATH="$APP_PARENT/$(basename "$APP_PATH")"
    resolve_app_metadata
fi

[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "invalid Developer Team ID: $TEAM_ID"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "invalid configured version: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "invalid configured build: $BUILD_NUMBER"
[[ "$PRODUCT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "PRODUCT_NAME is not safe for artifact filenames: $PRODUCT_NAME"
[[ -z "$EXPECTED_VERSION" || "$EXPECTED_VERSION" == "$VERSION" ]] || \
    fail "configured version is $VERSION, expected $EXPECTED_VERSION; update and commit the Xcode project first"
[[ -z "$EXPECTED_BUILD" || "$EXPECTED_BUILD" == "$BUILD_NUMBER" ]] || \
    fail "configured build is $BUILD_NUMBER, expected $EXPECTED_BUILD; update and commit the Xcode project first"

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(find_developer_id_identity)"
fi
[[ -n "$IDENTITY" ]] || fail "no Developer ID Application identity found for Team ID $TEAM_ID"

if [[ "$SKIP_DMG_NOTARIZATION" -eq 0 ]]; then
    if [[ -n "$NOTARY_PROFILE" ]]; then
        NOTARY_AUTH_MODE="profile"
    elif [[ -n "$APPLE_ID" && -n "$APPLE_ID_PASSWORD" ]]; then
        NOTARY_AUTH_MODE="environment"
    elif [[ -n "$APPLE_ID" || -n "$APPLE_ID_PASSWORD" ]]; then
        fail "both APPLE_ID and APPLE_ID_PASSWORD are required for environment-based notarization"
    else
        fail "export APPLE_ID and APPLE_ID_PASSWORD, provide --notary-profile/NOTARY_PROFILE, or explicitly pass --skip-dmg-notarization"
    fi
fi

case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;;
esac

TAG="v$VERSION"
ensure_release_tree

if [[ "$PUBLISH" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
    prepare_github_release
fi

echo "Release plan"
if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
    echo "  Source:       $PROJECT_PATH ($SCHEME, $CONFIGURATION)"
else
    echo "  Source:       $APP_PATH (archive/upload skipped)"
fi
echo "  Product:      $PRODUCT_NAME $VERSION ($BUILD_NUMBER)"
echo "  Bundle ID:    $BUNDLE_ID"
echo "  Team ID:      $TEAM_ID"
echo "  Identity:     $IDENTITY"
echo "  Architectures: arm64 + x86_64 required"
if [[ "$SKIP_DMG_NOTARIZATION" -eq 1 ]]; then
    echo "  DMG:          signed; notarization explicitly skipped"
elif [[ "$NOTARY_AUTH_MODE" == "profile" ]]; then
    echo "  DMG:          signed and notarized with profile '$NOTARY_PROFILE'"
else
    echo "  DMG:          signed and notarized with environment credentials"
fi
echo "  Output:       $OUT_DIR"
if [[ "$PUBLISH" -eq 1 ]]; then
    echo "  GitHub:       publish $TAG${GH_REPOSITORY:+ to $GH_REPOSITORY}"
else
    echo "  GitHub:       package only"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run complete; no archive or artifacts were created."
    exit 0
fi

for command in ditto find grep hdiutil lipo mktemp plutil shasum spctl; do
    command_exists "$command"
done

if [[ "$SKIP_DMG_NOTARIZATION" -eq 0 ]]; then
    if [[ "$NOTARY_AUTH_MODE" == "profile" ]]; then
        echo "Validating notary profile '$NOTARY_PROFILE'..."
    else
        echo "Validating notarization credentials from the environment..."
    fi
    notarytool_with_auth history >/dev/null || fail "notarization credentials are unavailable or invalid"
fi

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
WORK_DIR="$(mktemp -d "$TMP_BASE/xcode-release.XXXXXX")"
trap cleanup EXIT

if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
    ARCHIVE_PATH="$WORK_DIR/$PRODUCT_NAME-$VERSION.xcarchive"
    UPLOAD_PATH="$WORK_DIR/upload"
    EXPORT_PATH="$WORK_DIR/notarized"
    EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"

    plutil -create xml1 "$EXPORT_OPTIONS"
    "$PLIST_BUDDY" -c 'Add :destination string upload' "$EXPORT_OPTIONS"
    "$PLIST_BUDDY" -c 'Add :method string developer-id' "$EXPORT_OPTIONS"
    "$PLIST_BUDDY" -c 'Add :signingCertificate string Developer ID Application' "$EXPORT_OPTIONS"
    "$PLIST_BUDDY" -c 'Add :signingStyle string automatic' "$EXPORT_OPTIONS"
    "$PLIST_BUDDY" -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS"

    echo "Archiving $PRODUCT_NAME $VERSION ($BUILD_NUMBER)..."
    xcodebuild "${XCODE_CONTEXT[@]}" \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        archive

    echo "Developer ID-signing and uploading the app to Apple..."
    xcodebuild \
        -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$UPLOAD_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates

    wait_for_notarized_export
    APP_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -type d -name '*.app' -print -quit)"
    [[ -n "$APP_PATH" && -d "$APP_PATH" ]] || fail "Xcode exported no app at $EXPORT_PATH"
fi

verify_app

mkdir -p "$OUT_DIR"
ZIP_NAME="$PRODUCT_NAME-$VERSION-macOS.zip"
DMG_NAME="$PRODUCT_NAME-$VERSION-macOS.dmg"
CHECKSUM_NAME=SHA256SUMS.txt
ZIP_PATH="$OUT_DIR/$ZIP_NAME"
DMG_PATH="$OUT_DIR/$DMG_NAME"
rm -f "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/$CHECKSUM_NAME"

echo "Creating $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

STAGING_DIR="$WORK_DIR/dmg-root"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$PRODUCT_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating $DMG_NAME..."
hdiutil create \
    -volname "$PRODUCT_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "Signing DMG with $IDENTITY..."
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=4 "$DMG_PATH"

if [[ "$SKIP_DMG_NOTARIZATION" -eq 0 ]]; then
    echo "Submitting the DMG for notarization..."
    notarytool_with_auth submit "$DMG_PATH" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
else
    echo "warning: the DMG contains a notarized app but the outer container was not submitted"
fi

(
    cd "$OUT_DIR"
    shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > "$CHECKSUM_NAME"
    shasum -a 256 -c "$CHECKSUM_NAME"
)

echo "Created:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo "  $OUT_DIR/$CHECKSUM_NAME"

if [[ "$PUBLISH" -eq 1 ]]; then
    if [[ "$RELEASE_EXISTS" -eq 1 ]]; then
        gh release upload "$TAG" \
            "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/$CHECKSUM_NAME" \
            --clobber ${GH_ARGS[@]+"${GH_ARGS[@]}"}
    else
        gh release create "$TAG" \
            "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/$CHECKSUM_NAME" \
            --target "$HEAD_COMMIT" \
            --title "$PRODUCT_NAME $VERSION" \
            --generate-notes \
            ${GH_ARGS[@]+"${GH_ARGS[@]}"}
    fi

    RELEASE_URL="$(gh release view "$TAG" ${GH_ARGS[@]+"${GH_ARGS[@]}"} --json url --jq .url)"
    echo "Published GitHub Release $TAG: $RELEASE_URL"
fi
