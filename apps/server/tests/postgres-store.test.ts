import { afterAll, describe, expect, it } from "vitest";

import { createPostgresAuthStore } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { connectAuthDatabase } from "../src/db/client";

const databaseUrl = process.env.TEST_DATABASE_URL;
const integration = describe.runIf(databaseUrl);
const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "postgres",
  databaseUrl,
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
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

  it("paginates artifacts within their owner workspace", async () => {
    const store = createPostgresAuthStore(connection!.db);
    const suffix = crypto.randomUUID().replaceAll("-", "").slice(0, 12);
    const owner = `personal:${suffix}`;
    const first = `019cc4dd-e5c5-7bd4-94e0-${suffix}`;
    const second = `019cc4dd-e5c6-7bd4-94e0-${suffix}`;
    const firstStorageKey = `artifacts/${first}`;
    const secondStorageKey = `artifacts/${second}`;
    try {
      expect(await store.createArtifact({ id: first, ownerWorkspaceId: owner, contentType: "text/plain" }))
        .not.toBeNull();
      expect(await store.createArtifact({ id: second, ownerWorkspaceId: owner, contentType: "text/plain" }))
        .not.toBeNull();
      expect(await store.listArtifacts(owner, undefined, 2)).toEqual([]);
      expect(await store.commitArtifactStorage(first, owner, null, firstStorageKey)).not.toBeNull();
      expect(await store.commitArtifactStorage(second, owner, null, secondStorageKey)).not.toBeNull();
      expect((await store.listArtifacts(owner, undefined, 1)).map(({ id }) => id)).toEqual([second]);
      expect((await store.listArtifacts(owner, second, 1)).map(({ id }) => id)).toEqual([first]);
    } finally {
      const firstArtifact = await store.getArtifact(first);
      const secondArtifact = await store.getArtifact(second);
      await store.deleteArtifact(first, owner, firstArtifact?.storageKey ?? null);
      await store.deleteArtifact(second, owner, secondArtifact?.storageKey ?? null);
    }
  });
});
