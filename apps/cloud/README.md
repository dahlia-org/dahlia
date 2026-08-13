# Dahlia Cloud

`apps/cloud` is the optional, self-hostable AI Gateway used by the Codex process embedded in Dahlia. It does not receive or store recordings, the local SQLite database, or transcript records. Responses request content is relayed to the configured provider without being persisted or logged.

The Gateway exposes administrator-managed Model Aliases backed by SQLite, PostgreSQL/Lakebase, or D1. Provider credentials remain in runtime secrets; they are never stored in the database or exposed through the API, so `DAHLIA_ENCRYPTION_KEY` is not required.

## Runtime presets

`DAHLIA_RUNTIME` selects the deployment preset and defaults to `custom`:

| Runtime | Authentication | Database | Upstream Gateway |
| --- | --- | --- | --- |
| `cloudflare` | `accounts` | D1 | OpenAI-compatible upstream |
| `databricks` | `header` | PostgreSQL / Lakebase | OpenAI-compatible upstream |
| `custom` | `accounts` by default; `header` allowed | SQLite by default; PostgreSQL allowed | OpenAI-compatible upstream |

The managed presets are fixed. Explicit `DAHLIA_AUTH_PROVIDER` or `DAHLIA_AUTH_DATABASE` values are accepted only when they match the selected preset; conflicting values fail startup. `custom` is the only runtime that allows authentication and database overrides.

## API contract

| Path | `accounts` | `header` |
| --- | --- | --- |
| `/`, `/sign-in`, `/dashboard/**` | Static SPA | Static SPA |
| `/api/auth/**` | Google sign-in and OAuth 2.1 endpoints | Disabled |
| `/api/session` | Account session and capabilities | Validated email-header identity and capabilities |
| `/api/billing/summary` | Enabled only when Stripe is fully configured | Disabled |
| `/api/admin/**` | Platform administrators only | Platform administrators only |
| `/api/v1/models` | Dahlia OAuth access token | Platform U2M / proxy authentication |
| `/api/v1/responses` | Dahlia OAuth access token | Platform U2M / proxy authentication |
| `/healthz` | Minimal liveness | Internal liveness; anonymous external access is not guaranteed |

`accounts` is the default authentication for `custom` and is fixed for `cloudflare`. It serves OAuth/OIDC discovery under `/.well-known/**`. The fixed public client is `dahlia-macos`; it requires authorization code with S256 PKCE and supports rotating refresh tokens and revocation. Dynamic client registration is disabled.

OAuth access uses `api.model.read` for `GET /api/v1/models` and `api.model.request` for `POST /api/v1/responses`. The fixed client is allowed to request both scopes; each endpoint verifies its own scope.

`header` reads the authenticated email from `X-Forwarded-Email` by default. Override the name with `DAHLIA_AUTH_HEADER`, for example `Cf-Access-Authenticated-User-Email`. The upstream proxy must remove client-supplied values and write the verified header itself. A non-local `custom` deployment must set `DAHLIA_TRUSTED_PROXY_CIDRS`; local development defaults to loopback only. Databricks relies on its managed Apps proxy instead.

## Provider and model configuration

Every runtime uses the same OpenAI Responses-compatible upstream contract. Set `OPENAI_API_KEY`; `OPENAI_BASE_URL` defaults to `https://api.openai.com/v1`. The provider is optional at startup in every runtime. While it is absent, `/api/v1/models` returns an empty list and Responses returns `503 provider_not_configured`. After signing in as an administrator, create public aliases and their upstream model IDs under `/admin/models`.

Set the optional `DAHLIA_ADMIN_EMAIL` to bootstrap administration. That email remains an administrator while configured and cannot be removed in the UI. Additional administrator emails are managed under `/admin/members`. Starting with no administrator is allowed.

## Optional Stripe billing

Stripe billing is available only when the selected runtime uses `accounts` authentication. Configure all three values together:

```dotenv
STRIPE_SECRET_KEY=sk_...
STRIPE_WEBHOOK_SECRET=whsec_...
STRIPE_PRO_MONTHLY_PRICE_ID=price_...
```

