#!/bin/bash
set -euo pipefail

APP_NAME="Dahlia"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENTITLEMENTS_PATH="${PROJECT_DIR}/Dahlia.entitlements"
CODEX_ENTITLEMENTS_PATH="${PROJECT_DIR}/CodexHelper.entitlements"

source "${SCRIPT_DIR}/common.sh"

cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# .env.local から環境変数を読み込む（SENTRY_DSN、TELEMETRYDECK_APP_ID など）
if [ -f .env.local ]; then
    set -a
    source .env.local
    set +a
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Kazuki Matsuda (XCHHYPN52N)}"

BUILD_ONLY=false
OPEN_SETTINGS=0
RESET_QA=false
COPY_PRODUCTION=false
for argument in "$@"; do
    case "$argument" in
        --build-only) BUILD_ONLY=true ;;
        --settings) OPEN_SETTINGS=1 ;;
        --reset) RESET_QA=true ;;
        --copy-production|--copy) COPY_PRODUCTION=true ;;
        *) echo "usage: $0 [--build-only] [--settings] [--reset|--copy-production|--copy]" >&2; exit 1 ;;
    esac
done

if "$BUILD_ONLY" && { "$RESET_QA" || "$COPY_PRODUCTION"; }; then
    echo "error: --build-only cannot be combined with --reset or --copy-production" >&2
    exit 1
fi
if "$RESET_QA" && "$COPY_PRODUCTION"; then
    echo "error: --reset cannot be combined with --copy-production" >&2
    exit 1
fi

APPLICATION_SUPPORT_DIR="${DAHLIA_APPLICATION_SUPPORT_DIR:-${HOME}/Library/Application Support}"
PRODUCTION_DB="${APPLICATION_SUPPORT_DIR}/Dahlia/dahlia.sqlite"
QA_DIR="${APPLICATION_SUPPORT_DIR}/Dahlia-Development"
QA_DB="${QA_DIR}/dahlia.sqlite"

ensure_qa_is_not_running() {
    local database_file
    for database_file in "$QA_DB" "${QA_DB}-wal" "${QA_DB}-shm"; do
        if [ -e "$database_file" ] && /usr/sbin/lsof -t -- "$database_file" >/dev/null 2>&1; then
            echo "error: the development database is in use; quit Dahlia before resetting it" >&2
            return 1
        fi
    done
}

reset_qa_database() {
    ensure_qa_is_not_running || return 1
    rm -f "$QA_DB" "${QA_DB}-wal" "${QA_DB}-shm"
}

prepare_qa_database() {
    local check_result snapshot_path

    if "$RESET_QA"; then
        reset_qa_database
        return
    fi
    if ! "$COPY_PRODUCTION"; then
        return
    fi
    if [ ! -f "$PRODUCTION_DB" ]; then
        echo "error: production database not found at ${PRODUCTION_DB}" >&2
        exit 1
    fi
    snapshot_path="$(mktemp "${TMPDIR:-/tmp}/dahlia-production.XXXXXX")"
    if ! sqlite3 "$PRODUCTION_DB" ".backup '${snapshot_path}'"; then
        rm -f "$snapshot_path"
        echo "error: failed to copy the production database" >&2
        exit 1
    fi
    if ! check_result="$(sqlite3 "file:${snapshot_path}?immutable=1" 'PRAGMA quick_check;')" \
        || [ "$check_result" != "ok" ]; then
        rm -f "$snapshot_path"
        echo "error: copied production database failed quick_check" >&2
        exit 1
    fi
    if ! reset_qa_database; then
        rm -f "$snapshot_path"
        exit 1
    fi
    mkdir -p "$QA_DIR"
    mv "$snapshot_path" "$QA_DB"
}

CACHE_DIR="${PROJECT_DIR}/.build/run-dev"
mkdir -p "$CACHE_DIR"
if ! mkdir "${CACHE_DIR}/lock" 2>/dev/null; then
    echo "error: another run-dev build holds ${CACHE_DIR}/lock; remove it only if that build is no longer running" >&2
    exit 1
fi
trap 'rmdir "${CACHE_DIR}/lock"' EXIT

