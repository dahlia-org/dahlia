# Deploy Dahlia Server on Databricks Apps

This bundle creates separate Dahlia Server and Hindsight Databricks Apps backed by one dedicated Lakebase Autoscaling project per target. Dahlia uses its existing PostgreSQL schemas and Hindsight uses `${hindsight_schema}` (default `hindsight`) in the same `databricks-postgres` database. The Apps proxy authenticates requests before they reach either App; Dahlia Server uses Header identity and sets `DAHLIA_AUTH_PROVIDER_ID=databricks` for linked Better Auth accounts.

```text
browser / Dahlia Codex with U2M token
        │
        ▼
Databricks Apps proxy
        │ identity headers + X-Forwarded-Access-Token
        ▼
Dahlia Server App ─┬─ forwarded user token ── Databricks AI Gateway Responses
                  ├─ app service principal ── Responses fallback / background AI jobs
                  ├─ app service principal ── Lakebase PostgreSQL
                  └─ app service principal ── managed Volume / Files API

Hindsight App ─────┬─ app service principal ── same Lakebase database / `hindsight` schema
                  └─ OpenAI-compatible API ─── Databricks AI Gateway models
```

## Prerequisites

- A Databricks workspace with Databricks Apps, Lakebase Autoscaling, and access to the Lakebase Search preview.
- Permission to create Apps and Lakebase projects and query the configured Responses and embedding models.
- Databricks CLI 1.4.0 or newer, authenticated with a CLI profile or environment variables.
- Bash for postdeploy.
- Node.js 22.13 or newer, Corepack, and pnpm for local validation.
- Python 3.11 or newer and uv for preparing the pinned Hindsight source before upload.

## Configure

The first authenticated user becomes the initial administrator. Additional administrators must authenticate once before they can be promoted under `/admin/members`.

Dahlia Desktop requests `all-apis` when authorizing against a deployed Databricks App. Separately, the App resource keeps `user_api_scopes` set to `ai-gateway` and `files`; these scopes govern only the Apps proxy's OBO token and are not the Desktop API capability scope. Dahlia prefers `X-Forwarded-Access-Token` as Bearer authentication for the workspace OpenAI-compatible Responses API at `DATABRICKS_HOST/ai-gateway/mlflow/v1/responses`. When that header is absent, and for background AI requests, it uses short-lived App service principal tokens obtained from `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; this fallback is independent of the Server runtime. No provider secret or forwarded user token is stored. The configured Codex model list performs no workspace discovery request. `DAHLIA_APP_URL` is the canonical public origin; when it is absent, Dahlia uses the runtime-provided `DATABRICKS_APP_URL`. `/mcp` needs no additional user API scope: the Apps proxy authenticates the caller and supplies verified identity headers, while file and recording bytes use the App service principal's existing Volume permission.

The bundle temporarily sets `DAHLIA_AUTH_SECRET` directly to the fixed value `test-only-better-auth-secret-value`. It does not define a Secret resource, retrieve a Unity Catalog Secret, or grant secret permissions. This is a shared test value; replace it with a unique signing secret before production use. Header authentication uses `DAHLIA_AUTH_HEADER` (default `X-Forwarded-Email`) as the email identity and stores its normalized value in `account.account_id`. New users join their email-domain Organization; the first is owner and later users are members. Departed or removed users are not automatically added again. `DAHLIA_SIGNOUT_URL=/.auth/logout` sends the browser through the Databricks Apps proxy logout endpoint after Dahlia clears its local session.

The App name is `mcp-dahlia-server-{target}`, for example `mcp-dahlia-server-dev` or `mcp-dahlia-server-prod`. The Hindsight App name is `dahlia-hindsight-{target}`. The corresponding Lakebase project IDs are `dahlia-db-dev` and `dahlia-db`. By default, both targets use the managed Volume `dahlia.app.storage`. Choose the deployment environment by overriding `catalog`; override `app_schema` only when a catalog needs more than one Dahlia Server installation. Explicit Vault sharing is available in every target; Vault Admins can grant Admin, Editor, or Viewer access to a user, Organization, or Team. Organization membership alone does not grant Vault access. The bundle lists public Gateway models in `DAHLIA_FOUNDATION_MODELS`, routes automatic reviews to `system.ai.gpt-5-6-luna`, and uses `system.ai.qwen3-embedding-0-6b` for search embeddings. All AI models are used directly; postdeploy does not register Model Services. To disable a worker, remove its model environment value from the App resource.

