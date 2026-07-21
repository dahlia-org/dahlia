#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/create-github-release.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dahlia-release-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    echo "test failure: $*" >&2
    exit 1
}

expect_failure() {
    if ("$@") >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

write_appcast() {
    local path="$1"
    local enclosure_url="$2"
    local enclosure_length="$3"
    local enclosure_signature="$4"
    local build_version="$5"
    local marketing_version="$6"

    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">' \
        '  <channel>' \
        '    <item>' \
        "      <sparkle:version>${build_version}</sparkle:version>" \
        "      <sparkle:shortVersionString>${marketing_version}</sparkle:shortVersionString>" \
        "      <enclosure url=\"${enclosure_url}\" length=\"${enclosure_length}\" sparkle:edSignature=\"${enclosure_signature}\"/>" \
        '    </item>' \
        '  </channel>' \
        '</rss>' \
        > "$path"
}

test_build_version_validation() {
    local plist_path="${TEST_DIR}/Info.plist"

    cp "${PROJECT_DIR}/Resources/Info.plist" "$plist_path"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 24' "$plist_path"

    [ "$(read_build_version "$plist_path")" = "24" ] || fail "failed to read build version"
    validate_build_version_is_newer 24 23
    expect_failure validate_build_version_is_newer 23 23
    expect_failure validate_build_version_is_newer 22 23
}

test_latest_release_build_validation() {
    local previous_plist="${TEST_DIR}/PreviousInfo.plist"
    local gh_release_mode="success"

    cp "${PROJECT_DIR}/Resources/Info.plist" "$previous_plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 23' "$previous_plist"

    gh() {
        if [ "$1" = "release" ]; then
            case "$gh_release_mode" in
                success) printf '%s\n' 'v1.2.2' ;;
                empty) return 0 ;;
                failure) return 1 ;;
            esac
            return
        fi

        cat "$previous_plist"
    }

    RELEASE_REPOSITORY="dahlia-mtg/dahlia"
    BUILD_VERSION="24"
    validate_build_version_against_latest_release

    BUILD_VERSION="23"
    expect_failure validate_build_version_against_latest_release
    BUILD_VERSION="24"
    gh_release_mode="empty"
    expect_failure validate_build_version_against_latest_release
    gh_release_mode="failure"
    expect_failure validate_build_version_against_latest_release
}

test_sparkle_configuration_validation() {
    local fake_project="${TEST_DIR}/configuration-project"
    local generate_keys="${fake_project}/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

    mkdir -p "$(dirname "$generate_keys")"
    printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "test-public-key"' > "$generate_keys"
    chmod +x "$generate_keys"

    PROJECT_DIR="$fake_project"
    RELEASE_REPOSITORY="dahlia-mtg/dahlia"
    DMG_SPARKLE_FEED_URL="https://github.com/dahlia-mtg/dahlia/releases/latest/download/appcast.xml"
    DMG_SPARKLE_PUBLIC_KEY="test-public-key"
    DMG_SPARKLE_REQUIRES_SIGNED_FEED="true"
    DMG_SPARKLE_VERIFIES_BEFORE_EXTRACTION="true"
    gh() {
        printf '%s\n' "dahlia-mtg/dahlia"
    }

    validate_sparkle_release_configuration

    DMG_SPARKLE_FEED_URL="https://example.com/appcast.xml"
    expect_failure validate_sparkle_release_configuration
    DMG_SPARKLE_FEED_URL="https://github.com/dahlia-mtg/dahlia/releases/latest/download/appcast.xml"
    DMG_SPARKLE_PUBLIC_KEY="wrong-key"
    expect_failure validate_sparkle_release_configuration
}

