# Dahlia Server

`apps/server` is the optional, self-hostable AI Gateway used by the Codex process embedded in Dahlia. It also accepts explicitly uploaded arbitrary-byte artifacts; it does not automatically receive recordings, transcript records, SQLite databases, or Vault data. Responses request content is relayed to the configured provider without being persisted or logged.

Better Auth, Gateway administration, and future meeting cloud sync share one Drizzle application database. Provider credentials remain separate runtime secrets and are never stored in that database.

## Database and Gateway configuration

`DAHLIA_DATABASE_TYPE` selects storage independently from authentication and the AI Gateway:

| Type | Runtime | Connection |
| --- | --- | --- |
| `sqlite` | Node | `DAHLIA_DATABASE_URL=file:...` (default: `file:.data/dahlia-auth.sqlite`) |
| `postgres` | Node or Worker | `DAHLIA_DATABASE_URL=postgresql://...` |
| `lakebase` | Node / Databricks Apps | `LAKEBASE_ENDPOINT` and injected `PG*` variables |
| `hyperdrive` | Cloudflare Worker | `HYPERDRIVE` binding |
| `d1` | Cloudflare Worker | `dahlia_db_prod` binding |

Node supports `sqlite`, `postgres`, and `lakebase`; Workers support `d1`, `hyperdrive`, and direct `postgres`. PostgreSQL-compatible connections keep Better Auth tables in `auth` and Dahlia-owned tables in `dahlia`; both schemas are owned by the connection user. Lakebase uses the official `@databricks/lakebase` pool for OAuth credential refresh.

Better Auth schemas are generated unmodified into `src/db/generated`; Dahlia tables remain in the adjacent app schema files. `pnpm db:generate-auth` refreshes the auth definitions and `pnpm db:generate` produces one Drizzle migration stream per dialect under `drizzle/postgres` and `drizzle/sqlite`. The relations-v2 adapter is used with joins disabled. PostgreSQL migrations qualify both schemas; SQLite and D1 retain top-level tables and rely on the same application owner checks instead of RLS.

## API contract

| Path | `accounts` | `header` |
| --- | --- | --- |
| `/`, `/sign-in`, `/dashboard/**` | Static SPA | Static SPA |
| `/api/auth/**` | Google sign-in and OAuth 2.1 endpoints | Disabled |
| `/api/session` | Account session and capabilities | Validated email-header identity and capabilities |
| `/api/admin/**` | Platform administrators only | Platform administrators only |
| `/api/v1/models` | Dahlia OAuth access token | Platform U2M / proxy authentication |
| `/api/v1/responses` | Dahlia OAuth access token | Platform U2M / proxy authentication |
| `POST /api/v1/artifacts` | Dahlia OAuth with artifact write scope | Proxy identity |
| `/api/v1/artifacts/{uuidv7}` | Public reads are anonymous; private reads and mutations use Dahlia OAuth | Public reads are anonymous; private reads and mutations use proxy identity |
| `POST /mcp` | Dahlia OAuth with artifact write scope | Databricks Apps / trusted proxy identity |
| `/healthz` | Minimal liveness | Internal liveness; anonymous external access is not guaranteed |

`accounts` is the default authentication. It serves OAuth/OIDC discovery under `/.well-known/**`. Both hosted and self-hosted deployments use the fixed public client `databricks-cli`; it requires authorization code with S256 PKCE and supports rotating refresh tokens and revocation. Its default redirect allowlist retains the released `http://127.0.0.1:1455/oauth/callback` and also accepts the Desktop callback `http://localhost:8020`. RFC 7591 dynamic client registration remains disabled. Node deployments support MCP 2026-07-28 Client ID Metadata Documents (CIMD) with pinned public-address fetching; the MCP resource is `${DAHLIA_APP_URL}/mcp` and its protected-resource metadata is at `/.well-known/oauth-protected-resource/mcp`.

OAuth access uses `api.model.read` for models, `api.model.request` for Responses, and `api.artifact.read` / `api.artifact.write` for private artifact operations. The fixed client is allowed to request these scopes; each endpoint verifies its own scope.

### Artifact API

`POST /api/v1/artifacts` accepts an uncompressed raw body with a required `Content-Length` up to 64 MiB, creates a private artifact with a Server-generated canonical lowercase UUIDv7, and returns its stable API URL in `Location`. `PUT /api/v1/artifacts/{uuidv7}` replaces an existing artifact owned by the caller and requires the original `Content-Type`; it never creates a missing ID. `PATCH` accepts only `{"visibility":"private"}` or `{"visibility":"public"}`, and `DELETE` removes bytes before metadata so a storage failure can be retried. There is no list, history, expiry, malware scan, HTML sanitization, or per-user share API.

All storage backends stream authorized `GET` and `HEAD` responses through Dahlia, forward `Range` and `If-Unmodified-Since`, and apply a CSP sandbox so uploaded HTML cannot inherit the Dahlia application origin. Storage URLs and credentials are never returned to clients.

### Artifact MCP

`POST /mcp` is a stateless, modern-only MCP 2026-07-28 endpoint. It exposes `create_artifact`, `update_artifact_content`, `update_artifact_visibility`, and `delete_artifact`; all operations use the same owner checks and private-by-default metadata as the Artifact REST API. Tool content is UTF-8 or canonical RFC 4648 base64, decoded to at most 8 MiB. MCP requests are rejected above 12 MiB before JSON parsing, including streamed requests without `Content-Length`. Tool results contain the artifact ID, canonical Dahlia URL, content type, visibility, and a resource link, never artifact bytes or storage URLs. Streaming uploads larger than 8 MiB remain available through the REST API.

