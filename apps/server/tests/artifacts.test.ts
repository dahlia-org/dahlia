import { describe, expect, it } from "vitest";

import { createApp } from "../src/app";
import type { ArtifactRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { ObjectStorageError, type ObjectStorage } from "../src/artifacts/storage";
import { testStore } from "./test-store";

const OWNER = { "X-Forwarded-Email": "owner@example.com", "X-Forwarded-User": "owner" };
const OTHER = { "X-Forwarded-Email": "other@example.com", "X-Forwarded-User": "other" };
const ID = "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9";
const OTHER_ID = "019cc4dd-e5c5-7bd4-94e0-98df9cc40dba";

const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "sqlite",
  databaseUrl: "file:unused",
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
  artifactMaxBytes: 64 * 1024 * 1024,
};

function fixture() {
  const records = new Map<string, ArtifactRecord>();
  const reservations = new Set<string>();
  const objects = new Map<string, { body: Uint8Array; contentType: string }>();
  let deleteFails = false;
  let beforePut: (() => Promise<void>) | undefined;
  const store = testStore({
    getArtifact: async (id) => records.get(id) ?? null,
    createArtifact: async (input) => {
      if (reservations.has(input.id)) return false;
      reservations.add(input.id);
      const now = new Date();
      records.set(input.id, { ...input, visibility: "private", createdAt: now, updatedAt: now });
      return true;
    },
    touchArtifact: async (id, ownerWorkspaceId) => {
      const artifact = records.get(id);
      if (!artifact || artifact.ownerWorkspaceId !== ownerWorkspaceId) return null;
      const updated = { ...artifact, updatedAt: new Date() };
      records.set(id, updated);
      return updated;
    },
    updateArtifactVisibility: async (id, ownerWorkspaceId, visibility) => {
      const artifact = records.get(id);
      if (!artifact || artifact.ownerWorkspaceId !== ownerWorkspaceId) return null;
      const updated = { ...artifact, visibility, updatedAt: new Date() };
      records.set(id, updated);
      return updated;
    },
    deleteArtifact: async (id, ownerWorkspaceId) => {
      const artifact = records.get(id);
      return Boolean(artifact && artifact.ownerWorkspaceId === ownerWorkspaceId && records.delete(id));
    },
  });
  const storage: ObjectStorage = {
    put: async (key, body, _contentLength, contentType) => {
      await beforePut?.();
      const bytes = body instanceof Uint8Array
        ? body
        : new Uint8Array(await new Response(body).arrayBuffer());
      objects.set(key, { body: bytes, contentType });
    },
    exists: async (key) => objects.has(key),
    read: async (key, method) => {
      const object = objects.get(key);
      if (!object) return new Response(null, { status: 404 });
      return new Response(method === "HEAD" ? null : object.body.buffer as ArrayBuffer, {
        headers: {
          "content-type": object.contentType,
          "content-length": String(object.body.byteLength),
          "x-storage-secret": "do-not-forward",
        },
      });
    },
    delete: async (key) => {
      if (deleteFails) throw new ObjectStorageError();
      objects.delete(key);
    },
  };
  return {
    app: createApp({ config, authStore: store, artifactStorage: storage }),
    objects,
    records,
    failDelete(value: boolean) { deleteFails = value; },
    beforePut(callback?: () => Promise<void>) { beforePut = callback; },
  };
}

function upload(app: ReturnType<typeof createApp>, id = ID, body = "hello", headers: HeadersInit = {}) {
  return app.request(`/api/v1/artifacts/${id}`, {
    method: "PUT",
    headers: { ...OWNER, "content-length": String(new TextEncoder().encode(body).byteLength), ...headers },
    body,
  });
}