test_appcast_validation() {
    local fake_project="${TEST_DIR}/appcast-project"
    local sign_update="${fake_project}/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    local archive_path="${TEST_DIR}/Dahlia.dmg"
    local appcast_path="${TEST_DIR}/appcast.xml"
    local sign_update_log="${TEST_DIR}/sign-update.log"
    local expected_sign_update_log="${TEST_DIR}/expected-sign-update.log"
    local archive_length
    local expected_url="https://github.com/dahlia-mtg/dahlia/releases/download/v1.2.3/Dahlia.dmg"

    mkdir -p "$(dirname "$sign_update")"
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "call\n" >> "$SIGN_UPDATE_LOG"' \
        'printf "<%s>\n" "$@" >> "$SIGN_UPDATE_LOG"' \
        '[ "${FAIL_SIGN_UPDATE:-0}" != "1" ]' \
        > "$sign_update"
    chmod +x "$sign_update"
    printf '%s' 'archive fixture' > "$archive_path"
    archive_length="$(stat -f '%z' "$archive_path")"

    PROJECT_DIR="$fake_project"
    RELEASE_REPOSITORY="dahlia-mtg/dahlia"
    TAG_NAME="v1.2.3"
    EXPECTED_DMG_NAME="Dahlia.dmg"
    BUILD_VERSION="24"
    MARKETING_VERSION="1.2.3"
    export SIGN_UPDATE_LOG="$sign_update_log"

    write_appcast "$appcast_path" "$expected_url" "$archive_length" "test-signature" "$BUILD_VERSION" "$MARKETING_VERSION"
    validate_sparkle_appcast "$appcast_path" "$archive_path"
    printf '%s\n' \
        'call' \
        '<--account>' \
        '<com.dahlia.app>' \
        '<--verify>' \
        "<${appcast_path}>" \
        'call' \
        '<--account>' \
        '<com.dahlia.app>' \
        '<--verify>' \
        "<${archive_path}>" \
        '<test-signature>' \
        > "$expected_sign_update_log"
    diff -u "$expected_sign_update_log" "$sign_update_log"

    write_appcast "$appcast_path" "https://example.com/Dahlia.dmg" "$archive_length" "test-signature" "$BUILD_VERSION" "$MARKETING_VERSION"
    expect_failure validate_sparkle_appcast "$appcast_path" "$archive_path"
    write_appcast "$appcast_path" "$expected_url" "$archive_length" "" "$BUILD_VERSION" "$MARKETING_VERSION"
    expect_failure validate_sparkle_appcast "$appcast_path" "$archive_path"
    write_appcast "$appcast_path" "$expected_url" "$archive_length" "test-signature" "$BUILD_VERSION" "$MARKETING_VERSION"
    export FAIL_SIGN_UPDATE=1
    expect_failure validate_sparkle_appcast "$appcast_path" "$archive_path"
    unset FAIL_SIGN_UPDATE
    unset SIGN_UPDATE_LOG
}

test_sparkle_appcast_creation() {
    local fake_project="${TEST_DIR}/creation-project"
    local bin_dir="${fake_project}/.build/artifacts/sparkle/Sparkle/bin"
    local generate_appcast="${bin_dir}/generate_appcast"
    local sign_update="${bin_dir}/sign_update"
    local source_archive="${TEST_DIR}/source-Dahlia.dmg"
    local generate_appcast_log="${TEST_DIR}/generate-appcast.log"
    local expected_generate_appcast_log="${TEST_DIR}/expected-generate-appcast.log"
    local release_dir

    mkdir -p "$bin_dir"
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "<%s>\n" "$@" > "$GENERATE_APPCAST_LOG"' \
        'for argument in "$@"; do release_dir="$argument"; done' \
        'archive_path="${release_dir}/Dahlia.dmg"' \
        'archive_length="$(stat -f "%z" "$archive_path")"' \
        'cat > "${release_dir}/appcast.xml" <<EOF' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>' \
        '<sparkle:version>24</sparkle:version>' \
        '<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>' \
        '<enclosure url="https://github.com/dahlia-mtg/dahlia/releases/download/v1.2.3/Dahlia.dmg" length="${archive_length}" sparkle:edSignature="test-signature"/>' \
        '</item></channel></rss>' \
        'EOF' \
        > "$generate_appcast"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$sign_update"
    chmod +x "$generate_appcast" "$sign_update"

    printf '%s' 'signed archive fixture' > "$source_archive"
    printf '%s' 'release notes fixture' > "${TEST_DIR}/release-notes.md"

    PROJECT_DIR="$fake_project"
    RELEASE_REPOSITORY="dahlia-mtg/dahlia"
    TAG_NAME="v1.2.3"
    EXPECTED_DMG_NAME="Dahlia.dmg"
    BUILD_VERSION="24"
    MARKETING_VERSION="1.2.3"
    DMG_PATH="$source_archive"
    NOTES_FILE="${TEST_DIR}/release-notes.md"
    DMG_CHECKSUM="$(sha256_digest "$source_archive")"
    SPARKLE_RELEASE_DIR=""
    export GENERATE_APPCAST_LOG="$generate_appcast_log"

    create_sparkle_appcast
    release_dir="$SPARKLE_RELEASE_DIR"
    cmp "$source_archive" "${release_dir}/Dahlia.dmg"
    [ -s "${release_dir}/Dahlia.md" ] || fail "release notes were not copied"
    [ -s "${release_dir}/appcast.xml" ] || fail "appcast was not generated"
    printf '%s\n' \
        '<--account>' \
        '<com.dahlia.app>' \
        '<--download-url-prefix>' \
        '<https://github.com/dahlia-mtg/dahlia/releases/download/v1.2.3/>' \
        '<--embed-release-notes>' \
        "<${release_dir}>" \
        > "$expected_generate_appcast_log"
    diff -u "$expected_generate_appcast_log" "$generate_appcast_log"
    unset GENERATE_APPCAST_LOG

    cleanup
    [ ! -e "$release_dir" ] || fail "Sparkle release directory was not cleaned up"
    SPARKLE_RELEASE_DIR=""
}

