# Deploy Dahlia Server on Databricks Apps

This bundle creates a Databricks App and a dedicated Lakebase Autoscaling project, role, and database for each target. The Apps proxy authenticates requests before they reach Dahlia Server, so the deployment uses header identity without creating Better Auth sessions.

```text
browser / Dahlia Codex with U2M token
        │
        ▼
Databricks Apps proxy
        │ X-Forwarded-Email
        ▼
Dahlia Server App ─┬─ Databricks Secret ── OpenAI-compatible Responses API
                  └─ app service principal ── Lakebase PostgreSQL
```

## Prerequisites

- A Databricks workspace with Databricks Apps and Lakebase Autoscaling enabled.
- Permission to create Apps and Lakebase projects and to read the configured secret.
- Databricks CLI 1.4.0 or newer, authenticated with a CLI profile or environment variables.
- An existing Databricks secret containing the upstream API key or bearer token. The bundle references the secret but never stores its value.
- Node.js 22.13 or newer, Corepack, and pnpm for local validation.

## Configure

From `deploy/databricks`, export the required bundle variables:

```bash
export BUNDLE_VAR_admin_email="admin@example.com"
export BUNDLE_VAR_openai_secret_scope="dahlia"
export BUNDLE_VAR_openai_secret_key="openai-api-key"
```

The upstream defaults to the workspace OpenAI-compatible AI Gateway endpoint. Override it for OpenAI or another compatible provider:

```bash
export BUNDLE_VAR_openai_base_url=https://api.openai.com/v1
```

The default resource names are `dahlia-server-dev` for `dev` and `dahlia-server` for `prod`. Override `BUNDLE_VAR_app_name` and `BUNDLE_VAR_database_project_id` when those names are already in use.

## Validate and deploy

```bash
databricks bundle validate --strict -t dev
databricks bundle deploy -t dev
databricks bundle run dahlia_server -t dev
databricks bundle summary -t dev
```

Use `-t prod` for production. The production Lakebase project and `dahlia` database have `lifecycle.prevent_destroy: true`; destructive changes fail until an operator deliberately removes that protection. Development deletion uses Lakebase's recoverable soft-delete behavior.

`bundle deploy` creates or updates the resources and uploads source code, but it does not restart an already-running App. Always run `dahlia_server` after deployment.

The App resource grants its service principal `CAN_CONNECT_AND_CREATE` on the generated `dahlia` database. Databricks injects `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER`; the `postgres` resource key supplies `LAKEBASE_ENDPOINT`. Dahlia refreshes database OAuth credentials through the official Lakebase connector, applies migrations under an advisory lock, and then starts the Node server.

## Smoke test

Wait for the App to reach `RUNNING`, then retrieve its URL from `bundle summary` and use a workspace access token:

```bash
TOKEN="$(databricks auth token --output json | jq -r .access_token)"

curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  https://<app-host>/api/session

curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  https://<app-host>/api/v1/models
```

Sign in as the configured administrator, create a public Model Alias under `/admin/models`, and complete a real `POST /api/v1/responses` request with `stream: true`. Confirm that SSE events arrive incrementally through the Apps proxy.

## Security requirements

- Trust `X-Forwarded-Email` only behind the Databricks Apps proxy. Dahlia ignores `X-Forwarded-User`.
- Provider credentials are injected from Databricks Secrets and are sent only to the configured upstream endpoint.
- Responses request and response content is streamed without being persisted or logged.
- `/healthz` is process liveness only; anonymous external access is not guaranteed.
