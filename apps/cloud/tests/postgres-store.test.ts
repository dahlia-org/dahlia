import { afterAll, describe, expect, it } from "vitest";

import { createPostgresAuthStore } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { connectAuthDatabase } from "../src/db/client";

const databaseUrl = process.env.TEST_DATABASE_URL;
const integration = describe.runIf(databaseUrl);
const config: AppConfig = {
  runtime: "custom",
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  authDatabase: "postgres",
  authDatabaseUrl: databaseUrl,
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  trustedProxyCidrs: [],
  maxRequestBytes: 1024,
};
const connection = databaseUrl ? connectAuthDatabase(config) : undefined;

afterAll(async () => connection?.close());

integration("PostgreSQL application store", () => {
  it("persists Model Aliases and platform administrators", async () => {
    const store = createPostgresAuthStore(connection!.db);
    const suffix = crypto.randomUUID();
    const alias = `test-${suffix}`;
    const email = `${suffix}@example.com`;

    expect(await store.createModelAlias({
      alias,
      upstreamModel: "provider/model",
      displayName: null,
      enabled: true,
    })).toBe(true);
    expect(await store.getEnabledModelAlias(alias)).toMatchObject({ alias, upstreamModel: "provider/model" });
    expect(await store.updateModelAlias(alias, {
      upstreamModel: "provider/model-v2",
      displayName: "Test model",
      enabled: false,
    })).toBe(true);
    expect(await store.getEnabledModelAlias(alias)).toBeNull();

    expect(await store.addPlatformAdmin(email)).toBe(true);
    expect(await store.isPlatformAdmin(email)).toBe(true);
    expect(await store.deletePlatformAdmin(email)).toBe(true);
    expect(await store.deleteModelAlias(alias)).toBe(true);
  });
});
