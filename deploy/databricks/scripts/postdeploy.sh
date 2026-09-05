#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: postdeploy.sh PROFILE CATALOG AI_SCHEMA DATABASE_PROJECT_ID" >&2
  exit 1
fi
profile=$1
catalog=$2
ai_schema=$3
database_project_id=$4

# Keep upstream response bodies and CLI diagnostics out of deployment logs.
cli() {
  if ! databricks "$@" --profile "$profile" --output json 2>/dev/null; then
    echo "Databricks command failed: $1 $2" >&2
    return 1
  fi
}

cli grants update catalog "$catalog" --json '{"changes":[{"principal":"account users","add":["USE_CATALOG"]}]}' >/dev/null

cli api post "/api/2.0/postgres/projects/${database_project_id}/search-extensions" --json '{}' >/dev/null

for source_name in gpt-5-6-luna gpt-6-astra gpt-5-6-sol gpt-5-6-terra kimi-k3 deepseek-v4-pro-0813; do
  registered_name=${source_name%-0813}
  body=$(cli ai-gateway get-model-service "model-services/system.ai.${source_name}" | jq -ce '
    .config.routing.destinations
    | if length == 1 and .[0].destination_type == "DESTINATION_TYPE_PAY_PER_TOKEN_FOUNDATION_MODEL"
      then .[0].pay_per_token_config.model
      else error("Expected a single pay-per-token foundation model destination") end
    | if type == "string" and startswith("models/system.ai.")
      then . else error("Invalid foundation model destination") end
    | {config: {routing: {destinations: [{
        name: "primary",
        destination_type: "DESTINATION_TYPE_PAY_PER_TOKEN_FOUNDATION_MODEL",
        pay_per_token_config: {model: .},
        traffic_percentage: 100
      }]}}}
  ')
  cli ai-gateway create-model-service "schemas/${catalog}.${ai_schema}" "$registered_name" --json "$body" >/dev/null
done

echo "Initial model services created."
