#!/bin/bash
set -euo pipefail

APP_NAME="Dahlia"
RELEASE_REPOSITORY="dahlia-org/dahlia"
INVOCATION_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFO_PLIST="${PROJECT_DIR}/Resources/Info.plist"

source "${SCRIPT_DIR}/common.sh"

GENERATED_NOTES_FILE=""
DMG_MOUNT_DIR=""
SPARKLE_RELEASE_DIR=""
PREVIOUS_RELEASE_INFO_PLIST=""
DMG_BUILD_VERSION=""
DMG_SPARKLE_FEED_URL=""
DMG_SPARKLE_PUBLIC_KEY=""
DMG_SPARKLE_REQUIRES_SIGNED_FEED=""
DMG_SPARKLE_VERIFIES_BEFORE_EXTRACTION=""
DMG_SPARKLE_AUTOMATIC_CHECKS=""
DMG_SPARKLE_CHECK_INTERVAL=""
DMG_SPARKLE_AUTOMATIC_UPDATES=""

cleanup() {
    if [ -n "$DMG_MOUNT_DIR" ]; then
        hdiutil detach "$DMG_MOUNT_DIR" >/dev/null 2>&1 || true
        rmdir "$DMG_MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    if [ -n "$GENERATED_NOTES_FILE" ]; then
        rm -f "$GENERATED_NOTES_FILE"
    fi
    if [ -n "$SPARKLE_RELEASE_DIR" ]; then
        rm -rf "$SPARKLE_RELEASE_DIR"
    fi
    if [ -n "$PREVIOUS_RELEASE_INFO_PLIST" ]; then
        rm -f "$PREVIOUS_RELEASE_INFO_PLIST"
    fi
}

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

validate_dmg_versions() {
    local expected_marketing_version="$1"
    local expected_build_version="$2"
    local app_info_plist
    local dmg_marketing_version

    DMG_MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dahlia-release-mount.XXXXXX")"
    hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT_DIR" "$DMG_PATH" >/dev/null

    app_info_plist="${DMG_MOUNT_DIR}/${APP_NAME}.app/Contents/Info.plist"
    dmg_marketing_version="$(read_marketing_version "$app_info_plist")"
    DMG_BUILD_VERSION="$(read_build_version "$app_info_plist")"
    DMG_SPARKLE_FEED_URL="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$app_info_plist")"
    DMG_SPARKLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app_info_plist")"
    DMG_SPARKLE_REQUIRES_SIGNED_FEED="$(/usr/libexec/PlistBuddy -c "Print :SURequireSignedFeed" "$app_info_plist")"
    DMG_SPARKLE_VERIFIES_BEFORE_EXTRACTION="$(/usr/libexec/PlistBuddy -c "Print :SUVerifyUpdateBeforeExtraction" "$app_info_plist")"
    DMG_SPARKLE_AUTOMATIC_CHECKS="$(/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$app_info_plist")"
    DMG_SPARKLE_CHECK_INTERVAL="$(/usr/libexec/PlistBuddy -c "Print :SUScheduledCheckInterval" "$app_info_plist")"
    DMG_SPARKLE_AUTOMATIC_UPDATES="$(/usr/libexec/PlistBuddy -c "Print :SUAutomaticallyUpdate" "$app_info_plist")"

    hdiutil detach "$DMG_MOUNT_DIR" >/dev/null
    rmdir "$DMG_MOUNT_DIR"
    DMG_MOUNT_DIR=""

    if [ "$dmg_marketing_version" != "$expected_marketing_version" ]; then
        echo "error: DMG contains ${APP_NAME} ${dmg_marketing_version}, expected ${expected_marketing_version}" >&2
        exit 1
    fi
    if [ "$DMG_BUILD_VERSION" != "$expected_build_version" ]; then
        echo "error: DMG build is ${DMG_BUILD_VERSION}, expected ${expected_build_version}" >&2
        exit 1
    fi
}

