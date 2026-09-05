# Dahlia Server Guide

## Scope

This file applies to `apps/server`. The repository-root `AGENTS.md` still applies; this file adds only Server-specific guidance.

Dahlia Server is the SaaS backend and canonical data service for Server accounts, with a Private Web client, authentication, Vault sharing, search, an AI Gateway, and artifact storage. Desktop and Web update the same Server records; Desktop SQLite is an offline working copy, as in Notion. Preserve tenant isolation, durable data, public APIs, and runtime portability. Local accounts remain standalone, and recording and finalized-transcript persistence must never wait for network access.

## Reference Routing

Use progressive disclosure. Read the closest implementation first, then only the references needed for the change.

| Change | Required reference |
| --- | --- |
| Local setup, API behavior, configuration, or deployment overview | [`README.md`](README.md) |
| Product scope or whether a cloud feature belongs in Dahlia | [`PRODUCT.md`](../../PRODUCT.md), especially T4 and T5 |
| Account authentication and API access | [`README.md` API contract](README.md#api-contract), then the affected `src/auth` implementation |
| Gateway upstream relay | [Gateway 境界](../../docs/adr/server/gateway.md#gateway-境界) |
| Canonical data, remote mutations, conflicts, or catch-up | [Transaction と競合](../../docs/adr/shared/sync.md#transaction-と競合), then `src/sync` and the affected Desktop sync path |
| Vault ownership and sharing | [`README.md` Vault sharing](README.md#meeting-sync-and-vault-sharing) |
| Public package exports or extension hooks | [配布と拡張](../../docs/adr/server/gateway.md#配布と拡張) |
| Application database, identity, or migrations | [Schema と migration](../../docs/adr/server/database-and-identity.md#schema-と-migration) |
| Databricks deployment or Lakebase setup | [`deploy/databricks/README.md`](../../deploy/databricks/README.md) |
| Databricks forwarded user token | [Upstream identity](../../docs/adr/server/databricks.md#upstream-identity) |
| Databricks model discovery | [Upstream identity](../../docs/adr/server/databricks.md#upstream-identity) |
| Artifact authorization, storage, IDs, or public URLs | [Ownership と storage](../../docs/adr/server/artifacts.md#ownership-と-storage), [API と ID](../../docs/adr/server/artifacts.md#api-と-id) |
| Dependencies, lockfiles, packaging, or deployment source layout | [アプリ単位の依存管理](../../docs/adr/monorepo/dependencies.md) |

Use the [ADR index](../../docs/adr/README.md) only when historical rationale or a contract change requires it. Do not read unrelated ADRs by default.

## Runtime and Package Boundaries

- `src/app.ts` owns the shared Hono API. Put behavior shared by Node and Workers in the application or its services, not in both entry points.
- `src/node.ts` owns Node startup, static serving, Node storage adapters, and graceful shutdown. Keep it on HTTP/1.1; deployment edge proxies terminate HTTP/2 or HTTP/3.
- `src/worker.ts` owns Worker bindings and workerd initialization. Do not import Node-only modules into the Worker graph.
- The package root export must remain Worker-safe. Export Node-only APIs through `@dahlia-ai/server/node`. Treat package exports and extension hooks as versioned public contracts.
- Keep database, authentication, AI provider, and artifact storage selection independent. Add deployment-specific behavior behind the existing adapter boundary.
- Keep authenticated application routes under `/api/**` and the Codex-compatible contract under `/api/v1/**`.

## Canonical Data and Client Synchronization

- Server-account Vaults, Projects, meeting metadata, summaries, original transcripts, screenshots, OCR, and captions are canonical Server data. Store them durably through the supported application database and object-storage paths. Recording audio, translated transcripts, SQLite files, and device-local export paths are not part of meeting sync.
- Desktop and Private Web mutations use `POST /api/v1/transactions`: one Vault per atomic transaction, UUIDv7 idempotency keys, stored receipts, and rejection of a reused ID with different content. Preserve revision checks and `409` conflicts with the canonical record; never silently replace them with last-write-wins.
- Authorize every read, staged upload, and committed mutation against current Vault permissions. Desktop is a remote client, not a trusted database writer. Validate IDs, relationships, payload limits, and content hashes at the Server boundary; staging alone must not publish data.
- Preserve the durable cursor delta feed and its high-water pagination boundary. SSE sends invalidations and cursors only; clients recover from missed events through canonical reads. A commit receipt cursor must not advance a client's separate delta pull checkpoint.
- Desktop records local edits and retryable operations atomically, applies receipts without losing newer local edits, and applies remote records without enqueueing echoes. Keep authorization, validation, revision conflicts, and retryable transport failures distinct. Validate both client and Server paths when changing this wire contract.
- Signing in does not implicitly migrate a Local Account Vault. Removing a local working copy or signing out does not delete Server records. Keep deletion of canonical data explicit and authorized.
- Current sharing grants read-only member access to personally owned Vaults; Server MCP is read-only. SaaS deployment does not imply collaborative write access or weaker owner checks.

## Security and Data Contracts

- Never put user content, tool input/output, bearer tokens, provider/storage credentials, or local paths in diagnostic logs. Logs may include bounded event names, status codes, and upstream request IDs.
- Relay Gateway Responses request and response bodies without persisting their content. This relay restriction does not prohibit authorized canonical content or artifact storage. Better Auth may persist the session, token, and signing material its authentication contract requires; protect it as credential data.
- Read provider and infrastructure credentials from runtime secrets. Keep them separate from application content and Model Alias configuration.
- Enforce request byte limits before parsing or buffering. Stream Responses and artifact bodies without buffering the complete payload.
- Header authentication is safe only behind a proxy that strips client-supplied identity headers, writes verified values, and prevents direct Server access. Do not weaken that deployment requirement with trust-by-header fallback logic.
- With the Databricks backend, use `X-Forwarded-Access-Token` only for the current Responses request. Do not store, log, cache, return, or forward that header by name. Model discovery uses the App service principal and must not use the forwarded token.
- Personal workspaces are deterministic identity claims. Organization and Team sharing must preserve personal Vault ownership and read-only member access; do not add per-organization providers or shared write access without an approved product and architecture decision.
- Artifact IDs remain server-generated UUIDv7 values, owner-scoped, and default-private. Preserve authorization-before-storage access, streamed reads, the CSP sandbox, and non-disclosure of storage URLs and credentials.

## Database and Migrations

- Better Auth and Dahlia application tables share one Drizzle application database. All authentication modes use the generated `auth` tables, `core` for application and sharing state, and `content` for synchronized meeting data. Header mode projects validated users into `auth.user` without starting the Better Auth runtime. References flow only from `content` to `core` to `auth`. Node supports SQLite, PostgreSQL, and Lakebase; Workers support D1, Hyperdrive, and direct PostgreSQL.
- Released migrations are immutable. Add forward-only migrations; never edit, reorder, or silently omit an existing migration.
- Treat the Drizzle schemas as the source of truth and use Drizzle Kit to generate migrations. Hand-write SQL only for data migrations or DDL that Drizzle cannot express, using a new custom migration while keeping the declarative schema synchronized.
- `pnpm db:generate-auth` uses the pinned official Better Auth CLI to regenerate only `src/db/generated/postgres-auth-schema.ts` and `src/db/generated/sqlite-auth-schema.ts`. Keep those outputs unmodified and keep Dahlia-owned tables in the adjacent dialect-specific app schema files.
- Better Auth tables live in the PostgreSQL `auth` schema and are outside the application RLS policy. SQLite and D1 have no schema namespaces, so their Better Auth tables remain top-level. Do not add RLS or hand-written DDL to generated Better Auth declarations.
- PostgreSQL tables containing Dahlia-owned user content require declaratively defined RLS policies in addition to application authorization. RLS receives only transaction-local `app.user_id`, resolves organization and Team membership from `auth.member` and `auth.team_member`, and must account for table-owner and privileged-role RLS bypass.
- SQLite and D1 do not provide PostgreSQL RLS. Keep equivalent owner checks in the shared application/store layer; never remove them because PostgreSQL has RLS.
- `core.artifact` is exempt from RLS while it contains only authorization/storage metadata and is reachable only through owner-scoped Server operations. Revisit the exemption before storing user content or exposing another database access path.
- Drizzle Kit owns `drizzle/postgres-auth`, `drizzle/postgres`, and `drizzle/sqlite`. Run `pnpm db:generate` after declarative schema changes, preserve generated snapshots after release, and register each generated `migration.sql` package-relative path in `src/migrations.ts`; add a directory only for an independent migration ledger root.
- Migration execution is explicit. Do not run production migrations or destructive cleanup as an incidental validation step.

## Configuration and Public Surface

- Parse and validate environment variables in `src/config.ts`. Mirror Worker-visible variables in `RuntimeSecrets`, document operator-facing values in `.env.example` and `README.md`, and update deployment templates only when their runtime needs the value.
- Add focused configuration tests for defaults, valid runtime combinations, and rejected unsafe combinations. Do not preserve removed environment aliases unless an approved compatibility contract requires them.
- When changing package exports, migrations, or bundled assets, update `package.json` and `scripts/verify-package.mjs` so the packed artifact—not only the source tree—is verified.
- Public API, configuration, schema, auth, or UI behavior changes require matching tests and documentation.
- Dependency additions or upgrades require user authorization for the specific change. This package owns its `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, and pinned pnpm version; run pnpm commands from `apps/server`.

## Validation

Use Node 22.13 or newer and the package-pinned pnpm. From `apps/server`:

```bash
pnpm exec vitest run tests/<relevant>.test.ts  # Narrow regression check
pnpm test                                      # Server test suite
pnpm typecheck                                 # TypeScript contracts
pnpm check                                     # Full lint, types, tests, builds, package, Worker dry-run
```

- Run the narrowest relevant test while iterating. Confirm from Vitest output that the intended tests ran.
- For source changes, run focused tests and relevant lint/type checks. Run `pnpm check` for shared runtime, authentication/authorization, sync, migration, dependency, package-export, or release changes. Reuse successful results for unchanged inputs. Documentation-only changes need `git diff --check` plus verification that referenced paths and commands exist.
- Exercise every affected runtime boundary. Shared application changes need Node and Worker coverage; Node-only or Worker-only changes need focused coverage for that runtime.
- Deployment build, dry-run, or process startup does not prove availability. When live deployment is requested, separately verify the routed root page, affected API, authentication, and visible result; for Databricks model changes, require actual model rows and correlate failures with sanitized logs and request IDs.
- Review the final diff for accidental secret disclosure, content logging, API drift, migration edits, Node imports in Worker-safe exports, and unrelated changes.

## Definition of Done

The requested behavior is implemented at the shared owning layer, relevant regression tests pass, the required validation above is complete, public contracts and operator documentation agree with the implementation, and any skipped runtime or live check is reported with the exact next verification step.
