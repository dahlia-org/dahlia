# Dahlia Server

`apps/server` is the optional, self-hostable AI Gateway used by the Codex process embedded in Dahlia. It also accepts explicitly uploaded arbitrary-byte artifacts and optional owner-controlled meeting sync. Meeting sync stores Vault names, Project names/descriptions/hierarchy, summaries, original transcripts, screenshots, OCR, and captions; it never uploads recordings, translated transcripts, or SQLite databases. Responses request content is relayed to the configured provider without being persisted or logged.

Better Auth, Gateway administration, and meeting sync share one Drizzle application database. Provider credentials remain separate runtime secrets and are never stored in that database.

## Database and Gateway configuration

`DAHLIA_DATABASE_TYPE` selects storage independently from authentication and the AI Gateway:

| Type | Runtime | Connection |
| --- | --- | --- |
| `sqlite` | Node | `DAHLIA_DATABASE_URL=file:...` (default: `file:.data/dahlia-auth.sqlite`) |
| `postgres` | Node or Worker | `DAHLIA_DATABASE_URL=postgresql://...` |
| `lakebase` | Node / Databricks Apps | `LAKEBASE_ENDPOINT` and injected `PG*` variables |
| `hyperdrive` | Cloudflare Worker | `HYPERDRIVE` binding |
| `d1` | Cloudflare Worker | `dahlia_db_prod` binding |

Node supports `sqlite`, `postgres`, and `lakebase`; Workers support `d1`, `hyperdrive`, and direct `postgres`. PostgreSQL-compatible connections keep generated Better Auth tables in `auth`, application and sharing state in `core`, and synchronized meeting data in `content`; all schemas are owned by the connection user. References flow only from `content` to `core` to `auth`. Lakebase uses the official `@databricks/lakebase` pool for OAuth credential refresh.

Better Auth schemas are generated unmodified into `src/db/generated`; Dahlia tables remain in the adjacent app schema files. `pnpm db:generate-auth` refreshes the auth definitions and `pnpm db:generate` produces separate PostgreSQL auth and application streams under `drizzle/postgres-auth` and `drizzle/postgres`. Every authentication mode applies both streams in that order. Header mode keeps Better Auth endpoints disabled and projects each verified proxy identity into `auth.user`; accounts mode leaves that table under Better Auth's control. The relations-v2 adapter is used with joins disabled. SQLite and D1 retain one stream with top-level Better Auth tables, prefix Dahlia tables with `core_` or `content_`, and rely on the same application permission checks instead of RLS.

## API contract

| Path | `accounts` | `header` |
| --- | --- | --- |
| `/`, `/sign-in`, `/dashboard/**`, `/artifacts/**`, `/vaults/**` | Static SPA | Static SPA |
| `/organizations` | Better Auth Organization and Team management | External Organization and Team management |
| `/accept-invitation/**` | Better Auth invitation management | Not used |
| `/api/auth/**` | Google sign-in and OAuth 2.1 endpoints | Disabled |
| `/api/session` | Account session and capabilities | Validated email-header identity and capabilities |
| `/api/admin/**` | Platform administrators only | Platform administrators only |
| `/api/v1/models` | Dahlia OAuth with `all-apis` | Platform U2M / proxy authentication |
| `/api/v1/responses` | Dahlia OAuth with `all-apis` | Platform U2M / proxy authentication |
| `GET /api/v1/artifacts` | Dahlia OAuth with `all-apis` or browser session | Proxy identity |
| `POST /api/v1/artifacts` | Dahlia OAuth with `all-apis` | Proxy identity |
| `/api/v1/artifacts/{uuidv7}` | Public reads are anonymous; private reads use `all-apis` or browser session; mutations use `all-apis` | Public reads are anonymous; private reads and mutations use proxy identity |
| `/api/v1/artifacts/{uuidv7}/content` | Public reads are anonymous; private reads use `all-apis` or browser session | Public reads are anonymous; private reads use proxy identity |
| `/api/v1/vaults/**` | Browser session or Dahlia OAuth with `all-apis` | Proxy identity |
| `POST /mcp` | Dahlia OAuth with `mcp` or `mcp:read` | Databricks Apps / trusted proxy identity |
| `/healthz` | Minimal liveness | Internal liveness; anonymous external access is not guaranteed |