validate_build_version_is_newer() {
    local current_build_version="$1"
    local previous_build_version="$2"

    if ((10#$current_build_version <= 10#$previous_build_version)); then
        echo "error: build ${current_build_version} must be greater than the latest released build ${previous_build_version}" >&2
        return 1
    fi
}

validate_build_version_against_latest_release() {
    local previous_release_tag
    local previous_build_version

    if ! previous_release_tag="$(gh release view --repo "$RELEASE_REPOSITORY" --json tagName --jq '.tagName')"; then
        echo "error: could not determine the latest GitHub Release" >&2
        return 1
    fi
    if [ -z "$previous_release_tag" ]; then
        echo "error: latest GitHub Release did not contain a tag name" >&2
        return 1
    fi

    PREVIOUS_RELEASE_INFO_PLIST="$(mktemp "${TMPDIR:-/tmp}/dahlia-previous-release-info.XXXXXX")"
    if ! gh api \
        --method GET \
        -H "Accept: application/vnd.github.raw+json" \
        "repos/${RELEASE_REPOSITORY}/contents/Resources/Info.plist" \
        -f "ref=${previous_release_tag}" \
        > "$PREVIOUS_RELEASE_INFO_PLIST"; then
        rm -f "$PREVIOUS_RELEASE_INFO_PLIST"
        PREVIOUS_RELEASE_INFO_PLIST=""
        echo "error: could not read Info.plist from ${previous_release_tag}" >&2
        return 1
    fi
    if ! previous_build_version="$(read_build_version "$PREVIOUS_RELEASE_INFO_PLIST")"; then
        rm -f "$PREVIOUS_RELEASE_INFO_PLIST"
        PREVIOUS_RELEASE_INFO_PLIST=""
        return 1
    fi
    rm -f "$PREVIOUS_RELEASE_INFO_PLIST"
    PREVIOUS_RELEASE_INFO_PLIST=""
    validate_build_version_is_newer "$BUILD_VERSION" "$previous_build_version"
}

validate_sparkle_release_configuration() {
    local generate_keys="${PROJECT_DIR}/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
    local sparkle_key_account="${SPARKLE_KEY_ACCOUNT:-com.dahlia.app}"
    local expected_feed_url="https://github.com/${RELEASE_REPOSITORY}/releases/latest/download/appcast.xml"
    local current_repository
    local keychain_public_key

    if [ ! -x "$generate_keys" ]; then
        cat >&2 <<EOF
error: Sparkle's generate_keys tool was not found.

Resolve package artifacts first with:
  swift package resolve
EOF
        exit 1
    fi

    current_repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
    if [ "$current_repository" != "$RELEASE_REPOSITORY" ]; then
        echo "error: release repository is ${current_repository}, expected ${RELEASE_REPOSITORY}" >&2
        exit 1
    fi
    if [ "$DMG_SPARKLE_FEED_URL" != "$expected_feed_url" ]; then
        echo "error: DMG Sparkle feed is ${DMG_SPARKLE_FEED_URL}, expected ${expected_feed_url}" >&2
        exit 1
    fi
    if [ "$DMG_SPARKLE_REQUIRES_SIGNED_FEED" != "true" ] || [ "$DMG_SPARKLE_VERIFIES_BEFORE_EXTRACTION" != "true" ]; then
        echo "error: DMG must require a signed Sparkle feed and verify updates before extraction" >&2
        exit 1
    fi
    if [ "$DMG_SPARKLE_AUTOMATIC_CHECKS" != "true" ]; then
        echo "error: DMG must enable automatic Sparkle update checks" >&2
        exit 1
    fi
    if [ "$DMG_SPARKLE_CHECK_INTERVAL" != "86400" ]; then
        echo "error: DMG Sparkle update check interval is ${DMG_SPARKLE_CHECK_INTERVAL}, expected 86400" >&2
        exit 1
    fi
    if [ "$DMG_SPARKLE_AUTOMATIC_UPDATES" != "false" ]; then
        echo "error: DMG must not enable automatic Sparkle updates by default" >&2
        exit 1
    fi

    keychain_public_key="$("$generate_keys" --account "$sparkle_key_account" -p)"
    if [ "$keychain_public_key" != "$DMG_SPARKLE_PUBLIC_KEY" ]; then
        echo "error: Sparkle key ${sparkle_key_account} does not match SUPublicEDKey in the DMG" >&2
        exit 1
    fi
}

has_release_notes() {
    local notes_file="$1"

    [ -s "$notes_file" ] && grep -q '[^[:space:]]' "$notes_file"
}

sha256_digest() {
    local checksum

    checksum="$(shasum -a 256 "$1")"
    printf '%s\n' "${checksum%% *}"
}

validate_sparkle_appcast() {
    local appcast_path="$1"
    local archive_path="$2"
    local sign_update="${PROJECT_DIR}/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    local sparkle_key_account="${SPARKLE_KEY_ACCOUNT:-com.dahlia.app}"
    local expected_archive_url="https://github.com/${RELEASE_REPOSITORY}/releases/download/${TAG_NAME}/${EXPECTED_DMG_NAME}"
    local enclosure_count
    local enclosure_length
    local enclosure_signature
    local enclosure_url
    local appcast_build_version
    local appcast_marketing_version
    local archive_length

    if [ ! -x "$sign_update" ]; then
        echo "error: Sparkle's sign_update tool was not found" >&2
        return 1
    fi

    xmllint --noout "$appcast_path"
    "$sign_update" --account "$sparkle_key_account" --verify "$appcast_path"

    enclosure_count="$(xmllint --xpath 'count(//*[local-name()="enclosure"])' "$appcast_path")"
    enclosure_url="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$appcast_path")"
    enclosure_length="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@length)' "$appcast_path")"
    enclosure_signature="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$appcast_path")"
    appcast_build_version="$(xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="version"])' "$appcast_path")"
    appcast_marketing_version="$(xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="shortVersionString"])' "$appcast_path")"
    archive_length="$(stat -f '%z' "$archive_path")"

    if [ "$enclosure_count" != "1" ]; then
        echo "error: Sparkle appcast must contain exactly one update enclosure" >&2
        return 1
    fi
    if [ "$enclosure_url" != "$expected_archive_url" ]; then
        echo "error: Sparkle enclosure URL is ${enclosure_url}, expected ${expected_archive_url}" >&2
        return 1
    fi
    if [ "$enclosure_length" != "$archive_length" ]; then
        echo "error: Sparkle enclosure length is ${enclosure_length}, expected ${archive_length}" >&2
        return 1
    fi
    if [ "$appcast_build_version" != "$BUILD_VERSION" ] || [ "$appcast_marketing_version" != "$MARKETING_VERSION" ]; then
        echo "error: Sparkle appcast version does not match the release DMG" >&2
        return 1
    fi
    if [ -z "$enclosure_signature" ]; then
        echo "error: Sparkle appcast does not contain a signed update enclosure" >&2
        return 1
    fi

    "$sign_update" --account "$sparkle_key_account" --verify "$archive_path" "$enclosure_signature"
}

