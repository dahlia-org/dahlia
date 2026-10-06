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
- Node.js 22.13 or newer, Corepack, and pnpm for local validation.
- Python 3.11 or newer and uv for preparing the pinned Hindsight source before upload.

## Configure

The first authenticated user becomes the initial administrator. Additional administrators must authenticate once before they can be promoted under `/admin/members`.

Dahlia Desktop requests `all-apis` when authorizing against a deployed Databricks App. Separately, the App resource keeps `user_api_scopes` set to `ai-gateway` and `files`; these scopes govern only the Apps proxy's OBO token and are not the Desktop API capability scope. Dahlia prefers `X-Forwarded-Access-Token` as Bearer authentication for the workspace OpenAI-compatible Responses API at `DATABRICKS_HOST/ai-gateway/codex/v1/responses`. When that header is absent, and for background AI requests, it uses short-lived App service principal tokens obtained from `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; this fallback is independent of the Server runtime. No provider secret or forwarded user token is stored. Model discovery uses `/ai-gateway/codex/v1/models` with the same token preference; the platform controls the returned catalog. `DAHLIA_APP_URL` is the canonical public origin; when it is absent, Dahlia uses the runtime-provided `DATABRICKS_APP_URL`. `/mcp` needs no additional user API scope: the Apps proxy authenticates the caller and supplies verified identity headers, while file and recording bytes use the App service principal's existing Volume permission.

The bundle temporarily sets `DAHLIA_AUTH_SECRET` directly to the fixed value `test-only-better-auth-secret-value`. It does not define a Secret resource, retrieve a Unity Catalog Secret, or grant secret permissions. This is a shared test value; replace it with a unique signing secret before production use. Header authentication uses `DAHLIA_AUTH_HEADER` (default `X-Forwarded-Email`) as the email identity and stores its normalized value in `account.account_id`. New users join their email-domain Organization; the first is owner and later users are members. Departed or removed users are not automatically added again. `DAHLIA_SIGNOUT_URL=/.auth/logout` sends the browser through the Databricks Apps proxy logout endpoint after Dahlia clears its local session.

The App name is `mcp-dahlia-server-{target}`, for example `mcp-dahlia-server-dev` or `mcp-dahlia-server-prod`. The Hindsight App name is `dahlia-hindsight-{target}`. The corresponding Lakebase project IDs are `dahlia-db-dev` and `dahlia-db`. By default, both targets use the managed Volume `dahlia.app.storage`. Choose the deployment environment by overriding `catalog`; override `app_schema` only when a catalog needs more than one Dahlia Server installation. Explicit Vault sharing is available in every target; Vault Admins can grant Admin, Editor, or Viewer access to a user, Organization, or Team. Organization membership alone does not grant Vault access. The platform controls public Gateway models; the bundle routes automatic reviews to `system.ai.gpt-6-luna`, and uses `system.ai.qwen3-embedding-0-6b` for search embeddings. All AI models are used directly; the bundle does not register Model Services. To disable a worker, remove its model environment value from the App resource.

The Server App deploys the repository root (`source_code_path: ../../..`), where Databricks Apps builds the pnpm workspace. The bundle's `sync.paths` uploads only the repository-root `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml` and `turbo.json`, `apps/server`, the bundled `packages/ui` source, `apps/hindsight` and the setup notebooks in `deploy/databricks/notebooks`. Ignored files such as dependencies, build output and local secrets are never uploaded, and Desktop apps and other repository files stay out, so the frozen install skips their workspace packages. `pnpm test:package` copies the same Server workspace files to a temporary directory, runs a frozen install and the root build, then packs and checks the resulting package. The Server ships its own transcript activity policy JSON; a cross-platform test keeps it equal to the Desktop resource.

Databricks Apps runs `pnpm install --frozen-lockfile` and the root `pnpm run build` (`turbo run build`, with Turborepo telemetry disabled), which builds `@dahlia-ai/server` and generates the Web and Server runtime assets without TypeScript declarations or the embeddable client library. Declaration generation uses a separate tsup Worker and can exceed its JavaScript heap limit during deployment (`ERR_WORKER_OUT_OF_MEMORY` after `DTS Build start`). Those package-only artifacts are generated by `pnpm build:package`, also run automatically by `pnpm pack`. `pnpm test:package` verifies both the deployment build and the complete packed artifact independently.

