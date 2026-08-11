#!/bin/bash
# Run the SwiftFormat version managed by the BuildTools package.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" ]] \
    && [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]] \
    && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

exec swift run \
    --package-path "$repo_root/BuildTools" \
    --configuration release \
    --disable-automatic-resolution \
    swiftformat \
    "$@"