fingerprint() {
    python3 "${SCRIPT_DIR}/dev-build-fingerprint.py" "$@"
}

export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/dahlia-clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "=== Building ${APP_NAME} (debug) ==="
HELPER_INPUTS=(
    "${SCRIPT_DIR}/build-codex.sh" "${SCRIPT_DIR}/common.sh" "${SCRIPT_DIR}/dev-build-fingerprint.py"
    "$CODEX_ENTITLEMENTS_PATH" "Resources/Codex-LICENSE" "Resources/Codex-NOTICE.txt"
    "apps/desktop/Sources/Dahlia/Services/CodexBundle.swift" ".build/codex-helper"
)
if [ -f "${CACHE_DIR}/helper.inputs" ] \
    && [ "$(fingerprint "${HELPER_INPUTS[@]}")" = "$(cat "${CACHE_DIR}/helper.inputs")" ]; then
    bash "${SCRIPT_DIR}/build-codex.sh" --validate-only
else
    bash "${SCRIPT_DIR}/build-codex.sh"
    fingerprint "${HELPER_INPUTS[@]}" > "${CACHE_DIR}/helper.inputs"
fi
CODEX_VERSION="$(bash "${SCRIPT_DIR}/build-codex.sh" --print-version)"
# The current Swift Build engine flattens static XCFramework headers into one directory,
# so DahliaAEC3 and DahliaLindera both try to produce include/module.modulemap.
swift build --build-system native --arch arm64

BUILD_DIR="$(swift build --build-system native --arch arm64 --show-bin-path)"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
HELPERS="${CONTENTS}/Helpers"
ICON_SRC="apps/desktop/Sources/Dahlia/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
ICONSET_DIR="${CONTENTS}/Resources/AppIcon.iconset"

# ponytail: support assets share one cache; split it if resource-heavy edits become common.
SUPPORT_INPUTS=(
    "${SCRIPT_DIR}/run-dev.sh" "${SCRIPT_DIR}/common.sh" "${SCRIPT_DIR}/dev-build-fingerprint.py"
    "$ENTITLEMENTS_PATH" "$CODEX_ENTITLEMENTS_PATH" "$ICON_SRC" "Resources"
    "${BUILD_DIR}/dahlia-mcp" "${BUILD_DIR}/auth-helper" "${BUILD_DIR}/Dahlia_Dahlia.bundle"
    "${BUILD_DIR}/Dahlia_DahliaRuntimeSupport.bundle" "${BUILD_DIR}/TelemetryDeck_TelemetryDeck.bundle"
    ".build/codex-helper" ".build/artifacts/sparkle/Sparkle"
    ".build/checkouts/argmax-oss-swift/LICENSE" ".build/checkouts/argmax-oss-swift/NOTICES"
    ".build/checkouts/SwiftSDK/LICENSE" ".build/checkouts/libwebp-Xcode/LICENSE"
    ".build/checkouts/libwebp-Xcode/libwebp/COPYING" ".build/checkouts/libwebp-Xcode/libwebp/PATENTS"
    ".build/checkouts/libwebp-Xcode/libwebp/AUTHORS"
    "Vendor/DahliaLindera-LICENSE.txt" "Vendor/DahliaLindera-THIRD-PARTY-NOTICES.txt"
)
# Hash configuration without persisting its potentially secret values.
SUPPORT_FILE_FINGERPRINT="$(fingerprint "${SUPPORT_INPUTS[@]}")"
SUPPORT_FINGERPRINT="$(
    {
        printf '%s\0' "$SUPPORT_FILE_FINGERPRINT" "$SIGN_IDENTITY" "${GOOGLE_CLIENT_ID:-}" "${GOOGLE_CLIENT_SECRET:-}" \
            "${DAHLIA_CLOUD_URL:-}" "${DAHLIA_CLOUD_OAUTH_CLIENT_ID:-}" \
            "${SENTRY_DSN:-}" "${TELEMETRYDECK_APP_ID:-}"
    } | shasum -a 256
)"
APP_INPUT_FINGERPRINT="$(fingerprint "${BUILD_DIR}/${APP_NAME}")"

