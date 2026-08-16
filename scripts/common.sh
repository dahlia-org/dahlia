#!/bin/bash
# Shared build and release helpers.

require_commands() {
    local command_name

    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "error: required command not found: ${command_name}" >&2
            return 1
        fi
    done
}

read_marketing_version() {
    local plist_path="$1"
    local version

    if [ ! -f "$plist_path" ]; then
        echo "error: Info.plist not found: ${plist_path}" >&2
        return 1
    fi

    version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path")"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: CFBundleShortVersionString must use x.y.z format: ${version}" >&2
        return 1
    fi

    printf '%s\n' "$version"
}

read_build_version() {
    local plist_path="$1"
    local version

    if [ ! -f "$plist_path" ]; then
        echo "error: Info.plist not found: ${plist_path}" >&2
        return 1
    fi

    version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist_path")"
    if [[ ! "$version" =~ ^[0-9]+$ ]]; then
        echo "error: CFBundleVersion must be a non-negative integer: ${version}" >&2
        return 1
    fi

    printf '%s\n' "$version"
}

configure_google_calendar_plist() {
    local plist_path="$1"

    /usr/libexec/PlistBuddy -c "Delete :GIDClientID" "$plist_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Delete :GOOGLE_CLIENT_ID" "$plist_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Delete :GOOGLE_CLIENT_SECRET" "$plist_path" >/dev/null 2>&1 || true

    if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
        /usr/libexec/PlistBuddy -c "Add :GOOGLE_CLIENT_ID string ${GOOGLE_CLIENT_ID}" "$plist_path"
    fi

    if [ -n "${GOOGLE_CLIENT_SECRET:-}" ]; then
        /usr/libexec/PlistBuddy -c "Add :GOOGLE_CLIENT_SECRET string ${GOOGLE_CLIENT_SECRET}" "$plist_path"
    fi
}

configure_sentry_plist() {
    local plist_path="$1"

    /usr/libexec/PlistBuddy -c "Delete :SENTRY_DSN" "$plist_path" >/dev/null 2>&1 || true

    if [ -n "${SENTRY_DSN:-}" ]; then
        /usr/libexec/PlistBuddy -c "Add :SENTRY_DSN string ${SENTRY_DSN}" "$plist_path"
    fi
}

configure_telemetrydeck_plist() {
    local plist_path="$1"

    /usr/libexec/PlistBuddy -c "Delete :TELEMETRYDECK_APP_ID" "$plist_path" >/dev/null 2>&1 || true

    if [ -n "${TELEMETRYDECK_APP_ID:-}" ]; then
        /usr/libexec/PlistBuddy -c "Add :TELEMETRYDECK_APP_ID string ${TELEMETRYDECK_APP_ID}" "$plist_path"
    fi
}

validate_telemetrydeck_adapter() {
    local adapter_path="$1"
    local runtime="$2"
    local actual_sdk_members
    local actual_configuration_members
    local expected_sdk_members=$'TelemetryDeck.Config\nTelemetryDeck.initialize\nTelemetryDeck.signal'
    local expected_configuration_members=$'configuration.defaultParameters\nconfiguration.testMode'

    actual_sdk_members="$(grep -Eo 'TelemetryDeck\.[A-Za-z][A-Za-z0-9_]*' "$adapter_path" | sort -u || true)"
    if [ "$actual_sdk_members" != "$expected_sdk_members" ]; then
        echo "error: TelemetryDeck adapter uses SDK members outside the approved allowlist" >&2
        return 1
    fi

    actual_configuration_members="$(grep -Eo 'configuration\.[A-Za-z][A-Za-z0-9_]*' "$adapter_path" | sort -u || true)"
    if [ "$actual_configuration_members" != "$expected_configuration_members" ]; then
        echo "error: TelemetryDeck adapter mutates configuration outside the approved allowlist" >&2
        return 1
    fi

    if ! grep -Eq 'Task\.detached\(priority: \.utility\)' "$adapter_path"; then
        echo "error: TelemetryDeck initialization must stay on the background utility task" >&2
        return 1
    fi

    if ! grep -Fq "configuration.defaultParameters = { [\"runtime\": \"${runtime}\"] }" "$adapter_path"; then
        echo "error: TelemetryDeck adapter must set its allowlisted runtime" >&2
        return 1
    fi

    if grep -Eq 'customUserID:' "$adapter_path"; then
        echo "error: custom user IDs are forbidden by docs/telemetry.md" >&2
        return 1
    fi
}

embed_telemetrydeck_resources() {
    local project_dir="$1"
    local build_dir="$2"
    local contents_dir="$3"
    local bundle_name="TelemetryDeck_TelemetryDeck.bundle"
    local resource_bundle="${build_dir}/${bundle_name}"
    local license_source="${project_dir}/.build/checkouts/SwiftSDK/LICENSE"
    local license_destination="${contents_dir}/Resources/Licenses/TelemetryDeck/LICENSE"

    if [ ! -d "$resource_bundle" ]; then
        echo "error: TelemetryDeck privacy resource bundle was not found" >&2
        return 1
    fi
    if [ ! -f "$license_source" ]; then
        echo "error: TelemetryDeck license was not found in the SwiftPM checkout" >&2
        return 1
    fi

    mkdir -p "${contents_dir}/Resources" "$(dirname "$license_destination")"
    cp -R "$resource_bundle" "${contents_dir}/Resources/"
    cp "$license_source" "$license_destination"
}