`accounts` is the default authentication. It serves OAuth/OIDC discovery under `/.well-known/**`. Both hosted and self-hosted deployments use the fixed public client `databricks-cli`; it requires authorization code with S256 PKCE and supports rotating refresh tokens and revocation. Its default redirect allowlist retains the released `http://127.0.0.1:1455/oauth/callback` and also accepts the Desktop callback `http://localhost:8020`. RFC 7591 dynamic client registration remains disabled. Node deployments support MCP 2026-07-28 Client ID Metadata Documents (CIMD) with pinned public-address fetching; the MCP resource is `${DAHLIA_APP_URL}/mcp` and its protected-resource metadata is at `/.well-known/oauth-protected-resource/mcp`.

OAuth access from Dahlia Desktop uses the single `all-apis` capability scope for models, Responses, artifacts, synchronization, deltas, and events. OIDC identity scopes remain separate protocol scopes.

### Meeting sync and Vault sharing

Meeting sync is opt-in per Desktop Vault and uploads only to the selected Dahlia account connection. Desktop API calls require `all-apis`; Server MCP reads require `mcp:read`. `core.vault_permissions` is the permission source of truth: every Vault has one immutable `user` owner identified by the authentication provider's raw user ID, while optional `user`, `organization`, and `team` members are read-only. Content rows carry only `vault_id`; PostgreSQL/Lakebase RLS and the SQLite/D1 store resolve access through the Vault permission. Screenshot bytes use deterministic object keys under `meetings/{meetingId}/screenshots/{screenshotId}.{extension}`.

Desktop and Private Web mutations use `POST /api/v1/transactions`. Each UUIDv7 transaction is limited to one Vault, committed atomically, and replay-safe by transaction ID. Vault, Project, meeting metadata, and summary writes require the current canonical revision; conflicts return `409` with the Server record. Screenshot content and transcript chunks remain bounded staging uploads and are activated by a transaction.

Desktop keeps immutable operations until the Server receipt is applied. Screenshot operations include the staged content SHA-256; transcript operations use `transcript:patch` with per-chunk hashes and explicit segment upserts/deletes. `400`/`411`/`413`/`415`/`422` stop as validation errors, `409` stops as a revision conflict, `401`/`403` stop as authorization errors after one token refresh, and only transport errors, `408`, `425`, `429`, and `5xx` retry automatically. The transaction response cursor records the last local commit; it never advances the separate delta pull checkpoint.

`GET /api/v1/vaults/{vaultId}/changes?cursor=...` is the durable delta feed. `GET /api/v1/events` sends only SSE invalidations and opaque cursors; clients always fetch canonical data from the delta/read APIs and can catch up after disconnect or application shutdown. Server MCP remains read-only.

Vault and Project operations are committed through the domain transaction endpoint before meeting data. Projects are available for hierarchy browsing and meeting filtering but are not added to full-text or vector search. Transcript segments keep `audioSource` (`mic` or `system`) separate from nullable `speakerLabel`, which is reserved for future diarization.

`GET /api/v1/vaults/{vaultId}/meetings` returns at most 200 meetings. Pass its opaque `nextCursor` as `cursor` to continue the same date-ordered Vault or Project listing. `query_meetings` exposes the same cursor contract. Search results remain a bounded relevance-ranked page and do not return a continuation cursor.

`GET /api/v1/vaults/{vaultId}/meetings/{meetingId}/screenshots` likewise returns at most 200 screenshots. Pass `nextCursor` as `cursor` to continue chronological listings; MCP `get_meeting_screenshots` accepts the same cursor and emits the next cursor as JSON text before its resource links. Screenshot search remains a bounded page without a cursor.

