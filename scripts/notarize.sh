#!/bin/bash
set -euo pipefail

APP_NAME="Dahlia"
DMG_NAME="${APP_NAME}.dmg"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
STAGING_DIR=""

source "${SCRIPT_DIR}/common.sh"

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf "$STAGING_DIR"
    fi
}

trap cleanup EXIT

check_notary_profile() {
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        cat >&2 <<EOF
error: notarytool keychain profile '${NOTARY_PROFILE}' is not available.

Create it once with:
  xcrun notarytool store-credentials "${NOTARY_PROFILE}" \\
    --apple-id "YOUR_APPLE_ID" \\
    --team-id "YOUR_TEAM_ID" \\
    --password "APP_SPECIFIC_PASSWORD"
EOF
        exit 1
    fi
}

cd "$PROJECT_DIR"

if [ -f .env.local ]; then
    set -a
    source .env.local
    set +a
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-dahlia-notary}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Kazuki Matsuda (XCHHYPN52N)}"

require_commands xcrun codesign ditto hdiutil spctl

check_notary_profile

echo "=== Building signed app ==="
"${SCRIPT_DIR}/build-app.sh"

echo "=== Verifying signature ==="
codesign -dvvv --entitlements - --xml "$APP_BUNDLE"

DMG_PATH="${DMG_PATH:-${PROJECT_DIR}/${DMG_NAME}}"
if [ "$(basename "$DMG_PATH")" != "$DMG_NAME" ]; then
    echo "error: release DMG filename must be: ${DMG_NAME}" >&2
    exit 1
fi

echo "=== Creating signed DMG: $(basename "$DMG_PATH") ==="
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dahlia-dmg.XXXXXX")"
ditto "$APP_BUNDLE" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "=== Submitting for notarization ==="
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "=== Stapling notarization ticket ==="
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "=== Verifying notarized DMG ==="
hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"

if [ -n "${SENTRY_DSN:-}" ]; then
    echo "=== Uploading release dSYM to Sentry ==="
    "${SCRIPT_DIR}/upload-dsyms.sh" "${PROJECT_DIR}/.build/release" "$APP_NAME"
else
    echo "=== Skipping Sentry dSYM upload: SENTRY_DSN is not configured ==="
fi

echo "=== Notarization complete: ${DMG_PATH} ==="
