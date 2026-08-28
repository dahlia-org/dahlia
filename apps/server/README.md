# Dahlia Server

`apps/server` is the optional, self-hostable AI Gateway used by the Codex process embedded in Dahlia. It does not currently receive recordings or transcript records. Responses request content is relayed to the configured provider without being persisted or logged.

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

Node supports `sqlite`, `postgres`, and `lakebase`; Workers support `d1`, `hyperdrive`, and direct `postgres`. Lakebase uses the official `@databricks/lakebase` pool for OAuth credential refresh. All queries and Better Auth adapters use Drizzle.

## API contract

| Path | `accounts` | `header` |
| --- | --- | --- |
| `/`, `/sign-in`, `/dashboard/**` | Static SPA | Static SPA |
| `/api/auth/**` | Google sign-in and OAuth 2.1 endpoints | Disabled |
| `/api/session` | Account session and capabilities | Validated email-header identity and capabilities |
| `/api/admin/**` | Platform administrators only | Platform administrators only |
| `/api/v1/models` | Dahlia OAuth access token | Platform U2M / proxy authentication |
| `/api/v1/responses` | Dahlia OAuth access token | Platform U2M / proxy authentication |
| `/healthz` | Minimal liveness | Internal liveness; anonymous external access is not guaranteed |

`accounts` is the default authentication. It serves OAuth/OIDC discovery under `/.well-known/**`. The fixed public client is `dahlia-macos`; it requires authorization code with S256 PKCE and supports rotating refresh tokens and revocation. Dynamic client registration is disabled.

OAuth access uses `api.model.read` for `GET /api/v1/models` and `api.model.request` for `POST /api/v1/responses`. The fixed client is allowed to request both scopes; each endpoint verifies its own scope.

`header` reads the authenticated email from `X-Forwarded-Email` by default. Override the name with `DAHLIA_AUTH_HEADER`, for example `Cf-Access-Authenticated-User-Email`. The upstream proxy must remove client-supplied values, write the verified header itself, and prevent direct access to the Server.

## Provider and model configuration

The AI backend uses the OpenAI Responses-compatible contract and is independent of the database. Set `OPENAI_API_KEY`; `OPENAI_BASE_URL` defaults to `https://api.openai.com/v1`. While it is absent, `/api/v1/models` returns an empty list and Responses returns `503 provider_not_configured`.

Set the optional `DAHLIA_ADMIN_EMAIL` to bootstrap administration. That email remains an administrator while configured and cannot be removed in the UI. Additional administrator emails are managed under `/admin/members`. Starting with no administrator is allowed.

OpenAI or another OpenAI-compatible provider:

```dotenv
OPENAI_API_KEY=...
# OPENAI_BASE_URL=https://api.openai.com/v1
```

Non-local provider URLs must use HTTPS. The database is the only Model Alias source of truth.

Databricks native OpenAI Responses API:

```dotenv
OPENAI_API_KEY=<databricks-pat-or-bearer-token>
OPENAI_BASE_URL=https://<workspace-host>/ai-gateway/openai/v1
DAHLIA_DATABASE_TYPE=lakebase
LAKEBASE_ENDPOINT=<injected from the postgres app resource>
```

The Lakebase connector uses the Databricks Apps service principal only for rotating database credentials. Those credentials are not sent to the model endpoint.

Cloudflare AI Gateway:

```dotenv
OPENAI_API_KEY=<cloudflare-api-token>
OPENAI_BASE_URL=https://api.cloudflare.com/client/v4/accounts/<account-id>/ai/v1
```

This uses Cloudflare's account-level OpenAI-compatible REST API and its default gateway. Dahlia disables Cloudflare payload logging on forwarded requests.

## Local Node deployment

Node 22.13 or newer is required. From the repository root:

```bash
cp .env.example .env.local
pnpm install --frozen-lockfile
pnpm dev
```

The development scripts load the repository-root `.env.local`. SQLite at `apps/server/.data/dahlia-auth.sqlite` is the default, so PostgreSQL and Docker are not required locally.

Set `DAHLIA_DATABASE_TYPE=postgres` and `DAHLIA_DATABASE_URL` to move Better Auth and Gateway administration to PostgreSQL, or set `DAHLIA_AUTH_PROVIDER=header` for an identity-aware proxy.

For `accounts`, configure the Google OAuth callback as `http://localhost:5173/api/auth/callback/google` locally or `https://<host>/api/auth/callback/google` in production.

For an identity-aware proxy, set `DAHLIA_AUTH_PROVIDER=header` and `DAHLIA_AUTH_HEADER` to the verified email header. Ensure the proxy removes and replaces that header and the application server is not directly reachable.

The reference production container runs `pnpm db:migrate:prod` before starting Node, including with `header` authentication. PostgreSQL migrations use a session-level advisory lock, so replicas wait for one migrator instead of racing the same DDL.

SQLite contains user accounts, OAuth sessions, refresh tokens, and signing keys. Persist it across container replacement with a named volume:

```bash
docker build -f apps/server/Dockerfile -t dahlia-server .
docker volume create dahlia-server-data
docker run --mount source=dahlia-server-data,target=/app/apps/server/.data \
  --env-file .env.local -p 3000:3000 dahlia-server
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

## Codex 0.148.0 manual configuration

```toml
model = "<alias-configured-in-admin>"
model_provider = "dahlia-server"

[model_providers.dahlia-server]
name = "Dahlia Server"
base_url = "https://<host>/api/v1"
env_key = "DAHLIA_ACCESS_TOKEN"
wire_api = "responses"

[features]
enable_request_compression = false
```

With `accounts`, use an access token issued to `dahlia-macos`. With Databricks Apps `header` authentication, use a current Databricks U2M access token. Request compression remains disabled because the service validates the uncompressed JSON body before forwarding it.

## Validation

```bash
pnpm check
```

This runs lint, TypeScript checks, unit and adapter contract tests, Node/SPA builds, and a Workers dry-run. Live credentials are tested separately with a pinned Codex 0.148.0 tool-call session and, on Databricks Apps, an SSE streaming smoke test.

## Package consumers

`@dahlia-ai/server` is versioned independently from the macOS app and published to npm from `server-v<version>` tags. Consumers should pin an exact version. Before the first package publication, run `pnpm --filter @dahlia-ai/server build` and then use `pnpm link ../dahlia/apps/server` for active sibling-repository development. To verify the exact published artifact shape, install the tarball produced by `pnpm --filter @dahlia-ai/server pack`; the `prepack` lifecycle builds the artifact automatically.

The tag workflow requires an `NPM_TOKEN` repository secret with publish access to the `@dahlia-ai/server` package.

The Worker-safe package root exports the backend extension contract from `@dahlia-ai/server`; Node-only APIs such as `createNodeAuthStore` are exported from `@dahlia-ai/server/node`. Dashboard components come from `@dahlia-ai/server/client`, shared styles from `@dahlia-ai/server/client/styles.css`, and the migration manifest from `@dahlia-ai/server/migrations`. Server migrations must run before consumer migrations. Give every SQLite and PostgreSQL migration directory a stable lowercase ledger ID; never derive it from manifest position. Each SQLite directory explicitly lists the SQL filenames to apply; other files in that directory are ignored.