test_release_upload_arguments() {
    local release_dir="${TEST_DIR}/upload-release"
    local gh_log="${TEST_DIR}/gh-release-create.log"
    local expected_gh_log="${TEST_DIR}/expected-gh-release-create.log"

    mkdir -p "$release_dir"
    printf '%s' 'archive' > "${release_dir}/Dahlia.dmg"
    printf '%s' 'appcast' > "${release_dir}/appcast.xml"
    printf '%s' 'notes' > "${TEST_DIR}/upload-notes.md"

    APP_NAME="Dahlia"
    TAG_NAME="v1.2.3"
    MARKETING_VERSION="1.2.3"
    EXPECTED_DMG_NAME="Dahlia.dmg"
    SPARKLE_RELEASE_DIR="$release_dir"
    NOTES_FILE="${TEST_DIR}/upload-notes.md"
    RELEASE_TARGET_ARGS=(--target test-commit)
    gh() {
        printf '<%s>\n' "$@" > "$gh_log"
    }

    publish_github_release
    printf '%s\n' \
        '<release>' \
        '<create>' \
        '<v1.2.3>' \
        "<${release_dir}/Dahlia.dmg>" \
        "<${release_dir}/appcast.xml>" \
        '<--title>' \
        '<Dahlia 1.2.3>' \
        '<--notes-file>' \
        "<${TEST_DIR}/upload-notes.md>" \
        '<--target>' \
        '<test-commit>' \
        > "$expected_gh_log"
    diff -u "$expected_gh_log" "$gh_log"
}

test_cleanup_removes_previous_release_plist() {
    PREVIOUS_RELEASE_INFO_PLIST="${TEST_DIR}/temporary-previous-Info.plist"
    printf '%s' 'temporary plist' > "$PREVIOUS_RELEASE_INFO_PLIST"
    cleanup
    [ ! -e "$PREVIOUS_RELEASE_INFO_PLIST" ] || fail "previous release plist was not cleaned up"
    PREVIOUS_RELEASE_INFO_PLIST=""
}

test_framework_embedding_validation() {
    local fake_project="${TEST_DIR}/framework-project"
    local artifact_dir="${fake_project}/.build/artifacts/sparkle/Sparkle"
    local framework_dir="${artifact_dir}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    local contents_dir="${TEST_DIR}/Contents"

    mkdir -p "$framework_dir"
    printf '%s' 'framework fixture' > "${framework_dir}/Sparkle"
    printf '%s' 'license fixture' > "${artifact_dir}/LICENSE"
    lipo() {
        return 0
    }
    ditto() {
        cp -R "$1" "$2"
    }

    embed_sparkle_framework "$fake_project" "$contents_dir"
    [ -f "${contents_dir}/Frameworks/Sparkle.framework/Sparkle" ] || fail "framework was not embedded"

    mkdir -p "${artifact_dir}/Sparkle.xcframework/macos-arm64/Sparkle.framework"
    printf '%s' 'second framework fixture' > "${artifact_dir}/Sparkle.xcframework/macos-arm64/Sparkle.framework/Sparkle"
    expect_failure embed_sparkle_framework "$fake_project" "$contents_dir"
}

test_whisperkit_license_embedding_validation() {
    local fake_project="${TEST_DIR}/whisperkit-license-project"
    local checkout_dir="${fake_project}/.build/checkouts/argmax-oss-swift"
    local contents_dir="${TEST_DIR}/WhisperKitContents"

    mkdir -p "$checkout_dir"
    printf '%s' 'license fixture' > "${checkout_dir}/LICENSE"
    printf '%s' 'notices fixture' > "${checkout_dir}/NOTICES"

    embed_whisperkit_licenses "$fake_project" "$contents_dir"
    cmp "${checkout_dir}/LICENSE" "${contents_dir}/Resources/Licenses/WhisperKit/LICENSE"
    cmp "${checkout_dir}/NOTICES" "${contents_dir}/Resources/Licenses/WhisperKit/NOTICES"

    rm "${checkout_dir}/NOTICES"
    expect_failure embed_whisperkit_licenses "$fake_project" "$contents_dir"
}

test_build_version_validation
test_latest_release_build_validation
test_sparkle_configuration_validation
test_appcast_validation
test_sparkle_appcast_creation
test_release_upload_arguments
test_cleanup_removes_previous_release_plist
test_framework_embedding_validation
test_whisperkit_license_embedding_validation

echo "Release script tests passed"