ensure_app_is_not_running() {
    if [ -f "${MACOS}/${APP_NAME}" ] \
        && /usr/sbin/lsof -t "${PROJECT_DIR}/${MACOS}/${APP_NAME}" >/dev/null 2>&1; then
        echo "error: this development app is running; finish recording and quit it before rebuilding" >&2
        exit 1
    fi
}

finish_build() {
    if [ "$(lipo -archs "${MACOS}/${APP_NAME}")" != "arm64" ]; then
        echo "error: Dahlia.app must contain only arm64" >&2
        exit 1
    fi
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    printf '%s\n' "$SUPPORT_FINGERPRINT" > "${CACHE_DIR}/support.inputs"
    printf '%s\n' "$APP_INPUT_FINGERPRINT" > "${CACHE_DIR}/app.inputs"
    fingerprint "$APP_BUNDLE" > "${CACHE_DIR}/app.output"
    echo "=== ${APP_NAME} ready (${SECONDS}s) ==="
    if ! "$BUILD_ONLY"; then
        prepare_qa_database
    fi
    rmdir "${CACHE_DIR}/lock"
    trap - EXIT
    if "$BUILD_ONLY"; then
        exit 0
    fi

    echo "=== Running ${APP_NAME} (development profile) ==="
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$lsregister" ]; then
        "$lsregister" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
    fi
    exec env DAHLIA_RUNTIME_PROFILE=development DAHLIA_DEV_OPEN_SETTINGS="$OPEN_SETTINGS" "${MACOS}/${APP_NAME}"
}

if [ -f "${CACHE_DIR}/support.inputs" ] && [ -f "${CACHE_DIR}/app.output" ] \
    && [ "$SUPPORT_FINGERPRINT" = "$(cat "${CACHE_DIR}/support.inputs")" ] \
    && [ "$(fingerprint "$APP_BUNDLE")" = "$(cat "${CACHE_DIR}/app.output")" ]; then
    if [ -f "${CACHE_DIR}/app.inputs" ] \
        && [ "$APP_INPUT_FINGERPRINT" = "$(cat "${CACHE_DIR}/app.inputs")" ]; then
        echo "=== Reusing signed ${APP_NAME}.app ==="
    else
        echo "=== Updating ${APP_NAME} executable; reusing signed support assets ==="
        ensure_app_is_not_running
        unlock_codesigning_keychain_if_needed
        cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"
        if has_entitlements "$ENTITLEMENTS_PATH"; then
            codesign_path "$APP_BUNDLE" --entitlements "$ENTITLEMENTS_PATH"
        else
            codesign_path "$APP_BUNDLE"
        fi
    fi
    finish_build
fi

ensure_app_is_not_running
unlock_codesigning_keychain_if_needed
echo "=== Assembling ${APP_NAME}.app ==="

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}"
mkdir -p "${CONTENTS}/Resources"
mkdir -p "${HELPERS}"
mkdir -p "${CONTENTS}/Resources/Licenses/Codex"

cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"
cp "${BUILD_DIR}/dahlia-mcp" "${HELPERS}/dahlia-mcp"
cp "${BUILD_DIR}/auth-helper" "${HELPERS}/auth-helper"
cp ".build/codex-helper/codex" "${HELPERS}/codex"
cp ".build/codex-helper/codex-code-mode-host" "${HELPERS}/codex-code-mode-host"
cp ".build/codex-helper/LICENSE" "${CONTENTS}/Resources/Licenses/Codex/LICENSE"
cp ".build/codex-helper/NOTICE.txt" "${CONTENTS}/Resources/Licenses/Codex/NOTICE.txt"
if [ "$(lipo -archs "${HELPERS}/codex")" != "arm64" ]; then
    echo "error: bundled Codex must contain only arm64" >&2
    exit 1
fi
if [ "$(lipo -archs "${HELPERS}/codex-code-mode-host")" != "arm64" ]; then
    echo "error: bundled Codex code-mode host must contain only arm64" >&2
    exit 1
fi
if [ "$(lipo -archs "${HELPERS}/dahlia-mcp")" != "arm64" ]; then
    echo "error: bundled dahlia-mcp must contain only arm64" >&2
    exit 1
