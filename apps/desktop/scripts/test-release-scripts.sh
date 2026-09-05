#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_SCRIPTS_DIR="$SCRIPT_DIR"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REPOSITORY_DIR="$PROJECT_DIR"

source "${SCRIPT_DIR}/common.sh"
source "${PROJECT_DIR}/.agents/skills/release-dahlia-app/scripts/create-github-release.sh"

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
    local notes_ja_length="$7"
    local notes_en_length="$8"

    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">' \
        '  <channel>' \
        '    <item>' \
        "      <sparkle:version>${build_version}</sparkle:version>" \
        "      <sparkle:shortVersionString>${marketing_version}</sparkle:shortVersionString>" \
        "      <sparkle:releaseNotesLink xml:lang=\"ja\" length=\"${notes_ja_length}\" sparkle:edSignature=\"ja-signature\">https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/release-note-ja.md</sparkle:releaseNotesLink>" \
        "      <sparkle:releaseNotesLink xml:lang=\"en\" length=\"${notes_en_length}\" sparkle:edSignature=\"en-signature\">https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/release-note-en.md</sparkle:releaseNotesLink>" \
        "      <enclosure url=\"${enclosure_url}\" length=\"${enclosure_length}\" sparkle:edSignature=\"${enclosure_signature}\"/>" \
        '    </item>' \
        '  </channel>' \
        '</rss>' \
        > "$path"
}

