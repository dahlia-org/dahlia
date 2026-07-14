#!/bin/bash
set -euo pipefail

CODEX_VERSION="0.144.4"
TARGET="aarch64-apple-darwin"
ASSET_NAME="codex-${TARGET}.tar.gz"
ASSET_SHA256="77c8969a481302f9db1d9ea2a6c21c083abae3f1a8fc8a7275dc38323699391e"
ARCHIVE_BINARY="codex-${TARGET}"
DOWNLOAD_URL="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/${ASSET_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.build/codex-download"
ARCHIVE_PATH="${CACHE_DIR}/${ASSET_NAME}"
OUTPUT_DIR="${PROJECT_DIR}/.build/codex-helper"
OUTPUT_BINARY="${OUTPUT_DIR}/codex"
MODE="${1:-build}"

case "$MODE" in
    build|--prepare-only|--validate-only|--print-cache-key|--print-version) ;;
    *)
        echo "error: usage: $0 [--prepare-only|--validate-only|--print-cache-key|--print-version]" >&2
        exit 1
        ;;
esac

if [ "$MODE" = "--print-version" ]; then
    echo "$CODEX_VERSION"
    exit 0
fi

if [ "$MODE" = "--print-cache-key" ]; then
    echo "codex-release-${CODEX_VERSION}-${TARGET}-${ASSET_SHA256}-v1"
    exit 0
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: Dahlia's bundled Codex helper supports Apple Silicon only" >&2
    exit 1
fi

for command in chmod cmp codesign file grep lipo mkdir shasum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
done

validate_output() {
    local expected file_path reference validation_home

    for reference in \
        "${PROJECT_DIR}/Sources/Dahlia/Services/CodexBundle.swift:static let version = \"${CODEX_VERSION}\"" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:Codex CLI ${CODEX_VERSION}" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:Asset: ${ASSET_NAME}" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:SHA-256: ${ASSET_SHA256}" \
        "${PROJECT_DIR}/README.md:Codex ${CODEX_VERSION}" \
        "${PROJECT_DIR}/README_ja.md:Codex ${CODEX_VERSION}"; do
        file_path="${reference%%:*}"
        expected="${reference#*:}"
        if ! grep -Fq "$expected" "$file_path"; then
            echo "error: ${file_path} does not reference bundled Codex ${CODEX_VERSION}" >&2
            exit 1
        fi
    done
    if [ ! -x "$OUTPUT_BINARY" ]; then
        echo "error: bundled Codex helper is missing: ${OUTPUT_BINARY}" >&2
        exit 1
    fi
    case "$(file -b "$OUTPUT_BINARY")" in
        "Mach-O 64-bit executable arm64"*) ;;
        *)
            echo "error: bundled Codex is not an arm64 Mach-O executable" >&2
            exit 1
            ;;
    esac
    if [ "$(lipo -archs "$OUTPUT_BINARY")" != "arm64" ]; then
        echo "error: bundled Codex must contain only arm64" >&2
        exit 1
    fi
    validation_home="${CACHE_DIR}/validation-home"
    mkdir -p "$validation_home"
    chmod 700 "$validation_home"
    if [ "$(CODEX_HOME="$validation_home" "$OUTPUT_BINARY" --version)" != "codex-cli ${CODEX_VERSION}" ]; then
        echo "error: bundled Codex must report exactly codex-cli ${CODEX_VERSION}" >&2
        exit 1
    fi
    if ! codesign --verify --strict "$OUTPUT_BINARY"; then
        echo "error: cached Codex validation signature is invalid" >&2
        exit 1
    fi
    if ! cmp -s "${PROJECT_DIR}/Resources/Codex-LICENSE" "${OUTPUT_DIR}/LICENSE"; then
        echo "error: bundled Codex LICENSE is missing or outdated" >&2
        exit 1
    fi
    if ! cmp -s "${PROJECT_DIR}/Resources/Codex-NOTICE.txt" "${OUTPUT_DIR}/NOTICE.txt"; then
        echo "error: bundled Codex NOTICE.txt is missing or outdated" >&2
        exit 1
    fi
}

if [ "$MODE" = "--validate-only" ]; then
    validate_output
    echo "=== Cached Codex helper verified: ${OUTPUT_BINARY} ==="
    exit 0
fi

for command in cp curl cut mv rm tar; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
done

archive_sha256() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

verify_archive() {
    [ -f "$ARCHIVE_PATH" ] && [ "$(archive_sha256 "$ARCHIVE_PATH")" = "$ASSET_SHA256" ]
}

mkdir -p "$CACHE_DIR"
if [ -f "$ARCHIVE_PATH" ] && ! verify_archive; then
    echo "warning: discarding cached Codex archive with an invalid SHA-256" >&2
    rm -f "$ARCHIVE_PATH"
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
    TEMP_ARCHIVE="${ARCHIVE_PATH}.download"
    rm -f "$TEMP_ARCHIVE"
    echo "=== Downloading Codex ${CODEX_VERSION} (${TARGET}) ==="
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 \
        --output "$TEMP_ARCHIVE" "$DOWNLOAD_URL"
    if [ "$(archive_sha256 "$TEMP_ARCHIVE")" != "$ASSET_SHA256" ]; then
        rm -f "$TEMP_ARCHIVE"
        echo "error: downloaded Codex archive SHA-256 did not match the pinned release" >&2
        exit 1
    fi
    mv "$TEMP_ARCHIVE" "$ARCHIVE_PATH"
fi

if [ "$(tar -tzf "$ARCHIVE_PATH")" != "$ARCHIVE_BINARY" ]; then
    echo "error: Codex release archive has an unexpected layout" >&2
    exit 1
fi

if [ "$MODE" = "--prepare-only" ]; then
    echo "=== Codex release archive cached: ${ARCHIVE_PATH} ==="
    exit 0
fi

EXTRACT_DIR="${CACHE_DIR}/extracted-${CODEX_VERSION}-${TARGET}"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR" "$OUTPUT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
cp "${EXTRACT_DIR}/${ARCHIVE_BINARY}" "$OUTPUT_BINARY"
codesign --remove-signature "$OUTPUT_BINARY"
codesign --force --sign - "$OUTPUT_BINARY"
chmod 755 "$OUTPUT_BINARY"
cp "${PROJECT_DIR}/Resources/Codex-LICENSE" "${OUTPUT_DIR}/LICENSE"
cp "${PROJECT_DIR}/Resources/Codex-NOTICE.txt" "${OUTPUT_DIR}/NOTICE.txt"
rm -rf "$EXTRACT_DIR"

validate_output
echo "=== Codex helper ready: ${OUTPUT_BINARY} ==="