fi
if [ "$(lipo -archs "${HELPERS}/auth-helper")" != "arm64" ]; then
    echo "error: bundled auth-helper must contain only arm64" >&2
    exit 1
fi
if [ "$("${HELPERS}/codex" --version)" != "codex-cli ${CODEX_VERSION}" ]; then
    echo "error: bundled Codex must report exactly codex-cli ${CODEX_VERSION}" >&2
    exit 1
fi
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"
cp -R "Resources/en.lproj" "Resources/ja.lproj" "${CONTENTS}/Resources/"
configure_google_calendar_plist "${CONTENTS}/Info.plist"
configure_dahlia_cloud_plist "${CONTENTS}/Info.plist"
configure_sentry_plist "${CONTENTS}/Info.plist"
configure_telemetrydeck_plist "${CONTENTS}/Info.plist"

mkdir -p "$ICONSET_DIR"
sips -z 16 16     "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null
sips -z 64 64     "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null
sips -z 128 128   "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null
sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null
iconutil -c icns "$ICONSET_DIR" -o "${CONTENTS}/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

RESOURCE_BUNDLE="${BUILD_DIR}/Dahlia_Dahlia.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "${CONTENTS}/Resources/"
fi
cp -R "${BUILD_DIR}/Dahlia_DahliaRuntimeSupport.bundle" "${CONTENTS}/Resources/"
embed_sparkle_framework "$PROJECT_DIR" "$CONTENTS"
embed_whisperkit_licenses "$PROJECT_DIR" "$CONTENTS"
embed_lindera_licenses "$PROJECT_DIR" "$CONTENTS"
embed_webp_licenses "$PROJECT_DIR" "$CONTENTS"
embed_telemetrydeck_resources "$PROJECT_DIR" "$BUILD_DIR" "$CONTENTS"

xattr -cr "${APP_BUNDLE}" || true

SIGNED_RESOURCE_BUNDLE="${CONTENTS}/Resources/Dahlia_Dahlia.bundle"
if [ -d "$SIGNED_RESOURCE_BUNDLE" ]; then
    codesign_path "$SIGNED_RESOURCE_BUNDLE"
fi
codesign_path "${CONTENTS}/Resources/Dahlia_DahliaRuntimeSupport.bundle"
codesign_sparkle_framework "${CONTENTS}/Frameworks/Sparkle.framework"

codesign --remove-signature "${HELPERS}/codex"
codesign_path "${HELPERS}/codex" --entitlements "$CODEX_ENTITLEMENTS_PATH"
codesign --verify --strict --verbose=2 "${HELPERS}/codex"
if ! has_boolean_entitlement "${HELPERS}/codex" "com.apple.security.cs.allow-jit"; then
    echo "error: bundled Codex must allow JIT under the hardened runtime" >&2
    exit 1
fi
codesign --remove-signature "${HELPERS}/codex-code-mode-host"
codesign_path "${HELPERS}/codex-code-mode-host" --entitlements "$CODEX_ENTITLEMENTS_PATH"
codesign --verify --strict --verbose=2 "${HELPERS}/codex-code-mode-host"
if ! has_boolean_entitlement "${HELPERS}/codex-code-mode-host" "com.apple.security.cs.allow-jit"; then
    echo "error: bundled Codex code-mode host must allow JIT under the hardened runtime" >&2
    exit 1
fi
codesign --remove-signature "${HELPERS}/dahlia-mcp" 2>/dev/null || true
codesign --remove-signature "${HELPERS}/auth-helper" 2>/dev/null || true
codesign_path "${HELPERS}/dahlia-mcp"
codesign_path "${HELPERS}/auth-helper"
codesign --verify --strict --verbose=2 "${HELPERS}/dahlia-mcp"
codesign --verify --strict --verbose=2 "${HELPERS}/auth-helper"

if has_entitlements "$ENTITLEMENTS_PATH"; then
    codesign_path "${MACOS}/${APP_NAME}" --entitlements "$ENTITLEMENTS_PATH"
    codesign_path "${APP_BUNDLE}" --entitlements "$ENTITLEMENTS_PATH"
else
    codesign_path "${MACOS}/${APP_NAME}"
    codesign_path "${APP_BUNDLE}"
fi
finish_build
