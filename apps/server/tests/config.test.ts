import { describe, expect, it } from "vitest";

import { loadConfig } from "../src/config";

const accounts = {
  BETTER_AUTH_SECRET: "test-only-better-auth-secret-value",
  GOOGLE_CLIENT_ID: "google-client",
  GOOGLE_CLIENT_SECRET: "google-secret",
};

describe("configuration", () => {
  it("defaults to the existing local SQLite database", () => {
    expect(loadConfig(accounts)).toMatchObject({
      authProvider: "accounts",
      authHeader: "X-Forwarded-Email",
      databaseType: "sqlite",
      databaseUrl: "file:.data/dahlia-auth.sqlite",
      baseUrl: "http://localhost:5173",
    });
  });

  it("selects PostgreSQL independently from the AI Gateway", () => {
    const config = loadConfig({
      ...accounts,
      DAHLIA_DATABASE_TYPE: "postgres",
      DAHLIA_DATABASE_URL: "postgresql://dahlia.example/dahlia",
      OPENAI_API_KEY: "gateway-secret",
      OPENAI_BASE_URL: "https://provider.example/v1/",
    });
    expect(config).toMatchObject({
      databaseType: "postgres",
      databaseUrl: "postgresql://dahlia.example/dahlia",
      provider: { apiKey: "gateway-secret", baseUrl: "https://provider.example/v1" },
    });
  });

  it("loads Lakebase connection fields for the official connector", () => {
    expect(loadConfig({
      DAHLIA_AUTH_PROVIDER: "header",
      DAHLIA_DATABASE_TYPE: "lakebase",
      LAKEBASE_ENDPOINT: "projects/project/branches/main/endpoints/app",
      PGDATABASE: "databricks_postgres",
      PGHOST: "ep-example.database.databricks.com",
      PGPORT: "5432",
      PGSSLMODE: "require",
      PGUSER: "app-client-id",
    })).toMatchObject({
      databaseType: "lakebase",
      databaseUrl: undefined,
      lakebaseDatabase: {
        database: "databricks_postgres",
        endpoint: "projects/project/branches/main/endpoints/app",
        host: "ep-example.database.databricks.com",
        port: 5432,
        sslMode: "require",
        username: "app-client-id",
      },
    });
  });

  it.each(["d1", "hyperdrive"] as const)("selects %s without a URL", (databaseType) => {
    expect(loadConfig({ DAHLIA_AUTH_PROVIDER: "header", DAHLIA_DATABASE_TYPE: databaseType }))
      .toMatchObject({ databaseType, databaseUrl: undefined });
  });

  it("rejects invalid database URLs", () => {
    expect(() => loadConfig({ ...accounts, DAHLIA_DATABASE_URL: "./auth.sqlite" })).toThrow("must use file:");
    expect(() => loadConfig({
      ...accounts,
      DAHLIA_DATABASE_TYPE: "postgres",
      DAHLIA_DATABASE_URL: "https://example.com/database",
    })).toThrow("must use postgres:");
    const password = "must-not-leak";
    try {
      loadConfig({
        ...accounts,
        DAHLIA_DATABASE_TYPE: "postgres",
        DAHLIA_DATABASE_URL: `postgresql://user:${password}@[invalid/database`,
      });
      throw new Error("expected invalid URL rejection");
    } catch (error) {
      expect(String(error)).toBe("Error: DAHLIA_DATABASE_URL must use postgres: or postgresql: for PostgreSQL storage");
      expect(JSON.stringify(error)).not.toContain(password);
    }
  });

  it("ignores removed bundled-runtime variables", () => {
    expect(loadConfig({
      ...accounts,
      DAHLIA_RUNTIME: "cloudflare",
      DAHLIA_AUTH_DATABASE: "postgres",
      DATABASE_URL: "postgresql://legacy.example/dahlia",
    })).toMatchObject({ databaseType: "sqlite", databaseUrl: "file:.data/dahlia-auth.sqlite" });
  });

  it("keeps header identity configuration independent from storage", () => {
    expect(loadConfig({
      DAHLIA_AUTH_PROVIDER: "header",
      DAHLIA_AUTH_HEADER: "Cf-Access-Authenticated-User-Email",
      DAHLIA_BASE_URL: "https://dahlia.example",
    })).toMatchObject({
      authProvider: "header",
      authHeader: "Cf-Access-Authenticated-User-Email",
      databaseType: "sqlite",
    });
  });

  it("validates account secrets and provider URLs", () => {
    expect(() => loadConfig({
      ...accounts,
      BETTER_AUTH_SECRET: "replace-with-at-least-32-random-characters",
    })).toThrow("unique random value");
    expect(() => loadConfig({
      DAHLIA_AUTH_PROVIDER: "header",
      OPENAI_API_KEY: "secret",
      OPENAI_BASE_URL: "http://provider.example/v1",
    })).toThrow("must use HTTPS");
  });

  it("normalizes an optional bootstrap administrator", () => {
    expect(loadConfig({ ...accounts, DAHLIA_ADMIN_EMAIL: " Admin@Example.COM " }).adminEmail)
      .toBe("admin@example.com");
    expect(loadConfig(accounts).adminEmail).toBeUndefined();
  });
});
