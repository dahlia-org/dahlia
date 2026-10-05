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