`GET /api/v1/vaults/{vaultId}/meetings/{meetingId}/transcript` returns up to 10,000 segments in chronological order. Pass `nextCursor` as `cursor` to continue; MCP `get_meeting_transcript` uses the same page contract.

Explicit Organization and Team sharing is disabled unless `DAHLIA_SYNC_SHARING_ENABLED=true`. Disabled deployments do not expose permission mutations or member reads; owner sync and owner reads remain available.

In accounts mode, owners use Better Auth Organizations, invitations, and Teams. In header mode, every validated proxy user is projected into the visible `external` Organization; the first user is its immutable owner and belongs to the `External` default Team, while later users join only the Organization. Organization owners manage Team membership from the same Web page. Vault owners explicitly grant read-only access through `PUT|DELETE /api/v1/vaults/{vaultId}/permissions/organizations/{organizationId}` or `/permissions/teams/{teamId}`; direct user member rows remain schema-only. PostgreSQL/Lakebase always migrate the generated `auth` baseline before the application baseline. RLS receives only transaction-local `app.user_id` and resolves current membership from `auth.member` and `auth.team_member`.

### Server hybrid search

Meeting and screenshot search is tokenized by the Server; it never reads Desktop's SQLite tokenizer or token data. Meeting search covers name, description, and visible summary text. Screenshot search covers OCR and caption. Original transcripts remain synchronized but are not searchable. Queries are limited to 500 characters and 16 AND-combined tokens. Node uses the pinned Lindera IPADIC WASM package, while Cloudflare Workers use `Intl.Segmenter`; changing runtime for an existing database requires recreating it or fully resynchronizing every meeting.

`content.search_documents` is the shared rebuildable projection for meetings and screenshots. PostgreSQL uses its generated `tsvector` with GIN, SQLite uses an external-content FTS5 table, and Lakebase uses `lakebase_text` with BM25. D1 sync is fail-closed until its multi-statement writes use D1's atomic `batch()` API. Lakebase Search must be enabled by an operator before deployment; startup stops when the required extension cannot be loaded. After the first full synchronization, update BM25 corpus statistics once with:

```sql
VACUUM content.search_documents;
```

Set `DAHLIA_SEARCH_EMBEDDING_MODEL` to enable asynchronous semantic indexing on Node; an empty or missing value keeps it off. `DAHLIA_SEARCH_EMBEDDING_DIMENSIONS` defaults to `1024` and accepts powers of two from 32 through 1024. The App service principal calls the Databricks embedding endpoint, and content or credentials are never stored in the queue. Lakebase uses `lakebase_vector` with `lakebase_ann`; other PostgreSQL deployments use pgvector's `vector` extension with HNSW. Install `vector` as a database operator before enabling embeddings when the application role cannot create extensions. SQLite performs exact cosine ranking in Node. Search automatically combines the top 100 FTS and vector candidates with RRF and falls back to FTS when embeddings are absent, rebuilding, or unavailable. Document text and the user's search query are sent to the configured embedding provider; Dahlia does not persist or log query text.

### Artifact API

`POST /api/v1/artifacts` accepts an uncompressed raw body with a required `Content-Length` up to 64 MiB, creates a private artifact with a Server-generated canonical lowercase UUIDv7, and returns its mutable `/api/v1/artifacts/{uuidv7}` resource in `Location`. The response `viewerUrl` contains the human-facing `/artifacts/{uuidv7}` URL. Storage version filenames under the `artifacts/` prefix start with Unix time milliseconds and include a collision-resistant suffix. Clients may supply a safe extension with `Content-Disposition: attachment; filename="name.ext"`; otherwise HTML uses `.html`, other text uses `.txt`, and binary content uses `.bin`. `PUT /api/v1/artifacts/{uuidv7}` replaces an existing artifact owned by the caller and requires the original `Content-Type`; it never creates a missing ID. `PATCH` accepts only `{"visibility":"private"}` or `{"visibility":"public"}`, and `DELETE` removes bytes before metadata so a storage failure can be retried. There is no history, expiry, malware scan, HTML sanitization, or per-user share API.

