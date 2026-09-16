#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: postdeploy.sh PROFILE CATALOG DATABASE_PROJECT_ID DAHLIA_APP_NAME HINDSIGHT_APP_NAME" >&2
  exit 1
fi
profile=$1
catalog=$2
database_project_id=$3
dahlia_app_name=$4
hindsight_app_name=$5

# Keep successful response bodies quiet, but preserve CLI failure diagnostics.
cli() {
  if ! databricks "$@" --profile "$profile" --output json; then
    echo "Databricks command failed: $1 $2 (${3:-})" >&2
    return 1
  fi
}

app_service_principal() {
  cli apps get "$1" | jq -er '.service_principal_client_id | select(type == "string" and length > 0)' \
    || { echo "App service principal not found for app '$1'; check that the app deployed before postdeploy ran" >&2; return 1; }
}

dahlia_app_service_principal=$(app_service_principal "$dahlia_app_name")
hindsight_app_service_principal=$(app_service_principal "$hindsight_app_name")

catalog_grants=$(jq -cn \
  --arg dahlia "$dahlia_app_service_principal" \
  --arg hindsight "$hindsight_app_service_principal" \
  '{changes: [
    {principal: "account users", add: ["USE_CATALOG"]},
    {principal: $dahlia, add: ["USE_CATALOG"]},
    {principal: $hindsight, add: ["USE_CATALOG"]}
  ]}')
cli grants update catalog "$catalog" --json "$catalog_grants" >/dev/null

cli api post "/api/2.0/postgres/projects/${database_project_id}/search-extensions" --json '{}' >/dev/null