When all three are absent, billing navigation, routes, API endpoints, and Gateway entitlement checks are disabled. A partial configuration, or any Stripe configuration with `header` authentication, fails startup. The webhook URL is `https://<host>/api/auth/stripe/webhook`; enable `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, and `customer.subscription.deleted` in Stripe.

When enabled, only an `active` or `trialing` Pro subscription whose paid period has not ended can use either Gateway endpoint. Free, stale, `past_due`, and canceled accounts receive `402 billing_required`. Checkout, signature verification, and Customer Portal are provided by the Better Auth Stripe plugin. Dahlia atomically stores each signed webhook snapshot with its event generation in an ordered entitlement projection, so an older, duplicate, or concurrent webhook cannot restore stale access. Dahlia fetches the latest twelve invoices only for the Billing page and never sends recording, transcript, prompt, response, or usage content to Stripe.

OpenAI or another OpenAI-compatible provider:

```dotenv
DAHLIA_RUNTIME=custom
OPENAI_API_KEY=...
# OPENAI_BASE_URL=https://api.openai.com/v1
```

Non-local provider URLs must use HTTPS. The database is the only Model Alias source of truth.

Databricks native OpenAI Responses API:

```dotenv
DAHLIA_RUNTIME=databricks
OPENAI_API_KEY=<databricks-pat-or-bearer-token>
OPENAI_BASE_URL=https://<workspace-host>/ai-gateway/openai/v1
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_CLIENT_ID=...
DATABRICKS_CLIENT_SECRET=...
```

The `DATABRICKS_*` service-principal values are used only to mint rotating Lakebase database credentials. They are not sent to the model endpoint.

Cloudflare AI Gateway:

```dotenv
DAHLIA_RUNTIME=cloudflare
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

The development scripts load the repository-root `.env.local`. `DAHLIA_RUNTIME` defaults to `custom`, `DAHLIA_BASE_URL` defaults to `http://localhost:5173`, and account authentication uses SQLite at `apps/cloud/.data/dahlia-auth.sqlite`, so PostgreSQL and Docker are not required locally.

In the `custom` runtime, set `DAHLIA_AUTH_DATABASE=postgres` and `DATABASE_URL` to move authentication and Gateway administration to PostgreSQL, or set `DAHLIA_AUTH_PROVIDER=header` for an identity-aware proxy. D1 is selected only by the `cloudflare` runtime. The `databricks` preset uses PostgreSQL/Lakebase for Model Aliases and administrators while header authentication itself remains sessionless.

For `accounts`, configure the Google OAuth callback as `http://localhost:5173/api/auth/callback/google` locally or `https://<host>/api/auth/callback/google` in production.

For an identity-aware proxy, set `DAHLIA_AUTH_PROVIDER=header` and `DAHLIA_AUTH_HEADER` to the verified email header. Ensure the proxy removes and replaces that header. The application server must not be directly reachable, and non-local `custom` deployments must set `DAHLIA_TRUSTED_PROXY_CIDRS` to the proxy network.

The reference production container runs `pnpm db:migrate:prod` before starting Node, including with `header` authentication. PostgreSQL migrations use a session-level advisory lock, so replicas wait for one migrator instead of racing the same DDL.

Because the application has not been released yet, the current schema edits the existing final migration directly. Delete and recreate an already-migrated local SQLite or D1 development database before testing this revision.

SQLite contains user accounts, OAuth sessions, refresh tokens, billing links, and signing keys. Persist it across container replacement with a named volume:

```bash
docker build -f apps/cloud/Dockerfile -t dahlia-cloud .
docker volume create dahlia-cloud-data
docker run --mount source=dahlia-cloud-data,target=/app/apps/cloud/.data \
  --env-file .env.local -p 3000:3000 dahlia-cloud
```

Back up that volume when using SQLite. PostgreSQL deployments should back up the configured database instead.

## Local Cloudflare development

Cloudflare development has a separate Vite configuration so the regular `pnpm dev` Node flow remains unchanged. Put local Worker secrets in `apps/cloud/.dev.vars`, apply the local D1 migrations, and then start the Cloudflare Vite plugin:

```bash
pnpm db:migrate:d1:local
pnpm dev:cloudflare
```

The API Worker runs in workerd with the local D1 binding. React, JavaScript, CSS, and SPA navigations are served by Workers Static Assets without passing through Hono. Production-equivalent builds and previews use:

```bash
pnpm build:cloudflare
pnpm preview:cloudflare
```

Managed deployment guides:

- [Cloudflare Workers + D1](deploy/cloudflare/README.md)
- [Databricks Apps](deploy/databricks/README.md)

## Codex 0.146.0 manual configuration

```toml
model = "<alias-configured-in-admin>"
model_provider = "dahlia-cloud"

[model_providers.dahlia-cloud]
name = "Dahlia Cloud"
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

This runs lint, TypeScript checks, unit and adapter contract tests, Node/SPA builds, and a Workers dry-run. Live credentials are tested separately with a pinned Codex 0.146.0 tool-call session and, on Databricks Apps, an SSE streaming smoke test.