`GET /api/v1/artifacts` lists the current personal workspace in descending UUIDv7 order, 50 records at a time. Pass the opaque `nextCursor` response as `cursor` to fetch the next page. `GET /api/v1/artifacts/{uuidv7}` keeps its existing raw-byte response; request `Accept: application/vnd.dahlia.artifact+json` for metadata. `GET` and `HEAD` on `/api/v1/artifacts/{uuidv7}/content` always return bytes and are used by the browser viewer. If an `Authorization` header is present, read endpoints validate only that OAuth credential; otherwise they accept the signed-in browser session. Browser sessions do not authorize artifact mutations.

All storage backends stream authorized `GET` and `HEAD` responses through Dahlia, forward `Range` and `If-Unmodified-Since`, and apply a CSP sandbox so uploaded HTML cannot inherit the Dahlia application origin. Storage URLs and credentials are never returned to clients. `/artifacts` lists only artifacts owned by the signed-in user; `/artifacts/{uuidv7}` renders browser-supported content in a sandboxed frame and offers other content as a download.

### Artifact MCP

`POST /mcp` is a stateless, modern-only MCP 2026-07-28 endpoint. `mcp` exposes every MCP tool, including the four artifact mutations and all synchronized-content reads; `mcp:read` exposes only the Project, meeting, transcript, and screenshot read tools, including Project-filtered meeting queries. Each tool uses the same authorization as its REST API. Tool content is UTF-8 or canonical RFC 4648 base64, decoded to at most 8 MiB. MCP requests are rejected above 12 MiB before JSON parsing, including streamed requests without `Content-Length`. Tool results contain the artifact ID, canonical viewer URL, content type, visibility, and a resource link to the content endpoint, never artifact bytes or storage URLs. Streaming uploads larger than 8 MiB remain available through the REST API.

In `accounts` mode, `/mcp` requires a DPoP-bound access token for the exact MCP resource and either `mcp` or `mcp:read`; only tools covered by the granted scope are registered. In `header` mode, authentication is delegated to the trusted proxy and Dahlia derives ownership from its verified forwarded identity headers. Databricks Apps exposes custom MCP servers at `/mcp`; its proxy has already authenticated the request, and `X-Forwarded-Access-Token` is not used for artifact storage. A present `Origin` must match the configured application origin; non-browser clients may omit it.

`DAHLIA_STORAGE_BACKEND` selects `local`, `s3`, `databricks`, or `r2`. Node defaults to `local` under `DAHLIA_STORAGE_LOCAL_PATH=.data/storage`. Databricks uses `DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH=/Volumes/<catalog>/<schema>/<volume>`. S3 uses `DAHLIA_STORAGE_S3_BUCKET`, optional `DAHLIA_STORAGE_S3_ENDPOINT`, and the standard `AWS_*` credential variables. Workers must explicitly select `r2` with the `DAHLIA_STORAGE` binding or `s3`; they reject the local default.

`header` reads the authenticated email from `X-Forwarded-Email` by default. Override the email header name with `DAHLIA_AUTH_HEADER`, for example `Cf-Access-Authenticated-User-Email`. `X-Forwarded-User` supplies the stable user ID and `X-Forwarded-Preferred-Username` supplies the display name; when absent, the email remains the user ID. The upstream proxy must remove client-supplied identity headers, write the verified values itself, and prevent direct access to the Server.

`DAHLIA_APP_URL` sets the canonical public application origin used for OAuth metadata and browser mutation checks. When it is absent, Dahlia uses `DATABRICKS_APP_URL`, then falls back to `http://localhost:5173` for local development.

## Provider and model configuration

The AI backend uses the OpenAI Responses-compatible contract and is independent of the database. Select `databricks`, `cloudflare`, or `openai` with `DAHLIA_AI_BACKEND`; it defaults to `openai`. While the selected non-Databricks backend has no `OPENAI_API_KEY`, `/api/v1/models` returns an empty standard model list and a Codex catalog with no picker-visible models, while Responses returns `503 provider_not_configured`.

