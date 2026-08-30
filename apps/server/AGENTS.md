# Dahlia Server Guide

## Scope

This file applies to `apps/server`. The repository-root `AGENTS.md` still applies; this file adds only Server-specific guidance.

Dahlia Server is an optional, self-hostable AI control plane and artifact transport. It must never become a prerequisite for macOS recording, transcription, browsing, or search. Preserve the public API, package exports, runtime portability, user data, and privacy boundaries unless the request explicitly changes them.

## Read Before Editing

Use progressive disclosure. Read the closest implementation first, then only the references needed for the change.

| Change | Required reference |
| --- | --- |
| Local setup, API behavior, configuration, or deployment overview | [`README.md`](README.md) |
| Product scope or whether a cloud feature belongs in Dahlia | [`PRODUCT.md`](../../PRODUCT.md), especially T4 and T5 |
| Gateway, authentication, upstream relay, or privacy boundary | [ADR-0029](../../docs/adr/0029-offer-an-optional-codex-ai-gateway.md) |
| Public package exports or extension hooks | [ADR-0031](../../docs/adr/0031-publish-dahlia-server-extension-contract.md) |
| Application database, identity, or migrations | [ADR-0043](../../docs/adr/0043-unify-dahlia-server-application-database.md) |
| Databricks Apps, Lakebase, or forwarded user tokens | [ADR-0044](../../docs/adr/0044-deploy-dahlia-server-to-databricks-apps.md), [ADR-0046](../../docs/adr/0046-forward-databricks-user-token-to-ai-gateway.md), and [`deploy/databricks/README.md`](../../deploy/databricks/README.md) |
| Artifact authorization, storage, IDs, or public URLs | [ADR-0045](../../docs/adr/0045-add-owner-scoped-artifact-transport.md), [ADR-0048](../../docs/adr/0048-issue-artifact-ids-server-side.md) |
| Dependencies, lockfiles, packaging, or deployment source layout | [ADR-0047](../../docs/adr/0047-manage-pnpm-dependencies-per-application.md) |

Use the [ADR index](../../docs/adr/README.md) only when historical rationale or a contract change requires it. Do not read unrelated ADRs by default.

## Runtime and Package Boundaries

- `src/app.ts` owns the shared Hono API. Put behavior shared by Node and Workers in the application or its services, not in both entry points.
- `src/node.ts` owns Node startup, static serving, Node storage adapters, and graceful shutdown. Keep it on HTTP/1.1; deployment edge proxies terminate HTTP/2 or HTTP/3.
- `src/worker.ts` owns Worker bindings and workerd initialization. Do not import Node-only modules into the Worker graph.
- The package root export must remain Worker-safe. Export Node-only APIs through `@dahlia-ai/server/node`. Treat package exports and extension hooks as versioned public contracts.
- Keep database, authentication, AI provider, and artifact storage selection independent. Add deployment-specific behavior behind the existing adapter boundary.
- Keep authenticated application routes under `/api/**` and the Codex-compatible contract under `/api/v1/**`.

## Security and Data Contracts

- Never log or persist Responses request or response bodies, transcripts, images, tool input or output, bearer tokens, forwarded access tokens, provider secrets, storage credentials, or local paths. Diagnostic logs may include bounded event names, status codes, and upstream request IDs.
- Read credentials from runtime secrets only. Model Aliases are public configuration; provider credentials are not application data.
- Enforce request byte limits before parsing or buffering. Stream Responses and artifact bodies without buffering the complete payload.
- Header authentication is safe only behind a proxy that strips client-supplied identity headers, writes verified values, and prevents direct Server access. Do not weaken that deployment requirement with trust-by-header fallback logic.
- With the Databricks backend, use `X-Forwarded-Access-Token` only for the current upstream request. Do not store, log, cache, return, or forward that header by name; do not replace it with App client-credential authentication.
- Personal workspaces are deterministic identity claims. Do not add organizations, invitations, team sharing, per-organization providers, automatic recording uploads, or meeting cloud sync without an approved product and architecture decision.
- Artifact IDs remain server-generated UUIDv7 values, owner-scoped, and default-private. Preserve authorization-before-storage access, streamed reads, the CSP sandbox, and non-disclosure of storage URLs and credentials.