describe("artifact API", () => {
  it("keeps new artifacts private until the owner publishes them", async () => {
    const { app } = fixture();
    expect((await upload(app)).status).toBe(201);
    expect((await app.request(`/api/v1/artifacts/${ID}`)).status).toBe(401);
    expect((await app.request(`/api/v1/artifacts/${ID}`, { headers: OTHER })).status).toBe(404);

    const privateRead = await app.request(`/api/v1/artifacts/${ID}`, { headers: OWNER });
    expect(privateRead.status).toBe(200);
    expect(privateRead.headers.get("content-security-policy")).toBe("sandbox allow-scripts");
    expect(privateRead.headers.get("x-storage-secret")).toBeNull();
    expect(await privateRead.text()).toBe("hello");

    const published = await app.request(`/api/v1/artifacts/${ID}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "public" }),
    });
    expect(published.status).toBe(200);
    const publicRead = await app.request(`/api/v1/artifacts/${ID}`);
    expect(await publicRead.text()).toBe("hello");

    const hidden = await app.request(`/api/v1/artifacts/${ID}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "private" }),
    });
    expect(hidden.status).toBe(200);
    expect((await app.request(`/api/v1/artifacts/${ID}`)).status).toBe(401);
  });

  it("validates the upload contract and replacement media type", async () => {
    const { app } = fixture();
    expect((await app.request(`/api/v1/artifacts/${ID}`, { method: "PUT", headers: OWNER, body: "x" })).status)
      .toBe(411);
    expect((await upload(app, ID, "x", { "content-encoding": "gzip" })).status).toBe(415);
    expect((await upload(app, ID, "x", { "content-length": String(64 * 1024 * 1024 + 1) })).status).toBe(413);
    expect((await upload(app, ID, "x", { "content-length": String(64 * 1024 * 1024) })).status).toBe(201);
    expect((await upload(app, ID, "replacement")).status).toBe(200);
    expect((await upload(app, ID, "x", { "content-type": "text/plain" })).status).toBe(409);
    expect((await upload(app, ID.toUpperCase())).status).toBe(400);
    expect((await upload(app, "not-a-uuid")).status).toBe(400);
  });

  it("does not expose or mutate another owner's artifact", async () => {
    const { app } = fixture();
    expect((await upload(app)).status).toBe(201);
    const replace = await app.request(`/api/v1/artifacts/${ID}`, {
      method: "PUT",
      headers: { ...OTHER, "content-length": "1" },
      body: "x",
    });
    expect(replace.status).toBe(404);
    expect((await app.request(`/api/v1/artifacts/${ID}`, { method: "DELETE", headers: OTHER })).status).toBe(404);
  });

  it("does not allow a deleted public URL to be reclaimed", async () => {
    const { app } = fixture();
    expect((await upload(app)).status).toBe(201);
    expect((await app.request(`/api/v1/artifacts/${ID}`, { method: "DELETE", headers: OWNER })).status).toBe(204);
    const reclaim = await app.request(`/api/v1/artifacts/${ID}`, {
      method: "PUT",
      headers: { ...OTHER, "content-length": "8" },
      body: "attacker",
    });
    expect(reclaim.status).toBe(404);
  });

  it("requires bytes before publication and preserves metadata when deletion fails", async () => {
    const fixtureValue = fixture();
    const { app, records } = fixtureValue;
    const now = new Date();
    records.set(OTHER_ID, {
      id: OTHER_ID,
      ownerWorkspaceId: "personal:owner",
      contentType: "application/octet-stream",
      visibility: "private",
      createdAt: now,
      updatedAt: now,
    });
    const publishMissing = await app.request(`/api/v1/artifacts/${OTHER_ID}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "public" }),
    });
    expect(publishMissing.status).toBe(409);

    expect((await upload(app)).status).toBe(201);
    fixtureValue.failDelete(true);
    expect((await app.request(`/api/v1/artifacts/${ID}`, { method: "DELETE", headers: OWNER })).status).toBe(502);
    expect(records.has(ID)).toBe(true);
    fixtureValue.failDelete(false);
    expect((await app.request(`/api/v1/artifacts/${ID}`, { method: "DELETE", headers: OWNER })).status).toBe(204);
    expect(records.has(ID)).toBe(false);
  });

  it("returns a stable error when storage is not configured", async () => {
    const app = createApp({ config, authStore: testStore() });
    const response = await upload(app);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "artifact_storage_not_configured" });
    expect((await app.request(`/api/v1/artifacts/${ID}`)).status).toBe(503);
  });

  it("removes replacement bytes when a concurrent delete wins", async () => {
    const fixtureValue = fixture();
    const { app, objects, records } = fixtureValue;
    expect((await upload(app)).status).toBe(201);

    let releasePut!: () => void;
    const putBlocked = new Promise<void>((resolve) => { releasePut = resolve; });
    let putReachedStorage!: () => void;
    const storageReached = new Promise<void>((resolve) => { putReachedStorage = resolve; });
    fixtureValue.beforePut(async () => {
      putReachedStorage();
      await putBlocked;
    });
    const replacement = upload(app, ID, "replacement");
    await storageReached;
    expect((await app.request(`/api/v1/artifacts/${ID}`, { method: "DELETE", headers: OWNER })).status).toBe(204);
    releasePut();

    expect((await replacement).status).toBe(404);
    expect(records.has(ID)).toBe(false);
    expect(objects.has(`artifacts/${ID}`)).toBe(false);
  });

  it("does not overwrite a concurrent visibility change after replacement", async () => {
    const fixtureValue = fixture();
    const { app, records } = fixtureValue;
    expect((await upload(app)).status).toBe(201);

    let releasePut!: () => void;
    const putBlocked = new Promise<void>((resolve) => { releasePut = resolve; });
    let putReachedStorage!: () => void;
    const storageReached = new Promise<void>((resolve) => { putReachedStorage = resolve; });
    fixtureValue.beforePut(async () => {
      putReachedStorage();
      await putBlocked;
    });
    const replacement = upload(app, ID, "replacement");
    await storageReached;
    const published = await app.request(`/api/v1/artifacts/${ID}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "public" }),
    });
    expect(published.status).toBe(200);
    releasePut();

    expect((await replacement).status).toBe(200);
    expect(records.get(ID)?.visibility).toBe("public");
  });
});
