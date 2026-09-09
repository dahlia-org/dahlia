# Deploy Dahlia Server on Cloudflare

This target uses Hono only for the API Worker. React, JavaScript, CSS, and SPA navigation are served directly by Cloudflare Workers Static Assets. The default template selects `DAHLIA_DATABASE_TYPE=d1`; the alternate `wrangler.hyperdrive.example.jsonc` selects PostgreSQL through the `HYPERDRIVE` binding. Authentication and the OpenAI-compatible upstream are configured independently.

```text
browser ─────────────── Workers Static Assets ── React SPA / JS / CSS
   │ API, discovery, health
   ▼
Hono API Worker ─┬──── D1 ── Better Auth and application metadata
                 ├──── R2 ── object storage
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

Copy the database name and ID returned by the first command into `d1_databases[0]` in `apps/server/wrangler.jsonc`. Keep the binding name `dahlia_db_prod` and `migrations_dir=drizzle/d1` unchanged. `pnpm db:generate:sqlite` refreshes this Wrangler-compatible flat mirror from the Drizzle SQLite migrations. The real configuration stays local and is not committed.

Set the bucket name in the `DAHLIA_STORAGE` binding. The Worker uses that binding for upload, download, metadata, and deletion; no S3 credentials are required for the `r2` backend.

For Hyperdrive, start from the alternate template and replace its Hyperdrive ID, then apply the schema-qualified PostgreSQL SQL under `apps/server/drizzle/postgres`. The migrations create the `auth` and `app` schemas. Keep the binding name `HYPERDRIVE` unchanged.

## 3. Configure authentication

```bash
pnpm exec wrangler secret put DAHLIA_APP_URL
pnpm exec wrangler secret put BETTER_AUTH_SECRET
pnpm exec wrangler secret put GOOGLE_CLIENT_ID
pnpm exec wrangler secret put GOOGLE_CLIENT_SECRET
```

Use the final HTTPS Worker or custom-domain origin for `DAHLIA_APP_URL`; do not include a path.
The first authenticated user becomes the initial administrator. Add further registered users from `/admin/members`.

## 4. Configure Cloudflare AI Gateway

The example Wrangler configuration sets `DAHLIA_AI_BACKEND=cloudflare`. Configure Cloudflare's account-level OpenAI-compatible Responses endpoint. Use an API token with **Account > Workers AI > Read** permission as `OPENAI_API_KEY` and enter the full account URL as `OPENAI_BASE_URL`:

```bash
pnpm exec wrangler secret put OPENAI_API_KEY
pnpm exec wrangler secret put OPENAI_BASE_URL
```

Use `https://api.cloudflare.com/client/v4/accounts/<account-id>/ai/v1` as the base URL. Set `CLOUDFLARE_AI_GATEWAY_ID` to select a gateway (default: `default`). Dahlia disables gateway logging, payload collection, caching, and additional gateway attempts. The existing `gpt-5.6-luna` entry is retained; jobs support `gpt-4.1` (text/image, reasoning `none`) and `gemini-3-flash` (audio, reasoning `minimal`, `low`, `medium`, `high`). Public short names map to `openai/gpt-4.1` and `google/gemini-3-flash`. Set `CODEX_AUTO_REVIEW_MODEL` to override the reserved automatic-review model independently of that catalog.

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

## Operational notes

- `/.well-known/*`, `/api/*`, `/mcp`, and `/healthz` are the only `assets.run_worker_first` paths. They always reach Hono, including browser navigation, so protocol and OAuth errors cannot become the SPA shell.
- The Worker does not advertise CIMD because the required DNS-resolve-once and connection-pinning transport is Node-only. Cloudflare `accounts` mode therefore cannot onboard a remote MCP client; use trusted-proxy `header` authentication for `/mcp`, and do not replace the transport with unrestricted Worker `fetch`.
- Matching static files and `/dashboard/**` navigations are handled by Workers Static Assets. The Worker has no `ASSETS` binding and does not fetch assets programmatically.
- Use `pnpm dev:cloudflare` for workerd, local D1, and production-equivalent asset routing. Local Worker secrets belong in the ignored `apps/server/.dev.vars`; regular `pnpm dev` uses `apps/server/.env.local` and Node.
- Responses requests are capped at 4 MiB on Workers to remain within the isolate memory budget.
- Back up D1 for Better Auth, Model Alias, and administrator recovery. Provider credentials are recovered from the deployment secret store, not D1.
- Rotate Google and provider credentials independently and redeploy after changing non-secret configuration.

