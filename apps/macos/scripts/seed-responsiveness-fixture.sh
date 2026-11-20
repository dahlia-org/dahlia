#!/bin/bash
# Seed the development profile with the responsiveness fixture: 500 meetings, a 5000-segment transcript,
# 500 screenshots, and a chat thread with 50 KB answers. Run before launching ./scripts/run-dev.sh.
# Only a linked worktree's .dahlia profile is accepted, so the production database is never written.
set -euo pipefail

cd "$(dirname "$0")/../../.."
if [[ ! -f .git ]] || [[ ! "$(sed -n 's/^gitdir:[[:space:]]*//p' .git)" =~ /worktrees/[^/]+/?$ ]]; then
    echo "error: run this from a linked worktree; its .dahlia profile receives the fixture" >&2
    exit 1
fi
database="$(pwd -P)/.dahlia/dahlia.sqlite"
for file in "$database" "${database}-wal"; do
    if [[ -e "$file" ]] && /usr/sbin/lsof -t -- "$file" >/dev/null 2>&1; then
        echo "error: the development database is in use; quit Dahlia first" >&2
        exit 1
    fi
done
mkdir -p "$(dirname "$database")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DAHLIA_RESPONSIVENESS_FIXTURE_DB="$database" \
    swift test --build-system native --arch arm64 --filter 'ResponsivenessFixtureSeeder' "$@"
