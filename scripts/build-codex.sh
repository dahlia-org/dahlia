#!/bin/bash
set -euo pipefail

CODEX_VERSION="0.148.0"
TARGET="aarch64-apple-darwin"
ASSET_NAME="codex-${TARGET}.tar.gz"
ASSET_SHA256="758916aa38efa7ad076a050830fcbef1a7ed6f41efae9c1cceaeef63e428fc2b"
ARCHIVE_BINARY="codex-${TARGET}"
DOWNLOAD_URL="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/${ASSET_NAME}"
CODE_MODE_HOST_ASSET_NAME="codex-code-mode-host-${TARGET}.tar.gz"
CODE_MODE_HOST_ASSET_SHA256="10eaf562ecefee1b9f17fb609cd8f32b6f01876674555abd2ddb81962f3b5e34"
CODE_MODE_HOST_ARCHIVE_BINARY="codex-code-mode-host-${TARGET}"
CODE_MODE_HOST_DOWNLOAD_URL="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/${CODE_MODE_HOST_ASSET_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CODEX_ENTITLEMENTS_PATH="${PROJECT_DIR}/CodexHelper.entitlements"
CACHE_DIR="${PROJECT_DIR}/.build/codex-download"
ARCHIVE_PATH="${CACHE_DIR}/${ASSET_NAME}"
CODE_MODE_HOST_ARCHIVE_PATH="${CACHE_DIR}/${CODE_MODE_HOST_ASSET_NAME}"
OUTPUT_DIR="${PROJECT_DIR}/.build/codex-helper"
OUTPUT_BINARY="${OUTPUT_DIR}/codex"
OUTPUT_CODE_MODE_HOST="${OUTPUT_DIR}/codex-code-mode-host"
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
    echo "$CODEX_VERSION"
    exit 0
fi

if [ "$MODE" = "--print-cache-key" ]; then
    echo "codex-release-${CODEX_VERSION}-${TARGET}-${ASSET_SHA256}-${CODE_MODE_HOST_ASSET_SHA256}-v3"
    exit 0
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: Dahlia's bundled Codex helper supports Apple Silicon only" >&2
    exit 1
fi

require_commands chmod cmp codesign file grep lipo mkdir shasum

validate_arm64_executable() {
    local binary_path="$1"
    local label="$2"

    if [ ! -x "$binary_path" ]; then
        echo "error: bundled ${label} is missing: ${binary_path}" >&2
        return 1
    fi
    case "$(file -b "$binary_path")" in
        "Mach-O 64-bit executable arm64"*) ;;
        *)
            echo "error: bundled ${label} is not an arm64 Mach-O executable" >&2
            return 1
            ;;
    esac
    if [ "$(lipo -archs "$binary_path")" != "arm64" ]; then
        echo "error: bundled ${label} must contain only arm64" >&2
        return 1
    fi
}

validate_jit_signature() {
    local binary_path="$1"
    local label="$2"

    if ! codesign --verify --strict "$binary_path"; then
        echo "error: cached ${label} signature is invalid" >&2
        return 1
    fi
    if ! has_boolean_entitlement "$binary_path" "com.apple.security.cs.allow-jit"; then
        echo "error: cached ${label} must allow JIT under the hardened runtime" >&2
        return 1
    fi
}