The templates configure a once-per-minute Cron Trigger for recording staging expiration and queued object deletion. Keep `triggers.crons` enabled when adapting the configuration: the scheduled handler performs maintenance without any HTTP traffic, including after a cold start.


## PostgreSQL background jobs

The Hyperdrive template enables independent summary, image-analysis and search Queues, each with a DLQ, batch size 1 and concurrency 1. Create `dahlia-summary`, `dahlia-image`, `dahlia-search` and their `-dlq` queues before deploying (for example, `pnpm exec wrangler queues create dahlia-summary`). The `IMAGES` binding transforms private R2 screenshot streams to WebP without public URLs. D1 keeps its existing authentication/gateway features; meeting sync and these jobs require PostgreSQL or Hyperdrive.

Disable Hyperdrive query caching before using the binding: `pnpm exec wrangler hyperdrive update <id> --caching-disabled true`. This is Hyperdrive resource configuration, not a Wrangler binding field. Stale authorization and job reads are unsafe. Apply the registered PostgreSQL migrations using `DAHLIA_DATABASE_TYPE=postgres DAHLIA_DATABASE_URL=<migration-url> pnpm db:migrate`. Supply the same provider/embedding environment values used by the Worker when migrating. Semantic search requires the existing pgvector extension and its model/dimension-specific HNSW index; the migration command creates that index when embeddings are configured (the underlying column remains `real[]`).

`DAHLIA_AI_BACKEND` is independent of the runtime. Both Node and Workers support Databricks (service principal credentials plus model schema) and Cloudflare (account REST token). Workers require `DAHLIA_SUMMARY_QUEUE` plus `IMAGES` for summary capability; configured captioning requires `DAHLIA_IMAGE_QUEUE` plus `IMAGES`, and configured embeddings require `DAHLIA_SEARCH_QUEUE`. Missing required bindings fail initialization. Cloudflare embedding is `@cf/baai/bge-m3`, 1024 dimensions; captioning is `gpt-4.1`. Existing saved model settings are preserved: select supported models and reasoning explicitly before enabling generation.

Messages contain job references only. DB commits precede notification. Every minute, Cron enumerates owners and reconciles/dispatches pages of at most 100 rows, with continuations in Queue. Search run messages hold at most 16 document references. DB state owns attempts, availability, leases and generations; duplicates and stale claims do no work. Summary timeout/lease/attempt limits remain 4 minutes / 5 minutes / 3 attempts. Transient AI failures persist a DB retry; DB errors use native Queue retry. A DLQ entry does not delete the canonical job, and Cron can recover an expired lease. Monitor bounded `job_notification_failed`, `queue_job_failed` and processor event/error codes plus Queue/DLQ counts. Keep Cron enabled and resolve infrastructure failures before replaying DLQ messages. Drain jobs before changing the deployment-wide provider.

Audio uses checksum-verified streaming Base64 with mic/system manifests intact. Cloudflare audio requests fail explicitly above 20,000,000 encoded bytes, including JSON and images; recordings are never truncated. Images are capped at 4 MiB each and 12 MiB per summary; summary responses at 2 MiB, caption responses at 1 MiB and embedding responses at 4 MiB. These limits apply before complete response buffering.

Validate with `pnpm check` and the local runtime check documented in the Server README. Live validation needs dedicated synthetic recordings/screenshots and real provider credentials: complete a summary, audio transcription/summary, caption/OCR and semantic search, then check persisted results and retry behavior. Mock tests and bundle dry-run do not establish live AI, Hyperdrive or Images availability.

Contracts: [AI REST API](https://developers.cloudflare.com/ai-gateway/usage/rest-api/), [Images binding](https://developers.cloudflare.com/images/optimization/binding/), [Hyperdrive caching](https://developers.cloudflare.com/hyperdrive/concepts/query-caching/).