`GET /api/v1/models` returns the standard OpenAI `object` and `data` fields together with the `models` catalog required by Dahlia's bundled Codex. Omitting `client_version` selects the latest supported bundled version, currently `0.149.1`; callers may also request `client_version=0.149.1` explicitly. Other explicit versions return `400 unsupported_codex_client_version`. The enabled Model Alias rows remain the source of truth for both representations. Codex picker and runtime metadata is inferred from the upstream model or alias when it matches the pinned catalog; models without pinned Codex metadata use the OSS default of `none`, `low`, `high`, and `max` reasoning effort with `max` as the default. OpenAI-internal transport, hosted-tool, service-tier, and canonical-model lifecycle fields are not inherited by aliases. Updating the bundled Codex requires updating this Server catalog and its contract test in the same change.

The first authenticated user becomes the initial administrator. Administrator roles are stored in Better Auth's `auth.user.role`; additional registered users can be promoted or demoted under `/admin/members`.

OpenAI or another OpenAI-compatible provider:

```dotenv
DAHLIA_AI_BACKEND=openai
OPENAI_API_KEY=...
# OPENAI_BASE_URL=https://api.openai.com/v1
```

Non-local provider URLs must use HTTPS. The database is the only Model Alias source of truth.

Databricks native OpenAI Responses API:

```dotenv
DAHLIA_AI_BACKEND=databricks
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_CLIENT_ID=<app-service-principal-client-id>
DATABRICKS_CLIENT_SECRET=<app-service-principal-secret>
DAHLIA_DATABASE_TYPE=lakebase
LAKEBASE_ENDPOINT=<injected from the postgres app resource>
```

Databricks Apps supplies `DATABRICKS_HOST`, App service principal credentials, and `X-Forwarded-Access-Token`. Dahlia sends the forwarded user token as Bearer authentication only to `DATABRICKS_HOST/ai-gateway/mlflow/v1/responses`; it does not persist, log, or forward the proxy header itself. The Lakebase connector and model discovery independently use the App identity.

For administrators, `GET /api/admin/models` uses the App service principal to list the system-provided model services from `DATABRICKS_HOST/api/2.1/unity-catalog/model-services?parent=schemas/system.ai&view=BASIC`, follows all result pages, and merges their saved enabled state. `DAHLIA_AI_BACKEND=databricks` therefore requires `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; Databricks Apps injects both at runtime. Desktop authorization requests `all-apis`; the App's separate OBO token retains the configured `ai-gateway` and `files` user API scopes. The Dashboard searches models by name and sorts enabled models first, then by model name and newest `update_time`; it enables or disables those models directly and does not show the manual Model Alias form for this backend.

Cloudflare AI Gateway:

```dotenv
DAHLIA_AI_BACKEND=cloudflare
OPENAI_API_KEY=<cloudflare-api-token>
OPENAI_BASE_URL=https://api.cloudflare.com/client/v4/accounts/<account-id>/ai/v1
```

This uses Cloudflare's account-level OpenAI-compatible REST API and its default gateway. Dahlia disables Cloudflare payload logging on forwarded requests.

## Local Node deployment

Node 22.13 or newer is required. Dahlia Server owns its pnpm version, lockfile, and dependency build allowlist independently from the other applications:

```bash
cd apps/server
corepack enable
cp .env.example .env.local
pnpm install --frozen-lockfile
pnpm dev
```

The development scripts load `apps/server/.env.local`. SQLite at `apps/server/.data/dahlia-auth.sqlite` is the default, so PostgreSQL and Docker are not required locally. Existing Server values in the repository-root `.env.local` must be copied manually; that file remains owned by macOS development and release tooling.

Set `DAHLIA_DATABASE_TYPE=postgres` and `DAHLIA_DATABASE_URL` to move Better Auth and Gateway administration to PostgreSQL, or set `DAHLIA_AUTH_TYPE=header` for an identity-aware proxy.

For `accounts`, configure the Google OAuth callback as `http://localhost:5173/api/auth/callback/google` locally or `https://<host>/api/auth/callback/google` in production.

