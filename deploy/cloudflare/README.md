# Deploy Dahlia Server on Cloudflare

This target uses Hono only for the API Worker. React, JavaScript, CSS, and SPA navigation are served directly by Cloudflare Workers Static Assets. The default template selects `DAHLIA_DATABASE_TYPE=d1`; the alternate `wrangler.hyperdrive.example.jsonc` selects PostgreSQL through the `HYPERDRIVE` binding. Authentication and the OpenAI-compatible upstream are configured independently.

```text
browser ─────────────── Workers Static Assets ── React SPA / JS / CSS
   │ API, discovery, health
   ▼
Hono API Worker ─┬──── D1 ── Better Auth and artifact metadata
                 ├──── R2 ── artifact bytes
                 └──── HTTPS ── Cloudflare AI Gateway
```

Copy either [`wrangler.example.jsonc`](wrangler.example.jsonc) for D1 or [`wrangler.hyperdrive.example.jsonc`](wrangler.hyperdrive.example.jsonc) for Hyperdrive to the ignored `apps/server/wrangler.jsonc`. The selected database stores Better Auth data, Model Aliases, and administrator emails.

## Prerequisites

- A Cloudflare account, an existing private R2 bucket, and authenticated Wrangler CLI.
- A Google OAuth client with `https://<host>/api/auth/callback/google` registered as a redirect URI.
- Node.js 22.13 or newer, Corepack, and pnpm.

## 1. Install and build

```bash
cd apps/server
corepack enable
pnpm install --frozen-lockfile
pnpm build:cloudflare
```

## 2. Configure and migrate the database

```bash
cp ../../deploy/cloudflare/wrangler.example.jsonc wrangler.jsonc
pnpm exec wrangler d1 create dahlia-db-prod
pnpm exec wrangler d1 migrations apply dahlia_db_prod --remote
```

Copy the database name and ID returned by the first command into `d1_databases[0]` in `apps/server/wrangler.jsonc`. Keep the binding name `dahlia_db_prod` and migrations directory `auth-migrations` unchanged. The real configuration stays local and is not committed.

Set the bucket name in the `DAHLIA_STORAGE` binding. The Worker uses that binding for upload, download, metadata, and deletion; no S3 credentials are required for the `r2` backend.

For Hyperdrive, start from the alternate template and replace its Hyperdrive ID, then apply the PostgreSQL SQL under `apps/server/drizzle` as the connection user. The baseline creates the user-owned `auth` and `dahlia` schemas. Keep the binding name `HYPERDRIVE` unchanged.

## 3. Configure authentication

```bash
pnpm exec wrangler secret put DAHLIA_APP_URL
pnpm exec wrangler secret put BETTER_AUTH_SECRET
pnpm exec wrangler secret put GOOGLE_CLIENT_ID
pnpm exec wrangler secret put GOOGLE_CLIENT_SECRET
```

Use the final HTTPS Worker or custom-domain origin for `DAHLIA_APP_URL`; do not include a path.
Optionally set `DAHLIA_ADMIN_EMAIL` to bootstrap `/admin` and add further administrators from `/admin/members`.

## 4. Configure Cloudflare AI Gateway

The example Wrangler configuration sets `DAHLIA_AI_BACKEND=cloudflare`. Configure Cloudflare's account-level OpenAI-compatible Responses endpoint. Use an API token with AI Gateway permission as `OPENAI_API_KEY` and enter the full account URL as `OPENAI_BASE_URL`:

```bash
pnpm exec wrangler secret put OPENAI_API_KEY
pnpm exec wrangler secret put OPENAI_BASE_URL
```

Use `https://api.cloudflare.com/client/v4/accounts/<account-id>/ai/v1` as the base URL. This contract uses the default gateway and does not expose named-gateway selection. Dahlia sends `cf-aig-collect-log-payload: false` so prompt and response content are not collected in AI Gateway logs. After deployment, create public aliases such as `gpt-5.6-luna` and upstream IDs such as `openai/gpt-5.6-luna` under `/admin/models`.

## 5. Validate and deploy

```bash
pnpm check
pnpm build:cloudflare
pnpm exec wrangler deploy
```

The Cloudflare Vite plugin writes the deployable Worker, client assets, and output `wrangler.json` under `dist/cloudflare`. Wrangler automatically uses that output configuration after the Vite build.

After deployment:

```bash
curl -fsS https://<host>/healthz
curl -fsS https://<host>/.well-known/oauth-authorization-server
```

Then sign in with Google, create a Model Alias, and complete a streaming Responses request through `/api/v1/responses` using that alias.
Also smoke-test an HTML artifact through private upload/read, public read, Range read, private transition, and deletion. R2 responses stream through the Dahlia API and must not contain a storage URL.

## Operational notes

- `/.well-known/*`, `/api/*`, and `/healthz` are the only `assets.run_worker_first` paths. They always reach Hono, including browser navigation, so API and OAuth errors cannot become the SPA shell.
- Matching static files and `/dashboard/**` navigations are handled by Workers Static Assets. The Worker has no `ASSETS` binding and does not fetch assets programmatically.
- Use `pnpm dev:cloudflare` for workerd, local D1, and production-equivalent asset routing. Local Worker secrets belong in the ignored `apps/server/.dev.vars`; regular `pnpm dev` uses `apps/server/.env.local` and Node.
- Responses requests are capped at 4 MiB on Workers to remain within the isolate memory budget.
- Artifact uploads have their independent 64 MiB limit and stream directly to the R2 binding.
- Back up D1 for Better Auth, Model Alias, and administrator recovery. Provider credentials are recovered from the deployment secret store, not D1.
- Rotate Google and provider credentials independently and redeploy after changing non-secret configuration.
