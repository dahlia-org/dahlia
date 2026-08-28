import { readFileSync } from "node:fs";

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
      observability: { enabled: boolean; logs: { enabled: boolean; invocation_logs: boolean } };
      vars: Record<string, string>;
    };

    expect(wrangler.assets).toEqual({
      not_found_handling: "single-page-application",
      run_worker_first: ["/api/*", "/.well-known/*", "/healthz"],
    });
    expect(wrangler.d1_databases).toContainEqual(expect.objectContaining({
      binding: "dahlia_db_prod",
      database_id: "00000000-0000-0000-0000-000000000000",
      migrations_dir: "auth-migrations",
    }));
    expect(wrangler.vars).toEqual({
      DAHLIA_AUTH_PROVIDER: "accounts",
      DAHLIA_BASE_URL: "https://{name}.{subdomain}.workers.dev",
      DAHLIA_DATABASE_TYPE: "d1",
      GOOGLE_CLIENT_ID: "replace-with-google-client-id",
    });
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
    expect(worker).not.toContain("isApplicationPath");
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
      DAHLIA_AUTH_PROVIDER: "header",
      DAHLIA_DATABASE_TYPE: databaseType,
    })).rejects.toThrow(message);
  });

  it("uses the Vite origin for local OAuth and proxies its protocol endpoints", () => {
    const example = readText("../../../.env.example");
    const packageJson = JSON.parse(readText("../package.json")) as {
      scripts: Record<string, string>;
    };

    expect(example).toContain("DAHLIA_BASE_URL=http://localhost:5173");
    expect(example).toContain("DAHLIA_DATABASE_TYPE=sqlite");
    expect(example).toContain("DAHLIA_DATABASE_URL=file:.data/dahlia-auth.sqlite");
    expect(packageJson.scripts.predev).toBe("pnpm run db:migrate");
    expect(packageJson.scripts["dev:api"]).toContain("--env-file-if-exists=../../.env.local");
    expect(packageJson.scripts["db:migrate"]).toContain("--env-file-if-exists=../../.env.local");
    expect(viteConfig.envDir).toBe("../..");
    expect(viteConfig.server?.proxy).toHaveProperty("/.well-known");
  });

  it("uses the current database variables in Server CI", () => {
    const workflow = readText("../../../.github/workflows/server.yml");
    expect(workflow).toContain("DAHLIA_DATABASE_TYPE: postgres");
    expect(workflow).toContain("DAHLIA_DATABASE_URL: postgresql://dahlia@127.0.0.1:5432/dahlia");
    expect(workflow).toContain("DAHLIA_DATABASE_URL: file:/tmp/dahlia-auth.sqlite");
    expect(workflow).not.toMatch(/DAHLIA_RUNTIME|DAHLIA_AUTH_DATABASE|DAHLIA_AUTH_SQLITE_PATH|\n\s+DATABASE_URL:/);
  });

  it("deploys the pnpm workspace as a Databricks App backed by Lakebase", () => {
    const bundle = readText("../../../deploy/databricks/databricks.yml");
    const appResource = readText("../../../deploy/databricks/resources/dahlia_server.app.yml");
    const databaseResource = readText("../../../deploy/databricks/resources/dahlia_server.postgres.yml");
    const rootPackage = JSON.parse(readText("../../../package.json")) as {
      packageManager: string;
      scripts: Record<string, string>;
    };
    const serverPackage = JSON.parse(readText("../package.json")) as {
      exports: Record<string, unknown>;
      name: string;
      scripts: Record<string, string>;
    };
    const workspace = readText("../../../pnpm-workspace.yaml");

    expect(rootPackage.packageManager).toMatch(/^pnpm@/);
    expect(rootPackage.scripts.dev).toContain("@dahlia-ai/server");
    expect(rootPackage.scripts["dev:cloudflare"]).toContain("@dahlia-ai/server");
    expect(workspace).toContain("apps/*");
    expect(bundle).toContain('databricks_cli_version: ">= 1.4.0"');
    expect(bundle).toContain("- ../../Vendor/**");
    expect(bundle).toContain(`      postgres_databases:
        dahlia_database:
          lifecycle:
            prevent_destroy: true`);
    expect(appResource).toContain("source_code_path: ../..");
    expect(appResource)
      .toContain('command: ["corepack", "pnpm", "--filter", "@dahlia-ai/server", "start:databricks"]');
    expect(appResource).toContain("value: https://${resources.apps.dahlia_server.url}");
    expect(appResource).toContain("value_from: postgres");
    expect(appResource).toContain("value_from: openai_api_key");
    expect(appResource).toContain("permission: CAN_CONNECT_AND_CREATE");
    expect(databaseResource).toContain("postgres_projects:");
    expect(databaseResource).toContain("postgres_roles:");
    expect(databaseResource).toContain("postgres_databases:");
    expect(serverPackage.name).toBe("@dahlia-ai/server");
    expect(serverPackage.exports).toHaveProperty(".");
    expect(serverPackage.exports).toHaveProperty("./client");
    expect(serverPackage.exports).toHaveProperty("./package.json");
    expect(serverPackage.scripts["start:databricks"]).toBe("pnpm run db:migrate:prod && pnpm run start");
    expect(serverPackage.scripts["dev:cloudflare"]).toContain("vite.cloudflare.config.ts");
    expect(serverPackage.scripts["preview:cloudflare"]).toContain("vite.cloudflare.config.ts");
    expect(readText("../Dockerfile"))
      .toContain("pnpm run db:migrate:prod && exec node dist/server/node.js");
    expect(readText("../Dockerfile"))
      .toContain('VOLUME ["/app/apps/server/.data"]');
    expect(readText("../src/db/client.ts"))
      .toContain("pg_advisory_lock");
    expect(serverPackage.scripts["ensure:wrangler"]).toContain("../../deploy/cloudflare/wrangler.example.jsonc");
  });

  it("commits only Server application tables after Better Auth", () => {
    const d1 = readText("../auth-migrations/0002_server.sql");
    const postgres = readText("../drizzle/0001_server.sql");
    for (const migration of [d1, postgres]) {
      expect(migration).toContain('CREATE TABLE "model');
      expect(migration).toContain('CREATE TABLE "platform');
      expect(migration).not.toContain("subscription");
      expect(migration).not.toContain("stripe");
      expect(migration).not.toContain("organization");
    }
  });
});
