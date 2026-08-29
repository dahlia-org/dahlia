# Deploy Dahlia Server on Databricks Apps

This bundle creates a Databricks App and a dedicated Lakebase Autoscaling project for each target. The Apps proxy authenticates requests before they reach Dahlia Server, so the deployment uses header identity without creating Better Auth sessions.

```text
browser / Dahlia Codex with U2M token
        │
        ▼
Databricks Apps proxy
        │ X-Forwarded-User / X-Forwarded-Preferred-Username / X-Forwarded-Email
        ▼
Dahlia Server App ─┬─ app service principal ── Databricks AI Gateway
                  ├─ app service principal ── Lakebase PostgreSQL
                  └─ app service principal ── managed Volume / Files API
```

## Prerequisites

- A Databricks workspace with Databricks Apps and Lakebase Autoscaling enabled.
- Permission to create Apps and Lakebase projects and query the configured AI Gateway models.
- Databricks CLI 1.4.0 or newer, authenticated with a CLI profile or environment variables.
- Node.js 22.13 or newer, Corepack, and pnpm for local validation.

## Configure

Optionally bootstrap an administrator:

```bash
export BUNDLE_VAR_admin_email="admin@example.com"
```

The App requests the `ai-gateway` and `files` user authorization scopes. It uses its Databricks service principal to obtain short-lived OAuth credentials and calls the workspace OpenAI-compatible AI Gateway at `DATABRICKS_HOST/ai-gateway/openai/v1`. No provider secret is required. Dahlia also uses the runtime-provided `DATABRICKS_APP_URL` as its canonical public origin, so the bundle does not need to reference its own App URL.

The default App names are `dahlia-dev` for `dev` and `dahlia-prod` for `prod`. The corresponding Lakebase project IDs are `dahlia-db-dev` and `dahlia-db`. The bundle creates separate managed Volumes named `main.default.dahlia_artifacts_dev` and `main.default.dahlia_artifacts`; override the `artifact_catalog`, `artifact_schema`, or `artifact_volume_name` variables when needed.

## Validate and deploy

```bash
databricks bundle validate --strict -t dev
databricks bundle deploy -t dev
databricks bundle run dahlia_server -t dev
databricks bundle summary -t dev
```

Use `-t prod` for production. The production Lakebase project and artifact Volume have `lifecycle.prevent_destroy: true`; destructive changes fail until an operator deliberately removes that protection. Development uses separate disposable resources.

`bundle deploy` creates or updates the resources and uploads source code, but it does not restart an already-running App. Always run `dahlia_server` after deployment.

The App resource grants its service principal `CAN_CONNECT_AND_CREATE` on the project's default `databricks_postgres` database and `WRITE_VOLUME` on the target managed Volume. Databricks injects `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER`; the `postgres` resource key supplies `LAKEBASE_ENDPOINT`. Dahlia creates and owns the `auth` schema for Better Auth tables and the `dahlia` schema for application tables through that service principal, applies migrations under an advisory lock, and then starts the Node server. Artifact bytes are uploaded and streamed through `/api/2.0/fs/files/Volumes/...`; no Volume credential is issued to clients.

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

For an artifact smoke test, upload an HTML file with a new lowercase UUID, read it privately, set `visibility` to `public`, read the same stable API URL without authentication, make it private again, and delete it. Use `Content-Length` and keep the bearer token out of shell history.

Sign in as the configured administrator, create a public Model Alias under `/admin/models`, and complete a real `POST /api/v1/responses` request with `stream: true`. Confirm that SSE events arrive incrementally through the Apps proxy.

## Security requirements

- Trust `X-Forwarded-User`, `X-Forwarded-Preferred-Username`, and `X-Forwarded-Email` only behind the Databricks Apps proxy.
- Provider credentials are short-lived OAuth tokens obtained with the App service principal and are sent only to the workspace AI Gateway.
- Responses request and response content is streamed without being persisted or logged.
- Artifact bytes are content-agnostic and are not inspected or sanitized. Metadata is owner-scoped and private by default.
- `/healthz` is process liveness only; anonymous external access is not guaranteed.
