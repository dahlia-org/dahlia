#!/bin/bash
set -euo pipefail

APP_NAME="Dahlia"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS_PATH="${PROJECT_DIR}/Dahlia.entitlements"
CODEX_ENTITLEMENTS_PATH="${PROJECT_DIR}/CodexHelper.entitlements"

source "${SCRIPT_DIR}/common.sh"

cd "$PROJECT_DIR"

# .env.local から環境変数を読み込む（SENTRY_DSN など）
if [ -f .env.local ]; then
    set -a
    source .env.local
    set +a
fi

export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/dahlia-clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "=== Building ${APP_NAME} (debug) ==="
bash "${SCRIPT_DIR}/build-codex.sh"
CODEX_VERSION="$(bash "${SCRIPT_DIR}/build-codex.sh" --print-version)"
swift build --arch arm64

BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
HELPERS="${CONTENTS}/Helpers"
ICON_SRC="Sources/Dahlia/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
ICONSET_DIR="${CONTENTS}/Resources/AppIcon.iconset"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}"
mkdir -p "${CONTENTS}/Resources"
mkdir -p "${HELPERS}"
mkdir -p "${CONTENTS}/Resources/Licenses/Codex"

cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"
cp "${BUILD_DIR}/dahlia-mcp" "${HELPERS}/dahlia-mcp"
cp ".build/codex-helper/codex" "${HELPERS}/codex"
cp ".build/codex-helper/LICENSE" "${CONTENTS}/Resources/Licenses/Codex/LICENSE"
cp ".build/codex-helper/NOTICE.txt" "${CONTENTS}/Resources/Licenses/Codex/NOTICE.txt"
if [ "$(lipo -archs "${HELPERS}/codex")" != "arm64" ]; then
    echo "error: bundled Codex must contain only arm64" >&2
    exit 1
fi
if [ "$(lipo -archs "${HELPERS}/dahlia-mcp")" != "arm64" ]; then
    echo "error: bundled dahlia-mcp must contain only arm64" >&2
    exit 1
fi
if [ "$("${HELPERS}/codex" --version)" != "codex-cli ${CODEX_VERSION}" ]; then
    echo "error: bundled Codex must report exactly codex-cli ${CODEX_VERSION}" >&2
    exit 1
fi
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"
configure_google_calendar_plist "${CONTENTS}/Info.plist"
configure_sentry_plist "${CONTENTS}/Info.plist"

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

SIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Kazuki Matsuda (XCHHYPN52N)}"
xattr -cr "${APP_BUNDLE}" || true

SIGNED_RESOURCE_BUNDLE="${CONTENTS}/Resources/Dahlia_Dahlia.bundle"
if [ -d "$SIGNED_RESOURCE_BUNDLE" ]; then
    codesign_path "$SIGNED_RESOURCE_BUNDLE"
fi

codesign --remove-signature "${HELPERS}/codex"
codesign_path "${HELPERS}/codex" --entitlements "$CODEX_ENTITLEMENTS_PATH"
codesign --verify --strict --verbose=2 "${HELPERS}/codex"
if ! has_boolean_entitlement "${HELPERS}/codex" "com.apple.security.cs.allow-jit"; then
    echo "error: bundled Codex must allow JIT under the hardened runtime" >&2
    exit 1
fi
codesign --remove-signature "${HELPERS}/dahlia-mcp" 2>/dev/null || true
codesign_path "${HELPERS}/dahlia-mcp"
codesign --verify --strict --verbose=2 "${HELPERS}/dahlia-mcp"

if has_entitlements "$ENTITLEMENTS_PATH"; then
    codesign_path "${MACOS}/${APP_NAME}" --entitlements "$ENTITLEMENTS_PATH"
    codesign_path "${APP_BUNDLE}" --entitlements "$ENTITLEMENTS_PATH"
else
    codesign_path "${MACOS}/${APP_NAME}"
    codesign_path "${APP_BUNDLE}"
fi
if [ "$(lipo -archs "${MACOS}/${APP_NAME}")" != "arm64" ]; then
    echo "error: Dahlia.app must contain only arm64" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "=== Running ${APP_NAME} (development profile) ==="
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "${APP_BUNDLE}" >/dev/null 2>&1 || true
fi

exec env DAHLIA_RUNTIME_PROFILE=development "${MACOS}/${APP_NAME}"