test_build_version_validation() {
    local plist_path="${TEST_DIR}/Info.plist"

    cp "${REPOSITORY_DIR}/Resources/Info.plist" "$plist_path"
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

    RELEASE_REPOSITORY="dahlia-org/dahlia"
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

test_release_notes_validation_and_snapshot() {
    local source_ja="${TEST_DIR}/source-notes.ja.md"
    local source_en="${TEST_DIR}/source-notes.en.md"
    local snapshot_dir

    printf '%s\n' 'Japanese notes' > "$source_ja"
    printf '%s\n' 'English notes' > "$source_en"
    validate_release_notes_files "$source_ja" "$source_en"

    NOTES_FILE_JA="$source_ja"
    NOTES_FILE_EN="$source_en"
    snapshot_release_notes
    snapshot_dir="$NOTES_SNAPSHOT_DIR"
    cmp "$source_ja" "$NOTES_FILE_JA"
    cmp "$source_en" "$NOTES_FILE_EN"

    printf '%s\n' 'Changed Japanese notes' > "$source_ja"
    grep -Fxq 'Japanese notes' "$NOTES_FILE_JA" \
        || fail "release notes snapshot changed with its source"

    cleanup
    [ ! -e "$snapshot_dir" ] || fail "release notes snapshot was not cleaned up"
    NOTES_SNAPSHOT_DIR=""

    printf '%s\n' 'Same notes' > "$source_ja"
    printf '%s\n' 'Same notes' > "$source_en"
    expect_failure validate_release_notes_files "$source_ja" "$source_en"
}

test_sparkle_configuration_validation() {
    local fake_project="${TEST_DIR}/configuration-project"
    local generate_keys="${fake_project}/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

    mkdir -p "$(dirname "$generate_keys")"
    printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "test-public-key"' > "$generate_keys"
    chmod +x "$generate_keys"

    PROJECT_DIR="$fake_project"
    RELEASE_REPOSITORY="dahlia-org/dahlia"
    DMG_SPARKLE_FEED_URL="https://github.com/dahlia-org/dahlia/releases/latest/download/appcast.xml"
    DMG_SPARKLE_PUBLIC_KEY="test-public-key"
    DMG_SPARKLE_REQUIRES_SIGNED_FEED="true"
    DMG_SPARKLE_VERIFIES_BEFORE_EXTRACTION="true"
    DMG_SPARKLE_AUTOMATIC_CHECKS="true"
    DMG_SPARKLE_CHECK_INTERVAL="3600"
    DMG_SPARKLE_AUTOMATIC_UPDATES="false"
    DMG_SPARKLE_ALLOWS_AUTOMATIC_UPDATES="false"
    gh() {
        printf '%s\n' "dahlia-org/dahlia"
    }

    validate_sparkle_release_configuration

    DMG_SPARKLE_FEED_URL="https://example.com/appcast.xml"
    expect_failure validate_sparkle_release_configuration
    DMG_SPARKLE_FEED_URL="https://github.com/dahlia-org/dahlia/releases/latest/download/appcast.xml"
    DMG_SPARKLE_PUBLIC_KEY="wrong-key"
    expect_failure validate_sparkle_release_configuration
    DMG_SPARKLE_PUBLIC_KEY="test-public-key"
    DMG_SPARKLE_AUTOMATIC_CHECKS="false"
    expect_failure validate_sparkle_release_configuration
    DMG_SPARKLE_AUTOMATIC_CHECKS="true"
    DMG_SPARKLE_CHECK_INTERVAL="86400"
    expect_failure validate_sparkle_release_configuration
    DMG_SPARKLE_CHECK_INTERVAL="3600"
    DMG_SPARKLE_AUTOMATIC_UPDATES="true"
    expect_failure validate_sparkle_release_configuration
    DMG_SPARKLE_AUTOMATIC_UPDATES="false"
    DMG_SPARKLE_ALLOWS_AUTOMATIC_UPDATES="true"
    expect_failure validate_sparkle_release_configuration
}

test_appcast_validation() {
    local fake_project="${TEST_DIR}/appcast-project"
    local sign_update="${fake_project}/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    local archive_path="${TEST_DIR}/Dahlia.dmg"
    local appcast_path="${TEST_DIR}/appcast.xml"
    local sign_update_log="${TEST_DIR}/sign-update.log"
    local expected_sign_update_log="${TEST_DIR}/expected-sign-update.log"
    local notes_file_ja="${TEST_DIR}/validation-release-note-ja.md"
    local notes_file_en="${TEST_DIR}/validation-release-note-en.md"
    local archive_length
    local notes_ja_length
    local notes_en_length
    local expected_url="https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/Dahlia.dmg"

    mkdir -p "$(dirname "$sign_update")"
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "call\n" >> "$SIGN_UPDATE_LOG"' \
        'printf "<%s>\n" "$@" >> "$SIGN_UPDATE_LOG"' \
        '[ "${FAIL_SIGN_UPDATE:-0}" != "1" ]' \
        > "$sign_update"
    chmod +x "$sign_update"
    printf '%s' 'archive fixture' > "$archive_path"
    printf '%s' 'Japanese notes fixture' > "$notes_file_ja"
    printf '%s' 'English notes fixture' > "$notes_file_en"
    archive_length="$(stat -f '%z' "$archive_path")"
    notes_ja_length="$(stat -f '%z' "$notes_file_ja")"
    notes_en_length="$(stat -f '%z' "$notes_file_en")"

    PROJECT_DIR="$fake_project"
    RELEASE_REPOSITORY="dahlia-org/dahlia"
    TAG_NAME="v1.2.3"
    EXPECTED_DMG_NAME="Dahlia.dmg"
    BUILD_VERSION="24"
    MARKETING_VERSION="1.2.3"
    export SIGN_UPDATE_LOG="$sign_update_log"

    write_appcast \
        "$appcast_path" "$expected_url" "$archive_length" "test-signature" \
        "$BUILD_VERSION" "$MARKETING_VERSION" "$notes_ja_length" "$notes_en_length"
    validate_sparkle_appcast "$appcast_path" "$archive_path" "$notes_file_ja" "$notes_file_en"
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
        'call' \
        '<--account>' \
        '<com.dahlia.app>' \
        '<--verify>' \
        "<${notes_file_ja}>" \
        '<ja-signature>' \
        'call' \
        '<--account>' \
        '<com.dahlia.app>' \
        '<--verify>' \
        "<${notes_file_en}>" \
        '<en-signature>' \
        > "$expected_sign_update_log"
    diff -u "$expected_sign_update_log" "$sign_update_log"

    write_appcast \
        "$appcast_path" "https://example.com/Dahlia.dmg" "$archive_length" "test-signature" \
        "$BUILD_VERSION" "$MARKETING_VERSION" "$notes_ja_length" "$notes_en_length"
    expect_failure validate_sparkle_appcast "$appcast_path" "$archive_path" "$notes_file_ja" "$notes_file_en"
    write_appcast \
        "$appcast_path" "$expected_url" "$archive_length" "" \
        "$BUILD_VERSION" "$MARKETING_VERSION" "$notes_ja_length" "$notes_en_length"
    expect_failure validate_sparkle_appcast "$appcast_path" "$archive_path" "$notes_file_ja" "$notes_file_en"
    write_appcast \
        "$appcast_path" "$expected_url" "$archive_length" "test-signature" \
        "$BUILD_VERSION" "$MARKETING_VERSION" "$notes_ja_length" "$notes_en_length"
    export FAIL_SIGN_UPDATE=1
    expect_failure validate_sparkle_appcast "$appcast_path" "$archive_path" "$notes_file_ja" "$notes_file_en"
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
    local sign_update_log="${TEST_DIR}/create-sign-update.log"
    local release_dir

    mkdir -p "$bin_dir"
    printf '%s\n' \
        '#!/bin/bash' \
        'set -euo pipefail' \
        'printf "<%s>\n" "$@" > "$GENERATE_APPCAST_LOG"' \
        'for argument in "$@"; do release_dir="$argument"; done' \
        'archive_path="${release_dir}/Dahlia.dmg"' \
        'archive_length="$(stat -f "%z" "$archive_path")"' \
        'notes_ja_length="$(stat -f "%z" "${release_dir}/Dahlia.ja.md")"' \
        'notes_en_length="$(stat -f "%z" "${release_dir}/Dahlia.en.md")"' \
        'cat > "${release_dir}/appcast.xml" <<EOF' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>' \
        '<sparkle:version>24</sparkle:version>' \
        '<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>' \
        '<sparkle:releaseNotesLink xml:lang="ja" length="${notes_ja_length}" sparkle:edSignature="ja-signature">https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/Dahlia.ja.md</sparkle:releaseNotesLink>' \
        '<sparkle:releaseNotesLink xml:lang="en" length="${notes_en_length}" sparkle:edSignature="en-signature">https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/Dahlia.en.md</sparkle:releaseNotesLink>' \
        '<enclosure url="https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/Dahlia.dmg" length="${archive_length}" sparkle:edSignature="test-signature"/>' \
        '</item></channel></rss>' \
        'EOF' \
        > "$generate_appcast"
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "<%s>\n" "$@" >> "$SIGN_UPDATE_LOG"' \
        'exit 0' \
        > "$sign_update"
    chmod +x "$generate_appcast" "$sign_update"

    printf '%s' 'signed archive fixture' > "$source_archive"
    printf '%s' 'Japanese release notes fixture' > "${TEST_DIR}/release-notes.ja.md"
    printf '%s' 'English release notes fixture' > "${TEST_DIR}/release-notes.en.md"

    PROJECT_DIR="$fake_project"
    RELEASE_REPOSITORY="dahlia-org/dahlia"
    TAG_NAME="v1.2.3"
    EXPECTED_DMG_NAME="Dahlia.dmg"
    BUILD_VERSION="24"
    MARKETING_VERSION="1.2.3"
    DMG_PATH="$source_archive"
    NOTES_FILE_JA="${TEST_DIR}/release-notes.ja.md"
    NOTES_FILE_EN="${TEST_DIR}/release-notes.en.md"
    DMG_CHECKSUM="$(sha256_digest "$source_archive")"
    SPARKLE_RELEASE_DIR=""
    export GENERATE_APPCAST_LOG="$generate_appcast_log"
    export SIGN_UPDATE_LOG="$sign_update_log"

    create_sparkle_appcast
    release_dir="$SPARKLE_RELEASE_DIR"
    cmp "$source_archive" "${release_dir}/Dahlia.dmg"
    cmp "$NOTES_FILE_JA" "${release_dir}/release-note-ja.md"
    cmp "$NOTES_FILE_EN" "${release_dir}/release-note-en.md"
    [ -s "${release_dir}/appcast.xml" ] || fail "appcast was not generated"
    grep -Fq '/release-note-ja.md' "${release_dir}/appcast.xml" \
        || fail "Japanese release notes URL was not renamed"
    grep -Fq '/release-note-en.md' "${release_dir}/appcast.xml" \
        || fail "English release notes URL was not renamed"
    ! grep -Fq '/Dahlia.ja.md' "${release_dir}/appcast.xml" \
        || fail "Sparkle Japanese staging URL was retained"
    ! grep -Fq '/Dahlia.en.md' "${release_dir}/appcast.xml" \
        || fail "Sparkle English staging URL was retained"
    sed -n '1,3p' "$sign_update_log" | diff -u - <(printf '%s\n' \
        '<--account>' \
        '<com.dahlia.app>' \
        "<${release_dir}/appcast.xml>")
    printf '%s\n' \
        '<--account>' \
        '<com.dahlia.app>' \
        '<--download-url-prefix>' \
        '<https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/>' \
        '<--release-notes-url-prefix>' \
        '<https://github.com/dahlia-org/dahlia/releases/download/v1.2.3/>' \
        "<${release_dir}>" \
        > "$expected_generate_appcast_log"
    diff -u "$expected_generate_appcast_log" "$generate_appcast_log"
    unset GENERATE_APPCAST_LOG
    unset SIGN_UPDATE_LOG

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
    printf '%s' 'Japanese notes' > "${release_dir}/release-note-ja.md"
    printf '%s' 'English notes' > "${release_dir}/release-note-en.md"
    printf '%s' 'Japanese notes' > "${TEST_DIR}/upload-notes.ja.md"
    printf '%s' 'English notes' > "${TEST_DIR}/upload-notes.en.md"

    APP_NAME="Dahlia"
    TAG_NAME="v1.2.3"
    MARKETING_VERSION="1.2.3"
    EXPECTED_DMG_NAME="Dahlia.dmg"
    SPARKLE_RELEASE_DIR="$release_dir"
    NOTES_FILE_JA="${TEST_DIR}/upload-notes.ja.md"
    NOTES_FILE_EN="${TEST_DIR}/upload-notes.en.md"
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
        "<${release_dir}/release-note-ja.md>" \
        "<${release_dir}/release-note-en.md>" \
        '<--title>' \
        '<Dahlia 1.2.3>' \
        '<--notes-file>' \
        "<${TEST_DIR}/upload-notes.en.md>" \
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
    chmod a-w "${checkout_dir}/LICENSE" "${checkout_dir}/NOTICES"

    embed_whisperkit_licenses "$fake_project" "$contents_dir"
    cmp "${checkout_dir}/LICENSE" "${contents_dir}/Resources/Licenses/WhisperKit/LICENSE"
    cmp "${checkout_dir}/NOTICES" "${contents_dir}/Resources/Licenses/WhisperKit/NOTICES"
    [ -w "${contents_dir}/Resources/Licenses/WhisperKit/LICENSE" ] \
        || fail "embedded WhisperKit license was not writable"
    [ -w "${contents_dir}/Resources/Licenses/WhisperKit/NOTICES" ] \
        || fail "embedded WhisperKit notices were not writable"

    rm "${checkout_dir}/NOTICES"
    expect_failure embed_whisperkit_licenses "$fake_project" "$contents_dir"
}

test_lindera_license_embedding_validation() {
    local fake_project="${TEST_DIR}/lindera-license-project"
    local vendor_dir="${fake_project}/Vendor"
    local contents_dir="${TEST_DIR}/LinderaContents"

    mkdir -p "$vendor_dir"
    printf '%s' 'Lindera and IPADIC license fixture' > "${vendor_dir}/DahliaLindera-LICENSE.txt"
    printf '%s' 'Rust notices fixture' > "${vendor_dir}/DahliaLindera-THIRD-PARTY-NOTICES.txt"

    embed_lindera_licenses "$fake_project" "$contents_dir"
    cmp \
        "${vendor_dir}/DahliaLindera-LICENSE.txt" \
        "${contents_dir}/Resources/Licenses/DahliaLindera/LICENSE"
    cmp \
        "${vendor_dir}/DahliaLindera-THIRD-PARTY-NOTICES.txt" \
        "${contents_dir}/Resources/Licenses/DahliaLindera/THIRD-PARTY-NOTICES.txt"

    rm "${vendor_dir}/DahliaLindera-THIRD-PARTY-NOTICES.txt"
    expect_failure embed_lindera_licenses "$fake_project" "$contents_dir"
}

test_telemetrydeck_configuration_and_embedding() {
    local plist_path="${TEST_DIR}/TelemetryInfo.plist"
    local fake_project="${TEST_DIR}/telemetrydeck-project"
    local build_dir="${fake_project}/build"
    local checkout_dir="${fake_project}/.build/checkouts/SwiftSDK"
    local contents_dir="${TEST_DIR}/TelemetryContents"

    if grep -Eq 'codesign_path.*TelemetryDeck_TelemetryDeck\.bundle' \
        "${DESKTOP_SCRIPTS_DIR}/build-app.sh" \
        "${DESKTOP_SCRIPTS_DIR}/run-dev.sh" >/dev/null; then
        fail "TelemetryDeck's resource-only bundle must not be signed separately"
    fi

    cp "${REPOSITORY_DIR}/Resources/Info.plist" "$plist_path"
    TELEMETRYDECK_APP_ID="test-app-id"
    configure_telemetrydeck_plist "$plist_path"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :TELEMETRYDECK_APP_ID' "$plist_path")" = "test-app-id" ] \
        || fail "TelemetryDeck App ID was not embedded"
    unset TELEMETRYDECK_APP_ID
    configure_telemetrydeck_plist "$plist_path"
    expect_failure /usr/libexec/PlistBuddy -c 'Print :TELEMETRYDECK_APP_ID' "$plist_path"

    mkdir -p "${build_dir}/TelemetryDeck_TelemetryDeck.bundle" "$checkout_dir"
    printf '%s' 'privacy manifest' > "${build_dir}/TelemetryDeck_TelemetryDeck.bundle/PrivacyInfo.xcprivacy"
    printf '%s' 'license fixture' > "${checkout_dir}/LICENSE"
    chmod a-w \
        "${build_dir}/TelemetryDeck_TelemetryDeck.bundle/PrivacyInfo.xcprivacy" \
        "${checkout_dir}/LICENSE"
    embed_telemetrydeck_resources "$fake_project" "$build_dir" "$contents_dir"
    cmp \
        "${build_dir}/TelemetryDeck_TelemetryDeck.bundle/PrivacyInfo.xcprivacy" \
        "${contents_dir}/Resources/TelemetryDeck_TelemetryDeck.bundle/PrivacyInfo.xcprivacy"
    cmp "$checkout_dir/LICENSE" "${contents_dir}/Resources/Licenses/TelemetryDeck/LICENSE"
    [ -w "${contents_dir}/Resources/TelemetryDeck_TelemetryDeck.bundle/PrivacyInfo.xcprivacy" ] \
        || fail "embedded TelemetryDeck privacy manifest was not writable"
    [ -w "${contents_dir}/Resources/Licenses/TelemetryDeck/LICENSE" ] \
        || fail "embedded TelemetryDeck license was not writable"

    rm "${build_dir}/TelemetryDeck_TelemetryDeck.bundle/PrivacyInfo.xcprivacy"
    rmdir "${build_dir}/TelemetryDeck_TelemetryDeck.bundle"
    expect_failure embed_telemetrydeck_resources "$fake_project" "$build_dir" "$contents_dir"
}

test_codex_code_mode_host_packaging() {
    local build_script

    for build_script in \
        "${DESKTOP_SCRIPTS_DIR}/build-app.sh" \
        "${DESKTOP_SCRIPTS_DIR}/run-dev.sh"; do
        grep -Fq \
            'cp ".build/codex-helper/codex-code-mode-host" "${HELPERS}/codex-code-mode-host"' \
            "$build_script" \
            || fail "$(basename "$build_script") does not embed the Codex code-mode host"
        grep -Fq \
            'codesign_path "${HELPERS}/codex-code-mode-host" --entitlements "$CODEX_ENTITLEMENTS_PATH"' \
            "$build_script" \
            || fail "$(basename "$build_script") does not sign the Codex code-mode host"
    done
}

test_telemetrydeck_adapter_allowlist() {
    local adapter_path="${TEST_DIR}/TelemetryDeckClient.swift"

    printf '%s\n' \
        'await Task.detached(priority: .utility) {' \
        'let configuration = TelemetryDeck.Config(appID: appID)' \
        'configuration.testMode = testMode' \
        'configuration.defaultParameters = { ["runtime": "app"] }' \
        'TelemetryDeck.initialize(config: configuration)' \
        'TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)' > "$adapter_path"
    validate_telemetrydeck_adapter "$adapter_path" "app"

    printf '%s\n' 'TelemetryDeck.updateDefaultUserID(to: userID)' >> "$adapter_path"
    expect_failure validate_telemetrydeck_adapter "$adapter_path" "app"

    printf '%s\n' \
        'await Task.detached(priority: .utility) {' \
        'let configuration = TelemetryDeck.Config(appID: appID)' \
        'configuration.testMode = testMode' \
        'configuration.defaultParameters = parameters' \
        'TelemetryDeck.initialize(config: configuration)' \
        'TelemetryDeck.signal(name, parameters: parameters)' > "$adapter_path"
    expect_failure validate_telemetrydeck_adapter "$adapter_path" "app"
}

test_codesigning_keychain_unlock() {
    local keychain_log="${TEST_DIR}/keychain.log"
    local keychain_mode="locked"

    security() {
        printf '<%s>\n' "$@" >> "$keychain_log"
        case "$1" in
            default-keychain) printf '%s\n' '    "/tmp/Test Keychain.keychain-db"' ;;
            show-keychain-info) [ "$keychain_mode" = "unlocked" ] ;;
            unlock-keychain) [ "$keychain_mode" != "failure" ] ;;
            *) return 1 ;;
        esac
    }

    SIGN_IDENTITY="Developer ID Application: Test"
    unset CODESIGN_KEYCHAIN
    unlock_codesigning_keychain_if_needed
    grep -Fxq '</tmp/Test Keychain.keychain-db>' "$keychain_log" \
        || fail "quoted default keychain path was not normalized"

    : > "$keychain_log"
    keychain_mode="unlocked"
    unlock_codesigning_keychain_if_needed
    ! grep -Fxq '<unlock-keychain>' "$keychain_log" \
        || fail "an unlocked keychain was unlocked again"

    keychain_mode="failure"
    expect_failure unlock_codesigning_keychain_if_needed

    : > "$keychain_log"
    SIGN_IDENTITY="-"
    unlock_codesigning_keychain_if_needed
    [ ! -s "$keychain_log" ] || fail "ad-hoc signing should not access a keychain"

    unset -f security
    unset SIGN_IDENTITY
}

