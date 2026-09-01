import { describe, expect, it } from "vitest";

import { createApp } from "../src/app";
import { ARTIFACT_METADATA_MEDIA_TYPE } from "../src/artifacts/service";
import type { ArtifactRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { ObjectStorageError, type ObjectStorage } from "../src/artifacts/storage";
import { testStore } from "./test-store";

const OWNER = { "X-Forwarded-Email": "owner@example.com", "X-Forwarded-User": "owner" };
const OTHER = { "X-Forwarded-Email": "other@example.com", "X-Forwarded-User": "other" };
const ID = "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9";
const OTHER_ID = "019cc4dd-e5c5-7bd4-94e0-98df9cc40dba";
const UUID_V4 = "550e8400-e29b-41d4-a716-446655440000";

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
  const objects = new Map<string, { body: Uint8Array; contentType: string }>();
  let deleteFails = false;
  let putFails = false;
  let commitFails = false;
  let getCalls = 0;
  let beforePut: (() => Promise<void>) | undefined;
  let beforeRead: (() => Promise<void>) | undefined;
  const store = testStore({
    listArtifacts: async (ownerWorkspaceId, cursor, limit) => [...records.values()]
      .filter((artifact) => artifact.ownerWorkspaceId === ownerWorkspaceId
        && artifact.storageKey !== null
        && (!cursor || artifact.id < cursor))
      .toSorted((left, right) => right.id.localeCompare(left.id))
      .slice(0, limit),
    getArtifact: async (id) => {
      getCalls += 1;
      return records.get(id) ?? null;
    },
    createArtifact: async (input) => {
      if (records.has(input.id)) return null;
      const now = new Date();
      const artifact = { ...input, storageKey: null, visibility: "private" as const, createdAt: now, updatedAt: now };
      records.set(input.id, artifact);
      return artifact;
    },
    commitArtifactStorage: async (id, ownerWorkspaceId, expectedStorageKey, storageKey) => {
      const artifact = records.get(id);
      if (
        !artifact
        || artifact.ownerWorkspaceId !== ownerWorkspaceId
        || artifact.storageKey !== expectedStorageKey
      ) return null;
      const updated = { ...artifact, storageKey, updatedAt: new Date() };
      records.set(id, updated);
      if (commitFails) throw new Error("metadata unavailable after commit");
      return updated;
    },
    updateArtifactVisibility: async (id, ownerWorkspaceId, visibility) => {
      const artifact = records.get(id);
      if (!artifact || artifact.ownerWorkspaceId !== ownerWorkspaceId) return null;
      const updated = { ...artifact, visibility, updatedAt: new Date() };
      records.set(id, updated);
      return updated;
    },
    deleteArtifact: async (id, ownerWorkspaceId, expectedStorageKey) => {
      const artifact = records.get(id);
      return Boolean(
        artifact
        && artifact.ownerWorkspaceId === ownerWorkspaceId
        && artifact.storageKey === expectedStorageKey
        && records.delete(id),
      );
    },
  });
  const storage: ObjectStorage = {
    put: async (key, body, _contentLength, contentType) => {
      if (putFails) throw new ObjectStorageError();
      await beforePut?.();
      const bytes = body instanceof Uint8Array
        ? body
        : new Uint8Array(await new Response(body).arrayBuffer());
      objects.set(key, { body: bytes, contentType });
    },
    exists: async (key) => objects.has(key),
    read: async (key, method) => {
      const object = objects.get(key);
      await beforeRead?.();
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
    get getCalls() { return getCalls; },
    failDelete(value: boolean) { deleteFails = value; },
    failPut(value: boolean) { putFails = value; },
    failCommit(value: boolean) { commitFails = value; },
    beforePut(callback?: () => Promise<void>) { beforePut = callback; },
    beforeRead(callback?: () => Promise<void>) { beforeRead = callback; },
  };
}

function upload(app: ReturnType<typeof createApp>, body = "hello", headers: HeadersInit = {}) {
  return app.request("/api/v1/artifacts", {
    method: "POST",
    headers: { ...OWNER, "content-length": String(new TextEncoder().encode(body).byteLength), ...headers },
    body,
  });
}

function replace(
  app: ReturnType<typeof createApp>,
  id: string,
  body = "replacement",
  headers: HeadersInit = {},
) {
  return app.request(`/api/v1/artifacts/${id}`, {
    method: "PUT",
    headers: { ...OWNER, "content-length": String(new TextEncoder().encode(body).byteLength), ...headers },
    body,
  });
}

async function uploadedId(response: Response): Promise<string> {
  const body: unknown = await response.clone().json();
  if (!body || typeof body !== "object" || !("id" in body) || typeof body.id !== "string") {
    throw new Error("Artifact response is missing an ID");
  }
  return body.id;
}

function mcpRequest(
  app: ReturnType<typeof createApp>,
  method: string,
  params: Record<string, unknown>,
  headers: Record<string, string> = OWNER,
  includeContentLength = true,
) {
  const body = JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method,
    params: {
      ...params,
      _meta: {
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": { name: "Dahlia tests", version: "1.0.0" },
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      },
    },
  });
  return app.request("/mcp", {
    method: "POST",
    headers: {
      ...headers,
      ...(includeContentLength
        ? { "content-length": String(new TextEncoder().encode(body).byteLength) }
        : {}),
      "content-type": "application/json",
      "mcp-method": method,
      "mcp-name": method === "tools/call" ? String(params.name) : "",
      "mcp-protocol-version": "2026-07-28",
    },
    body,
  });
}

