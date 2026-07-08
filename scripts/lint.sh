#!/bin/bash
# SwiftFormat + SwiftLint を実行するスクリプト
set -euo pipefail

cd "$(dirname "$0")/.."

is_ci=false
if [[ "${CI:-}" == "true" ]]; then
    is_ci=true
fi

echo "=== SwiftFormat ==="
if ! command -v swiftformat &>/dev/null; then
    echo "SwiftFormat not found. Install: brew install swiftformat"
    exit 1
fi

if [[ "$is_ci" == "true" ]]; then
    swiftformat --lint Sources/
else
    swiftformat Sources/
fi
echo "SwiftFormat: done"

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

if [[ "$is_ci" == "true" ]]; then
    if ! swiftlint lint --quiet; then
        echo "SwiftLint reported violations. Keeping non-blocking until existing violations are cleaned up."
    fi
else
    swiftlint lint --quiet || true
fi
echo "SwiftLint: done"
