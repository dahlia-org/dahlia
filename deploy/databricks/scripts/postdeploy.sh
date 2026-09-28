#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: postdeploy.sh PROFILE DATABASE_PROJECT_ID" >&2
  exit 1
fi
profile=$1
database_project_id=$2

databricks api post "/api/2.0/postgres/projects/${database_project_id}/search-extensions" \
  --json '{}' \
  --profile "$profile" >/dev/null
