#!/bin/bash
set -euo pipefail

PI_VERSION="1.5.0"
ASSET_NAME="pi-darwin-arm64.tar.gz"
ASSET_SHA256="a9bf0d82d58d2a7d337f4ae4171b5fc9ebffe42509527a831364c4b65adf2cdf"
DOWNLOAD_URL="https://github.com/earendil-works/pi/releases/download/v${PI_VERSION}/${ASSET_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PI_ENTITLEMENTS_PATH="${PROJECT_DIR}/PiHelper.entitlements"
CACHE_DIR="${PROJECT_DIR}/.build/pi-download"
ARCHIVE_PATH="${CACHE_DIR}/${ASSET_NAME}"
OUTPUT_DIR="${PROJECT_DIR}/.build/pi-helper"
OUTPUT_PI_DIR="${OUTPUT_DIR}/pi"
OUTPUT_BINARY="${OUTPUT_PI_DIR}/pi"
NATIVE_MODULE="native/darwin/prebuilds/darwin-arm64/darwin-platform.node"
MODE="${1:-build}"

source "${SCRIPT_DIR}/common.sh"

case "$MODE" in
    build|--prepare-only|--validate-only|--print-cache-key|--print-version) ;;
    *)
        echo "error: usage: $0 [--prepare-only|--validate-only|--print-cache-key|--print-version]" >&2
        exit 1
        ;;
esac

if [ "$MODE" = "--print-version" ]; then
    echo "$PI_VERSION"
    exit 0
fi

if [ "$MODE" = "--print-cache-key" ]; then
    echo "pi-release-${PI_VERSION}-darwin-arm64-${ASSET_SHA256}-v1"
    exit 0
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: Dahlia's bundled Pi supports Apple Silicon only" >&2
    exit 1
fi

require_commands chmod cmp codesign file grep lipo mkdir shasum

validate_output() {
    local expected file_path reference validation_home

    for reference in \
        "${PROJECT_DIR}/apps/macos/Sources/Dahlia/Services/PiBundle.swift:static let version = \"${PI_VERSION}\"" \
        "${PROJECT_DIR}/Resources/Pi-NOTICE.txt:Pi ${PI_VERSION}" \
        "${PROJECT_DIR}/Resources/Pi-NOTICE.txt:Asset: ${ASSET_NAME}" \
        "${PROJECT_DIR}/Resources/Pi-NOTICE.txt:SHA-256: ${ASSET_SHA256}"; do
        file_path="${reference%%:*}"
        expected="${reference#*:}"
        if ! grep -Fq "$expected" "$file_path"; then
            echo "error: ${file_path} does not reference bundled Pi ${PI_VERSION}" >&2
            exit 1
        fi
    done
    case "$(file -b "$OUTPUT_BINARY")" in
        "Mach-O 64-bit executable arm64"*) ;;
        *)
            echo "error: bundled Pi is not an arm64 Mach-O executable" >&2
            exit 1
            ;;
    esac
    if [ "$(lipo -archs "$OUTPUT_BINARY")" != "arm64" ]; then
        echo "error: bundled Pi must contain only arm64" >&2
        exit 1
    fi
    if ! codesign --verify --strict "$OUTPUT_BINARY" \
        || ! has_boolean_entitlement "$OUTPUT_BINARY" "com.apple.security.cs.allow-jit"; then
        echo "error: cached Pi must allow JIT under the hardened runtime" >&2
        exit 1
    fi
    validation_home="${CACHE_DIR}/validation-home"
    mkdir -p "$validation_home"
    chmod 700 "$validation_home"
    if [ "$(PI_CODING_AGENT_DIR="$validation_home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 \
        "$OUTPUT_BINARY" --version </dev/null)" != "$PI_VERSION" ]; then
        echo "error: bundled Pi must report exactly ${PI_VERSION}" >&2
        exit 1
    fi
    if ! cmp -s "${PROJECT_DIR}/Resources/Pi-LICENSE" "${OUTPUT_DIR}/LICENSE" \
        || ! cmp -s "${PROJECT_DIR}/Resources/Pi-NOTICE.txt" "${OUTPUT_DIR}/NOTICE.txt"; then
        echo "error: bundled Pi LICENSE or NOTICE.txt is missing or outdated" >&2
        exit 1
    fi
}

if [ "$MODE" = "--validate-only" ]; then
    validate_output
    echo "=== Cached Pi verified: ${OUTPUT_BINARY} ==="
    exit 0
fi

require_commands cp curl cut mv rm tar

archive_sha256() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

mkdir -p "$CACHE_DIR"
if [ -f "$ARCHIVE_PATH" ] && [ "$(archive_sha256 "$ARCHIVE_PATH")" != "$ASSET_SHA256" ]; then
    echo "warning: discarding cached Pi archive with an invalid SHA-256" >&2
    rm -f "$ARCHIVE_PATH"
fi
if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "=== Downloading Pi ${PI_VERSION} (darwin-arm64) ==="
    rm -f "${ARCHIVE_PATH}.download"
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 \
        --output "${ARCHIVE_PATH}.download" "$DOWNLOAD_URL"
    if [ "$(archive_sha256 "${ARCHIVE_PATH}.download")" != "$ASSET_SHA256" ]; then
        rm -f "${ARCHIVE_PATH}.download"
        echo "error: downloaded Pi archive SHA-256 did not match the pinned release" >&2
        exit 1
    fi
    mv "${ARCHIVE_PATH}.download" "$ARCHIVE_PATH"
fi
if tar -tzf "$ARCHIVE_PATH" | grep -Ev '^pi/' | grep -q .; then
    echo "error: Pi release archive has an unexpected layout" >&2
    exit 1
fi

if [ "$MODE" = "--prepare-only" ]; then
    echo "=== Pi release archive cached: ${ARCHIVE_PATH} ==="
    exit 0
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$OUTPUT_DIR"
# Documentation, examples, and source maps are not needed at runtime.
rm -rf "${OUTPUT_PI_DIR}/docs" "${OUTPUT_PI_DIR}/examples" "${OUTPUT_PI_DIR}/README.md" "${OUTPUT_PI_DIR}/CHANGELOG.md"
find "${OUTPUT_PI_DIR}/export-html" \( -name '*.map' -o -name '*.d.ts' \) -delete
codesign --remove-signature "$OUTPUT_BINARY"
codesign --force --options runtime --sign - --entitlements "$PI_ENTITLEMENTS_PATH" "$OUTPUT_BINARY"
codesign --force --options runtime --sign - "${OUTPUT_PI_DIR}/${NATIVE_MODULE}"
chmod 755 "$OUTPUT_BINARY"
cp "${PROJECT_DIR}/Resources/Pi-LICENSE" "${OUTPUT_DIR}/LICENSE"
cp "${PROJECT_DIR}/Resources/Pi-NOTICE.txt" "${OUTPUT_DIR}/NOTICE.txt"

validate_output
echo "=== Pi ready: ${OUTPUT_BINARY} ==="
