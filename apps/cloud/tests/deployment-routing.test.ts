import { readFileSync } from "node:fs";

import { describe, expect, it, vi } from "vitest";

import { createApp } from "../src/app";
import type { AppConfig } from "../src/config";
import { createWorkerHandler } from "../src/worker";
import viteConfig from "../vite.config";
import { testStore } from "./test-store";

const headerConfig: AppConfig = {
  runtime: "custom",
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  authDatabase: "sqlite",
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  trustedProxyCidrs: [],
  maxRequestBytes: 1024,
};

describe("deployment routing", () => {
  it("routes OAuth discovery through the Worker instead of the SPA", () => {
    const wrangler = JSON.parse(readFileSync(new URL("../wrangler.example.jsonc", import.meta.url), "utf8")) as {
      assets: {
        binding?: string;
        directory?: string;
        not_found_handling: string;
        run_worker_first: string[];
      };
      d1_databases: Array<{ binding: string; migrations_dir: string }>;
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
      DAHLIA_RUNTIME: "cloudflare",
      DAHLIA_BASE_URL: "https://{name}.{subdomain}.workers.dev",
      GOOGLE_CLIENT_ID: "replace-with-google-client-id",
    });
    expect(wrangler).not.toHaveProperty("hyperdrive");
    expect(readFileSync(new URL("../.gitignore", import.meta.url), "utf8")).toContain("wrangler.jsonc");
  });

  it("keeps static assets outside the API-only Worker", () => {
    const worker = readFileSync(new URL("../src/worker.ts", import.meta.url), "utf8");
    const cloudflareVite = readFileSync(new URL("../vite.cloudflare.config.ts", import.meta.url), "utf8");

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

  it("uses the Vite origin for local OAuth and proxies its protocol endpoints", () => {
    const example = readFileSync(new URL("../../../.env.example", import.meta.url), "utf8");
    const packageJson = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as {
      scripts: Record<string, string>;
    };

    expect(example).toContain("DAHLIA_BASE_URL=http://localhost:5173");
    expect(example).toContain("DAHLIA_RUNTIME=custom");
    expect(packageJson.scripts.predev).toBe("pnpm run db:migrate");
    expect(packageJson.scripts["dev:api"]).toContain("--env-file-if-exists=../../.env.local");
    expect(packageJson.scripts["db:migrate"]).toContain("--env-file-if-exists=../../.env.local");
    expect(viteConfig.envDir).toBe("../..");
    expect(viteConfig.server?.proxy).toHaveProperty("/.well-known");
  });

  it("uses pnpm workspaces and starts the built cloud application", () => {
    const appYaml = readFileSync(new URL("../../../app.yaml", import.meta.url), "utf8");
    const rootPackage = JSON.parse(readFileSync(new URL("../../../package.json", import.meta.url), "utf8")) as {
      packageManager: string;
      scripts: Record<string, string>;
    };
    const cloudPackage = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as {
      scripts: Record<string, string>;
    };
    const workspace = readFileSync(new URL("../../../pnpm-workspace.yaml", import.meta.url), "utf8");

    expect(rootPackage.packageManager).toMatch(/^pnpm@/);
    expect(rootPackage.scripts.dev).toContain("@dahlia/cloud");
    expect(rootPackage.scripts["dev:cloudflare"]).toContain("@dahlia/cloud");
    expect(workspace).toContain("apps/*");
    expect(appYaml).toContain('command: ["corepack", "pnpm", "--filter", "@dahlia/cloud", "start:databricks"]');
    expect(appYaml).toContain("name: DAHLIA_RUNTIME");
    expect(appYaml).toContain("value: databricks");
    expect(cloudPackage.scripts["start:databricks"]).toBe("pnpm run db:migrate:prod && pnpm run start");
    expect(appYaml).toContain("name: ENDPOINT_NAME");
    expect(appYaml).toContain("valueFrom: postgres");
    expect(cloudPackage.scripts["dev:cloudflare"]).toContain("vite.cloudflare.config.ts");
    expect(cloudPackage.scripts["preview:cloudflare"]).toContain("vite.cloudflare.config.ts");
    expect(readFileSync(new URL("../Dockerfile", import.meta.url), "utf8"))
      .toContain("pnpm run db:migrate:prod && exec node dist/server/node.js");
    expect(readFileSync(new URL("../Dockerfile", import.meta.url), "utf8"))
      .toContain('VOLUME ["/app/apps/cloud/.data"]');
    expect(readFileSync(new URL("../src/db/client.ts", import.meta.url), "utf8"))
      .toContain("pg_advisory_lock");
  });

  it("commits billing and single-Team membership migrations for D1 and PostgreSQL", () => {
    const d1 = readFileSync(new URL("../auth-migrations/0002_billing_and_team.sql", import.meta.url), "utf8");
    const postgres = readFileSync(new URL("../drizzle/0001_gigantic_ironclad.sql", import.meta.url), "utf8");

    for (const migration of [d1, postgres]) {
      expect(migration).toContain('CREATE TABLE "subscription"');
      expect(migration).toContain('CREATE TABLE "organization"');
      expect(migration).toContain('CREATE TABLE "member"');
      expect(migration).toContain('CREATE TABLE "invitation"');
      expect(migration).toContain('CREATE UNIQUE INDEX "member_userId_uidx"');
    }
  });

  it("commits Model Alias and administrator tables in the final pre-release migration", () => {
    const d1 = readFileSync(new URL("../auth-migrations/0003_gateway_entitlement.sql", import.meta.url), "utf8");
    const postgres = readFileSync(new URL("../drizzle/0003_overconfident_peter_quill.sql", import.meta.url), "utf8");
    for (const migration of [d1, postgres]) {
      expect(migration).toContain('CREATE TABLE "model');
      expect(migration).toContain('CREATE TABLE "platform');
    }
  });
});
