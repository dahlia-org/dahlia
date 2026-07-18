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
