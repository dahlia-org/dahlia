#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: postdeploy.sh PROFILE CATALOG AI_SCHEMA DATABASE_PROJECT_ID APP_NAME AUTH_SECRET_NAME" >&2
  exit 1
fi
profile=$1
catalog=$2
ai_schema=$3
database_project_id=$4
app_name=$5
auth_secret_name=$6

# Keep successful response bodies quiet, but preserve CLI failure diagnostics.
cli() {
  if ! databricks "$@" --profile "$profile" --output json; then
    echo "Databricks command failed: $1 $2 (${3:-})" >&2
    return 1
  fi
}

cli grants update catalog "$catalog" --json '{"changes":[{"principal":"account users","add":["USE_CATALOG"]}]}' >/dev/null

# READ_SECRET is not yet represented in the CLI's bundle grants enum.
app_principal=$(cli apps get "$app_name" | jq -er '.service_principal_client_id | select(type == "string" and length > 0)')
secret_grant=$(jq -nc --arg principal "$app_principal" '{changes: [{principal: $principal, add: ["READ_SECRET"]}]}')
secret_path=$(jq -nr --arg name "$auth_secret_name" '$name | @uri')
cli api patch "/api/2.1/unity-catalog/permissions/secret/${secret_path}" --json "$secret_grant" >/dev/null

cli api post "/api/2.0/postgres/projects/${database_project_id}/search-extensions" --json '{}' >/dev/null

# The CLI collects all pages unless --limit is supplied. Fail before creating
# anything if listing fails; a permission error does not mean a model is absent.
existing_models=$(cli ai-gateway list-model-services --parent "schemas/${catalog}.${ai_schema}" | jq -ce '
  if type == "array" then map(.name) else error("Expected a model service list") end
')

for mapping in gpt-5-6-luna gpt-6-astra gpt-5-6-sol gpt-5-6-terra kimi-k3 deepseek-v4-1-flash deepseek-v4-pro-0813 glm-5-3-flash glm-5-3 gemini-3-8-flash gemini-3-7-flash qwen3-embedding-0-6b codex-auto-review:gpt-5-6-luna; do
  registered_name=${mapping%%:*}
  source_name=${mapping##*:}
  target_name="model-services/${catalog}.${ai_schema}.${registered_name}"
  if jq -e --arg name "$target_name" 'index($name) != null' <<<"$existing_models" >/dev/null; then
    echo "Keeping existing model service: $target_name"
    continue
  fi
  echo "Creating model service: $target_name (source: system.ai.${source_name})"
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

echo "Initial model services ready."
