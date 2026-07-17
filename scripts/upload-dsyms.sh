#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/common.sh"

if [ $# -lt 1 ]; then
    echo "usage: $0 <build-dir> [app-name]" >&2
    exit 1
fi

BUILD_DIR="$1"
APP_NAME="${2:-Dahlia}"
DSYM_PATH="${BUILD_DIR}/${APP_NAME}.dSYM"
EXECUTABLE_PATH="${BUILD_DIR}/${APP_NAME}"
DSYM_EXECUTABLE_PATH="${DSYM_PATH}/Contents/Resources/DWARF/${APP_NAME}"

cd "$PROJECT_DIR"

if [ -f .env.local ]; then
    set -a
    source .env.local
    set +a
fi

SENTRY_ORG="${SENTRY_ORG:-dahlia-app}"
SENTRY_PROJECT="${SENTRY_PROJECT:-dahlia-app}"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    echo "error: SENTRY_AUTH_TOKEN is required to upload dSYM files" >&2
    exit 1
fi

require_commands awk dwarfdump sentry-cli sort

if [ ! -f "$EXECUTABLE_PATH" ]; then
    echo "error: release executable not found: ${EXECUTABLE_PATH}" >&2
    exit 1
fi

if [ ! -f "$DSYM_EXECUTABLE_PATH" ]; then
    echo "error: dSYM executable not found: ${DSYM_EXECUTABLE_PATH}" >&2
    exit 1
fi

EXECUTABLE_UUIDS="$(dwarfdump --uuid "$EXECUTABLE_PATH" | awk '/^UUID:/ { print $2 }' | LC_ALL=C sort)"
DSYM_UUIDS="$(dwarfdump --uuid "$DSYM_EXECUTABLE_PATH" | awk '/^UUID:/ { print $2 }' | LC_ALL=C sort)"
if [ -z "$EXECUTABLE_UUIDS" ] || [ "$EXECUTABLE_UUIDS" != "$DSYM_UUIDS" ]; then
    cat >&2 <<EOF
error: executable and dSYM UUIDs do not match
  executable: ${EXECUTABLE_UUIDS:-<none>}
  dSYM:       ${DSYM_UUIDS:-<none>}
EOF
    exit 1
fi

UPLOAD_ARGUMENTS=(
    debug-files upload
    --org "$SENTRY_ORG"
    --project "$SENTRY_PROJECT"
)
case "${SENTRY_INCLUDE_SOURCES:-}" in
    "" | 0 | false | FALSE | no | NO)
        echo "=== Source context upload disabled ==="
        ;;
    1 | true | TRUE | yes | YES)
        echo "=== Source context upload explicitly enabled ==="
        UPLOAD_ARGUMENTS+=(--include-sources)
        ;;
    *)
        echo "error: SENTRY_INCLUDE_SOURCES must be 0/1, false/true, or no/yes" >&2
        exit 1
        ;;
esac
UPLOAD_ARGUMENTS+=("$DSYM_PATH")

echo "=== Uploading dSYM to Sentry (${SENTRY_ORG}/${SENTRY_PROJECT}) ==="
sentry-cli "${UPLOAD_ARGUMENTS[@]}"
