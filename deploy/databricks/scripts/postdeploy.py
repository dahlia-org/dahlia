#!/usr/bin/env python3
"""Enable Lakebase search and register the initial AI model service."""
import argparse
import json
import subprocess
from urllib.parse import urlencode


def api(profile, method, path, body=None):
    command = ["databricks", "api", method, path, "--profile", profile, "--output", "json"]
    if body is not None:
        command += ["--json", json.dumps(body)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        # Do not echo upstream bodies or CLI diagnostics that may contain credentials.
        raise RuntimeError(f"Databricks {method} failed (exit {result.returncode})")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def postdeploy(profile, catalog, database_project_id):
    api(profile, "post", f"/api/2.0/postgres/projects/{database_project_id}/search-extensions", {})
    schema = f"{catalog}.ai"
    source = api(profile, "get", "/api/2.1/unity-catalog/model-services/system.ai.gpt-5-6-luna")
    destinations = source["config"]["routing"]["destinations"]
    if len(destinations) != 1 or destinations[0].get("destination_type") != "DESTINATION_TYPE_PAY_PER_TOKEN_FOUNDATION_MODEL":
        raise RuntimeError("Expected a single pay-per-token foundation model destination")
    model = destinations[0]["pay_per_token_config"]["model"]
    if not isinstance(model, str) or not model.startswith("models/system.ai."):
        raise RuntimeError("Invalid foundation model destination")
    query = urlencode({"parent": f"schemas/{schema}", "model_service_id": "gpt-5-6-luna"})
    api(profile, "post", "/api/2.1/unity-catalog/model-services?" + query, {
        "config": {"routing": {"destinations": [{
            "name": "primary",
            "destination_type": "DESTINATION_TYPE_PAY_PER_TOKEN_FOUNDATION_MODEL",
            "pay_per_token_config": {"model": model},
            "traffic_percentage": 100,
        }]}}
    })
    print("Initial model service created.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--database-project-id", required=True)
    args = parser.parse_args()
    postdeploy(args.profile, args.catalog, args.database_project_id)