test_pre_commit_compatibility_entrypoint() {
    local fake_repo="${TEST_DIR}/pre-commit-repo"

    git init -q "$fake_repo"
    mkdir -p "${fake_repo}/apps/desktop/scripts"
    cp "${REPOSITORY_DIR}/scripts/pre-commit" "${fake_repo}/.git/hooks/pre-commit"
    printf '%s\n' '#!/bin/bash' ': > hook-ran' > "${fake_repo}/apps/desktop/scripts/pre-commit"
    chmod +x "${fake_repo}/.git/hooks/pre-commit" "${fake_repo}/apps/desktop/scripts/pre-commit"

    (cd "$fake_repo" && .git/hooks/pre-commit)
    [ -f "${fake_repo}/hook-ran" ] || fail "installed pre-commit hook did not reach the desktop implementation"
}

test_build_version_validation
test_latest_release_build_validation
test_release_notes_validation_and_snapshot
test_sparkle_configuration_validation
test_appcast_validation
test_sparkle_appcast_creation
test_release_upload_arguments
test_cleanup_removes_previous_release_plist
test_framework_embedding_validation
test_whisperkit_license_embedding_validation
test_lindera_license_embedding_validation
test_telemetrydeck_configuration_and_embedding
test_codex_code_mode_host_packaging
test_telemetrydeck_adapter_allowlist
test_codesigning_keychain_unlock
test_pre_commit_compatibility_entrypoint

echo "Release script tests passed"