## Validate and deploy

For a target with existing Terraform deployment state, complete the [one-time migration to the direct engine](https://docs.databricks.com/aws/en/dev-tools/bundles/direct#migrate-an-existing-bundle) using its previously deployed bundle configuration before adopting this deployment sequence. The migration includes `databricks bundle deployment migrate -t dev`; use the target's existing profile and variable overrides, and repeat for `prod` if applicable. On CLI 1.4.x, migration requires a plan without pending actions, as described in the migration guide. Setting `bundle.engine: direct` alone does not guarantee that an existing Terraform state uses the direct engine on every supported CLI version.

The following deployment sequence assumes the target Lakebase project already exists. Enable Lakebase Search manually before starting either App. In the target Lakebase project (`dahlia-db-dev` or `dahlia-db`), open **Settings → Lakebase Search → Enable Lakebase Search**. This is a one-time project setting; enabling it restarts the project's computes and drops active connections. Wait for the restart to finish and verify that both extensions are available in the target database:

```sql
SELECT name FROM pg_available_extensions
WHERE name IN ('lakebase_text', 'lakebase_vector');
```

Both rows must be present. The App migrations install the extensions when they start. See [Enable Lakebase Search](https://docs.databricks.com/aws/en/oltp/projects/lakebase-search#enable-lakebase-search).

Run from `deploy/databricks`, using the same profile and variable overrides for every command. Prepare the pinned Hindsight checkout before strict validation on a fresh checkout:

```bash
uv run --no-project ../../apps/hindsight/scripts/sync_upstream.py
databricks bundle validate --strict -t dev
databricks bundle deploy -t dev
databricks bundle summary -t dev
```

Use `-t prod` for production and pass its catalog explicitly when it differs from `dahlia`, for example `--var catalog=dahlia_prod`. The production Lakebase project, storage Volume, and schema have `lifecycle.prevent_destroy: true`; destructive changes fail until an operator deliberately removes that protection. Development uses separate disposable resources. Recreating a development Lakebase project also resets its Search setting; enable Search again before starting either App.

The bundle explicitly uses the direct deployment engine and sets `lifecycle.started: true` for both Apps. `bundle deploy` uploads source code and deploys/starts the Apps, waiting for their deployments to succeed. Do not follow it with `bundle run dahlia_server` or `bundle run hindsight`: the CLI's App URL resolution during `bundle run` can overwrite `DAHLIA_HINDSIGHT_URL` with `/api`. Deployment success does not establish application health; check both Apps' runtime status and startup logs. The bundle's `prebuild` step materializes the pinned Hindsight v0.10.2 source and maintained Lakebase patch before upload; it does not follow newer upstream tags. Hindsight runs its database migrations when the App starts. Upgrading from v0.10.1 adds bank aliases and LLM-usage and refresh-failure columns, and rebuilds the entity trigram index per bank with `CREATE INDEX CONCURRENTLY` (the previous index stays in place if `btree_gin` is unavailable), so allow extra startup time on a large database and confirm the completed migrations in the `hindsight` App log.

Hindsight's `databricks` model provider derives the OpenAI-compatible base URL from the App-injected `DATABRICKS_HOST`. It uses `system.ai.gpt-6-luna` for LLM calls, with `HINDSIGHT_API_RETAIN_LLM_REASONING_EFFORT=low` for text and image fact extraction only (reflect, consolidation and Knowledge Pages keep the model default; changing it re-ingests every bank), and `system.ai.qwen3-embedding-0-6b` at `${search_embedding_dimensions}` dimensions for embeddings. Reflect and Knowledge Pages refresh call function tools, which Chat Completions rejects for this model unless reasoning is off, so `HINDSIGHT_API_REFLECT_LLM_PROVIDER=databricks-responses` sends them through the Responses API with the same OAuth and base URL; retain and consolidation stay on Chat Completions. Changing any operation's provider also re-ingests every bank. The provider obtains and refreshes OAuth tokens with the App-injected `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; it never reads a user's forwarded OBO token or a Databricks secret resource. The reranker is Hindsight's `local` cross-encoder with `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1`, forced onto the CPU inside the Hindsight App; it does not use Model Serving. The App therefore uses `compute_size: LARGE` (4 vCPUs). In measurements on 4 CPUs, reranking 50, 100, 200 and 300 candidates took 0.64, 1.25, 2.2 and 3.4 seconds, and the process used about 1.4 GB RSS. The bundle variables `reranker_max_candidates_low`, `reranker_max_candidates_mid` and `reranker_max_candidates_high` (defaults 50, 100 and 300) cap the candidates per recall budget; Dahlia's `depth` values `quick`, `normal` and `deep` select those budgets. Hindsight downloads the model weights (about 470 MB) from Hugging Face during startup, so the App needs outbound access to Hugging Face. Where it has none, the planned alternative is to stage the weights in a UC Volume and copy them to local disk at startup; that alternative is not implemented. `apps/hindsight/requirements.txt` adds the PyTorch CPU-only index so that the App build installs CPU wheels.

To compare retrieval settings on real data without changing it, run the operator-only evaluation harness described in [`apps/hindsight/README.md`](../../apps/hindsight/README.md#検索品質の評価). It clones a bank, prints aggregate numbers only, and deletes the clone.

Lakebase requires each `lakebase_bm25` index to be created after its table contains data. After Hindsight first writes `memory_units` or `mental_models`, create that table's index with the SQL in [`apps/hindsight/README.md`](../../apps/hindsight/README.md) before using full-text recall.

Lakebase Search enablement is managed manually. The bundle has no `postdeploy` hook: with `lifecycle.started: true`, that hook would run after App deployment and would be too late to establish the startup prerequisite.

The App resource grants its service principal `CAN_CONNECT_AND_CREATE` on the project's default `databricks_postgres` database and `WRITE_VOLUME` on the target managed Volume. Databricks injects `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER`; the `postgres` resource key supplies `LAKEBASE_ENDPOINT`. Dahlia creates the generated Better Auth `auth` schema in every authentication mode, then creates `app`, `search`, `crypto`, `jobs`, and the independently migrated `agent` schema under the same advisory lock before starting the Node server. Header mode projects each proxy-verified identity into `auth.user` and a linked `auth.account`, and uses Better Auth browser sessions for Web operations. Stored bytes are uploaded and streamed through `/api/2.0/fs/files/Volumes/...`; no Volume credential is issued to clients.

Lakebase UI schema listings can differ by the connected PostgreSQL role and its visibility. Verify the migration result from the SQL editor or another PostgreSQL client instead of relying on the schema browser:

```sql
SELECT to_regnamespace('auth') AS auth_schema,
       to_regclass('auth."user"') AS auth_user_table;
```

Both columns must be non-null. A successful authenticated header request also proves the table is usable because Dahlia projects that identity into `auth.user` before handling the request.

Dahlia installs `lakebase_text` and creates the unified BM25 index during migration. When an embedding model is configured it also installs `lakebase_vector` and creates a dimension- and model-specific `lakebase_ann` index. Failure to load either configured capability stops migration instead of silently changing search semantics. Grant the App service principal query permission on the embedding model. After the Desktop completes the first full Vault synchronization, run `VACUUM search.documents;` against the application database so BM25 corpus statistics include the uploaded rows.

## OTel tables

The bundle creates `${catalog}.${ops_schema}` (default `dahlia.ops`). Production
protects this schema with `lifecycle.prevent_destroy: true`. If the schema already
exists outside this bundle, bind the `ops_schema` resource before deployment.
Deployments sharing a catalog must use a single schema owner/bundle arrangement.

Bundles have no Unity Catalog table resource, so the unscheduled `create_otel_tables`
job creates the tables through MLflow's Unity Catalog trace location instead of
hand-written DDL. Its Python notebook installs `mlflow[databricks]>=3.14` on serverless
Jobs compute and calls `mlflow.set_experiment(experiment_id=..., trace_location=UnityCatalog(...))`
for the bundle's `otel_traces` experiment. Databricks creates
`<otel_table_prefix>_otel_spans`, `_otel_logs` and `_otel_metrics` (default prefix `dahlia`)
with their current OTel schema and links the spans table to the experiment's Traces tab;
the job fails if any of the three tables is missing afterwards. Reruns with the same
location are idempotent; MLflow rejects linking the experiment to a different location.
The Server writes through Zerobus, so the MLflow OTLP endpoint's ingestion limit does not apply.

MLflow creates the tables through a SQL warehouse. The notebook picks a warehouse
visible to the job's run-as principal (running first, then serverless; MLflow starts a
stopped one). When none is visible, it creates a temporary 2X-Small serverless warehouse
and deletes it after the tables are created.
The deployment principal needs `USE CATALOG` and `CREATE SCHEMA` on the catalog; the
job's run-as principal needs `USE CATALOG`, `USE SCHEMA` and `CREATE TABLE` on the
destination schema (or equivalent ownership), plus `CAN USE` on the visible warehouses or,
when none is visible, permission to create warehouses.

Run these commands from `deploy/databricks`, using the same profile, target and
variable overrides for deployment and execution:

```bash
databricks bundle validate --strict -t dev -p <profile> --var catalog=dahlia_dev,ops_schema=ops
node scripts/check-sync.mjs -t dev -p <profile>
databricks bundle deploy -t dev -p <profile> --var catalog=dahlia_dev,ops_schema=ops
databricks bundle run create_otel_tables -t dev -p <profile> --var catalog=dahlia_dev,ops_schema=ops
```

The sync check uses an authenticated CLI dry-run to confirm the notebook is included
in uploads and that nothing outside the Server workspace, Hindsight and the notebooks
is uploaded; it does not modify workspace files. Use `-t prod` and the production
catalog for production. Deployment only creates the schema, experiment and job; it
does not run the job.

The Server App forwards its OTLP receivers' data and its own Server logs to these tables
when `zerobus_endpoint` is set (default empty, no export). Zerobus requires explicit grants for
the App service principal, so after the job has created the tables, grant them once
with a principal that can manage the schema and tables (`USE CATALOG` normally comes
from the App's Volume resource in the same catalog):

```sql
GRANT USE SCHEMA ON SCHEMA dahlia_dev.ops TO `<server-app-service-principal-client-id>`;
GRANT SELECT, MODIFY ON TABLE dahlia_dev.ops.dahlia_otel_spans TO `<server-app-service-principal-client-id>`;
GRANT SELECT, MODIFY ON TABLE dahlia_dev.ops.dahlia_otel_logs TO `<server-app-service-principal-client-id>`;
GRANT SELECT, MODIFY ON TABLE dahlia_dev.ops.dahlia_otel_metrics TO `<server-app-service-principal-client-id>`;
```

Then redeploy with the workspace's Zerobus endpoint:

```bash
databricks bundle deploy -t dev -p <profile> --var catalog=dahlia_dev,ops_schema=ops,zerobus_endpoint=https://<workspace-id>.zerobus.<region>.cloud.databricks.com
```

The App sets the standard `OTEL_EXPORTER_OTLP_ENDPOINT` to `zerobus_endpoint` with a leading space,
which the Server trims. This keeps the Apps deployment API's `value` present even when the endpoint
is empty; an empty endpoint still disables export. Each signal's
`x-databricks-zerobus-table-name` header is set to `<catalog>.<ops_schema>.<otel_table_prefix>_otel_*`,
with `DAHLIA_OTEL_AUTH=databricks` so the Server requests a separate table-scoped token per signal; see the Server
[OpenTelemetry](../../apps/server/README.md#opentelemetry-otlp) contract. Other senders
can export OTLP to the App's `/api` endpoint, or directly to Zerobus with their own
service principal, explicit grants, and the `x-databricks-zerobus-table-name` header.

## AI models

The platform controls the models returned from `/ai-gateway/codex/v1/models`, including their order, visibility, and Codex metadata. `DAHLIA_FOUNDATION_MODELS` is not used by Databricks. Responses forwards the selected fully qualified ID unchanged to `/ai-gateway/codex/v1/responses`, where the platform authorizes it. `DAHLIA_CODEX_AUTO_REVIEW_MODEL=system.ai.gpt-6-luna` retains the reserved execution override without adding a local catalog entry or registering an alias service. Background audio Chat Completions and search Embeddings retain `/ai-gateway/mlflow/v1`.

Search embeddings, image analysis, and Hindsight also use their `system.ai.*` models directly. Manage model access for the App service principals separately; the bundle manages the Server-to-Hindsight App permission described below.


### Hindsight App permission

The Server App declares Hindsight as an App resource in `resources/dahlia_server.yml`. During `bundle deploy`, Databricks grants the Server App's service principal `CAN_USE` on the Hindsight App for the same target:

```yaml
resources:
  apps:
    dahlia_server:
      resources:
        - name: hindsight
          app:
            name: ${resources.apps.hindsight.name}
            permission: CAN_USE
```

The deployment identity must be allowed to manage both Apps. No service principal ID or separate manual grant is needed. After deployment, verify the Server principal's `CAN_USE` grant with `databricks apps get-permissions dahlia-hindsight-dev --profile <profile>` (use `dahlia-hindsight-prod` for production). See [App resources](https://docs.databricks.com/aws/en/dev-tools/bundles/resources#appresources).

## Smoke test

Wait for the App to reach `RUNNING`, then retrieve its URL from `bundle summary` and use a workspace access token:

```bash
TOKEN="$(databricks auth token --output json | jq -r .access_token)"

curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  https://<app-host>/api/v1/session

curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  https://<app-host>/api/v1/models
```


For MCP, connect a modern MCP 2026-07-28 client to `https://<app-host>/mcp` with Databricks Apps token authentication. Confirm `tools/list` exposes only read-only tools and only authorized Vault contents are readable. Dahlia trusts the proxy-authenticated forwarded identity in this deployment and does not run its own Better Auth OAuth exchange.

For Files and recording smoke tests, upload private content, commit it through the canonical transaction API, then verify GET, HEAD, Range, conditional reads and revoked-access rejection. HEAD must report the full size; a mismatched If-Range must return the full representation.

Confirm `/api/v1/models` includes `system.ai.gpt-6-sol` and `system.ai.gpt-6-luna`, then complete a real `POST /api/v1/responses` request with a full model ID, `input`, and `stream: true`. Confirm SSE events arrive incrementally through the Apps proxy. `/admin/models` is retired.

## Security requirements

- Trust the configured email header (default `X-Forwarded-Email`) and display name `X-Forwarded-Preferred-Username` only behind the Databricks Apps proxy. `X-Forwarded-User` is not used for identification.
- `X-Forwarded-Access-Token` is trusted only behind the Databricks Apps proxy, preferred as the Responses upstream Bearer credential, and never persisted or logged. If absent, Responses uses a short-lived App service principal token. Model discovery uses the same upstream credential preference.
- Responses request and response content is streamed without being persisted or logged. Synchronized summary, OCR, caption text, and search query text may be sent to the configured embedding model; only the resulting rebuildable vectors are persisted, and request content is not logged.
- `/healthz` is process liveness only; anonymous external access is not guaranteed.

The Server calls Hindsight at `${resources.apps.hindsight.url}/api`, resolved during `bundle deploy`, using short-lived App service-principal OAuth (`DAHLIA_HINDSIGHT_AUTH=databricks`). No workspace ID or hostname construction is needed. Hindsight's API base path is `/api`, keeping the authenticated API route separate from its UI. Environment isolation uses the separate `dahlia-hindsight-dev` / `dahlia-hindsight-prod` Apps, their service principals and the `dahlia-db-dev` / `dahlia-db` Lakebase projects. Bank IDs have the same fixed `dahlia_` application prefix in every environment; do not point development and production at the same Hindsight storage. Deployment configures connectivity; a Workspace admin must still enable memory in Dahlia settings. Existing completed meetings are then backfilled. See [Server Workspace memory](../../apps/server/README.md#workspace-analysis-hindsight) for evidence, deletion, and future user-bank boundaries.

Screenshot ingestion remains off for every Workspace until an admin enables it. The bundle explicitly pairs Server `DAHLIA_MEMORY_IMAGE_MODEL` and Hindsight standard VLM settings through `memory_image_model` (initially `system.ai.gpt-6-luna`). The image recipe uses one image per chunk, at most eight images / 8 MiB per meeting, 1568px Server variants, and standard retain temperature omission (`HINDSIGHT_API_LLM_TEMPERATURE_RETAIN=none`), verified with synthetic image inference. See [the image contract](../../apps/hindsight/README.md#phase-5-明示的な画像取り込み) before changing limits or models. Deployment alone does not opt a Workspace in.