async function mcpResult(response: Response): Promise<Record<string, unknown>> {
  const envelope: unknown = await response.json();
  if (
    !envelope
    || typeof envelope !== "object"
    || !("result" in envelope)
    || !envelope.result
    || typeof envelope.result !== "object"
  ) throw new Error(`Missing MCP result: ${JSON.stringify(envelope)}`);
  return envelope.result as Record<string, unknown>;
}

describe("artifact API", () => {
  it("serves owner-scoped artifact tools over modern MCP", async () => {
    const { app, objects, records } = fixture();
    const listed = await mcpRequest(app, "tools/list", {});
    expect(listed.status, await listed.clone().text()).toBe(200);
    const tools = (await mcpResult(listed)).tools as Array<Record<string, unknown>>;
    expect(tools).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "create_artifact" }),
      expect.objectContaining({ name: "update_artifact_content" }),
      expect.objectContaining({ name: "update_artifact_visibility" }),
      expect.objectContaining({ name: "delete_artifact" }),
    ]));
    expect(tools.find((tool) => tool.name === "delete_artifact")).toMatchObject({
      annotations: { destructiveHint: true, idempotentHint: true },
    });

    const created = await mcpRequest(app, "tools/call", {
      name: "create_artifact",
      arguments: { content: "aGVsbG8=", content_type: "text/plain", encoding: "base64" },
    });
    expect(created.status).toBe(200);
    const createResult = await mcpResult(created);
    const createdArtifact = createResult.structuredContent as Record<string, string>;
    const id = createdArtifact.artifact_id!;
    expect(createdArtifact).toEqual({
      artifact_id: id,
      url: `https://dahlia.example/artifacts/${id}`,
      content_type: "text/plain",
      visibility: "private",
    });
    expect(createResult.content).toContainEqual(expect.objectContaining({
      type: "resource_link",
      uri: `https://dahlia.example/api/v1/artifacts/${id}/content`,
    }));
    expect(Array.from(objects.values())[0]?.body).toEqual(new TextEncoder().encode("hello"));

    const invalidBase64 = await mcpRequest(app, "tools/call", {
      name: "create_artifact",
      arguments: { content: "AB==", content_type: "application/octet-stream", encoding: "base64" },
    });
    expect(await mcpResult(invalidBase64)).toMatchObject({ isError: true, content: [{ text: "invalid_base64" }] });

    const invalidContentType = await mcpRequest(app, "tools/call", {
      name: "create_artifact",
      arguments: { content: "hello", content_type: "text/🍣" },
    });
    const invalidContentTypeResult = await mcpResult(invalidContentType);
    expect(invalidContentTypeResult).toMatchObject({ isError: true });
    expect(JSON.stringify(invalidContentTypeResult)).toContain("invalid_content_type");

    const tooLarge = await mcpRequest(app, "tools/call", {
      name: "create_artifact",
      arguments: { content: "x".repeat(8 * 1024 * 1024 + 1), content_type: "text/plain" },
    });
    expect(await mcpResult(tooLarge)).toMatchObject({ isError: true, content: [{ text: "artifact_too_large" }] });

    const denied = await mcpRequest(app, "tools/call", {
      name: "update_artifact_content",
      arguments: { artifact_id: id, content: "no", content_type: "text/plain" },
    }, OTHER);
    expect(await mcpResult(denied)).toMatchObject({ isError: true, content: [{ text: "artifact_not_found" }] });

    const published = await mcpRequest(app, "tools/call", {
      name: "update_artifact_visibility",
      arguments: { artifact_id: id, visibility: "public" },
    });
    expect((await mcpResult(published)).structuredContent).toMatchObject({ visibility: "public" });

    const deleted = await mcpRequest(app, "tools/call", {
      name: "delete_artifact",
      arguments: { artifact_id: id },
    });
    expect((await mcpResult(deleted)).structuredContent).toMatchObject({ artifact_id: id, visibility: "public" });
    expect(records.has(id)).toBe(false);
    expect(objects.size).toBe(0);

    const withoutContentLength = await mcpRequest(app, "tools/list", {}, OWNER, false);
    expect(withoutContentLength.status, await withoutContentLength.clone().text()).toBe(200);
    expect((await app.request("/mcp", {
      method: "POST",
      headers: { ...OWNER, "content-length": String(12 * 1024 * 1024 + 1), origin: "https://dahlia.example" },
      body: "{}",
    })).status).toBe(413);
    expect((await app.request("/mcp", {
      method: "POST",
      headers: { ...OWNER, "content-length": "2", origin: "https://attacker.example" },
      body: "{}",
    })).status).toBe(403);
  });

  it("keeps new artifacts private until the owner publishes them", async () => {
    const { app, objects } = fixture();
    const created = await upload(app);
    const id = await uploadedId(created);
    const timestamp = Number.parseInt(id.replaceAll("-", "").slice(0, 12), 16);
    expect(created.status).toBe(201);
    expect(created.headers.get("location")).toBe(`https://dahlia.example/api/v1/artifacts/${id}`);
    expect(await created.clone().json()).toMatchObject({
      id,
      viewerUrl: `https://dahlia.example/artifacts/${id}`,
    });
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(Math.abs(Date.now() - timestamp)).toBeLessThan(1_000);
    expect([...objects.keys()]).toEqual([
      expect.stringMatching(new RegExp(
        `^artifacts/${id}/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.txt$`,
      )),
    ]);
    expect((await app.request(`/api/v1/artifacts/${id}`)).status).toBe(401);
    expect((await app.request(`/api/v1/artifacts/${id}`, { headers: OTHER })).status).toBe(404);

    const privateRead = await app.request(`/api/v1/artifacts/${id}`, { headers: OWNER });
    expect(privateRead.status).toBe(200);
    expect(privateRead.headers.get("vary")).toBe("Accept");
    expect(privateRead.headers.get("content-security-policy")).toBe("sandbox allow-scripts");
    expect(privateRead.headers.get("x-storage-secret")).toBeNull();
    expect(await privateRead.text()).toBe("hello");

    const metadata = await app.request(`/api/v1/artifacts/${id}`, {
      headers: { ...OWNER, accept: ARTIFACT_METADATA_MEDIA_TYPE },
    });
    expect(metadata.status).toBe(200);
    expect(metadata.headers.get("content-type")).toBe(ARTIFACT_METADATA_MEDIA_TYPE);
    expect(metadata.headers.get("vary")).toBe("Accept");
    expect(await metadata.json()).toMatchObject({ id, contentType: "text/plain;charset=UTF-8", visibility: "private" });
    const caseInsensitiveMetadata = await app.request(`/api/v1/artifacts/${id}`, {
      headers: { ...OWNER, accept: "Application/Vnd.Dahlia.Artifact+Json" },
    });
    expect(await caseInsensitiveMetadata.json()).toMatchObject({ id });
    const declinedMetadata = await app.request(`/api/v1/artifacts/${id}`, {
      headers: { ...OWNER, accept: `${ARTIFACT_METADATA_MEDIA_TYPE};q=0` },
    });
    expect(await declinedMetadata.text()).toBe("hello");
    const content = await app.request(`/api/v1/artifacts/${id}/content`, { headers: OWNER });
    expect(content.status).toBe(200);
    expect(content.headers.get("content-security-policy")).toBe("sandbox allow-scripts");
    expect(await content.text()).toBe("hello");

    const published = await app.request(`/api/v1/artifacts/${id}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "public" }),
    });
    expect(published.status).toBe(200);
    const publicRead = await app.request(`/api/v1/artifacts/${id}`);
    expect(await publicRead.text()).toBe("hello");
    expect(await (await app.request(`/api/v1/artifacts/${id}/content`)).text()).toBe("hello");
    expect((await app.request(`/api/v1/artifacts/${id}`, {
      headers: { authorization: "Bearer invalid" },
    })).status).toBe(401);
    expect((await app.request(`/api/v1/artifacts/${id}/content`, {
      headers: { authorization: "Bearer invalid" },
    })).status).toBe(401);

    const hidden = await app.request(`/api/v1/artifacts/${id}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "private" }),
    });
    expect(hidden.status).toBe(200);
    expect((await app.request(`/api/v1/artifacts/${id}`)).status).toBe(401);
  });

  it("lists only owned artifacts with bounded keyset pagination", async () => {
    const { app, records } = fixture();
    const now = new Date();
    for (let index = 0; index < 52; index += 1) {
      const timestamp = (0x019cc4dde5c5n + BigInt(index)).toString(16).padStart(12, "0");
      const id = `${timestamp.slice(0, 8)}-${timestamp.slice(8)}-7bd4-94e0-${index.toString(16).padStart(12, "0")}`;
      records.set(id, {
        id,
        ownerWorkspaceId: "personal:owner",
        contentType: "text/plain",
        storageKey: `artifacts/${id}`,
        visibility: "private",
        createdAt: now,
        updatedAt: now,
      });
    }
    records.set(OTHER_ID, {
      id: OTHER_ID,
      ownerWorkspaceId: "personal:other",
      contentType: "text/plain",
      storageKey: "artifacts/other",
      visibility: "public",
      createdAt: now,
      updatedAt: now,
    });

    expect((await app.request("/api/v1/artifacts")).status).toBe(401);
    const first: { items: Array<{ id: string; ownerWorkspaceId?: string }>; nextCursor: string } =
      await (await app.request("/api/v1/artifacts", { headers: OWNER })).json();
    expect(first.items).toHaveLength(50);
    expect(first.items.every((artifact) => artifact.ownerWorkspaceId === undefined)).toBe(true);
    expect(first.nextCursor).toBe(first.items.at(-1)?.id);

    const second: { items: Array<{ id: string }>; nextCursor?: string } = await (await app.request(
      `/api/v1/artifacts?cursor=${first.nextCursor}`,
      { headers: OWNER },
    )).json();
    expect(second.items).toHaveLength(2);
    expect(second).not.toHaveProperty("nextCursor");
    expect((await app.request("/api/v1/artifacts?cursor=not-a-uuid", { headers: OWNER })).status).toBe(400);
    expect(await (await app.request("/api/v1/artifacts", { headers: OTHER })).json())
      .toMatchObject({ items: [expect.objectContaining({ id: OTHER_ID })] });
  });

  it("validates the upload contract and replacement media type", async () => {
    const { app, objects } = fixture();
    expect((await app.request("/api/v1/artifacts", { method: "POST", headers: OWNER, body: "x" })).status)
      .toBe(411);
    expect((await upload(app, "x", { "content-encoding": "gzip" })).status).toBe(415);
    expect((await upload(app, "x", { "content-length": String(64 * 1024 * 1024 + 1) })).status).toBe(413);
    const created = await upload(app, "x", { "content-length": String(64 * 1024 * 1024) });
    const id = await uploadedId(created);
    expect(created.status).toBe(201);
    expect((await replace(app, id)).status).toBe(200);
    expect((await replace(app, id, "x", { "content-type": "text/plain" })).status).toBe(409);
    expect((await replace(app, id.toUpperCase())).status).toBe(400);
    expect((await replace(app, UUID_V4)).status).toBe(400);
    expect((await replace(app, "not-a-uuid")).status).toBe(400);
    expect((await replace(app, OTHER_ID)).status).toBe(404);

    const html = await upload(app, "<p>summary</p>", {
      "content-type": "text/html",
      "content-disposition": "attachment; filename=\"summary.html\"",
    });
    const htmlId = await uploadedId(html);
    expect([...objects.keys()]).toContainEqual(
      expect.stringMatching(new RegExp(
        `^artifacts/${htmlId}/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.html$`,
      )),
    );
  });

  it("does not expose or mutate another owner's artifact", async () => {
    const { app } = fixture();
    const created = await upload(app);
    const id = await uploadedId(created);
    expect(created.status).toBe(201);
    const replacement = await app.request(`/api/v1/artifacts/${id}`, {
      method: "PUT",
      headers: { ...OTHER, "content-length": "1" },
      body: "x",
    });
    expect(replacement.status).toBe(404);
    expect((await app.request(`/api/v1/artifacts/${id}`, { method: "DELETE", headers: OTHER })).status).toBe(404);
  });

  it("does not allow PUT to create or reclaim an artifact", async () => {
    const { app } = fixture();
    const created = await upload(app);
    const id = await uploadedId(created);
    expect(created.status).toBe(201);
    expect((await app.request(`/api/v1/artifacts/${id}`, { method: "DELETE", headers: OWNER })).status).toBe(204);
    const reclaim = await app.request(`/api/v1/artifacts/${id}`, {
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
      storageKey: null,
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

    const created = await upload(app);
    const id = await uploadedId(created);
    expect(created.status).toBe(201);
    fixtureValue.failDelete(true);
    expect((await app.request(`/api/v1/artifacts/${id}`, { method: "DELETE", headers: OWNER })).status).toBe(502);
    expect(records.has(id)).toBe(true);
    fixtureValue.failDelete(false);
    expect((await app.request(`/api/v1/artifacts/${id}`, { method: "DELETE", headers: OWNER })).status).toBe(204);
    expect(records.has(id)).toBe(false);
  });

  it("cleans up metadata when a new upload fails", async () => {
    const fixtureValue = fixture();
    fixtureValue.failPut(true);
    expect((await upload(fixtureValue.app)).status).toBe(502);
    expect(fixtureValue.records.size).toBe(0);
    expect(fixtureValue.objects.size).toBe(0);
  });

  it("returns the inserted row without re-reading metadata", async () => {
    const fixtureValue = fixture();
    expect((await upload(fixtureValue.app)).status).toBe(201);
    expect(fixtureValue.getCalls).toBe(0);
  });

  it("retains metadata when failed-create object cleanup must be retried", async () => {
    const fixtureValue = fixture();
    fixtureValue.failCommit(true);
    fixtureValue.failDelete(true);
    expect((await upload(fixtureValue.app)).status).toBe(503);
    expect(fixtureValue.records.size).toBe(1);
    expect(fixtureValue.objects.size).toBe(1);

    fixtureValue.failCommit(false);
    fixtureValue.failDelete(false);
    const [id] = fixtureValue.records.keys();
    expect((await fixtureValue.app.request(`/api/v1/artifacts/${id}`, {
      method: "DELETE",
      headers: OWNER,
    })).status).toBe(204);
    expect(fixtureValue.records.size).toBe(0);
    expect(fixtureValue.objects.size).toBe(0);
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
    const created = await upload(app);
    const id = await uploadedId(created);
    expect(created.status).toBe(201);

    let releasePut!: () => void;
    const putBlocked = new Promise<void>((resolve) => { releasePut = resolve; });
    let putReachedStorage!: () => void;
    const storageReached = new Promise<void>((resolve) => { putReachedStorage = resolve; });
    fixtureValue.beforePut(async () => {
      putReachedStorage();
      await putBlocked;
    });
    const replacement = replace(app, id);
    await storageReached;
    expect((await app.request(`/api/v1/artifacts/${id}`, { method: "DELETE", headers: OWNER })).status).toBe(204);
    releasePut();

    expect((await replacement).status).toBe(404);
    expect(records.has(id)).toBe(false);
    expect(objects.size).toBe(0);
  });

  it("does not overwrite a concurrent visibility change after replacement", async () => {
    const fixtureValue = fixture();
    const { app, records } = fixtureValue;
    const created = await upload(app);
    const id = await uploadedId(created);
    expect(created.status).toBe(201);

    let releasePut!: () => void;
    const putBlocked = new Promise<void>((resolve) => { releasePut = resolve; });
    let putReachedStorage!: () => void;
    const storageReached = new Promise<void>((resolve) => { putReachedStorage = resolve; });
    fixtureValue.beforePut(async () => {
      putReachedStorage();
      await putBlocked;
    });
    const replacement = replace(app, id);
    await storageReached;
    const published = await app.request(`/api/v1/artifacts/${id}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "public" }),
    });
    expect(published.status).toBe(200);
    releasePut();

    expect((await replacement).status).toBe(200);
    expect(records.get(id)?.visibility).toBe("public");
  });

  it("pins an authorized public read to the version it authorized", async () => {
    const fixtureValue = fixture();
    const { app } = fixtureValue;
    const created = await upload(app);
    const id = await uploadedId(created);
    expect(created.status).toBe(201);
    expect((await app.request(`/api/v1/artifacts/${id}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "public" }),
    })).status).toBe(200);

    let releaseRead!: () => void;
    const readBlocked = new Promise<void>((resolve) => { releaseRead = resolve; });
    let readReachedStorage!: () => void;
    const storageReached = new Promise<void>((resolve) => { readReachedStorage = resolve; });
    fixtureValue.beforeRead(async () => {
      readReachedStorage();
      await readBlocked;
    });
    const publicRead = app.request(`/api/v1/artifacts/${id}`);
    await storageReached;
    expect((await app.request(`/api/v1/artifacts/${id}`, {
      method: "PATCH",
      headers: { ...OWNER, "content-type": "application/json" },
      body: JSON.stringify({ visibility: "private" }),
    })).status).toBe(200);
    expect((await replace(app, id, "private replacement")).status).toBe(200);
    releaseRead();

    const response = await publicRead;
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("hello");
  });
});
