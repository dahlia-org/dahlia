import { describe, expect, it } from "vitest";

import { loadConfig } from "../src/config";

function headerEnv(): Record<string, string> {
  return {
    DAHLIA_AUTH_PROVIDER: "header",
    DAHLIA_BASE_URL: "https://dahlia.example",
    DAHLIA_TRUSTED_PROXY_CIDRS: "10.0.0.0/8",
  };
}

function accountsEnv(): Record<string, string> {
  return {
    BETTER_AUTH_SECRET: "test-only-better-auth-secret-value",
    GOOGLE_CLIENT_ID: "google-client",
    GOOGLE_CLIENT_SECRET: "google-secret",
  };
}

function databricksDatabaseEnv(): Record<string, string> {
  return {
    ENDPOINT_NAME: "projects/project/branches/main/endpoints/app",
    PGDATABASE: "databricks_postgres",
    PGHOST: "ep-example.database.databricks.com",
    PGPORT: "5432",
    PGSSLMODE: "require",
    PGUSER: "app-client-id",
  };
}

describe("configuration", () => {
  it("configures provider credentials without an environment model", () => {
    const config = loadConfig({
      ...headerEnv(),
      OPENAI_API_KEY: "runtime-secret",
      OPENAI_BASE_URL: "https://provider.example/v1/",
    });

    expect(config.provider).toEqual({
      apiKey: "runtime-secret",
      baseUrl: "https://provider.example/v1",
    });
  });

  it("uses the OpenAI API by default when a key is configured", () => {
    expect(loadConfig({ ...accountsEnv(), OPENAI_API_KEY: "runtime-secret" }).provider).toEqual({
      apiKey: "runtime-secret",
      baseUrl: "https://api.openai.com/v1",
    });
  });

  it("rejects cleartext provider URLs outside localhost", () => {
    expect(() => loadConfig({
      ...headerEnv(),
      OPENAI_API_KEY: "secret",
      OPENAI_BASE_URL: "http://provider.example/v1",
    })).toThrow("must use HTTPS");
  });

  it("uses the custom runtime with accounts, SQLite, and the custom Gateway by default", () => {
    expect(loadConfig(accountsEnv())).toMatchObject({
      runtime: "custom",
      authProvider: "accounts",
      authHeader: "X-Forwarded-Email",
      authDatabase: "sqlite",
      authSqlitePath: ".data/dahlia-auth.sqlite",
      baseUrl: "http://localhost:5173",
    });
  });

  it("rejects the published Better Auth placeholder secret", () => {
    expect(() => loadConfig({
      ...accountsEnv(),
      BETTER_AUTH_SECRET: "replace-with-at-least-32-random-characters",
    })).toThrow("unique random value");
  });

  it("normalizes an optional bootstrap administrator and allows none", () => {
    expect(loadConfig({ ...accountsEnv(), DAHLIA_ADMIN_EMAIL: " Admin@Example.COM " }).adminEmail)
      .toBe("admin@example.com");
    expect(loadConfig(accountsEnv()).adminEmail).toBeUndefined();
    expect(() => loadConfig({ ...accountsEnv(), DAHLIA_ADMIN_EMAIL: "not-an-email" })).toThrow();
  });

  it("uses the selected identity header without a database", () => {
    const config = loadConfig({
      DAHLIA_AUTH_PROVIDER: "header",
      DAHLIA_AUTH_HEADER: "Cf-Access-Authenticated-User-Email",
    });

    expect(config).toMatchObject({
      runtime: "custom",
      authProvider: "header",
      authHeader: "Cf-Access-Authenticated-User-Email",
      authDatabase: "sqlite",
      baseUrl: "http://localhost:5173",
      trustedProxyCidrs: ["127.0.0.0/8", "::1/128"],
    });
  });

  it("requires a trusted proxy network for non-local custom header authentication", () => {
    expect(() => loadConfig({
      DAHLIA_AUTH_PROVIDER: "header",
      DAHLIA_BASE_URL: "https://dahlia.example",
    })).toThrow("DAHLIA_TRUSTED_PROXY_CIDRS is required");
  });

  it("lets the custom runtime change accounts storage to PostgreSQL", () => {
    expect(loadConfig({
      ...accountsEnv(),
      DAHLIA_BASE_URL: "https://dahlia.example",
      DAHLIA_AUTH_DATABASE: "postgres",
      DATABASE_URL: "postgresql://dahlia.example/dahlia",
    })).toMatchObject({
      authDatabase: "postgres",
      authDatabaseUrl: "postgresql://dahlia.example/dahlia",
    });
    expect(() => loadConfig({ ...accountsEnv(), DAHLIA_AUTH_DATABASE: "d1" })).toThrow();
  });

  it("pins the Cloudflare runtime to Better Auth and D1", () => {
    const config = loadConfig({
      ...accountsEnv(),
      DAHLIA_RUNTIME: "cloudflare",
    });

    expect(config).toMatchObject({
      runtime: "cloudflare",
      authProvider: "accounts",
      authDatabase: "d1",
    });
    expect(config.provider).toBeUndefined();
  });

  it("allows provider-free startup for managed runtimes", () => {
    expect(loadConfig({
      ...accountsEnv(),
      DAHLIA_RUNTIME: "cloudflare",
    }).provider).toBeUndefined();
    expect(loadConfig({
      DAHLIA_RUNTIME: "databricks",
      ...databricksDatabaseEnv(),
      DATABRICKS_HOST: "https://workspace.cloud.databricks.com",
      DATABRICKS_CLIENT_ID: "app-client-id",
      DATABRICKS_CLIENT_SECRET: "app-client-secret",
    }).provider).toBeUndefined();
  });

  it("pins the Databricks runtime to header auth and PostgreSQL", () => {
    const config = loadConfig({
      DAHLIA_RUNTIME: "databricks",
      ...databricksDatabaseEnv(),
      DAHLIA_BASE_URL: "https://dahlia.example",
      DATABRICKS_HOST: "https://workspace.cloud.databricks.com",
      DATABRICKS_CLIENT_ID: "app-client-id",
      DATABRICKS_CLIENT_SECRET: "app-client-secret",
    });

    expect(config).toMatchObject({
      runtime: "databricks",
      authProvider: "header",
      authDatabase: "postgres",
      databricksDatabase: {
        workspaceUrl: "https://workspace.cloud.databricks.com",
        clientId: "app-client-id",
        clientSecret: "app-client-secret",
      },
    });
  });

  it("rejects overrides that conflict with managed runtime presets", () => {
    expect(() => loadConfig({
      ...accountsEnv(),
      DAHLIA_RUNTIME: "cloudflare",
      DAHLIA_AUTH_PROVIDER: "header",
    })).toThrow("DAHLIA_AUTH_PROVIDER must be accounts when DAHLIA_RUNTIME=cloudflare");
    expect(() => loadConfig({
      DAHLIA_RUNTIME: "databricks",
      DAHLIA_AUTH_DATABASE: "sqlite",
    })).toThrow("DAHLIA_AUTH_DATABASE must be postgres when DAHLIA_RUNTIME=databricks");
  });

  it("keeps Databricks Lakebase credentials independent from the OpenAI provider", () => {
    const config = loadConfig({
      DAHLIA_RUNTIME: "databricks",
      ...databricksDatabaseEnv(),
      DAHLIA_BASE_URL: "https://dahlia.example",
      DATABRICKS_HOST: "https://workspace.cloud.databricks.com",
      DATABRICKS_CLIENT_ID: "app-client-id",
      DATABRICKS_CLIENT_SECRET: "app-client-secret",
      OPENAI_API_KEY: "databricks-token",
      OPENAI_BASE_URL: "https://workspace.cloud.databricks.com/ai-gateway/openai/v1",
    });

    expect(config.authDatabase).toBe("postgres");
    expect(config.provider).toEqual({
      apiKey: "databricks-token",
      baseUrl: "https://workspace.cloud.databricks.com/ai-gateway/openai/v1",
    });
    expect(config.databricksDatabase).toMatchObject({ clientId: "app-client-id" });
  });

  it("configures the OpenAI-compatible provider in the Cloudflare preset", () => {
    const config = loadConfig({
      ...accountsEnv(),
      DAHLIA_RUNTIME: "cloudflare",
      DAHLIA_BASE_URL: "https://dahlia.example",
      OPENAI_API_KEY: "cloudflare-token",
      OPENAI_BASE_URL: "https://api.cloudflare.com/client/v4/accounts/account-id/ai/v1",
    });

    expect(config.provider).toEqual({
      apiKey: "cloudflare-token",
      baseUrl: "https://api.cloudflare.com/client/v4/accounts/account-id/ai/v1",
    });
  });

  it("ignores a base URL when the provider key is absent", () => {
    expect(loadConfig({
      ...accountsEnv(),
      OPENAI_BASE_URL: "not-a-url",
    }).provider).toBeUndefined();
  });
});
