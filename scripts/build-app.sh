#!/bin/bash
set -euo pipefail

APP_NAME="Dahlia"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS_PATH="${PROJECT_DIR}/Dahlia.entitlements"

source "${SCRIPT_DIR}/common.sh"

load_local_env() {
    if [ -f .env.local ]; then
        set -a
        source .env.local
        set +a
    fi
}

cd "$PROJECT_DIR"
load_local_env
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/dahlia-clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "=== Building ${APP_NAME} ==="
swift build -c release
dsymutil ".build/release/${APP_NAME}" -o ".build/release/${APP_NAME}.dSYM"

# .app バンドル作成
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}"
mkdir -p "${CONTENTS}/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"
configure_google_calendar_plist "${CONTENTS}/Info.plist"
configure_sentry_plist "${CONTENTS}/Info.plist"

# アイコン生成（.iconset → .icns）
ICON_SRC="Sources/Dahlia/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
ICONSET_DIR="${CONTENTS}/Resources/AppIcon.iconset"
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

# SPM リソースバンドルをコピー
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

if has_entitlements "$ENTITLEMENTS_PATH"; then
    codesign_path "${MACOS}/${APP_NAME}" --entitlements "$ENTITLEMENTS_PATH"
    codesign_path "${APP_BUNDLE}" --entitlements "$ENTITLEMENTS_PATH"
else
    codesign_path "${MACOS}/${APP_NAME}"
    codesign_path "${APP_BUNDLE}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "=== Build complete: ${APP_BUNDLE} ==="