create_sparkle_appcast() {
    local generate_appcast="${PROJECT_DIR}/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
    local sparkle_key_account="${SPARKLE_KEY_ACCOUNT:-com.dahlia.app}"

    if [ ! -x "$generate_appcast" ]; then
        cat >&2 <<EOF
error: Sparkle's generate_appcast tool was not found.

Resolve package artifacts first with:
  swift package resolve
EOF
        exit 1
    fi

    SPARKLE_RELEASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dahlia-sparkle-release.XXXXXX")"
    cp "$DMG_PATH" "${SPARKLE_RELEASE_DIR}/${EXPECTED_DMG_NAME}"
    cp "$NOTES_FILE" "${SPARKLE_RELEASE_DIR}/${APP_NAME}.md"

    if [ "$(sha256_digest "${SPARKLE_RELEASE_DIR}/${EXPECTED_DMG_NAME}")" != "$DMG_CHECKSUM" ]; then
        echo "error: Sparkle release DMG does not match the validated DMG" >&2
        exit 1
    fi

    "$generate_appcast" \
        --account "$sparkle_key_account" \
        --download-url-prefix "https://github.com/${RELEASE_REPOSITORY}/releases/download/${TAG_NAME}/" \
        --embed-release-notes \
        "$SPARKLE_RELEASE_DIR"

    if [ ! -s "${SPARKLE_RELEASE_DIR}/appcast.xml" ]; then
        echo "error: Sparkle appcast was not generated" >&2
        exit 1
    fi
    validate_sparkle_appcast \
        "${SPARKLE_RELEASE_DIR}/appcast.xml" \
        "${SPARKLE_RELEASE_DIR}/${EXPECTED_DMG_NAME}"
}

publish_github_release() {
    gh release create \
        "$TAG_NAME" \
        "${SPARKLE_RELEASE_DIR}/${EXPECTED_DMG_NAME}" \
        "${SPARKLE_RELEASE_DIR}/appcast.xml" \
        --title "${APP_NAME} ${MARKETING_VERSION}" \
        --notes-file "$NOTES_FILE" \
        "${RELEASE_TARGET_ARGS[@]}"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

trap cleanup EXIT

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

require_commands codesign gh git hdiutil shasum stat xmllint xcrun
if [ -z "$NOTES_FILE" ]; then
    require_commands codex
fi

MARKETING_VERSION="$(read_marketing_version "$INFO_PLIST")"
BUILD_VERSION="$(read_build_version "$INFO_PLIST")"
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
validate_dmg_versions "$MARKETING_VERSION" "$BUILD_VERSION"

DMG_CHECKSUM="$(sha256_digest "$DMG_PATH")"

gh auth status >/dev/null
git remote get-url origin >/dev/null
validate_sparkle_release_configuration
validate_build_version_against_latest_release

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

    if [ "$(sha256_digest "$DMG_PATH")" != "$DMG_CHECKSUM" ]; then
        echo "error: release DMG changed while Codex generated release notes; refusing to publish" >&2
        exit 1
    fi

    if [ "$(git rev-parse HEAD)" != "$HEAD_COMMIT" ] || [ -n "$(git status --porcelain --untracked-files=all)" ]; then
        echo "error: Codex changed the repository while generating release notes; refusing to publish" >&2
        exit 1
    fi
fi

echo "=== Generating signed Sparkle appcast ==="
create_sparkle_appcast

echo "=== Release notes ==="
sed 's/^/  /' "$NOTES_FILE"

if [ "$(sha256_digest "${SPARKLE_RELEASE_DIR}/${EXPECTED_DMG_NAME}")" != "$DMG_CHECKSUM" ]; then
    echo "error: signed Sparkle release DMG changed before upload; refusing to publish" >&2
    exit 1
fi

echo "=== Creating GitHub Release ${TAG_NAME} ==="
publish_github_release

echo "=== GitHub Release complete: ${TAG_NAME} ==="
