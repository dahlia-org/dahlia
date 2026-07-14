#!/bin/bash
set -euo pipefail

CODEX_VERSION="0.144.4"
CODEX_TAG="rust-v${CODEX_VERSION}"
CODEX_COMMIT="8c68d4c87dc54d38861f5114e920c3de2efa5876"
RUST_TOOLCHAIN="1.95.0"
TARGET="aarch64-apple-darwin"
REPOSITORY="https://github.com/openai/codex.git"
UPSTREAM_CARGO_LOCK_SHA256="175793a40a3147db1fee08fd9db0acc59312c344b3513dd7ee316f5446d8119e"
NORMALIZED_CARGO_LOCK_SHA256="01b177dee91b76aa82cb1fdd67ae202794cabdbe3f71846960263433a7cdd6cc"
WORKSPACE_CRATE_COUNT=132

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="${PROJECT_DIR}/.build/codex-src"
TARGET_DIR="${PROJECT_DIR}/.build/codex-cargo"
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
    echo "codex-${CODEX_VERSION}-${CODEX_COMMIT}-rust-${RUST_TOOLCHAIN}-${TARGET}-v1"
    exit 0
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: Dahlia's bundled Codex helper is built for Apple Silicon only" >&2
    exit 1
fi

validate_output() {
    for reference in \
        "${PROJECT_DIR}/Sources/Dahlia/Services/CodexBundle.swift:static let version = \"${CODEX_VERSION}\"" \
        "${PROJECT_DIR}/Resources/Codex-NOTICE.txt:Codex CLI ${CODEX_VERSION}" \
        "${PROJECT_DIR}/README.md:Codex ${CODEX_VERSION}" \
        "${PROJECT_DIR}/README_ja.md:Codex ${CODEX_VERSION}"; do
        file="${reference%%:*}"
        expected="${reference#*:}"
        if ! grep -Fq "$expected" "$file"; then
            echo "error: ${file} does not reference bundled Codex ${CODEX_VERSION}" >&2
            exit 1
        fi
    done
    if [ ! -x "$OUTPUT_BINARY" ]; then
        echo "error: bundled Codex helper is missing: ${OUTPUT_BINARY}" >&2
        exit 1
    fi
    if [ "$(lipo -archs "$OUTPUT_BINARY")" != "arm64" ]; then
        echo "error: bundled Codex must contain only arm64" >&2
        exit 1
    fi
    if [ "$("$OUTPUT_BINARY" --version)" != "codex-cli ${CODEX_VERSION}" ]; then
        echo "error: bundled Codex must report exactly codex-cli ${CODEX_VERSION}" >&2
        exit 1
    fi
    for notice in LICENSE NOTICE.txt; do
        if [ ! -s "${OUTPUT_DIR}/${notice}" ]; then
            echo "error: bundled Codex ${notice} is missing" >&2
            exit 1
        fi
    done
}

if [ "$MODE" = "--validate-only" ]; then
    command -v lipo >/dev/null 2>&1 || {
        echo "error: required command not found: lipo" >&2
        exit 1
    }
    validate_output
    echo "=== Cached Codex helper verified: ${OUTPUT_BINARY} ==="
    exit 0
fi

for command in git cargo rustup lipo shasum sed grep; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
done

if ! cargo "+${RUST_TOOLCHAIN}" --version >/dev/null 2>&1; then
    cat >&2 <<EOF
error: Rust ${RUST_TOOLCHAIN} is required to build bundled Codex.

Install the pinned toolchain, then retry:
  rustup toolchain install ${RUST_TOOLCHAIN} --profile minimal
EOF
    exit 1
fi

mkdir -p "$(dirname "$SOURCE_DIR")" "$TARGET_DIR" "$OUTPUT_DIR"
if [ ! -d "${SOURCE_DIR}/.git" ]; then
    git clone --depth 1 --branch "$CODEX_TAG" "$REPOSITORY" "$SOURCE_DIR"
fi

