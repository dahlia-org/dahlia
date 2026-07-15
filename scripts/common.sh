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
