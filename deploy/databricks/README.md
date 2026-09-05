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
                  ├─ app service principal ── Model discovery and embeddings
                  ├─ app service principal ── Lakebase PostgreSQL
                  └─ app service principal ── managed Volume / Files API
```

## Prerequisites

- A Databricks workspace with Databricks Apps, Lakebase Autoscaling, and access to the Lakebase Search preview.
- Permission to create Apps and Lakebase projects and query the configured Responses and embedding models.
- Databricks CLI 1.4.0 or newer with `ai-gateway get-model-service` and `create-model-service` support (verified with 1.12.1), authenticated with a CLI profile or environment variables.
- Bash and jq for postdeploy.
- Node.js 22.13 or newer, Corepack, and pnpm for local validation.

## Configure

The first authenticated user becomes the initial administrator. Additional administrators must authenticate once before they can be promoted under `/admin/members`.

Dahlia Desktop requests `all-apis` when authorizing against a deployed Databricks App. Separately, the App resource keeps `user_api_scopes` set to `ai-gateway` and `files`; these scopes govern only the Apps proxy's OBO token and are not the Desktop API capability scope. Dahlia uses `X-Forwarded-Access-Token` as Bearer authentication only for the workspace OpenAI-compatible Responses API at `DATABRICKS_HOST/ai-gateway/mlflow/v1/responses`. Configured-schema model discovery and background embedding requests use short-lived App service principal tokens obtained from the runtime-injected `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; no provider secret or forwarded user token is stored. Dahlia also uses the runtime-provided `DATABRICKS_APP_URL` as its canonical public origin, so the bundle does not need to reference its own App URL. `/mcp` needs no additional user API scope: the Apps proxy authenticates the caller and supplies verified identity headers, while artifact bytes use the App service principal's existing Volume permission.

The default App names are `dahlia-dev` for `dev` and `dahlia-prod` for `prod`. The corresponding Lakebase project IDs are `dahlia-db-dev` and `dahlia-db`. By default, both targets use the managed Volume `dahlia.app.storage`. Choose the deployment environment by overriding `catalog`; override `app_schema` only when a catalog needs more than one Dahlia Server installation. Explicit Vault sharing is enabled for the private `dev` target and remains disabled by default elsewhere. The bundle exposes `codex-auto-review` through `system.ai.gpt-5-6-luna`; override `codex_auto_review_model` to use another upstream model or set it to a blank value to disable the alias. The bundle enables Hybrid search with `system.ai.qwen3-embedding-0-6b` at 1024 dimensions; set `--var search_embedding_model=' '` to keep FTS only, or override both search variables for another compatible model.

The bundle syncs only the self-contained `apps/server` package. Its package manifest, pnpm lockfile, runtime configuration, and source are deployed without repository-root pnpm files.

## Validate and deploy

```bash
databricks bundle validate --strict -t dev
databricks bundle deploy -t dev
databricks bundle run dahlia_server -t dev
databricks bundle summary -t dev
```

Use `-t prod` for production and pass its catalog explicitly when it differs from `dahlia`, for example `--var catalog=dahlia_prod`. The production Lakebase project, storage Volume, and schema have `lifecycle.prevent_destroy: true`; destructive changes fail until an operator deliberately removes that protection. Development uses separate disposable resources.

`bundle deploy` creates or updates the resources and uploads source code, but it does not restart an already-running App. Always run `dahlia_server` after deployment.

After each deployment, the bundle requests Lakebase Search enablement through the Search Extensions API using the same resolved CLI profile as the bundle deployment. The deployment fails if that request fails; it does not wait, retry, or poll the returned operation. The separate App build/start step provides the expected propagation interval.

The App resource grants its service principal `CAN_CONNECT_AND_CREATE` on the project's default `databricks_postgres` database and `WRITE_VOLUME` on the target managed Volume. Databricks injects `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER`; the `postgres` resource key supplies `LAKEBASE_ENDPOINT`. Dahlia creates the generated Better Auth `auth` schema in every authentication mode, then creates `app` for all Dahlia-owned tables under the same advisory lock before starting the Node server. Header mode keeps Better Auth endpoints disabled and projects each proxy-verified identity into `auth.user`. Stored bytes are uploaded and streamed through `/api/2.0/fs/files/Volumes/...`; no Volume credential is issued to clients.

