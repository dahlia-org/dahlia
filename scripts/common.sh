#!/bin/bash

_dahlia_common_source="${BASH_SOURCE[0]:-$0}"
_dahlia_repo_root="$(cd "$(dirname "${_dahlia_common_source}")/.." && pwd)"
source "${_dahlia_repo_root}/apps/desktop/scripts/common.sh"
unset _dahlia_common_source _dahlia_repo_root