For an identity-aware proxy, set `DAHLIA_AUTH_TYPE=header` and `DAHLIA_AUTH_HEADER` to the verified email header. Ensure the proxy removes and replaces that header and the application server is not directly reachable.

The reference production container runs `pnpm db:migrate:prod` before starting Node, including with `header` authentication. PostgreSQL migrations use a session-level advisory lock, so replicas wait for one migrator instead of racing the same DDL. Migration metadata is kept outside the application schemas: Better Auth uses `drizzle.__dahlia_auth_migrations`, and the application baseline uses `drizzle.__dahlia_server_migrations`. Both are applied in every authentication mode, in that order.

SQLite contains user accounts, OAuth sessions, refresh tokens, and signing keys. Persist it across container replacement with a named volume:

```bash
docker build -t dahlia-server apps/server
docker volume create dahlia-server-data
docker run --mount source=dahlia-server-data,target=/app/.data \
  --env-file apps/server/.env.local -p 3000:3000 dahlia-server
```

Back up that volume when using SQLite. PostgreSQL deployments should back up the configured database instead.

## Local Cloudflare development

Cloudflare development has a separate Vite configuration so the regular `pnpm dev` Node flow remains unchanged. Put local Worker secrets in `apps/server/.dev.vars`, apply the local D1 migrations, and then start the Cloudflare Vite plugin:

```bash
pnpm db:migrate:d1:local
pnpm dev:cloudflare
```

The API Worker runs in workerd with the local D1 binding. React, JavaScript, CSS, and SPA navigations are served by Workers Static Assets without passing through Hono. Production-equivalent builds and previews use:

```bash
pnpm build:cloudflare
pnpm preview:cloudflare
```

Deployment guides:

- [Cloudflare Workers + D1 or Hyperdrive](../../deploy/cloudflare/README.md)
- [Databricks Apps](../../deploy/databricks/README.md)

## Codex 0.149.1 manual configuration

```toml
model = "<alias-configured-in-admin>"
model_provider = "dahlia-server"

[model_providers.dahlia-server]
name = "Dahlia Server"
base_url = "https://<host>/api/v1"
wire_api = "responses"

[model_providers.dahlia-server.auth]
command = "/path/to/short-lived-token-helper"
args = []
timeout_ms = 10000
refresh_interval_ms = 300000

[features]
enable_request_compression = false
```

The auth command prints a current bearer token to stdout; do not place that token in this file, an environment variable, or logs. With `accounts`, use an access token issued to `databricks-cli`. With Databricks Apps `header` authentication, use a current Databricks U2M access token. Request compression remains disabled because the service validates the uncompressed JSON body before forwarding it.

## Validation

```bash
pnpm check
```

This runs lint, TypeScript checks, unit and adapter contract tests, Node/SPA builds, and a Workers dry-run. Live credentials are tested separately with a pinned Codex 0.149.1 model-list and tool-call session and, on Databricks Apps, an SSE streaming smoke test.

## Package consumers

`@dahlia-ai/server` is versioned independently from the macOS app and published to npm from `server-v<version>` tags. Consumers should pin an exact version. Build it from `apps/server` with `pnpm build`. For active sibling-repository development, run `pnpm link ../dahlia/apps/server` from the consumer repository. To verify the exact published artifact shape, run `pnpm pack` from `apps/server` and install the resulting tarball; the `prepack` lifecycle builds the artifact automatically.

The tag workflow requires an `NPM_TOKEN` repository secret with publish access to the `@dahlia-ai/server` package.

The Worker-safe package root exports the backend extension contract from `@dahlia-ai/server`; Node-only APIs such as `createNodeAuthStore` are exported from `@dahlia-ai/server/node`. Dashboard components come from `@dahlia-ai/server/client`, shared styles from `@dahlia-ai/server/client/styles.css`, and the migration manifest from `@dahlia-ai/server/migrations`. Server migrations must run before consumer migrations. Give every SQLite and PostgreSQL Drizzle migration directory a stable lowercase ledger ID; never derive it from manifest position.