ACTUAL_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$CODEX_COMMIT" ]; then
    echo "error: ${CODEX_TAG} resolved to ${ACTUAL_COMMIT}, expected ${CODEX_COMMIT}" >&2
    exit 1
fi

# The rust-v0.144.4 release commit updates workspace.package.version to 0.144.4,
# but its checked-in Cargo.lock still records the 132 workspace crates as 0.0.0.
# Cargo therefore rejects the otherwise pinned lockfile when --locked is used.
# Normalize only that known release artifact mismatch, guarded by hashes before
# and after the transformation so dependency versions and checksums cannot drift.
CARGO_LOCK="${SOURCE_DIR}/codex-rs/Cargo.lock"
CARGO_LOCK_SHA256="$(shasum -a 256 "$CARGO_LOCK" | cut -d ' ' -f 1)"
if [ "$CARGO_LOCK_SHA256" = "$UPSTREAM_CARGO_LOCK_SHA256" ]; then
    WORKSPACE_CRATES="$(grep -c '^version = "0\.0\.0"$' "$CARGO_LOCK")"
    if [ "$WORKSPACE_CRATES" -ne "$WORKSPACE_CRATE_COUNT" ]; then
        echo "error: expected ${WORKSPACE_CRATE_COUNT} unreleased workspace crates, found ${WORKSPACE_CRATES}" >&2
        exit 1
    fi

    CARGO_LOCK_TEMP="${CARGO_LOCK}.dahlia.tmp"
    sed "s/^version = \"0\\.0\\.0\"$/version = \"${CODEX_VERSION}\"/" "$CARGO_LOCK" > "$CARGO_LOCK_TEMP"
    CARGO_LOCK_NORMALIZED_SHA256="$(shasum -a 256 "$CARGO_LOCK_TEMP" | cut -d ' ' -f 1)"
    if [ "$CARGO_LOCK_NORMALIZED_SHA256" != "$NORMALIZED_CARGO_LOCK_SHA256" ]; then
        rm -f "$CARGO_LOCK_TEMP"
        echo "error: normalized Cargo.lock checksum did not match the pinned release lockfile" >&2
        exit 1
    fi
    mv "$CARGO_LOCK_TEMP" "$CARGO_LOCK"
elif [ "$CARGO_LOCK_SHA256" != "$NORMALIZED_CARGO_LOCK_SHA256" ]; then
    echo "error: Cargo.lock does not match the pinned ${CODEX_TAG} release" >&2
    exit 1
fi

if [ "$MODE" = "--prepare-only" ]; then
    echo "=== Codex source ready for Cargo cache restore: ${SOURCE_DIR} ==="
    exit 0
fi

echo "=== Building Codex ${CODEX_VERSION} (${TARGET}) ==="
(
    cd "${SOURCE_DIR}/codex-rs"
    CARGO_TARGET_DIR="$TARGET_DIR" cargo "+${RUST_TOOLCHAIN}" build \
        --locked \
        --release \
        --bin codex \
        --target "$TARGET"
)

BUILT_BINARY="${TARGET_DIR}/${TARGET}/release/codex"
if [ ! -x "$BUILT_BINARY" ]; then
    echo "error: Cargo did not produce ${BUILT_BINARY}" >&2
    exit 1
fi
if [ "$(lipo -archs "$BUILT_BINARY")" != "arm64" ]; then
    echo "error: bundled Codex must contain only arm64" >&2
    exit 1
fi
if [ "$("$BUILT_BINARY" --version)" != "codex-cli ${CODEX_VERSION}" ]; then
    echo "error: built Codex does not report exactly codex-cli ${CODEX_VERSION}" >&2
    exit 1
fi

cp "$BUILT_BINARY" "$OUTPUT_BINARY"
chmod 755 "$OUTPUT_BINARY"
cp "${SOURCE_DIR}/LICENSE" "${OUTPUT_DIR}/LICENSE"
cp "${PROJECT_DIR}/Resources/Codex-NOTICE.txt" "${OUTPUT_DIR}/NOTICE.txt"
validate_output

echo "=== Codex helper ready: ${OUTPUT_BINARY} ==="