Lakebase UI schema listings can differ by the connected PostgreSQL role and its visibility. Verify the migration result from the SQL editor or another PostgreSQL client instead of relying on the schema browser:

```sql
SELECT to_regnamespace('auth') AS auth_schema,
       to_regclass('auth."user"') AS auth_user_table;
```

Both columns must be non-null. A successful authenticated header request also proves the table is usable because Dahlia projects that identity into `auth.user` before handling the request.

Dahlia installs `lakebase_text` and creates the unified BM25 index during migration. When an embedding model is configured it also installs `lakebase_vector` and creates a dimension- and model-specific `lakebase_ann` index. Failure to load either configured capability stops migration instead of silently changing search semantics. Grant the App service principal query permission on the embedding model. After the Desktop completes the first full Vault synchronization, run `VACUUM app.search_documents;` against the application database so BM25 corpus statistics include the uploaded rows.

## Initial AI models

The bundle creates `${catalog}.${ai_schema}` (default `dahlia.ai`) and sets `DATABRICKS_MODEL_SCHEMA` to that schema. It is independent of `app_schema` (default `app`), which contains stored content. The postdeploy Bash script preserves Lakebase search-extension activation, then registers these model services using the foundation-model destinations of the corresponding `system.ai` services:

| Registered name | Source service |
| --- | --- |
| `gpt-5-6-luna` | `system.ai.gpt-5-6-luna` |
| `gpt-6-astra` | `system.ai.gpt-6-astra` |
| `gpt-5-6-sol` | `system.ai.gpt-5-6-sol` |
| `gpt-5-6-terra` | `system.ai.gpt-5-6-terra` |
| `kimi-k3` | `system.ai.kimi-k3` |
| `deepseek-v4-pro` | `system.ai.deepseek-v4-pro-0813` |

This is a temporary registration step: it does not check for existing models or retry conflicts. If a model already exists, the CLI creation error stops postdeploy; remove or skip its registration for subsequent deployments. Model creation uses `databricks ai-gateway create-model-service`; `get-model-service` and jq resolve and validate each source foundation-model destination. No inference payload logging is enabled by the script.

The bundle grants `EXECUTE` on the AI schema to `account users`, inherited by its model services. The deployment principal needs `USE CATALOG`, `USE SCHEMA`, `CREATE SERVICE`, permission to manage schema grants, and access to the source models. The App service principal needs visibility of the target model services; users still need `USE CATALOG` and `USE SCHEMA`, managed by the operator. If the AI schema already exists outside the bundle, bind the `ai_schema` schema resource before deployment rather than creating a duplicate. Deployments sharing a catalog must share one schema owner/bundle management arrangement.

The existing `codex_auto_review_model` variable remains independent of discovery and defaults to `system.ai.gpt-5-6-luna`. It sets `CODEX_AUTO_REVIEW_MODEL`; the Server applies this override for every backend and sends its value unchanged. It need not be a member of `DATABRICKS_MODEL_SCHEMA`.

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

For MCP, connect a modern MCP 2026-07-28 client to `https://<app-host>/mcp` with Databricks Apps token authentication. Confirm that `tools/list` returns four artifact tools plus five synchronized meeting/screenshot read tools, verify that only the caller's Vaults are readable, then create a private artifact, publish it, and delete it. Dahlia trusts the proxy-authenticated forwarded identity in this deployment and does not run its own Better Auth OAuth exchange.

Confirm `/api/v1/models` includes `gpt-5-6-luna`, then complete a real `POST /api/v1/responses` request with that short model ID, `input`, and `stream: true`. Confirm SSE events arrive incrementally through the Apps proxy. Model management is now in Databricks; `/admin/models` is retired.

## Security requirements

- Trust `X-Forwarded-User`, `X-Forwarded-Preferred-Username`, and `X-Forwarded-Email` only behind the Databricks Apps proxy.
- `X-Forwarded-Access-Token` is trusted only behind the Databricks Apps proxy, converted to the Responses upstream Bearer credential, and never persisted or logged. Model discovery never uses it.
- Responses request and response content is streamed without being persisted or logged. Synchronized summary, OCR, caption text, and search query text may be sent to the configured embedding model; only the resulting rebuildable vectors are persisted, and request content is not logged.
- Artifact bytes are content-agnostic and are not inspected or sanitized. Metadata is owner-scoped and private by default.
- `/healthz` is process liveness only; anonymous external access is not guaranteed.