The bundle syncs the self-contained `apps/server` package and the setup notebooks in `deploy/databricks/notebooks`. The Server package manifest, pnpm lockfile, runtime configuration, and source are deployed without repository-root pnpm files. `pnpm test:package` builds and packs an isolated Server source directory without sibling Desktop files or existing build output, then checks the resulting package. The Server ships its own transcript activity policy JSON; a cross-platform test keeps it equal to the Desktop resource.

## Validate and deploy

```bash
databricks bundle validate --strict -t dev
databricks bundle deploy -t dev
databricks bundle run dahlia_server -t dev
databricks bundle run hindsight -t dev
databricks bundle summary -t dev
```

Use `-t prod` for production and pass its catalog explicitly when it differs from `dahlia`, for example `--var catalog=dahlia_prod`. The production Lakebase project, storage Volume, and schema have `lifecycle.prevent_destroy: true`; destructive changes fail until an operator deliberately removes that protection. Development uses separate disposable resources.

`bundle deploy` creates or updates the resources and uploads source code, but it does not restart an already-running App. Always run both `dahlia_server` and `hindsight` after deployment. The bundle's `prebuild` step materializes the pinned Hindsight v0.9.2 source and maintained Lakebase patch before upload; it does not follow newer upstream tags.

Hindsight's `databricks` model provider derives the OpenAI-compatible base URL from the App-injected `DATABRICKS_HOST`. It uses `system.ai.gpt-5-6-luna` for LLM calls and `system.ai.qwen3-embedding-0-6b` at `${search_embedding_dimensions}` dimensions for embeddings. The provider obtains and refreshes OAuth tokens with the App-injected `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; it never reads a user's forwarded OBO token or a Databricks secret resource.

Lakebase requires each `lakebase_bm25` index to be created after its table contains data. After Hindsight first writes `memory_units` or `mental_models`, create that table's index with the SQL in [`apps/hindsight/README.md`](../../apps/hindsight/README.md) before using full-text recall.

After each deployment, the bundle requests Lakebase Search enablement through the Search Extensions API using the same resolved CLI profile as the bundle deployment. The deployment fails if that request fails; it does not wait, retry, or poll the returned operation. The separate App build/start step provides the expected propagation interval.

The App resource grants its service principal `CAN_CONNECT_AND_CREATE` on the project's default `databricks_postgres` database and `WRITE_VOLUME` on the target managed Volume. Databricks injects `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER`; the `postgres` resource key supplies `LAKEBASE_ENDPOINT`. Dahlia creates the generated Better Auth `auth` schema in every authentication mode, then creates `app`, `search`, `crypto`, `jobs`, and the independently migrated `agent` schema under the same advisory lock before starting the Node server. Header mode projects each proxy-verified identity into `auth.user` and a linked `auth.account`, and uses Better Auth browser sessions for Web operations. Stored bytes are uploaded and streamed through `/api/2.0/fs/files/Volumes/...`; no Volume credential is issued to clients.

Lakebase UI schema listings can differ by the connected PostgreSQL role and its visibility. Verify the migration result from the SQL editor or another PostgreSQL client instead of relying on the schema browser:

```sql
SELECT to_regnamespace('auth') AS auth_schema,
       to_regclass('auth."user"') AS auth_user_table;
```

Both columns must be non-null. A successful authenticated header request also proves the table is usable because Dahlia projects that identity into `auth.user` before handling the request.

Dahlia installs `lakebase_text` and creates the unified BM25 index during migration. When an embedding model is configured it also installs `lakebase_vector` and creates a dimension- and model-specific `lakebase_ann` index. Failure to load either configured capability stops migration instead of silently changing search semantics. Grant the App service principal query permission on the embedding model. After the Desktop completes the first full Vault synchronization, run `VACUUM search.documents;` against the application database so BM25 corpus statistics include the uploaded rows.

The postdeploy regression check uses a fake CLI and does not access a workspace:

```bash
node --test scripts/postdeploy.test.mjs
```

## OTel tables

The bundle creates `${catalog}.${ops_schema}` (default `dahlia.ops`). Production
protects this schema with `lifecycle.prevent_destroy: true`. If the schema already
exists outside this bundle, bind the `ops_schema` resource before deployment.
Deployments sharing a catalog must use a single schema owner/bundle arrangement.

