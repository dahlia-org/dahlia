#!/bin/bash
# SwiftFormat + SwiftLint を実行するスクリプト
set -euo pipefail

cd "$(dirname "$0")/../../.."
source "apps/macos/scripts/common.sh"

is_ci=false
if [[ "${CI:-}" == "true" ]]; then
    is_ci=true
fi

echo "=== SwiftFormat ==="
swiftformat_command="$PWD/apps/macos/scripts/run-swiftformat.sh"

if [[ "$is_ci" == "true" ]]; then
    "$swiftformat_command" --cache ignore --lint apps/macos/Sources/
else
    "$swiftformat_command" --cache ignore apps/macos/Sources/
fi
echo "SwiftFormat: done"

echo ""
echo "=== Telemetry policy ==="
telemetrydeck_app_adapter="apps/macos/Sources/Dahlia/Services/TelemetryDeckClient.swift"
telemetrydeck_mcp_adapter="apps/macos/Sources/DahliaMCP/TelemetryDeckClient.swift"
telemetrydeck_adapters="$(printf '%s\n%s' "$telemetrydeck_app_adapter" "$telemetrydeck_mcp_adapter" | sort)"
telemetrydeck_imports="$(grep -RlE '^(@preconcurrency )?import TelemetryDeck$' apps/macos/Sources | sort || true)"
telemetrydeck_calls="$(grep -RlE 'TelemetryDeck\.' apps/macos/Sources | sort || true)"
if [ "$telemetrydeck_imports" != "$telemetrydeck_adapters" ] || [ "$telemetrydeck_calls" != "$telemetrydeck_adapters" ]; then
    echo "error: TelemetryDeck imports and SDK calls must stay inside designated adapters" >&2
    exit 1
fi
validate_telemetrydeck_adapter "$telemetrydeck_app_adapter" "app"
validate_telemetrydeck_adapter "$telemetrydeck_mcp_adapter" "mcpHelper"
echo "Telemetry policy: done"

echo ""
echo "=== Resource bundle policy ==="
# SPM の Bundle.module は配布版 .app の Contents/Resources を探さず fatalError する。
if grep -RnE 'Bundle\.module|bundle: \.module' apps/macos/Sources --include='*.swift' \
    | grep -vE '/Bundle\+(AppModule|RuntimeSupport)\.swift:'; then
    echo "error: use Bundle.appModule or Bundle.runtimeSupport instead of Bundle.module" >&2
    exit 1
fi
echo "Resource bundle policy: done"

echo ""
echo "=== Concurrency policy ==="
# Task.detached is not a general way off MainActor (docs/spec/desktop/concurrency-and-projection.md). Existing calls are
# counted per file in the allowlist; a new file or a higher count fails.
task_detached_allowlist="apps/macos/scripts/task-detached-allowlist.txt"
task_detached_current="$(grep -RlE 'Task\.detached' apps/macos/Sources | sort | while read -r file; do
    echo "$(grep -cE 'Task\.detached' "$file") $file"
done)"
task_detached_violations="$(echo "$task_detached_current" | while read -r count file; do
    [ -z "$file" ] && continue
    allowed="$(awk -v f="$file" '$2 == f { print $1 }' "$task_detached_allowlist")"
    if [ -z "$allowed" ] || [ "$count" -gt "$allowed" ]; then echo "$file: $count Task.detached (allowed ${allowed:-0})"; fi
done)"
if [ -n "$task_detached_violations" ]; then
    echo "$task_detached_violations" >&2
    echo "error: use an owned worker, an actor, or GRDB's async read/write instead of a new Task.detached" >&2
    exit 1
fi
echo "Concurrency policy: done"

echo ""
echo "=== SwiftLint ==="
if ! command -v swiftlint &>/dev/null; then
    if [[ "$is_ci" == "true" ]]; then
        echo "SwiftLint not found. Install: brew install swiftlint"
        exit 1
    fi
    echo "SwiftLint not found (requires Xcode.app). Skipping."
    exit 0
fi

swiftlint_command=(swiftlint)
if [[ -z "${DEVELOPER_DIR:-}" ]] \
    && [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]] \
    && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    swiftlint_command=(env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint)
fi

"${swiftlint_command[@]}" lint \
    --config apps/macos/.swiftlint.yml \
    --strict \
    --quiet \
    --no-cache \
    apps/macos/Sources apps/macos/Tests
echo "SwiftLint: done"
