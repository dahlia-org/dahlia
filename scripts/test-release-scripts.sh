#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
exec "${repo_root}/apps/desktop/scripts/test-release-scripts.sh" "$@"