After deployment, manually run the unscheduled `create_otel_tables` job. It uses
one SQL notebook on serverless Jobs compute; no SQL warehouse or additional
libraries are required. The workspace must support serverless notebooks. The
deployment principal needs `USE CATALOG` and `CREATE SCHEMA` on the catalog; the
job's run-as principal needs `USE CATALOG`, `USE SCHEMA`, and `CREATE TABLE` on the
destination schema (or equivalent ownership).

Run these commands from `deploy/databricks`, using the same profile, target and
variable overrides for deployment and execution:

```bash
databricks bundle validate --strict -t dev -p <profile> --var catalog=dahlia_dev,ops_schema=ops
node scripts/check-notebook-sync.mjs -t dev -p <profile>
databricks bundle deploy -t dev -p <profile> --var catalog=dahlia_dev,ops_schema=ops
databricks bundle run create_otel_tables -t dev -p <profile> --var catalog=dahlia_dev,ops_schema=ops
```

The sync check uses an authenticated CLI dry-run to confirm the SQL notebook is
included in uploads; it does not modify workspace files.

Use `-t prod` and the production catalog for production. Deployment only creates
the schema and job; postdeploy does not run this job. The job creates managed
Delta tables `dahlia_otel_spans`, `dahlia_otel_logs`, and `dahlia_otel_metrics` using
the [official Zerobus OTLP v2 definitions](https://docs.databricks.com/aws/en/ingestion/opentelemetry/configure),
including clustering, `otel.schemaVersion=v2` and `delta.checkpointPolicy=classic`.
Optional Variant shredding is not enabled.

Each statement uses `CREATE TABLE IF NOT EXISTS`: reruns preserve existing tables
and data, including after partial failure. Existing table definitions are not
validated or migrated by the job. SQL errors fail the run. Verify the first run
with `DESCRIBE TABLE EXTENDED` and `SHOW TBLPROPERTIES` for all three tables,
comparing columns/types and clustering with the linked definitions. In a test
catalog, insert a synthetic row, rerun the job and confirm that row remains;
repeat with a different `ops_schema` override to verify destination selection.

Before sending OTLP, separately grant the sending service principal `USE CATALOG`,
`USE SCHEMA`, and explicit `SELECT` and `MODIFY` on each table. Configure each
signal's `x-databricks-zerobus-table-name` header with its fully qualified table
name. This setup does not create credentials, grant sender access, configure a
Collector, or enable telemetry emission.

## AI models

The bundle exposes its Responses-compatible `system.ai.*` models through the ordered `DAHLIA_FOUNDATION_MODELS` value. `/api/v1/models` reads this value without calling a discovery API, and Responses forwards the selected fully qualified model ID unchanged. `DAHLIA_CODEX_AUTO_REVIEW_MODEL=system.ai.gpt-5-6-luna` preserves the reserved `codex-auto-review` route without registering an alias service.

Search embeddings, image analysis, and Hindsight also use their `system.ai.*` models directly. Postdeploy only activates Lakebase Search extensions.

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


For MCP, connect a modern MCP 2026-07-28 client to `https://<app-host>/mcp` with Databricks Apps token authentication. Confirm `tools/list` exposes only read-only tools and only authorized Vault contents are readable. Dahlia trusts the proxy-authenticated forwarded identity in this deployment and does not run its own Better Auth OAuth exchange.

For Files and recording smoke tests, upload private content, commit it through the canonical transaction API, then verify GET, HEAD, Range, conditional reads and revoked-access rejection. HEAD must report the full size; a mismatched If-Range must return the full representation.

Confirm `/api/v1/models` includes `system.ai.gpt-5-6-luna`, then complete a real `POST /api/v1/responses` request with that full model ID, `input`, and `stream: true`. Confirm SSE events arrive incrementally through the Apps proxy. `/admin/models` is retired.

## Security requirements

- Trust the configured email header (default `X-Forwarded-Email`) and display name `X-Forwarded-Preferred-Username` only behind the Databricks Apps proxy. `X-Forwarded-User` is not used for identification.
- `X-Forwarded-Access-Token` is trusted only behind the Databricks Apps proxy, preferred as the Responses upstream Bearer credential, and never persisted or logged. If absent, Responses uses a short-lived App service principal token. The configured model list performs no upstream request.
- Responses request and response content is streamed without being persisted or logged. Synchronized summary, OCR, caption text, and search query text may be sent to the configured embedding model; only the resulting rebuildable vectors are persisted, and request content is not logged.
- `/healthz` is process liveness only; anonymous external access is not guaranteed.
