#!/bin/bash
set -euo pipefail

APP_NAME="Dahlia"
INVOCATION_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFO_PLIST="${PROJECT_DIR}/Resources/Info.plist"

source "${SCRIPT_DIR}/common.sh"

GENERATED_NOTES_FILE=""
DMG_MOUNT_DIR=""

cleanup() {
    if [ -n "$DMG_MOUNT_DIR" ]; then
        hdiutil detach "$DMG_MOUNT_DIR" >/dev/null 2>&1 || true
        rmdir "$DMG_MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    if [ -n "$GENERATED_NOTES_FILE" ]; then
        rm -f "$GENERATED_NOTES_FILE"
    fi
}

trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $0 [--notes-file path] [path-to-dmg]

Create the GitHub Release for the version in Resources/Info.plist and attach
its signed and notarized DMG. The default path is Dahlia.dmg. By default,
Codex uses \$generate-release-notes to write human-friendly release notes.
Pass --notes-file to publish reviewed Markdown instead.
EOF
}

read_remote_tag_commit() {
    local tag_name="$1"
    local refs
    local direct_commit=""
    local peeled_commit=""
    local object_id
    local ref_name

    refs="$(git ls-remote --tags origin "refs/tags/${tag_name}" "refs/tags/${tag_name}^{}")"
    while IFS=$'\t' read -r object_id ref_name; do
        if [ -z "$object_id" ]; then
            continue
        fi

        case "$ref_name" in
            *"^{}") peeled_commit="$object_id" ;;
            *) direct_commit="$object_id" ;;
        esac
    done <<< "$refs"

    printf '%s\n' "${peeled_commit:-$direct_commit}"
}

validate_dmg_version() {
    local expected_version="$1"
    local app_info_plist
    local dmg_version

    DMG_MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dahlia-release-mount.XXXXXX")"
    hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT_DIR" "$DMG_PATH" >/dev/null

    app_info_plist="${DMG_MOUNT_DIR}/${APP_NAME}.app/Contents/Info.plist"
    dmg_version="$(read_marketing_version "$app_info_plist")"

    hdiutil detach "$DMG_MOUNT_DIR" >/dev/null
    rmdir "$DMG_MOUNT_DIR"
    DMG_MOUNT_DIR=""

    if [ "$dmg_version" != "$expected_version" ]; then
        echo "error: DMG contains ${APP_NAME} ${dmg_version}, expected ${expected_version}" >&2
        exit 1
    fi
}

has_release_notes() {
    local notes_file="$1"

    [ -s "$notes_file" ] && grep -q '[^[:space:]]' "$notes_file"
}

NOTES_FILE=""
DMG_ARGUMENT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --notes-file)
            if [ $# -lt 2 ]; then
                echo "error: --notes-file requires a path" >&2
                exit 1
            fi
            if [ -n "$NOTES_FILE" ]; then
                echo "error: --notes-file may only be specified once" >&2
                exit 1
            fi
            NOTES_FILE="$2"
            shift 2
            ;;
        --notes-file=*)
            if [ -n "$NOTES_FILE" ]; then
                echo "error: --notes-file may only be specified once" >&2
                exit 1
            fi
            NOTES_FILE="${1#*=}"
            if [ -z "$NOTES_FILE" ]; then
                echo "error: --notes-file requires a path" >&2
                exit 1
            fi
            shift
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [ -n "$DMG_ARGUMENT" ]; then
                echo "error: only one DMG path may be provided" >&2
                usage >&2
                exit 1
            fi
            DMG_ARGUMENT="$1"
            shift
            ;;
    esac
done

cd "$PROJECT_DIR"

require_commands codesign gh git hdiutil xcrun
if [ -z "$NOTES_FILE" ]; then
    require_commands codex shasum
fi

