# Deploy Dahlia Server on Databricks Apps

This bundle creates a Databricks App and a dedicated Lakebase Autoscaling project for each target. The Apps proxy authenticates requests before they reach Dahlia Server, so the deployment uses header identity without creating Better Auth sessions.

```text
browser / Dahlia Codex with U2M token
        │
        ▼
Databricks Apps proxy
        │ identity headers + X-Forwarded-Access-Token
        ▼
Dahlia Server App ─┬─ forwarded user token ── Databricks AI Gateway Responses
                  ├─ app service principal ── Model Services discovery
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

The App requests the `ai-gateway` and `files` user authorization scopes. It uses the Apps proxy's `X-Forwarded-Access-Token` as Bearer authentication only for the workspace OpenAI-compatible Responses API at `DATABRICKS_HOST/ai-gateway/mlflow/v1/responses`. System model discovery uses a short-lived App service principal token obtained from the runtime-injected `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; no provider secret is stored in the bundle. Dahlia also uses the runtime-provided `DATABRICKS_APP_URL` as its canonical public origin, so the bundle does not need to reference its own App URL. `/mcp` needs no additional user API scope: the Apps proxy authenticates the caller and supplies verified identity headers, while artifact bytes use the App service principal's existing Volume permission.

The default App names are `dahlia-dev` for `dev` and `dahlia-prod` for `prod`. The corresponding Lakebase project IDs are `dahlia-db-dev` and `dahlia-db`. The bundle uses the `dahlia_dev` catalog for development and `dahlia` for production, with a `server` schema and managed `storage` Volume in each target. Override `catalog`, `schema`, or `volume_name` when needed.

The bundle syncs only the self-contained `apps/server` package. Its package manifest, pnpm lockfile, runtime configuration, and source are deployed without repository-root pnpm files.

## Validate and deploy

```bash
databricks bundle validate --strict -t dev
databricks bundle deploy -t dev
databricks bundle run dahlia_server -t dev
databricks bundle summary -t dev
```

Use `-t prod` for production. The production Lakebase project has `lifecycle.prevent_destroy: true`; destructive project changes fail until an operator deliberately removes that protection. Development uses a separate disposable project.

`bundle deploy` creates or updates the resources and uploads source code, but it does not restart an already-running App. Always run `dahlia_server` after deployment.

The App resource grants its service principal `CAN_CONNECT_AND_CREATE` on the project's default `databricks_postgres` database and `WRITE_VOLUME` on the target managed Volume. Databricks injects `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER`; the `postgres` resource key supplies `LAKEBASE_ENDPOINT`. Dahlia creates `auth` for Better Auth and `dahlia` for application tables, applies schema-qualified Drizzle migrations under an advisory lock, and then starts the Node server. Artifact bytes are uploaded and streamed through `/api/2.0/fs/files/Volumes/...`; no Volume credential is issued to clients.

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

For an artifact smoke test, `POST` an HTML file to `/api/v1/artifacts`, read the returned UUIDv7 URL privately, replace it with `PUT`, set `visibility` to `public`, read the same stable API URL without authentication, make it private again, and delete it. Use `Content-Length` and keep the bearer token out of shell history.

For MCP, connect a modern MCP 2026-07-28 client to `https://<app-host>/mcp` with Databricks Apps token authentication. Confirm that `tools/list` returns the four artifact tools, create a private artifact, publish it, and delete it. Dahlia trusts the proxy-authenticated forwarded identity in this deployment and does not run its own Better Auth OAuth exchange.

Sign in as the configured administrator, enable a discovered model under `/admin/models`, and complete a real `POST /api/v1/responses` request with `stream: true`. Confirm that SSE events arrive incrementally through the Apps proxy. The Models page persists only the administrator's enabled or disabled selection as Dahlia Model Aliases; it does not persist the discovered model list.

## Security requirements

- Trust `X-Forwarded-User`, `X-Forwarded-Preferred-Username`, and `X-Forwarded-Email` only behind the Databricks Apps proxy.
- `X-Forwarded-Access-Token` is trusted only behind the Databricks Apps proxy, converted to the Responses upstream Bearer credential, and never persisted or logged. Model discovery never uses it.
- Responses request and response content is streamed without being persisted or logged.
- Artifact bytes are content-agnostic and are not inspected or sanitized. Metadata is owner-scoped and private by default.
- `/healthz` is process liveness only; anonymous external access is not guaranteed.