validate_output() {
    local expected file_path reference validation_home

    for reference in \
        "${PROJECT_DIR}/Sources/Dahlia/Services/CodexBundle.swift:static let version = \"${CODEX_VERSION}\"" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:Codex CLI ${CODEX_VERSION}" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:Asset: ${ASSET_NAME}" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:SHA-256: ${ASSET_SHA256}" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:Code Mode Host Asset: ${CODE_MODE_HOST_ASSET_NAME}" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:Code Mode Host SHA-256: ${CODE_MODE_HOST_ASSET_SHA256}"; do
        file_path="${reference%%:*}"
        expected="${reference#*:}"
        if ! grep -Fq "$expected" "$file_path"; then
            echo "error: ${file_path} does not reference bundled Codex ${CODEX_VERSION}" >&2
            exit 1
        fi
    done
    validate_arm64_executable "$OUTPUT_BINARY" "Codex"
    validate_arm64_executable "$OUTPUT_CODE_MODE_HOST" "Codex code-mode host"
    validation_home="${CACHE_DIR}/validation-home"
    mkdir -p "$validation_home"
    chmod 700 "$validation_home"
    if [ "$(CODEX_HOME="$validation_home" "$OUTPUT_BINARY" --version)" != "codex-cli ${CODEX_VERSION}" ]; then
        echo "error: bundled Codex must report exactly codex-cli ${CODEX_VERSION}" >&2
        exit 1
    fi
    validate_jit_signature "$OUTPUT_BINARY" "Codex"
    validate_jit_signature "$OUTPUT_CODE_MODE_HOST" "Codex code-mode host"
    if ! CODEX_HOME="$validation_home" "$OUTPUT_CODE_MODE_HOST" --help >/dev/null; then
        echo "error: cached Codex code-mode host could not start" >&2
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

require_commands cp curl cut mv rm tar

archive_sha256() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

verify_archive() {
    [ -f "$1" ] && [ "$(archive_sha256 "$1")" = "$2" ]
}

cache_archive() {
    local archive_path="$1"
    local expected_sha256="$2"
    local download_url="$3"
    local label="$4"
    local temporary_path="${archive_path}.download"

    if [ -f "$archive_path" ] && ! verify_archive "$archive_path" "$expected_sha256"; then
        echo "warning: discarding cached ${label} archive with an invalid SHA-256" >&2
        rm -f "$archive_path"
    fi
    if [ -f "$archive_path" ]; then
        return
    fi

    rm -f "$temporary_path"
    echo "=== Downloading ${label} ${CODEX_VERSION} (${TARGET}) ==="
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 \
        --output "$temporary_path" "$download_url"
    if ! verify_archive "$temporary_path" "$expected_sha256"; then
        rm -f "$temporary_path"
        echo "error: downloaded ${label} archive SHA-256 did not match the pinned release" >&2
        return 1
    fi
    mv "$temporary_path" "$archive_path"
}

mkdir -p "$CACHE_DIR"
cache_archive "$ARCHIVE_PATH" "$ASSET_SHA256" "$DOWNLOAD_URL" "Codex"
cache_archive \
    "$CODE_MODE_HOST_ARCHIVE_PATH" \
    "$CODE_MODE_HOST_ASSET_SHA256" \
    "$CODE_MODE_HOST_DOWNLOAD_URL" \
    "Codex code-mode host"

if [ "$(tar -tzf "$ARCHIVE_PATH")" != "$ARCHIVE_BINARY" ]; then
    echo "error: Codex release archive has an unexpected layout" >&2
    exit 1
fi
if [ "$(tar -tzf "$CODE_MODE_HOST_ARCHIVE_PATH")" != "$CODE_MODE_HOST_ARCHIVE_BINARY" ]; then
    echo "error: Codex code-mode host release archive has an unexpected layout" >&2
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
tar -xzf "$CODE_MODE_HOST_ARCHIVE_PATH" -C "$EXTRACT_DIR"
cp "${EXTRACT_DIR}/${ARCHIVE_BINARY}" "$OUTPUT_BINARY"
cp "${EXTRACT_DIR}/${CODE_MODE_HOST_ARCHIVE_BINARY}" "$OUTPUT_CODE_MODE_HOST"
codesign --remove-signature "$OUTPUT_BINARY"
codesign --force --options runtime --sign - --entitlements "$CODEX_ENTITLEMENTS_PATH" "$OUTPUT_BINARY"
codesign --remove-signature "$OUTPUT_CODE_MODE_HOST"
codesign --force --options runtime --sign - --entitlements "$CODEX_ENTITLEMENTS_PATH" "$OUTPUT_CODE_MODE_HOST"
chmod 755 "$OUTPUT_BINARY"
chmod 755 "$OUTPUT_CODE_MODE_HOST"
cp "${PROJECT_DIR}/Resources/Codex-LICENSE" "${OUTPUT_DIR}/LICENSE"
cp "${PROJECT_DIR}/Resources/Codex-NOTICE.txt" "${OUTPUT_DIR}/NOTICE.txt"
rm -rf "$EXTRACT_DIR"

validate_output
echo "=== Codex helper ready: ${OUTPUT_BINARY} ==="