MARKETING_VERSION="$(read_marketing_version "$INFO_PLIST")"
TAG_NAME="v${MARKETING_VERSION}"
EXPECTED_DMG_NAME="${APP_NAME}.dmg"
case "$DMG_ARGUMENT" in
    "") DMG_PATH="${PROJECT_DIR}/${EXPECTED_DMG_NAME}" ;;
    /*) DMG_PATH="$DMG_ARGUMENT" ;;
    *) DMG_PATH="${INVOCATION_DIR}/${DMG_ARGUMENT}" ;;
esac

if [ -n "$NOTES_FILE" ]; then
    case "$NOTES_FILE" in
        /*) ;;
        *) NOTES_FILE="${INVOCATION_DIR}/${NOTES_FILE}" ;;
    esac

    if ! has_release_notes "$NOTES_FILE"; then
        echo "error: release notes file is missing or empty: ${NOTES_FILE}" >&2
        exit 1
    fi
fi

if [ ! -f "$DMG_PATH" ]; then
    cat >&2 <<EOF
error: release DMG not found: ${DMG_PATH}

Create and notarize it first with:
  ./scripts/notarize.sh
EOF
    exit 1
fi

if [ "$(basename "$DMG_PATH")" != "$EXPECTED_DMG_NAME" ]; then
    echo "error: release DMG filename must be: ${EXPECTED_DMG_NAME}" >&2
    exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    cat >&2 <<EOF
error: the Git working tree must be clean before creating a release.

Commit or stash all changes, then rebuild and notarize the DMG.
EOF
    exit 1
fi

echo "=== Validating release asset ==="
hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
validate_dmg_version "$MARKETING_VERSION"

DMG_CHECKSUM=""
if [ -z "$NOTES_FILE" ]; then
    DMG_CHECKSUM="$(shasum -a 256 "$DMG_PATH")"
fi

gh auth status >/dev/null
git remote get-url origin >/dev/null

HEAD_COMMIT="$(git rev-parse HEAD)"
LOCAL_TAG_COMMIT="$(git rev-parse -q --verify "refs/tags/${TAG_NAME}^{}" || true)"
REMOTE_TAG_COMMIT="$(read_remote_tag_commit "$TAG_NAME")"

if [ -n "$LOCAL_TAG_COMMIT" ] && [ "$LOCAL_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "error: local ${TAG_NAME} points to ${LOCAL_TAG_COMMIT}, not ${HEAD_COMMIT}" >&2
    exit 1
fi

if ! gh api "repos/{owner}/{repo}/commits/${HEAD_COMMIT}" --silent; then
    echo "error: current commit ${HEAD_COMMIT} is not available on GitHub; push it first" >&2
    exit 1
fi

if [ -n "$REMOTE_TAG_COMMIT" ] && [ "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "error: ${TAG_NAME} already points to ${REMOTE_TAG_COMMIT}, not ${HEAD_COMMIT}" >&2
    exit 1
fi

if [ -n "$REMOTE_TAG_COMMIT" ]; then
    RELEASE_TARGET_ARGS=(--verify-tag)
else
    RELEASE_TARGET_ARGS=(--target "$HEAD_COMMIT")
fi

if [ -z "$NOTES_FILE" ]; then
    GENERATED_NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/dahlia-release-notes.XXXXXX")"
    NOTES_FILE="$GENERATED_NOTES_FILE"

    echo "=== Generating release notes with Codex ==="
    codex exec \
        --cd "$PROJECT_DIR" \
        --sandbox danger-full-access \
        --ignore-user-config \
        --model gpt-5.6-terra \
        --config 'approval_policy="untrusted"' \
        --config 'model_reasoning_effort="medium"' \
        --config 'web_search="disabled"' \
        --ephemeral \
        --color never \
        --output-last-message "$NOTES_FILE" \
        "Use \$generate-release-notes to draft the GitHub Release notes for ${TAG_NAME}. Inspect the repository and return only the final Markdown. Do not modify files, use the network or MCP tools, or change any external state."

    if ! has_release_notes "$NOTES_FILE"; then
        echo "error: Codex did not generate release notes" >&2
        exit 1
    fi

    if [ "$(shasum -a 256 "$DMG_PATH")" != "$DMG_CHECKSUM" ]; then
        echo "error: release DMG changed while Codex generated release notes; refusing to publish" >&2
        exit 1
    fi

    if [ "$(git rev-parse HEAD)" != "$HEAD_COMMIT" ] || [ -n "$(git status --porcelain --untracked-files=all)" ]; then
        echo "error: Codex changed the repository while generating release notes; refusing to publish" >&2
        exit 1
    fi
fi

echo "=== Release notes ==="
sed 's/^/  /' "$NOTES_FILE"

echo "=== Creating GitHub Release ${TAG_NAME} ==="
gh release create \
    "$TAG_NAME" \
    "$DMG_PATH" \
    --title "${APP_NAME} ${MARKETING_VERSION}" \
    --notes-file "$NOTES_FILE" \
    "${RELEASE_TARGET_ARGS[@]}"

echo "=== GitHub Release complete: ${TAG_NAME} ==="