## Database and Migrations

- Better Auth and Dahlia application tables share one Drizzle application database. Node supports SQLite, PostgreSQL, and Lakebase; Workers support D1, Hyperdrive, and direct PostgreSQL.
- Released migrations are immutable. Add forward-only migrations; never edit, reorder, or silently omit an existing migration.
- Treat the Drizzle schemas as the source of truth and use Drizzle Kit to generate migrations. Hand-write SQL only for data migrations or DDL that Drizzle cannot express, using a new custom migration while keeping the declarative schema synchronized.
- `pnpm db:generate-auth` uses the pinned official Better Auth CLI to regenerate only `src/db/generated/postgres-auth-schema.ts` and `src/db/generated/sqlite-auth-schema.ts`. Keep those outputs unmodified and keep Dahlia-owned tables in the adjacent dialect-specific app schema files.
- Better Auth tables live in the PostgreSQL `auth` schema and are outside the application RLS policy. SQLite and D1 have no schema namespaces, so their Better Auth tables remain top-level. Do not add RLS or hand-written DDL to generated Better Auth declarations.
- PostgreSQL tables containing Dahlia-owned user content require declaratively defined RLS policies in addition to application authorization. The policy design must identify the request identity source and account for table-owner and privileged-role RLS bypass.
- SQLite and D1 do not provide PostgreSQL RLS. Keep equivalent owner checks in the shared application/store layer; never remove them because PostgreSQL has RLS.
- `dahlia.artifact` is exempt from RLS while it contains only authorization/storage metadata and is reachable only through owner-scoped Server operations. Revisit the exemption before storing user content or exposing another database access path.
- Drizzle Kit owns both `drizzle/postgres` and `drizzle/sqlite`. Run `pnpm db:generate` after declarative schema changes, preserve generated snapshots after release, and register each generated `migration.sql` package-relative path in `src/migrations.ts`; add a directory only for an independent migration ledger root.
- Migration execution is explicit. Do not run production migrations or destructive cleanup as an incidental validation step.

## Configuration and Public Surface

- Parse and validate environment variables in `src/config.ts`. Mirror Worker-visible variables in `RuntimeSecrets`, document operator-facing values in `.env.example` and `README.md`, and update deployment templates only when their runtime needs the value.
- Add focused configuration tests for defaults, valid runtime combinations, and rejected unsafe combinations. Do not preserve removed environment aliases unless an approved compatibility contract requires them.
- When changing package exports, migrations, or bundled assets, update `package.json` and `scripts/verify-package.mjs` so the packed artifact—not only the source tree—is verified.
- Public API, configuration, schema, auth, or UI behavior changes require matching tests and documentation.
- Dependency additions or upgrades require user confirmation. This package owns its `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, and pinned pnpm version; run pnpm commands from `apps/server`.

## Validation

Use Node 22.13 or newer and the package-pinned pnpm. From `apps/server`:

```bash
pnpm exec vitest run tests/<relevant>.test.ts  # Narrow regression check
pnpm test                                      # Server test suite
pnpm typecheck                                 # TypeScript contracts
pnpm check                                     # Full lint, types, tests, builds, package, Worker dry-run
```

- Run the narrowest relevant test while iterating. Confirm from Vitest output that the intended tests ran.
- Run `pnpm check` for source, dependency, migration, package-export, or runtime changes. Documentation-only changes need `git diff --check` plus manual verification that referenced paths and commands still exist.
- Exercise every affected runtime boundary. Shared application changes need Node and Worker coverage; Node-only or Worker-only changes need focused coverage for that runtime.
- Deployment build, dry-run, or process startup does not prove availability. When live deployment is requested, separately verify the routed root page, affected API, authentication, and visible result; for Databricks model changes, require actual model rows and correlate failures with sanitized logs and request IDs.
- Review the final diff for accidental secret disclosure, content logging, API drift, migration edits, Node imports in Worker-safe exports, and unrelated changes.

## Definition of Done

The requested behavior is implemented at the shared owning layer, relevant regression tests pass, the required validation above is complete, public contracts and operator documentation agree with the implementation, and any skipped runtime or live check is reported with the exact next verification step.