embed_sparkle_framework() {
    local project_dir="$1"
    local contents_dir="$2"
    local artifact_dir="${project_dir}/.build/artifacts/sparkle/Sparkle"
    local framework_candidate
    local framework_candidates=()
    local framework_source
    local framework_destination="${contents_dir}/Frameworks/Sparkle.framework"
    local license_source="${artifact_dir}/LICENSE"
    local license_destination="${contents_dir}/Resources/Licenses/Sparkle/LICENSE"

    while IFS= read -r framework_candidate; do
        framework_candidates+=("$framework_candidate")
    done < <(find "${artifact_dir}/Sparkle.xcframework" \
        -mindepth 2 -maxdepth 2 -type d -path '*/macos-*/Sparkle.framework' -print)
    if [ "${#framework_candidates[@]}" -ne 1 ]; then
        echo "error: expected one macOS Sparkle.framework, found ${#framework_candidates[@]}" >&2
        return 1
    fi
    framework_source="${framework_candidates[0]}"
    if [ ! -f "$license_source" ]; then
        echo "error: Sparkle license was not found in SwiftPM artifacts" >&2
        return 1
    fi
    if ! lipo "${framework_source}/Sparkle" -verify_arch arm64; then
        echo "error: Sparkle.framework does not contain arm64" >&2
        return 1
    fi

    mkdir -p "$(dirname "$framework_destination")" "$(dirname "$license_destination")"
    ditto "$framework_source" "$framework_destination"
    cp "$license_source" "$license_destination"
    if ! lipo "${framework_destination}/Sparkle" -verify_arch arm64; then
        echo "error: embedded Sparkle.framework does not contain arm64" >&2
        return 1
    fi
}

embed_whisperkit_licenses() {
    local project_dir="$1"
    local contents_dir="$2"
    local checkout_dir="${project_dir}/.build/checkouts/argmax-oss-swift"
    local destination_dir="${contents_dir}/Resources/Licenses/WhisperKit"
    local notice_name

    for notice_name in LICENSE NOTICES; do
        if [ ! -f "${checkout_dir}/${notice_name}" ]; then
            echo "error: WhisperKit ${notice_name} was not found in the SwiftPM checkout" >&2
            return 1
        fi
    done

    mkdir -p "$destination_dir"
    cp "${checkout_dir}/LICENSE" "${destination_dir}/LICENSE"
    cp "${checkout_dir}/NOTICES" "${destination_dir}/NOTICES"
    chmod u+w "${destination_dir}/LICENSE" "${destination_dir}/NOTICES"
}

embed_lindera_licenses() {
    local project_dir="$1"
    local contents_dir="$2"
    local destination_dir="${contents_dir}/Resources/Licenses/DahliaLindera"
    local notice_name

    for notice_name in DahliaLindera-LICENSE.txt DahliaLindera-THIRD-PARTY-NOTICES.txt; do
        if [ ! -f "${project_dir}/Vendor/${notice_name}" ]; then
            echo "error: DahliaLindera notice was not found: ${notice_name}" >&2
            return 1
        fi
    done

    mkdir -p "$destination_dir"
    cp "${project_dir}/Vendor/DahliaLindera-LICENSE.txt" "${destination_dir}/LICENSE"
    cp "${project_dir}/Vendor/DahliaLindera-THIRD-PARTY-NOTICES.txt" "${destination_dir}/THIRD-PARTY-NOTICES.txt"
}

has_entitlements() {
    local entitlements_path="$1"

    if [ ! -f "$entitlements_path" ]; then
        return 1
    fi

    plutil -convert xml1 -o - "$entitlements_path" 2>/dev/null | grep -q "<key>"
}

has_boolean_entitlement() {
    local path="$1"
    local entitlement_key="$2"
    local escaped_key value

    escaped_key="${entitlement_key//./\\.}"
    value="$(
        codesign -d --entitlements - --xml "$path" 2>/dev/null \
            | plutil -extract "$escaped_key" raw -o - - 2>/dev/null \
            || true
    )"
    [ "$value" = "true" ]
}

unlock_codesigning_keychain_if_needed() {
    local keychain_path="${CODESIGN_KEYCHAIN:-}"

    if [ "$SIGN_IDENTITY" = "-" ]; then
        return
    fi

    if [ -z "$keychain_path" ]; then
        if ! keychain_path="$(security default-keychain -d user 2>/dev/null)"; then
            echo "error: could not determine the default user keychain" >&2
            return 1
        fi
        keychain_path="${keychain_path#*\"}"
        keychain_path="${keychain_path%\"*}"
    fi

    if security show-keychain-info "$keychain_path" >/dev/null 2>&1; then
        return
    fi

    echo "=== Unlocking code-signing keychain: ${keychain_path} ==="
    if security unlock-keychain "$keychain_path"; then
        return
    fi

    cat >&2 <<EOF
error: the code-signing keychain could not be unlocked.

Unlock it in Keychain Access, or run:
  security unlock-keychain "${keychain_path}"
Then retry this command.
EOF
    return 1
}

codesign_path() {
    local path="$1"
    shift

    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@" "$path"
}

codesign_sparkle_framework() {
    local framework_path="$1"
    local version_path="${framework_path}/Versions/Current"

    codesign_path "${version_path}/XPCServices/Installer.xpc"
    codesign_path "${version_path}/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
    codesign_path "${version_path}/Autoupdate"
    codesign_path "${version_path}/Updater.app"
    codesign_path "$framework_path"
}
