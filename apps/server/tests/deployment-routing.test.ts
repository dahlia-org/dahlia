import { existsSync, readFileSync, readdirSync } from "node:fs";

import { describe, expect, it, vi } from "vitest";

import { createApp } from "../src/app";
import type { AppConfig } from "../src/config";
import { createWorkerHandler, initializeWorkerApp } from "../src/worker";
import viteConfig from "../vite.config";
import { testStore } from "./test-store";

const headerConfig: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "sqlite",
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};

function readText(path: string): string {
  return readFileSync(new URL(path, import.meta.url), "utf8");
}

function exists(path: string): boolean {
  return existsSync(new URL(path, import.meta.url));
}

describe("deployment routing", () => {
  it("routes OAuth discovery through the Worker instead of the SPA", () => {
    const wrangler = JSON.parse(readText("../../../deploy/cloudflare/wrangler.example.jsonc")) as {
      assets: {
        binding?: string;
        directory?: string;
        not_found_handling: string;
        run_worker_first: string[];
      };
      d1_databases: Array<{ binding: string; migrations_dir: string }>;
      r2_buckets: Array<{ binding: string; bucket_name: string }>;
      observability: { enabled: boolean; logs: { enabled: boolean; invocation_logs: boolean } };
      vars: Record<string, string>;
    };

    expect(wrangler.assets).toEqual({
      not_found_handling: "single-page-application",
      run_worker_first: ["/api/*", "/.well-known/*", "/mcp", "/healthz"],
    });
    expect(wrangler.d1_databases).toContainEqual(expect.objectContaining({
      binding: "dahlia_db_prod",
      database_id: "00000000-0000-0000-0000-000000000000",
      migrations_dir: "drizzle/d1",
    }));
    const d1Migrations = readdirSync(new URL("../drizzle/d1", import.meta.url)).toSorted();
    expect(d1Migrations).toEqual(["20260903173555_lying_slipstream.sql", "20260905172528_unique_marvel_zombies.sql", "20260905172654_sync_history_backfill.sql"]);
    for (const migration of d1Migrations) {
      expect(readText(`../drizzle/d1/${migration}`))
        .toBe(readText(`../drizzle/sqlite/${migration.replace(/\.sql$/, "")}/migration.sql`));
    }
    expect(wrangler.vars).toEqual({
      DAHLIA_AI_BACKEND: "cloudflare",
      DAHLIA_STORAGE_BACKEND: "r2",
      DAHLIA_ARTIFACT_MAX_BYTES: "67108864",
      DAHLIA_AUTH_TYPE: "accounts",
      DAHLIA_APP_URL: "https://{name}.{subdomain}.workers.dev",
      DAHLIA_DATABASE_TYPE: "d1",
      GOOGLE_CLIENT_ID: "replace-with-google-client-id",
    });
    expect(wrangler.r2_buckets).toEqual([{
      binding: "DAHLIA_STORAGE",
      bucket_name: "replace-with-r2-bucket-name",
    }]);
    expect(wrangler).not.toHaveProperty("hyperdrive");
    expect(wrangler.observability).toEqual({
      enabled: false,
      logs: { enabled: false, invocation_logs: false },
    });
    expect(readText("../.gitignore")).toContain("wrangler.jsonc");
  });

  it("provides a Hyperdrive configuration with the stable binding name", () => {
    const wrangler = JSON.parse(readText("../../../deploy/cloudflare/wrangler.hyperdrive.example.jsonc")) as {
      hyperdrive: Array<{ binding: string; id: string }>;
      vars: Record<string, string>;
    };
    expect(wrangler.hyperdrive).toEqual([{
      binding: "HYPERDRIVE",
      id: "00000000000000000000000000000000",
    }]);
    expect(wrangler.vars.DAHLIA_DATABASE_TYPE).toBe("hyperdrive");
  });

  it("keeps static assets outside the API-only Worker", () => {
    const worker = readText("../src/worker.ts");
    const cloudflareVite = readText("../vite.cloudflare.config.ts");

    expect(worker).not.toContain("ASSETS");
    expect(worker).toContain("CODEX_AUTO_REVIEW_MODEL");
    expect(worker).not.toContain("isApplicationPath");
    expect(worker).toContain("DAHLIA_AI_BACKEND");
    expect(worker).toContain("DATABRICKS_HOST");
    expect(worker).toContain("DATABRICKS_MODEL_SCHEMA: env.DATABRICKS_MODEL_SCHEMA");
    expect(worker).toContain("OPENAI_API_KEY");
    expect(worker).toContain("OPENAI_BASE_URL");
    expect(cloudflareVite).toContain("cloudflare(");
    expect(cloudflareVite).toContain('outDir: "dist/cloudflare"');
  });

  it("returns Hono 404 responses for undefined Worker routes", async () => {
    const app = createApp({ config: headerConfig, authStore: testStore() });
    const api = await app.request("/api/not-defined");
    const discovery = await app.request("/.well-known/not-defined");

    expect(api.status).toBe(404);
    expect(await api.json()).toEqual({ error: "not_found" });
    expect(discovery.status).toBe(404);
    expect(await discovery.json()).toEqual({ error: "not_found" });
  });

  it("initializes the Cloudflare application once per isolate and keeps health independent", async () => {
    const initialize = vi.fn(async () => createApp({ config: headerConfig, authStore: testStore() }));
    const handler = createWorkerHandler(initialize);
    const env = {} as Cloudflare.Env;
    const fetch = handler.fetch!.bind(handler) as unknown as (
      request: Request,
      env: Cloudflare.Env,
      context: ExecutionContext,
    ) => Promise<Response>;

    const health = await fetch(new Request("https://dahlia.example/healthz"), env, {} as ExecutionContext);
    expect(health.status).toBe(200);
    expect(initialize).not.toHaveBeenCalled();

    await fetch(new Request("https://dahlia.example/api/not-defined"), env, {} as ExecutionContext);
    await fetch(new Request("https://dahlia.example/api/not-defined"), env, {} as ExecutionContext);
    expect(initialize).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["d1", "dahlia_db_prod D1 binding"],
    ["hyperdrive", "HYPERDRIVE binding"],
  ])("requires the selected %s Worker binding", async (databaseType, message) => {
    await expect(initializeWorkerApp({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_DATABASE_TYPE: databaseType,
    })).rejects.toThrow(message);
  });

  it("rejects local storage in the Worker runtime", async () => {
    await expect(initializeWorkerApp({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_DATABASE_TYPE: "d1",
      dahlia_db_prod: {} as never,
    })).rejects.toThrow("Storage backend local requires the Node runtime");
  });

  it("uses the Vite origin for local OAuth and proxies its protocol endpoints", () => {
    const example = readText("../.env.example");
    const packageJson = JSON.parse(readText("../package.json")) as {
      scripts: Record<string, string>;
    };

    expect(example).toContain("DAHLIA_APP_URL=http://localhost:5173");
    expect(example).toContain("DAHLIA_DATABASE_TYPE=sqlite");
    expect(example).toContain("DAHLIA_DATABASE_URL=file:.data/dahlia-auth.sqlite");
    expect(packageJson.scripts.predev).toBe("pnpm run db:migrate");
    expect(packageJson.scripts["dev:api"]).toContain("--env-file-if-exists=.env.local");
    expect(packageJson.scripts["db:migrate"]).toContain("--env-file-if-exists=.env.local");
    expect(viteConfig.envDir).toBeUndefined();
    expect(viteConfig.server?.proxy).toHaveProperty("/.well-known");
    expect(viteConfig.server?.proxy).toHaveProperty("/mcp");
  });

  it("uses the current database variables in Server CI", () => {
    const workflow = readText("../../../.github/workflows/server-ci.yml");
    expect(workflow).toContain("DAHLIA_DATABASE_TYPE: postgres");
    expect(workflow).toContain("DAHLIA_DATABASE_URL: postgresql://dahlia@127.0.0.1:5432/dahlia");
    expect(workflow).toContain("DAHLIA_DATABASE_URL: file:/tmp/dahlia-auth.sqlite");
    expect(workflow).toContain("working-directory: apps/server");
    expect(workflow).toContain("cache-dependency-path: apps/server/pnpm-lock.yaml");
    expect(workflow).not.toMatch(/DAHLIA_RUNTIME|DAHLIA_AUTH_DATABASE|DAHLIA_AUTH_SQLITE_PATH|\n\s+DATABASE_URL:/);
  });

  it("deploys the standalone Server package as a Databricks App backed by Lakebase", () => {
    const bundle = readText("../../../deploy/databricks/databricks.yml");
    const resource = readText("../../../deploy/databricks/resources/dahlia_server.yml");
    const serverPackage = JSON.parse(readText("../package.json")) as {
      exports: Record<string, unknown>;
      name: string;
      packageManager: string;
      scripts: Record<string, string>;
    };
    const packageConfig = readText("../pnpm-workspace.yaml");

    expect(exists("../../../package.json")).toBe(false);
    expect(exists("../../../pnpm-lock.yaml")).toBe(false);
    expect(exists("../../../pnpm-workspace.yaml")).toBe(false);
    expect(exists("../pnpm-lock.yaml")).toBe(true);
    expect(serverPackage.packageManager).toBe("pnpm@11.9.0");
    expect(packageConfig).not.toContain("packages:");
    expect(packageConfig).toContain("esbuild: true");
    expect(packageConfig).toContain("workerd: true");
    expect(bundle).toContain('databricks_cli_version: ">= 1.4.0"');
    expect(bundle).toContain("- ../../apps/server");
    expect(bundle).not.toContain("../../pnpm-lock.yaml");
    expect(bundle).not.toContain("- ../../pnpm-workspace.yaml");
    expect(bundle).toContain("app_name: dahlia-dev");
    expect(bundle).toContain("app_name: dahlia-prod");
    expect(bundle).toContain("database_project_id: dahlia-db-dev");
    expect(bundle).toContain("default: system.ai.gpt-5-6-luna");
    expect(resource).toContain("name: CODEX_AUTO_REVIEW_MODEL");
    expect(resource).toContain("value: ${var.codex_auto_review_model}");
    expect(bundle).toContain("database_project_id: dahlia-db");
    expect(bundle).toContain("catalog:");
    expect(bundle).toContain("default: dahlia");
    expect(bundle).toMatch(/app_schema:[\s\S]*?default: app/);
    expect(bundle).toMatch(/ai_schema:[\s\S]*?default: ai/);
    expect(resource).toContain("name: ${var.app_schema}");
    expect(resource).not.toContain("${var.schema}");
    expect(bundle).toContain("'${var.catalog}' '${var.ai_schema}' '${var.database_project_id}'");
    expect(bundle).toContain("volume_name:");
    expect(bundle).toContain("default: storage");
    expect(bundle).not.toContain("legacy_artifact_catalog:");
    expect(bundle).not.toContain("legacy_artifact_volume_name:");
    expect(resource).toContain(`dahlia_storage:
      catalog_name: \${var.catalog}
      schema_name: \${resources.schemas.app_schema.name}
      name: \${var.volume_name}`);
    expect(bundle).toContain("scripts/postdeploy.sh");
    expect(resource).toContain("name: DATABRICKS_MODEL_SCHEMA");
    expect(resource).toContain("value: ${var.catalog}.${var.ai_schema}");
    expect(resource).toContain("name: ${var.ai_schema}");
    expect(resource).toMatch(/ai_schema:[\s\S]*?principal: account users\s+privileges:\s+- EXECUTE/);
    expect(bundle).toContain("sync_sharing_enabled:");
    expect(bundle).toMatch(/sync_sharing_enabled:[\s\S]*?default: "false"/);
    expect(bundle).toMatch(/dev:[\s\S]*?sync_sharing_enabled: "true"[\s\S]*?prod:/);
    expect(bundle).toMatch(/prod:[\s\S]*?volumes:[\s\S]*?prevent_destroy: true/);
    expect(bundle).toMatch(/dev:[\s\S]*?purge_on_delete: true[\s\S]*?prod:/);
    expect(bundle).not.toContain("admin_email");
    expect(bundle).not.toContain("postgres_databases:");
    expect(resource).toContain("source_code_path: ../../../apps/server");
    expect(resource).toContain(`user_api_scopes:
        - ai-gateway
        - files`);
    expect(resource).not.toContain("catalog.catalogs:read");
    expect(resource).not.toContain("catalog.schemas:read");
    expect(resource)
      .toContain('command: ["corepack", "pnpm", "start:databricks"]');
    expect(resource).not.toContain("DAHLIA_APP_URL");
    expect(resource).not.toContain("resources.apps.dahlia_server.url");
    expect(resource).toContain("value: databricks");
    expect(resource).toContain("value_from: postgres");
    expect(resource).not.toContain("openai_api_key");
    expect(resource).toContain("permission: CAN_CONNECT_AND_CREATE");
    expect(resource).toContain("volume_type: MANAGED");
    expect(resource).toContain("permission: WRITE_VOLUME");
    expect(resource).toContain("name: DAHLIA_STORAGE_BACKEND");
    expect(resource).toContain("value: databricks");
    expect(resource).toContain("name: DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH");
    expect(resource).toContain("name: DAHLIA_SYNC_SHARING_ENABLED");
    expect(resource).toContain("value: ${var.sync_sharing_enabled}");
    expect(resource).toContain("/Volumes/${resources.volumes.dahlia_storage.catalog_name}/${resources.volumes.dahlia_storage.schema_name}/${resources.volumes.dahlia_storage.name}");
    expect(resource).toContain("securable_full_name: ${resources.volumes.dahlia_storage.catalog_name}.${resources.volumes.dahlia_storage.schema_name}.${resources.volumes.dahlia_storage.name}");
    expect(resource).toContain("postgres_projects:");
    expect(resource).not.toContain("postgres_roles:");
    expect(resource).not.toContain("postgres_databases:");
    expect(resource).toContain("/databases/databricks-postgres");
    expect(serverPackage.name).toBe("@dahlia-ai/server");
    expect(serverPackage.exports).toHaveProperty(".");
    expect(serverPackage.exports).toHaveProperty("./client");
    expect(serverPackage.exports).toHaveProperty("./migrations/postgres-auth/*");
    expect(serverPackage.exports).toHaveProperty("./package.json");
    expect(serverPackage.scripts["start:databricks"]).toBe("pnpm run db:migrate:prod && pnpm run start");
    expect(serverPackage.scripts["dev:cloudflare"]).toContain("vite.cloudflare.config.ts");
    expect(serverPackage.scripts["preview:cloudflare"]).toContain("vite.cloudflare.config.ts");
    expect(readText("../Dockerfile"))
      .toContain("pnpm run db:migrate:prod && exec node dist/server/node.js");
    expect(readText("../Dockerfile"))
      .toContain('VOLUME ["/app/.data"]');
    expect(readText("../.dockerignore")).toContain(".env*");
    expect(readText("../src/db/client.ts"))
      .toContain("pg_advisory_lock");
    expect(readText("../src/db/client.ts"))
      .toContain("migrationsSchema: POSTGRES_MIGRATION_SCHEMA");
    expect(serverPackage.scripts["ensure:wrangler"]).toContain("../../deploy/cloudflare/wrangler.example.jsonc");
  });

  it("separates generated PostgreSQL auth DDL from the application baseline", () => {
    const sqlite = readText("../drizzle/sqlite/20260903173555_lying_slipstream/migration.sql");
    const auth = readText("../drizzle/postgres-auth/20260903034253_melodic_scalphunter/migration.sql");
    const postgres = readText("../drizzle/postgres/20260903173551_bumpy_freak/migration.sql");
    for (const migration of [sqlite, `${auth}\n${postgres}`]) {
      expect(migration).not.toContain("model_alias");
      expect(migration).not.toContain("platform_admin");
      expect(migration).not.toContain("artifact_reservation");
      expect(migration).toContain("storage_key");
      expect(migration).not.toContain("subscription");
      expect(migration).not.toContain("stripe");
      expect(migration).toContain("organization");
    }
    expect(auth).toContain('CREATE TABLE "auth"."user"');
    expect(auth).toContain('"role" text');
    expect(auth).toContain('"banned" boolean');
    expect(auth).toContain('"impersonated_by" text');
    expect(auth).toContain('CREATE TABLE "auth"."team"');
    expect(auth).toContain('CREATE TABLE "auth"."team_member"');
    expect(auth).toContain('"active_team_id" text');
    expect(auth).toContain('"team_id" text');
    expect(postgres).not.toContain('CREATE TABLE "auth".');
    expect(postgres).toContain('REFERENCES "auth"."user"("id")');
    expect(postgres).toContain('CREATE TABLE "app"."artifact"');
    expect(postgres).toContain('CREATE TABLE "app"."meetings"');
    expect(postgres).not.toContain('CREATE TABLE "app"."user"');
    expect(postgres).toContain("ROW LEVEL SECURITY");
    expect(postgres).toContain("CREATE POLICY");
    expect(postgres).toContain('permission."principal_type" = \'team\'');
    expect(postgres).toContain('FROM "auth"."team_member"');
    expect(postgres).not.toContain("header_deployment");
    expect(sqlite).toContain("team_member_user_team_idx");
    expect(sqlite).not.toContain("header_deployment");
  });
});
