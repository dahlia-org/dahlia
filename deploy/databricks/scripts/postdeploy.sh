#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: postdeploy.sh PROFILE DATABASE_PROJECT_ID SERVER_APP HINDSIGHT_APP" >&2
  exit 1
fi
profile=$1
database_project_id=$2

databricks api post "/api/2.0/postgres/projects/${database_project_id}/search-extensions" \
  --json '{}' \
  --profile "$profile" >/dev/null

# Grant only the Server service principal access to the memory service. Do this
# after creation to avoid a resource cycle between the App URL and its principal.
permissions_file=$(mktemp)
trap 'rm -f "$permissions_file"' EXIT
databricks apps get "$3" --profile "$profile" --output json |
  python3 -c 'import json,sys; app=json.load(sys.stdin); print(json.dumps({"access_control_list":[{"service_principal_name":app["service_principal_client_id"],"permission_level":"CAN_USE"}]}))' > "$permissions_file"
databricks apps update-permissions "$4" --json "@$permissions_file" --profile "$profile" >/dev/null
