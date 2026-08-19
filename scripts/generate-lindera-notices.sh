#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="${PROJECT_DIR}/Vendor/DahliaLinderaSources"
OUTPUT_PATH="${PROJECT_DIR}/Vendor/DahliaLindera-THIRD-PARTY-NOTICES.txt"
TEMPORARY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dahlia-lindera-notices.XXXXXX")"
trap 'rm -rf "$TEMPORARY_DIR"' EXIT

cargo metadata \
    --manifest-path "${SOURCE_DIR}/Cargo.toml" \
    --locked \
    --offline \
    --filter-platform aarch64-apple-darwin \
    --format-version 1 > "${TEMPORARY_DIR}/metadata.json"
cargo tree \
    --manifest-path "${SOURCE_DIR}/Cargo.toml" \
    --locked \
    --offline \
    --target aarch64-apple-darwin \
    --edges normal,build \
    --prefix none \
    --format '{p}' \
    | sed -E 's/ \(\*\)$//; s/ \(proc-macro\)$//; s/ \([^)]*\)$//' \
    | LC_ALL=C sort -u > "${TEMPORARY_DIR}/packages.txt"

{
    printf '%s\n\n' \
        'DahliaLindera Rust third-party notices' \
        'Generated from Vendor/DahliaLinderaSources/Cargo.lock by scripts/generate-lindera-notices.sh.'

    jq -r '
        .packages[]
        | select(.source != null)
        | [.name, .version, .manifest_path, (.license // ""), (.license_file // "")]
        | @tsv
    ' "${TEMPORARY_DIR}/metadata.json" | LC_ALL=C sort | while IFS=$'\t' read -r name version manifest license license_file; do
        if ! grep -Fxq "${name} v${version}" "${TEMPORARY_DIR}/packages.txt"; then
            continue
        fi
        package_dir="$(dirname "$manifest")"
        printf '%s\n' '================================================================================'
        printf '%s %s\n' "$name" "$version"
        if [ -n "$license" ]; then
            printf 'Declared license: %s\n' "$license"
        fi
        printf '\n'

        notice_paths=()
        notice_count=0
        supplemental_notice="${SOURCE_DIR}/licenses/${name}-${version}-LICENSE.txt"
        if [ -f "$supplemental_notice" ]; then
            notice_paths+=("$supplemental_notice")
            notice_count=1
        elif [ -n "$license_file" ]; then
            notice_paths+=("${package_dir}/${license_file}")
            notice_count=1
        else
            while IFS= read -r notice_path; do
                notice_paths+=("$notice_path")
                notice_count=$((notice_count + 1))
            done < <(find "$package_dir" -maxdepth 1 -type f \
                \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) \
                | LC_ALL=C sort)
        fi
        if [ "$notice_count" -eq 0 ]; then
            if [ "$license" != "CC0-1.0" ]; then
                echo "error: no distributable license text found for ${name} ${version}" >&2
                exit 1
            fi
            printf '%s\n' 'The published crate contains no separate notice file.'
        fi
        if [ "$notice_count" -gt 0 ]; then
            for notice_path in "${notice_paths[@]}"; do
                if [ ! -f "$notice_path" ]; then
                    echo "error: missing license notice for ${name} ${version}: ${notice_path}" >&2
                    exit 1
                fi
                printf '%s\n' "--- $(basename "$notice_path") ---"
                sed -e '$a\' "$notice_path"
            done
        fi
        printf '\n'
    done
} > "${TEMPORARY_DIR}/notices.txt"

mv "${TEMPORARY_DIR}/notices.txt" "$OUTPUT_PATH"
