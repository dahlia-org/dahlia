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
      oauthRedirectUris: ["http://127.0.0.1:1455/oauth/callback", "http://localhost:8020"],
      storageBackend: "local",
      storageLocalPath: ".data/storage",
    });
  });

  it("selects PostgreSQL independently from the AI Gateway", () => {
    const config = loadConfig({
      ...accounts,
      DAHLIA_DATABASE_TYPE: "postgres",
      DAHLIA_DATABASE_URL: "postgresql://dahlia.example/dahlia",
      DAHLIA_AI_BACKEND: "openai",
      OPENAI_API_KEY: "gateway-secret",
      OPENAI_BASE_URL: "https://provider.example/v1/",
    });
    expect(config).toMatchObject({
      databaseType: "postgres",
      databaseUrl: "postgresql://dahlia.example/dahlia",
      provider: { backend: "openai", apiKey: "gateway-secret", baseUrl: "https://provider.example/v1" },
    });
  });

  it("builds the Databricks AI Gateway configuration from DATABRICKS_HOST", () => {
    const databricks = {
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_AI_BACKEND: "databricks",
      DATABRICKS_HOST: "workspace.cloud.databricks.com",
    };
    expect(loadConfig({
      ...databricks,
      DATABRICKS_CLIENT_ID: "app-client-id",
      DATABRICKS_CLIENT_SECRET: "app-client-secret",
    })).toMatchObject({
      provider: {
        backend: "databricks",
        baseUrl: "https://workspace.cloud.databricks.com/ai-gateway/mlflow/v1",
      },
      databricksWorkspace: {
        host: "https://workspace.cloud.databricks.com",
        clientId: "app-client-id",
      },
    });
    expect(() => loadConfig(databricks)).toThrow("DATABRICKS_CLIENT_ID is required");
    expect(() => loadConfig({
      ...databricks,
      DATABRICKS_CLIENT_ID: "app-client-id",
    })).toThrow("DATABRICKS_CLIENT_SECRET is required");
  });

  it("configures object storage independently from the AI backend", () => {
    expect(loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_STORAGE_BACKEND: "databricks",
      DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH: "/Volumes/main/default/dahlia_artifacts",
      DATABRICKS_HOST: "workspace.cloud.databricks.com",
      DATABRICKS_CLIENT_ID: "app-client-id",
      DATABRICKS_CLIENT_SECRET: "app-client-secret",
    })).toMatchObject({
      storageBackend: "databricks",
      artifactMaxBytes: 64 * 1024 * 1024,
      storageDatabricksVolumePath: "/Volumes/main/default/dahlia_artifacts",
      databricksWorkspace: { host: "https://workspace.cloud.databricks.com" },
    });
    expect(loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_STORAGE_BACKEND: "r2",
    })).toMatchObject({
      storageBackend: "r2",
    });
    expect(loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_STORAGE_BACKEND: "s3",
      DAHLIA_STORAGE_S3_BUCKET: "bucket",
      DAHLIA_STORAGE_S3_ENDPOINT: "https://s3.example/",
      AWS_ACCESS_KEY_ID: "key",
      AWS_REGION: "auto",
      AWS_SECRET_ACCESS_KEY: "secret",
      AWS_SESSION_TOKEN: "session",
    })).toMatchObject({
      storageBackend: "s3",
      storageS3: {
        accessKeyId: "key",
        bucket: "bucket",
        endpoint: "https://s3.example",
        region: "auto",
        sessionToken: "session",
      },
    });
  });

  it("rejects invalid artifact limits and Volume paths", () => {
    expect(() => loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_ARTIFACT_MAX_BYTES: String(64 * 1024 * 1024 + 1),
    })).toThrow();
    expect(() => loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_STORAGE_BACKEND: "databricks",
      DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH: "/Volumes/main/default/volume/nested",
      DATABRICKS_HOST: "workspace.cloud.databricks.com",
      DATABRICKS_CLIENT_ID: "app-client-id",
      DATABRICKS_CLIENT_SECRET: "app-client-secret",
    })).toThrow("must identify a Unity Catalog Volume");
  });

  it("rejects the replaced artifact backend variable", () => {
    expect(() => loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_ARTIFACT_BACKEND: "r2",
    })).toThrow("DAHLIA_ARTIFACT_BACKEND was replaced by DAHLIA_STORAGE_BACKEND");
  });

  it("requires the Cloudflare account endpoint when its backend is configured", () => {
    expect(() => loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_AI_BACKEND: "cloudflare",
      OPENAI_API_KEY: "secret",
    })).toThrow("OPENAI_BASE_URL is required");
  });

  it("loads Lakebase connection fields for the official connector", () => {
    expect(loadConfig({
      DAHLIA_AUTH_TYPE: "header",
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
    expect(loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_DATABASE_TYPE: databaseType }))
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
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_AUTH_HEADER: "Cf-Access-Authenticated-User-Email",
      DAHLIA_APP_URL: "https://dahlia.example",
    })).toMatchObject({
      authProvider: "header",
      authHeader: "Cf-Access-Authenticated-User-Email",
      databaseType: "sqlite",
    });
  });

  it("uses DATABRICKS_APP_URL unless DAHLIA_APP_URL overrides it", () => {
    expect(loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DATABRICKS_APP_URL: "https://dahlia-dev.example/",
    }).baseUrl).toBe("https://dahlia-dev.example");
    expect(loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_APP_URL: "https://dahlia.example",
      DATABRICKS_APP_URL: "https://dahlia-dev.example",
    }).baseUrl).toBe("https://dahlia.example");
  });

  it("validates account secrets and provider URLs", () => {
    expect(() => loadConfig({
      ...accounts,
      BETTER_AUTH_SECRET: "replace-with-at-least-32-random-characters",
    })).toThrow("unique random value");
    expect(() => loadConfig({
      DAHLIA_AUTH_TYPE: "header",
      DAHLIA_AI_BACKEND: "openai",
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