In `accounts` mode, `/mcp` requires a DPoP-bound access token for the exact MCP resource and `api.artifact.write`. In `header` mode, authentication is delegated to the trusted proxy and Dahlia derives ownership from its verified forwarded identity headers. Databricks Apps exposes custom MCP servers at `/mcp`; its proxy has already authenticated the request, and `X-Forwarded-Access-Token` is not used for artifact storage. A present `Origin` must match the configured application origin; non-browser clients may omit it.

`DAHLIA_STORAGE_BACKEND` selects `local`, `s3`, `databricks`, or `r2`. Node defaults to `local` under `DAHLIA_STORAGE_LOCAL_PATH=.data/storage`. Databricks uses `DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH=/Volumes/<catalog>/<schema>/<volume>`. S3 uses `DAHLIA_STORAGE_S3_BUCKET`, optional `DAHLIA_STORAGE_S3_ENDPOINT`, and the standard `AWS_*` credential variables. Workers must explicitly select `r2` with the `DAHLIA_STORAGE` binding or `s3`; they reject the local default.

`header` reads the authenticated email from `X-Forwarded-Email` by default. Override the email header name with `DAHLIA_AUTH_HEADER`, for example `Cf-Access-Authenticated-User-Email`. `X-Forwarded-User` supplies the stable user ID and `X-Forwarded-Preferred-Username` supplies the display name; when absent, the email remains the user ID. The upstream proxy must remove client-supplied identity headers, write the verified values itself, and prevent direct access to the Server.

`DAHLIA_APP_URL` sets the canonical public application origin used for OAuth metadata and browser mutation checks. When it is absent, Dahlia uses `DATABRICKS_APP_URL`, then falls back to `http://localhost:5173` for local development.

## Provider and model configuration

The AI backend uses the OpenAI Responses-compatible contract and is independent of the database. Select `databricks`, `cloudflare`, or `openai` with `DAHLIA_AI_BACKEND`; it defaults to `openai`. While the selected non-Databricks backend has no `OPENAI_API_KEY`, `/api/v1/models` returns an empty standard model list and a Codex catalog with no picker-visible models, while Responses returns `503 provider_not_configured`.

`GET /api/v1/models` returns the standard OpenAI `object` and `data` fields together with the `models` catalog required by Dahlia's bundled Codex. Omitting `client_version` selects the latest supported bundled version, currently `0.149.1`; callers may also request `client_version=0.149.1` explicitly. Other explicit versions return `400 unsupported_codex_client_version`. The enabled Model Alias rows remain the source of truth for both representations. Codex picker and runtime metadata is inferred from the upstream model or alias when it matches the pinned catalog; OpenAI-internal transport, hosted-tool, service-tier, and canonical-model lifecycle fields are not inherited by aliases. Databricks DeepSeek V4 Flash is exposed as text-only with `low`, `high`, and `max` reasoning efforts and a `max` default. Unknown aliases use conservative fallback metadata without reasoning-effort options. Updating the bundled Codex requires updating this Server catalog and its contract test in the same change.

Set the optional `DAHLIA_ADMIN_EMAIL` to bootstrap administration. That email remains an administrator while configured and cannot be removed in the UI. Additional administrator emails are managed under `/admin/members`. Starting with no administrator is allowed.

OpenAI or another OpenAI-compatible provider:

```dotenv
DAHLIA_AI_BACKEND=openai
OPENAI_API_KEY=...
# OPENAI_BASE_URL=https://api.openai.com/v1
```

Non-local provider URLs must use HTTPS. The database is the only Model Alias source of truth.

Databricks Codex AI Gateway:

```dotenv
DAHLIA_AI_BACKEND=databricks
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_CLIENT_ID=<app-service-principal-client-id>
DATABRICKS_CLIENT_SECRET=<app-service-principal-secret>
DAHLIA_DATABASE_TYPE=lakebase
LAKEBASE_ENDPOINT=<injected from the postgres app resource>
```

Databricks Apps supplies `DATABRICKS_HOST`, App service principal credentials, and `X-Forwarded-Access-Token`. Dahlia sends the forwarded user token as Bearer authentication only to `DATABRICKS_HOST/ai-gateway/codex/v1/responses`; it does not persist, log, or forward the proxy header itself. All Databricks models use this coding-agent-specific route so Codex tool requests are adapted by the workspace Gateway. The Lakebase connector and model discovery independently use the App identity.

For administrators, `GET /api/admin/models` uses the App service principal to list the system-provided model services from `DATABRICKS_HOST/api/2.1/unity-catalog/model-services?parent=schemas/system.ai&view=BASIC`, follows all result pages, and merges their saved enabled state. `DAHLIA_AI_BACKEND=databricks` therefore requires `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; Databricks Apps injects both at runtime. The App requests only the `ai-gateway` user API scope for Responses. The Dashboard searches models by name and sorts enabled models first, then by model name and newest `update_time`; it enables or disables those models directly and does not show the manual Model Alias form for this backend.

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

The reference production container runs `pnpm db:migrate:prod` before starting Node, including with `header` authentication. PostgreSQL migrations use a session-level advisory lock, so replicas wait for one migrator instead of racing the same DDL.

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
