# Deploy Dahlia Cloud on Cloudflare

This target uses Hono only for the API Worker. React, JavaScript, CSS, and SPA navigation are served directly by Cloudflare Workers Static Assets without invoking Hono or an assets binding. The checked-in `DAHLIA_RUNTIME=cloudflare` preset fixes authentication to `accounts` and storage to D1. The upstream uses the same OpenAI-compatible contract as every runtime. Provider credentials remain Worker secrets, while Model Aliases and administrators use D1; Hyperdrive is not used.

```text
browser ─────────────── Workers Static Assets ── React SPA / JS / CSS
   │ API, discovery, health
   ▼
Hono API Worker ─┬──── D1 ── Better Auth data
                 └──── HTTPS ── Cloudflare AI Gateway
```

The checked-in configuration is [`apps/cloud/wrangler.jsonc`](../../wrangler.jsonc). D1 stores Better Auth data, Model Aliases, and administrator emails. Run these commands from the repository root.

## Prerequisites

- A Cloudflare account and authenticated Wrangler CLI.
- A Google OAuth client with `https://<host>/api/auth/callback/google` registered as a redirect URI.
- Node.js 22.13 or newer, Corepack, and pnpm.

## 1. Install and build

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm --filter @dahlia/cloud build:cloudflare
```

## 2. Create and migrate D1

```bash
pnpm --filter @dahlia/cloud exec wrangler d1 create dahlia-auth
pnpm --filter @dahlia/cloud exec wrangler d1 migrations apply AUTH_DB --remote
```

Copy the database ID returned by the first command into `d1_databases[0].database_id` in `apps/cloud/wrangler.jsonc`. Keep the binding name `AUTH_DB` and migrations directory `auth-migrations` unchanged.

## 3. Configure authentication

```bash
pnpm --filter @dahlia/cloud exec wrangler secret put DAHLIA_BASE_URL
pnpm --filter @dahlia/cloud exec wrangler secret put BETTER_AUTH_SECRET
pnpm --filter @dahlia/cloud exec wrangler secret put GOOGLE_CLIENT_ID
pnpm --filter @dahlia/cloud exec wrangler secret put GOOGLE_CLIENT_SECRET
```

Use the final HTTPS Worker or custom-domain origin for `DAHLIA_BASE_URL`; do not include a path.
Optionally set `DAHLIA_ADMIN_EMAIL` to bootstrap `/admin` and add further administrators from `/admin/members`.

## 4. Configure Cloudflare AI Gateway

Configure Cloudflare's account-level OpenAI-compatible Responses endpoint. Use an API token with AI Gateway permission as `OPENAI_API_KEY` and enter the full account URL as `OPENAI_BASE_URL`:

```bash
pnpm --filter @dahlia/cloud exec wrangler secret put OPENAI_API_KEY
pnpm --filter @dahlia/cloud exec wrangler secret put OPENAI_BASE_URL
```

Use `https://api.cloudflare.com/client/v4/accounts/<account-id>/ai/v1` as the base URL. This contract uses the default gateway and does not expose named-gateway selection. Dahlia sends `cf-aig-collect-log-payload: false` so prompt and response content are not collected in AI Gateway logs. After deployment, create public aliases such as `gpt-5.6-luna` and upstream IDs such as `openai/gpt-5.6-luna` under `/admin/models`.

## Optional: enable Stripe billing

Leave Stripe entirely unconfigured for a self-hosted Gateway without billing. To enable personal Free/Pro billing, set all three secrets:

```bash
pnpm --filter @dahlia/cloud exec wrangler secret put STRIPE_SECRET_KEY
pnpm --filter @dahlia/cloud exec wrangler secret put STRIPE_WEBHOOK_SECRET
pnpm --filter @dahlia/cloud exec wrangler secret put STRIPE_PRO_MONTHLY_PRICE_ID
```

Configure the Stripe webhook destination as `https://<host>/api/auth/stripe/webhook`. Partial configuration is rejected at startup.

## 5. Validate and deploy

```bash
pnpm check
pnpm --filter @dahlia/cloud build:cloudflare
pnpm --filter @dahlia/cloud exec wrangler deploy
```

The Cloudflare Vite plugin writes the deployable Worker, client assets, and output `wrangler.json` under `dist/cloudflare`. Wrangler automatically uses that output configuration after the Vite build.

After deployment:

```bash
curl -fsS https://<host>/healthz
curl -fsS https://<host>/.well-known/oauth-authorization-server
```

Then sign in with Google, create a Model Alias, and complete a streaming Responses request through `/api/v1/responses` using that alias.

## Operational notes

- `/.well-known/*`, `/api/*`, and `/healthz` are the only `assets.run_worker_first` paths. They always reach Hono, including browser navigation, so API and OAuth errors cannot become the SPA shell.
- Matching static files and `/dashboard/**` navigations are handled by Workers Static Assets. The Worker has no `ASSETS` binding and does not fetch assets programmatically.
- Use `pnpm dev:cloudflare` for workerd, local D1, and production-equivalent asset routing. Local Worker secrets belong in the ignored `apps/cloud/.dev.vars`; regular `pnpm dev` continues to use the repository-root `.env.local` and Node.
- Responses requests are capped at 4 MiB on Workers to remain within the isolate memory budget.
- Back up D1 for Better Auth, Model Alias, and administrator recovery. Provider credentials are recovered from the deployment secret store, not D1.
- Rotate Google and provider credentials independently and redeploy after changing non-secret configuration.
