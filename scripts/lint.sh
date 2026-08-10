#!/bin/bash
# SwiftFormat + SwiftLint を実行するスクリプト
set -euo pipefail

cd "$(dirname "$0")/.."
source "scripts/common.sh"

is_ci=false
if [[ "${CI:-}" == "true" ]]; then
    is_ci=true
fi

echo "=== SwiftFormat ==="
swiftformat_command="$PWD/scripts/run-swiftformat.sh"

if [[ "$is_ci" == "true" ]]; then
    "$swiftformat_command" --cache ignore --lint Sources/
else
    "$swiftformat_command" --cache ignore Sources/
fi
echo "SwiftFormat: done"

echo ""
echo "=== Telemetry policy ==="
telemetrydeck_adapter="Sources/Dahlia/Services/TelemetryDeckClient.swift"
telemetrydeck_imports="$(grep -RlE '^(@preconcurrency )?import TelemetryDeck$' Sources/Dahlia || true)"
telemetrydeck_calls="$(grep -RlE 'TelemetryDeck\.' Sources/Dahlia || true)"
if [ "$telemetrydeck_imports" != "$telemetrydeck_adapter" ] || [ "$telemetrydeck_calls" != "$telemetrydeck_adapter" ]; then
    echo "error: TelemetryDeck imports and SDK calls must stay inside ${telemetrydeck_adapter}" >&2
    exit 1
fi
validate_telemetrydeck_adapter "$telemetrydeck_adapter"
echo "Telemetry policy: done"

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

if [[ "$is_ci" == "true" ]]; then
    if ! "${swiftlint_command[@]}" lint --quiet --no-cache; then
        echo "SwiftLint reported violations. Keeping non-blocking until existing violations are cleaned up."
    fi
else
    "${swiftlint_command[@]}" lint --quiet --no-cache || true
fi
echo "SwiftLint: done"
