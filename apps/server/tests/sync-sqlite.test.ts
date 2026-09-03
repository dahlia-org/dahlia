import { afterEach, describe, expect, it, vi } from "vitest";

import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import type { Identity } from "../src/auth/identity";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { LocalObjectStorage } from "../src/artifacts/local";
import { ObjectStorageError, type ObjectStorage } from "../src/artifacts/storage";
import { ArtifactRequestError } from "../src/artifacts/upload";
import { createApp } from "../src/app";
import type { AppConfig } from "../src/config";
import { MeetingSyncService } from "../src/sync/service";
import type { IdentitySyncStore, MeetingSyncStore, SyncTranscriptSegment } from "../src/sync/types";

const directories: string[] = [];
const owner: Identity = {
  userId: "owner",
  workspaceId: "personal:owner",
  source: "header",
};
const otherOwner: Identity = {
  userId: "other",
  workspaceId: "personal:other",
  source: "header",
};
const vaultId = "019d3f46-7e0d-7d21-98d9-f1456c0bfb58";
const meetingId = "019d3f46-8b72-77f1-b232-93726eec3e9e";
const screenshotId = "019d3f46-91e8-7ce0-ad52-bdd72825a61a";

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true });
});

describe("SQLite meeting sync", () => {
  it("keeps client IDs owner-scoped and activates only the manifest generation", async () => {
    const { store } = await setup();
    await store.sync.withIdentity(owner, async (sync) => {
      expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(true);
      expect(await sync.putTranscriptChunk(vaultId, meetingId, "a".repeat(64), [{
        segmentId: screenshotId,
        startTime: new Date("2026-09-02T00:00:00Z"),
        endTime: null,
        text: "first",
        isConfirmed: true,
        audioSource: "system",
        speakerLabel: null,
      }])).toBe(true);
      expect((await sync.commitManifest(manifest("a".repeat(64)))).committed).toBe(true);
      expect(await sync.listTranscript(vaultId, meetingId, 10)).toHaveLength(1);
    });
    await store.sync.withIdentity(otherOwner, async (sync) => {
      expect(await sync.getVault(vaultId)).toBeNull();
      expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(false);
    });
    await store.close?.();
  });

  it("replaces the Vault Project hierarchy and filters descendant meetings", async () => {
    const { store } = await setup();
    const service = new MeetingSyncService(store.sync);
    const rootId = "019d493e-063e-70ed-ab24-c86de735bca8";
    const childId = "019d493e-0d33-7359-96f5-2c45dc8285c1";
    const createdAt = "2026-09-02T00:00:00.000Z";
    await service.commitVaultManifest(owner, vaultId, {
      name: "Research Vault",
      createdAt,
      projects: [
        { projectId: rootId, parentProjectId: null, name: "Customers", description: "", projectType: "customer", revision: 1, createdAt },
        { projectId: childId, parentProjectId: rootId, name: "Dahlia", description: "Sync", projectType: null, revision: 2, createdAt },
      ],
    });
    await service.commitManifest(owner, vaultId, meetingId, {
      projectId: childId,
      name: "Project meeting",
      description: "",
      status: "READY",
      duration: null,
      recordingStartedAt: null,
      createdAt,
      updatedAt: createdAt,
      summary: null,
      activeTranscriptGeneration: null,
      screenshots: [],
    });
    expect(await service.getVault(owner, vaultId)).toMatchObject({ name: "Research Vault" });
    expect(await service.listProjects(owner, vaultId)).toEqual([
      expect.objectContaining({ projectId: rootId, path: "Customers", subtreeMeetingCount: 1 }),
      expect.objectContaining({ projectId: childId, path: "Customers/Dahlia", directMeetingCount: 1, effectiveType: "customer" }),
    ]);
    expect(await service.listMeetings(owner, vaultId, undefined, undefined, rootId))
      .toEqual({ items: [expect.objectContaining({ meetingId, projectId: childId })] });

    await service.commitVaultManifest(owner, vaultId, {
      name: "Research Vault",
      createdAt,
      projects: [{ projectId: rootId, parentProjectId: null, name: "Customers", description: "", projectType: "customer", revision: 2, createdAt }],
    });
    expect(await service.getMeeting(owner, vaultId, meetingId)).toMatchObject({ projectId: null });
    await expect(service.commitVaultManifest(owner, vaultId, {
      name: "Research Vault",
      createdAt,
      projects: [{ projectId: rootId, parentProjectId: rootId, name: "Cycle", description: "", projectType: null, revision: 3, createdAt }],
    })).rejects.toEqual(expect.objectContaining({ status: 400, code: "invalid_vault_manifest" }));
    await store.close?.();
  });

  it("applies sibling Project renames without transient uniqueness conflicts", async () => {
    const { store } = await setup();
    const service = new MeetingSyncService(store.sync);
    const firstId = "019d493e-063e-70ed-ab24-c86de735bca8";
    const secondId = "019d493e-0d33-7359-96f5-2c45dc8285c1";
    const createdAt = "2026-09-02T00:00:00.000Z";
    const project = (projectId: string, name: string, revision: number) => ({
      projectId,
      parentProjectId: null,
      name,
      description: "",
      projectType: "personal" as const,
      revision,
      createdAt,
    });
    await service.commitVaultManifest(owner, vaultId, {
      name: "Vault",
      createdAt,
      projects: [project(firstId, "A", 1), project(secondId, "B", 1)],
    });
    await service.commitVaultManifest(owner, vaultId, {
      name: "Vault",
      createdAt,
      projects: [project(firstId, "B", 2), project(secondId, "C", 2)],
    });
    expect((await service.listProjects(owner, vaultId)).map(({ name }) => name)).toEqual(["B", "C"]);
    await store.close?.();
  });

  it("paginates meetings beyond the first read page", async () => {
    const { store } = await setup();
    const service = new MeetingSyncService(store.sync);
    await store.sync.withIdentity(owner, async (sync) => {
      for (let index = 0; index < 201; index += 1) {
        const id = crypto.randomUUID();
        const createdAt = new Date(Date.UTC(2026, 8, 2, 0, 0, index));
        expect(await sync.ensureUploadTarget(vaultId, id)).toBe(true);
        expect((await sync.commitManifest({
          ...manifest(null),
          meetingId: id,
          name: `Meeting ${index}`,
          createdAt,
          updatedAt: createdAt,
        })).committed).toBe(true);
      }
    });

    const first = await service.listMeetings(owner, vaultId);
    if (!first.nextCursor) throw new Error("expected a continuation cursor");
    const second = await service.listMeetings(owner, vaultId, undefined, undefined, undefined, first.nextCursor);

    expect(first.items).toHaveLength(200);
    expect(first.nextCursor).toBeTypeOf("string");
    expect(second.items).toHaveLength(1);
    expect(second.nextCursor).toBeUndefined();
    expect(new Set([...first.items, ...second.items].map(({ meetingId }) => meetingId)).size).toBe(201);

    const app = createApp({ config: testConfig("file::memory:"), authStore: store });
    const response = await app.request(`/api/v1/vaults/${vaultId}/meetings?cursor=${encodeURIComponent(first.nextCursor)}`, {
      headers: { "x-forwarded-email": "owner@example.com", "x-forwarded-user": owner.userId },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ items: [expect.anything()] });
    await store.close?.();
  });

  it("paginates screenshots beyond the first read page", async () => {
    const { store } = await setup();
    const service = new MeetingSyncService(store.sync);
    const screenshots = Array.from({ length: 201 }, (_, index) => ({
      screenshotId: crypto.randomUUID(),
      capturedAt: new Date(Date.UTC(2026, 8, 2, 0, 0, index)),
      ocrText: null,
      caption: null,
    }));
    await store.sync.withIdentity(owner, async (sync) => {
      expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(true);
      for (const screenshot of screenshots) {
        expect(await sync.createScreenshot({
          ...screenshot,
          vaultId,
          meetingId,
          contentType: "image/png",
          storageKey: `meetings/${meetingId}/screenshots/${screenshot.screenshotId}.png`,
          contentLength: 3,
        })).toBe(true);
      }
      expect((await sync.commitManifest(manifest(null, screenshots))).committed).toBe(true);
    });

    const first = await service.listScreenshots(owner, vaultId, meetingId);
    if (!first.nextCursor) throw new Error("expected a continuation cursor");
    const second = await service.listScreenshots(owner, vaultId, meetingId, undefined, undefined, first.nextCursor);

    expect(first.items).toHaveLength(200);
    expect(second.items).toHaveLength(1);
    expect(second.nextCursor).toBeUndefined();
    expect(new Set([...first.items, ...second.items].map(({ screenshotId: id }) => id)).size).toBe(201);

    const app = createApp({ config: testConfig("file::memory:"), authStore: store });
    const response = await app.request(
      `/api/v1/vaults/${vaultId}/meetings/${meetingId}/screenshots?cursor=${encodeURIComponent(first.nextCursor)}`,
      { headers: { "x-forwarded-email": "owner@example.com", "x-forwarded-user": owner.userId } },
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ items: [expect.anything()] });
    await store.close?.();
  });

  it("paginates transcripts beyond the first read page", async () => {
    const segments: SyncTranscriptSegment[] = Array.from({ length: 10_001 }, (_, index) => ({
      segmentId: crypto.randomUUID(),
      startTime: new Date(Date.UTC(2026, 8, 2, 0, 0, index)),
      endTime: null,
      text: `${index}`,
      isConfirmed: true,
      audioSource: "system",
      speakerLabel: null,
    }));
    const listTranscript = vi.fn((
      _vaultId: string,
      _meetingId: string,
      limit: number,
      cursor?: { startTime: Date; segmentId: string },
    ) => Promise.resolve(segments.filter((segment) => !cursor
      || segment.startTime > cursor.startTime
      || (segment.startTime.getTime() === cursor.startTime.getTime() && segment.segmentId > cursor.segmentId))
    .slice(0, limit)));
    const store = {
      withIdentity: <T>(_identity: Identity, action: (sync: IdentitySyncStore) => Promise<T>) => action({
        listTranscript,
      } as unknown as IdentitySyncStore),
    } as MeetingSyncStore;
    const service = new MeetingSyncService(store);

    const first = await service.listTranscript(owner, vaultId, meetingId);
    if (!first.nextCursor) throw new Error("expected a continuation cursor");
    const second = await service.listTranscript(owner, vaultId, meetingId, first.nextCursor);

    expect(first.items).toHaveLength(10_000);
    expect(second.items).toHaveLength(1);
    expect(second.nextCursor).toBeUndefined();
    expect(listTranscript).toHaveBeenLastCalledWith(vaultId, meetingId, 10_001, expect.objectContaining({
      segmentId: first.items.at(-1)?.segmentId,
    }));
  });

  it("derives the deterministic object key from an allowlisted MIME type and relays safe headers", async () => {
    const { directory, store } = await setup();
    const storage = new LocalObjectStorage(join(directory, "objects"));
    const service = new MeetingSyncService(store.sync, storage);
    const bytes = new TextEncoder().encode("png-bytes");
    const request = new Request("http://localhost/upload", {
      method: "PUT",
      headers: {
        "content-length": String(bytes.byteLength),
        "content-type": "image/png",
        "x-dahlia-captured-at": "2026-09-02T00:00:00.000Z",
      },
      body: bytes,
    });
    const screenshot = await service.putScreenshot(owner, vaultId, meetingId, screenshotId, request);
    expect(screenshot.storageKey).toBe(`meetings/${meetingId}/screenshots/${screenshotId}.png`);
    expect(readFileSync(join(directory, "objects", screenshot.storageKey))).toEqual(Buffer.from(bytes));
    expect((await service.listScreenshots(owner, vaultId, meetingId)).items).toEqual([]);
    await expect(service.readScreenshot(
      owner,
      vaultId,
      meetingId,
      screenshotId,
      "GET",
      new Request("http://localhost/content"),
    )).rejects.toEqual(expect.objectContaining<Partial<ArtifactRequestError>>({
      status: 404,
      code: "screenshot_not_found",
    }));
    await service.commitManifest(owner, vaultId, meetingId, {
      name: "Meeting",
      projectId: null,
      description: "",
      status: "READY",
      duration: 60,
      recordingStartedAt: "2026-09-02T00:00:00.000Z",
      createdAt: "2026-09-02T00:00:00.000Z",
      updatedAt: "2026-09-02T00:00:00.000Z",
      summary: null,
      activeTranscriptGeneration: null,
      screenshots: [{
        screenshotId: screenshotId.toUpperCase(),
        capturedAt: "2026-09-02T00:00:00.000Z",
        ocrText: null,
        caption: null,
      }],
    });
    expect(existsSync(join(directory, "objects", screenshot.storageKey))).toBe(true);

    const response = await service.readScreenshot(
      owner,
      vaultId,
      meetingId,
      screenshotId,
      "GET",
      new Request("http://localhost/content"),
    );
    expect(response.headers.get("content-type")).toBe("image/png");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("content-security-policy")).toBe("sandbox allow-scripts");
    const stagedScreenshotId = "019d3f46-91e8-7ce0-ad52-bdd72825a61b";
    await service.putScreenshot(owner, vaultId, meetingId, stagedScreenshotId, new Request("http://localhost/upload", {
      method: "PUT",
      headers: {
        "content-length": String(bytes.byteLength),
        "content-type": "image/png",
        "x-dahlia-captured-at": "2026-09-02T00:00:01.000Z",
      },
      body: bytes,
    }));
    expect((await service.listScreenshots(owner, vaultId, meetingId)).items.map(({ screenshotId: id }) => id))
      .toEqual([screenshotId]);
    await expect(service.readScreenshot(
      owner,
      vaultId,
      "019d3f46-8b72-77f1-b232-93726eec3e9f",
      screenshotId,
      "GET",
      new Request("http://localhost/content"),
    )).rejects.toEqual(expect.objectContaining<Partial<ArtifactRequestError>>({
      status: 404,
      code: "screenshot_not_found",
    }));
    await service.commitManifest(owner, vaultId, meetingId, {
      name: "Meeting",
      projectId: null,
      description: "",
      status: "READY",
      duration: 60,
      recordingStartedAt: "2026-09-02T00:00:00.000Z",
      createdAt: "2026-09-02T00:00:00.000Z",
      updatedAt: "2026-09-02T00:00:00.000Z",
      summary: null,
      activeTranscriptGeneration: null,
      screenshots: [],
    });
    expect(existsSync(join(directory, "objects", screenshot.storageKey))).toBe(false);
    expect(existsSync(join(directory, "objects", `meetings/${meetingId}/screenshots/${stagedScreenshotId}.png`))).toBe(false);
    expect((await service.listScreenshots(owner, vaultId, meetingId)).items).toEqual([]);
    await store.close?.();
  });

  it("rejects SVG before reserving screenshot metadata", async () => {
    const { directory, store } = await setup();
    const service = new MeetingSyncService(store.sync, new LocalObjectStorage(join(directory, "objects")));
    const request = new Request("http://localhost/upload", {
      method: "PUT",
      headers: {
        "content-length": "6",
        "content-type": "image/svg+xml",
        "x-dahlia-captured-at": "2026-09-02T00:00:00.000Z",
      },
      body: "<svg/>",
    });
    await expect(service.putScreenshot(owner, vaultId, meetingId, screenshotId, request))
      .rejects.toEqual(expect.objectContaining<Partial<ArtifactRequestError>>({
        status: 415,
        code: "unsupported_screenshot_type",
      }));
    await store.close?.();
  });

  it("hides omitted screenshots before object deletion succeeds", async () => {
    const { directory, store } = await setup();
    const local = new LocalObjectStorage(join(directory, "objects"));
    const service = new MeetingSyncService(store.sync, local);
    const bytes = new TextEncoder().encode("png");
    await service.putScreenshot(owner, vaultId, meetingId, screenshotId, new Request("http://localhost/upload", {
      method: "PUT",
      headers: {
        "content-length": String(bytes.byteLength),
        "content-type": "image/png",
        "x-dahlia-captured-at": "2026-09-02T00:00:00.000Z",
      },
      body: bytes,
    }));
    await service.commitManifest(owner, vaultId, meetingId, manifestBody([{
      screenshotId,
      capturedAt: "2026-09-02T00:00:00.000Z",
      ocrText: null,
      caption: null,
    }]));
    const failingStorage: ObjectStorage = {
      put: (...arguments_) => local.put(...arguments_),
      exists: (key) => local.exists(key),
      read: (...arguments_) => local.read(...arguments_),
      delete: () => Promise.reject(new ObjectStorageError()),
    };
    const failingService = new MeetingSyncService(store.sync, failingStorage);

    await expect(failingService.commitManifest(owner, vaultId, meetingId, manifestBody([])))
      .rejects.toEqual(expect.objectContaining({ status: 502 }));
    expect((await service.listScreenshots(owner, vaultId, meetingId)).items).toEqual([]);
    await expect(service.readScreenshot(
      owner,
      vaultId,
      meetingId,
      screenshotId,
      "GET",
      new Request("http://localhost/content"),
    )).rejects.toEqual(expect.objectContaining({ status: 404, code: "screenshot_not_found" }));
    await store.close?.();
  });

  it("rejects manifests whose screenshot content was not uploaded", async () => {
    const { store } = await setup();
    const service = new MeetingSyncService(store.sync);
    await expect(service.commitManifest(owner, vaultId, meetingId, {
      name: "Meeting",
      projectId: null,
      description: "",
      status: "READY",
      duration: null,
      recordingStartedAt: null,
      createdAt: "2026-09-02T00:00:00.000Z",
      updatedAt: "2026-09-02T00:00:00.000Z",
      summary: null,
      activeTranscriptGeneration: null,
      screenshots: [{
        screenshotId,
        capturedAt: "2026-09-02T00:00:00.000Z",
        ocrText: null,
        caption: null,
      }],
    })).rejects.toEqual(expect.objectContaining<Partial<ArtifactRequestError>>({
      status: 409,
      code: "screenshot_content_missing",
    }));
    await store.close?.();
  });

  it("accepts only original transcript text", async () => {
    const { directory, store } = await setup();
    const service = new MeetingSyncService(store.sync, new LocalObjectStorage(join(directory, "objects")));
    await expect(service.putTranscriptChunk(owner, vaultId, meetingId, "a".repeat(64), {
      segments: [{
        segmentId: screenshotId,
        startTime: "2026-09-02T00:00:00.000Z",
        endTime: null,
        text: "original",
        translatedText: "not accepted",
        isConfirmed: true,
        audioSource: "system",
        speakerLabel: null,
      }],
    })).rejects.toEqual(expect.objectContaining<Partial<ArtifactRequestError>>({
      status: 400,
      code: "invalid_transcript_chunk",
    }));
    await store.close?.();
  });

  it("indexes server-tokenized meeting and screenshot text with FTS5", async () => {
    const { directory, store } = await setup();
    const service = new MeetingSyncService(store.sync, new LocalObjectStorage(join(directory, "objects")));
    const bytes = new TextEncoder().encode("png");
    await service.putScreenshot(owner, vaultId, meetingId, screenshotId, new Request("http://localhost/upload", {
      method: "PUT",
      headers: {
        "content-length": String(bytes.byteLength),
        "content-type": "image/png",
        "x-dahlia-captured-at": "2026-09-02T00:00:00.000Z",
      },
      body: bytes,
    }));
    await service.putTranscriptChunk(owner, vaultId, meetingId, "a".repeat(64), {
      segments: [{
        segmentId: screenshotId,
        startTime: "2026-09-02T00:00:00.000Z",
        endTime: null,
        text: "transcriptsecret",
        isConfirmed: true,
        audioSource: "system",
        speakerLabel: null,
      }],
    });
    await service.commitManifest(owner, vaultId, meetingId, {
      name: "Quarterly Alpha",
      projectId: null,
      description: "Roadmap",
      status: "READY",
      duration: 60,
      recordingStartedAt: "2026-09-02T00:00:00.000Z",
      createdAt: "2026-09-02T00:00:00.000Z",
      updatedAt: "2026-09-02T00:00:00.000Z",
      summary: {
        title: "Metadata title",
        document: JSON.stringify({
          description: "Budget overview",
          sections: [{
            heading: "Decision",
            blocks: [{ type: "paragraph", content: { text: "Budget approved", transcript_ref: { time: "00:01" } } }],
          }],
        }),
        createdAt: "2026-09-02T00:00:00.000Z",
      },
      activeTranscriptGeneration: "a".repeat(64),
      screenshots: [{
        screenshotId,
        capturedAt: "2026-09-02T00:00:00.000Z",
        ocrText: "Dashboard revenue",
        caption: "Growth chart",
      }],
    });

    const projectionDatabase = new DatabaseSync(join(directory, "server.sqlite"));
    const projection = projectionDatabase.prepare(
      "SELECT embedding_text FROM content_search_documents WHERE document_id = ?",
    ).get(meetingId) as { embedding_text: string };
    projectionDatabase.close();
    expect(projection.embedding_text).toContain("Budget approved");
    expect(projection.embedding_text).not.toContain("Quarterly Alpha");

    expect((await service.listMeetings(owner, vaultId, "alpha roadmap")).items).toHaveLength(1);
    expect((await service.listMeetings(owner, vaultId, "budget approved")).items).toHaveLength(1);
    expect((await service.listMeetings(owner, vaultId, "transcriptsecret")).items).toEqual([]);
    expect((await service.listScreenshots(owner, vaultId, meetingId, "revenue chart")).items).toHaveLength(1);
    const app = createApp({
      config: testConfig(join(directory, "server.sqlite")),
      authStore: store,
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    const apiSearch = await app.request(`/api/v1/vaults/${vaultId}/meetings?q=budget%20approved`, {
      headers: { "x-forwarded-email": "owner@example.com", "x-forwarded-user": owner.userId },
    });
    expect(apiSearch.status).toBe(200);
    expect(await apiSearch.json()).toEqual({ items: [expect.objectContaining({ meetingId })] });

    await service.commitManifest(owner, vaultId, meetingId, {
      name: "Replacement",
      projectId: null,
      description: "",
      status: "READY",
      duration: 60,
      recordingStartedAt: "2026-09-02T00:00:00.000Z",
      createdAt: "2026-09-02T00:00:00.000Z",
      updatedAt: "2026-09-02T00:01:00.000Z",
      summary: {
        title: "Ignored title",
        document: "invalid-json",
        createdAt: "2026-09-02T00:01:00.000Z",
      },
      activeTranscriptGeneration: "a".repeat(64),
      screenshots: [{
        screenshotId,
        capturedAt: "2026-09-02T00:00:00.000Z",
        ocrText: "Replacement screen",
        caption: null,
      }],
    });
    expect((await service.listMeetings(owner, vaultId, "budget")).items).toEqual([]);
    expect((await service.listMeetings(owner, vaultId, "replacement")).items).toHaveLength(1);
    expect((await service.listScreenshots(owner, vaultId, meetingId, "revenue")).items).toEqual([]);
    expect((await service.listScreenshots(owner, vaultId, meetingId, "replacement")).items).toHaveLength(1);

    const database = new DatabaseSync(join(directory, "server.sqlite"));
    database.exec("INSERT INTO content_search_documents_fts(content_search_documents_fts) VALUES('integrity-check')");
    database.close();
    expect(await service.deleteMeeting(owner, vaultId, meetingId)).toBe(true);
    expect((await service.listMeetings(owner, vaultId, "replacement")).items).toEqual([]);
    await store.close?.();
  });

  it("queues embeddings and returns vector-only SQLite results", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-sync-vector-"));
    directories.push(directory);
    const store = createNodeApplicationStore({
      ...testConfig(join(directory, "server.sqlite")),
      searchEmbedding: { model: "embedding-model", dimensions: 32 },
    });
    await store.migrate();
    await store.ensureIdentityUser(owner);
    await createVault(store, owner, vaultId);
    const vector = Array(32).fill(1) as number[];
    const tokenizer = { tokenize: (text: string) => text.toLowerCase().split(/\s+/).filter(Boolean) };
    const embedder = {
      model: "embedding-model",
      dimensions: 32,
      embedDocuments: () => Promise.resolve([vector]),
      embedQuery: () => Promise.resolve(vector),
    };
    const service = new MeetingSyncService(store.sync, undefined, tokenizer, embedder);
    const newerMeetingId = "019d3f46-8b72-77f1-b232-93726eec3e9f";
    for (const [id, createdAt] of [
      [meetingId, "2026-09-02T00:00:00.000Z"],
      [newerMeetingId, "2026-09-03T00:00:00.000Z"],
    ] as const) {
      await service.commitManifest(owner, vaultId, id, {
        name: "Planning",
      projectId: null,
        description: "",
        status: "READY",
        duration: 60,
        recordingStartedAt: createdAt,
        createdAt,
        updatedAt: createdAt,
        summary: {
          title: "Summary",
          document: JSON.stringify({ description: "Revenue outlook", sections: [] }),
          createdAt,
        },
        activeTranscriptGeneration: null,
        screenshots: [],
      });
    }
    await store.searchIndex!.reconcile("embedding-model", 32);
    const indexDatabase = new DatabaseSync(join(directory, "server.sqlite"));
    indexDatabase.exec("UPDATE core_search_index_jobs SET available_at = 0");
    indexDatabase.close();
    const jobs = await store.searchIndex!.claim("embedding-model", 32, 16);
    expect(jobs).toHaveLength(2);
    for (const job of jobs) {
      const document = await store.searchIndex!.load(job);
      expect(typeof document?.contentHash).toBe("string");
      expect(await store.searchIndex!.save(document!, "embedding-model", 32, vector)).toBe(true);
    }
    expect((await service.listMeetings(owner, vaultId, "semantic-only-query")).items.map(({ meetingId }) => meetingId))
      .toEqual([newerMeetingId, meetingId]);
    const embedQuery = vi.fn(() => Promise.resolve(vector));
    const noTokenService = new MeetingSyncService(
      store.sync,
      undefined,
      { tokenize: () => [] },
      { ...embedder, embedQuery },
    );
    expect((await noTokenService.listMeetings(owner, vaultId, "!!!")).items).toEqual([]);
    expect(embedQuery).not.toHaveBeenCalled();

    const guardedEmbedQuery = vi.fn(() => Promise.resolve(vector));
    const guardedService = new MeetingSyncService(store.sync, undefined, tokenizer, {
      ...embedder,
      embedQuery: guardedEmbedQuery,
    });
    expect((await guardedService.listMeetings(otherOwner, vaultId, "planning")).items).toEqual([]);
    expect(guardedEmbedQuery).not.toHaveBeenCalled();

    vi.useFakeTimers();
    try {
      let embeddingSignal: AbortSignal | undefined;
      const embedQuery = vi.fn((_query: string, signal?: AbortSignal) => {
        embeddingSignal = signal;
        return new Promise<number[]>(() => undefined);
      });
      const slowService = new MeetingSyncService(store.sync, undefined, tokenizer, {
        ...embedder,
        embedQuery,
      });
      const result = slowService.listMeetings(owner, vaultId, "planning");
      await expect(slowService.listMeetings(owner, vaultId, "planning")).resolves.toMatchObject({ items: { length: 2 } });
      expect(embedQuery).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(2_000);
      expect((await result).items).toHaveLength(2);
      expect(embeddingSignal?.aborted).toBe(true);
    } finally {
      vi.useRealTimers();
    }
    await store.close?.();
  });

  it("keeps projection rows isolated when a screenshot ID is reused as another Vault's meeting ID", async () => {
    const { store } = await setup();
    const otherVaultId = "019d3f46-a51b-7d37-860c-dda39ecf7482";
    await store.sync.withIdentity(owner, async (sync) => {
      expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(true);
      expect(await sync.createScreenshot({
        screenshotId,
        vaultId,
        meetingId,
        capturedAt: new Date("2026-09-02T00:00:00Z"),
        contentType: "image/png",
        storageKey: `meetings/${meetingId}/screenshots/${screenshotId}.png`,
        contentLength: 3,
        ocrText: null,
        caption: null,
      })).toBe(true);
      expect((await sync.commitManifest(manifest(null, [{
        screenshotId,
        capturedAt: new Date("2026-09-02T00:00:00Z"),
        ocrText: "victim projection",
        caption: null,
      }]))).committed).toBe(true);
    });
    await createVault(store, otherOwner, otherVaultId);
    await store.sync.withIdentity(otherOwner, async (sync) => {
      expect((await sync.commitManifest({
        ...manifest(null),
        vaultId: otherVaultId,
        meetingId: screenshotId,
        name: "attacker projection",
        searchText: "attacker projection",
      })).committed).toBe(true);
      expect(await sync.listMeetings(otherVaultId, { text: "attacker", tokens: ["attacker"] }, 10))
        .toHaveLength(1);
    });
    await store.sync.withIdentity(owner, async (sync) => {
      expect(await sync.listScreenshots(vaultId, meetingId, { text: "victim", tokens: ["victim"] }, 10))
        .toHaveLength(1);
    });
    await store.close?.();
  });

  it("removes queued embeddings when deletion starts", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-sync-vector-delete-"));
    directories.push(directory);
    const store = createNodeApplicationStore({
      ...testConfig(join(directory, "server.sqlite")),
      searchEmbedding: { model: "embedding-model", dimensions: 32 },
    });
    await store.migrate();
    await store.ensureIdentityUser(owner);
    await createVault(store, owner, vaultId);
    await store.sync.withIdentity(owner, async (sync) => {
      expect((await sync.commitManifest({
        ...manifest(null),
        embeddingText: "summary",
        embeddingContentHash: "hash",
      })).committed).toBe(true);
      expect(await sync.beginMeetingDeletion(vaultId, meetingId, 25)).toEqual([]);
    });
    const database = new DatabaseSync(join(directory, "server.sqlite"));
    database.exec("UPDATE core_search_index_jobs SET available_at = 0");
    database.close();
    expect(await store.searchIndex!.claim("embedding-model", 32, 16)).toEqual([]);
    await store.close?.();
  });

  it("shares personal vaults only with explicit organization or team members", async () => {
    const { directory, store } = await setup(false);
    const database = new DatabaseSync(join(directory, "server.sqlite"));
    const accountOwner = accountIdentity("account-owner");
    const member = accountIdentity("account-member");
    const outsider = accountIdentity("account-outsider");
    seedOrganization(database, "org-one", [accountOwner.userId, member.userId]);
    seedOrganization(database, "org-two", [accountOwner.userId]);
    seedTeam(database, "org-one-team", "org-one", [accountOwner.userId]);
    await createVault(store, accountOwner, vaultId);

    await store.sync.withIdentity(accountOwner, async (sync) => {
      expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(true);
      expect(await sync.putMemberPermission(vaultId, "organization", "org-one")).toBe(true);
      expect(await sync.putMemberPermission(vaultId, "organization", "org-two")).toBe(true);
      expect(await sync.putMemberPermission(vaultId, "team", "org-one-team")).toBe(true);
    });
    await store.sync.withIdentity(member, async (sync) => {
      expect(await sync.getVault(vaultId)).toMatchObject({ vaultId, role: "member" });
      expect(await sync.listPermissions(vaultId)).toEqual([
        expect.objectContaining({ principalType: "organization", principalId: "org-one", role: "member" }),
      ]);
      expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(false);
    });
    await store.sync.withIdentity(outsider, async (sync) => {
      expect(await sync.getVault(vaultId)).toBeNull();
      expect(await sync.listPermissions(vaultId)).toBeNull();
    });

    database.prepare("DELETE FROM member WHERE user_id = ? AND organization_id = ?")
      .run(member.userId, "org-one");
    await store.sync.withIdentity(member, async (sync) => {
      expect(await sync.getVault(vaultId)).toBeNull();
    });

    const headerVaultId = "019d3f46-a51b-7d37-860c-dda39ecf7482";
    const headerMeetingId = "019d3f46-a91d-7852-bdb6-1733b58db8a2";
    await createVault(store, owner, headerVaultId);
    await store.sync.withIdentity(owner, async (sync) => {
      expect(await sync.ensureUploadTarget(headerVaultId, headerMeetingId)).toBe(true);
      expect(await sync.putMemberPermission(headerVaultId, "organization", "external")).toBe(true);
    });
    await store.sync.withIdentity(otherOwner, async (sync) => {
      expect(await sync.getVault(headerVaultId)).toMatchObject({ vaultId: headerVaultId, role: "member" });
    });
    await store.deleteVaultPermissionsForOrganization("org-one");
    database.prepare("DELETE FROM organization WHERE id = ?").run("org-one");
    await store.sync.withIdentity(accountOwner, async (sync) => {
      const permissions = await sync.listPermissions(vaultId);
      expect(permissions).toHaveLength(2);
      expect(permissions?.map((permission) => permission.principalId))
        .toEqual(expect.arrayContaining(["account-owner", "org-two"]));
    });
    database.close();
    await store.close?.();
  });

  it("supports direct user members in the permission schema without granting writes or another owner", async () => {
    const { directory, store } = await setup();
    await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId));
    const database = new DatabaseSync(join(directory, "server.sqlite"));
    database.prepare(`
      INSERT INTO core_vault_permissions
        (vault_id, principal_type, principal_id, role, granted_by_user_id, created_at)
      VALUES (?, 'user', ?, 'member', ?, ?)
    `).run(vaultId, otherOwner.userId, owner.userId, Date.now());
    expect(() => database.prepare(`
      INSERT INTO core_vault_permissions
        (vault_id, principal_type, principal_id, role, granted_by_user_id, created_at)
      VALUES (?, 'user', 'second-owner', 'owner', ?, ?)
    `).run(vaultId, owner.userId, Date.now())).toThrow();
    expect(() => database.prepare(`
      INSERT INTO core_vault_permissions
        (vault_id, principal_type, principal_id, role, granted_by_user_id, created_at)
      VALUES (?, 'organization', 'org-owner', 'owner', ?, ?)
    `).run(vaultId, owner.userId, Date.now())).toThrow();
    database.close();

    await store.sync.withIdentity(otherOwner, async (sync) => {
      expect(await sync.getVault(vaultId)).toMatchObject({ role: "member" });
      expect(await sync.listPermissions(vaultId)).toEqual([
        expect.objectContaining({ principalType: "user", principalId: otherOwner.userId, role: "member" }),
      ]);
      expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(false);
      expect(await sync.beginVaultDeletion(vaultId, 25)).toBeNull();
      expect(await sync.putMemberPermission(vaultId, "organization", "external")).toBe(false);
    });
    await store.close?.();
  });

  it("keeps header Vault reads private until the owner shares with the external organization", async () => {
    const { directory, store } = await setup();
    await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId));
    const config = testConfig(join(directory, "server.sqlite"));
    const app = createApp({
      config,
      authStore: store,
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    const ownerHeaders = {
      "origin": config.baseUrl,
      "x-forwarded-email": "owner@example.com",
      "x-forwarded-user": owner.userId,
    };
    const otherHeaders = {
      "x-forwarded-email": "other@example.com",
      "x-forwarded-user": otherOwner.userId,
    };

    expect((await app.request(`/api/v1/vaults/${vaultId}`, { headers: otherHeaders })).status).toBe(404);
    expect((await app.request(`/api/v1/vaults/${vaultId}/shares`, { headers: ownerHeaders })).status).toBe(404);
    expect((await app.request(`/api/v1/vaults/${vaultId}/permissions/organizations/org-one`, {
      method: "PUT",
      headers: ownerHeaders,
    })).status).toBe(404);
    expect((await app.request(`/api/v1/vaults/${vaultId}/permissions/organizations/external`, {
      method: "PUT",
      headers: ownerHeaders,
    })).status).toBe(204);
    const ownerPermissions = await app.request(`/api/v1/vaults/${vaultId}/permissions`, { headers: ownerHeaders });
    const ownerPermissionBody = await ownerPermissions.json<{ items: unknown[] }>();
    expect(ownerPermissionBody.items).toEqual(expect.arrayContaining([
      expect.objectContaining({ principalType: "user", role: "owner" }),
      expect.objectContaining({ principalType: "organization", principalId: "external", role: "member" }),
    ]));
    expect((await app.request(`/api/v1/vaults/${vaultId}`, { headers: otherHeaders })).status).toBe(200);
    const memberPermissions = await app.request(`/api/v1/vaults/${vaultId}/permissions`, { headers: otherHeaders });
    expect(await memberPermissions.json()).toEqual({ items: [
      expect.objectContaining({ principalType: "organization", principalId: "external", role: "member" }),
    ] });
    expect((await app.request(`/api/v1/vaults/${vaultId}/permissions/organizations/external`, {
      method: "DELETE",
      headers: { ...otherHeaders, origin: config.baseUrl },
    })).status).toBe(404);
    expect((await app.request(`/api/v1/vaults/${vaultId}/permissions/organizations/external`, {
      method: "DELETE",
      headers: { ...ownerHeaders, origin: "https://attacker.example" },
    })).status).toBe(403);
    expect((await app.request(`/api/v1/vaults/${vaultId}/permissions/organizations/external`, {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(204);
    expect((await app.request(`/api/v1/vaults/${vaultId}/permissions/header-deployment`, {
      method: "PUT",
      headers: ownerHeaders,
    })).status).toBe(404);
    expect((await app.request(`/api/v1/vaults/${vaultId}`, { headers: otherHeaders })).status).toBe(404);
    await store.close?.();
  });

  it("keeps Vault sharing routes disabled unless explicitly enabled", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-sync-sharing-off-"));
    directories.push(directory);
    const config = { ...testConfig(join(directory, "server.sqlite")), syncSharingEnabled: false };
    const store = createNodeApplicationStore(config);
    await store.migrate();
    await store.ensureIdentityUser(owner);
    await store.ensureIdentityUser(otherOwner);
    await createVault(store, owner, vaultId);
    const app = createApp({
      config,
      authStore: store,
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    const headers = {
      "origin": config.baseUrl,
      "x-forwarded-email": "owner@example.com",
      "x-forwarded-user": owner.userId,
    };
    await store.sync.withIdentity(owner, async (sync) => {
      await sync.ensureUploadTarget(vaultId, meetingId);
      expect(await sync.putMemberPermission(vaultId, "organization", "external")).toBe(true);
    });
    expect(await store.sync.withIdentity(otherOwner, (sync) => sync.getVault(vaultId))).toBeNull();
    await expect((await app.request("/api/session", { headers })).json()).resolves.toMatchObject({
      capabilities: { sharing: false },
    });
    expect((await app.request(`/api/v1/vaults/${vaultId}/permissions/organizations/external`, {
      method: "PUT",
      headers,
    })).status).toBe(404);
    expect((await app.request("/api/v1/organizations/external/members", { headers })).status).toBe(404);
    await store.close?.();
  });

  it("lets the external organization owner manage teams and team-scoped Vault access", async () => {
    const { directory, store } = await setup();
    const config = testConfig(join(directory, "server.sqlite"));
    const app = createApp({
      config,
      authStore: store,
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    const ownerHeaders = {
      "origin": config.baseUrl,
      "x-forwarded-email": "owner@example.com",
      "x-forwarded-user": owner.userId,
    };
    const memberHeaders = {
      "origin": config.baseUrl,
      "x-forwarded-email": "other@example.com",
      "x-forwarded-user": otherOwner.userId,
    };
    expect((await app.request("/api/v1/organizations", { headers: memberHeaders })).status).toBe(200);
    expect((await app.request("/api/v1/organizations/external/teams", {
      method: "POST",
      headers: memberHeaders,
      body: JSON.stringify({ name: "Readers" }),
    })).status).toBe(404);
    const created = await app.request("/api/v1/organizations/external/teams", {
      method: "POST",
      headers: ownerHeaders,
      body: JSON.stringify({ name: "Readers" }),
    });
    expect(created.status).toBe(201);
    const team = await created.json<{ id: string }>();
    expect((await app.request("/api/v1/organizations/external/teams/external-default", {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(404);
    expect((await app.request(`/api/v1/organizations/external/teams/external-default/members/${owner.userId}`, {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(404);
    expect((await app.request(`/api/v1/organizations/external/teams/${team.id}/members/${otherOwner.userId}`, {
      method: "PUT",
      headers: ownerHeaders,
    })).status).toBe(204);

    const teamVaultId = "019d3f46-a51b-7d37-860c-dda39ecf7482";
    const teamMeetingId = "019d3f46-a91d-7852-bdb6-1733b58db8a2";
    await createVault(store, owner, teamVaultId);
    await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(teamVaultId, teamMeetingId));
    expect((await app.request(`/api/v1/vaults/${teamVaultId}/permissions/teams/${team.id}`, {
      method: "PUT",
      headers: ownerHeaders,
    })).status).toBe(204);
    expect((await app.request(`/api/v1/vaults/${teamVaultId}`, { headers: memberHeaders })).status).toBe(200);
    expect((await app.request(`/api/v1/organizations/external/teams/${team.id}/members/${otherOwner.userId}`, {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(204);
    expect((await app.request(`/api/v1/vaults/${teamVaultId}`, { headers: memberHeaders })).status).toBe(404);
    expect((await app.request(`/api/v1/organizations/external/teams/${team.id}`, {
      method: "DELETE",
      headers: ownerHeaders,
    })).status).toBe(204);
    await store.close?.();
  });

});

async function setup(createDefaultVault = true) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-sync-"));
  directories.push(directory);
  const store = createNodeApplicationStore(testConfig(join(directory, "server.sqlite")));
  await store.migrate();
  await store.ensureIdentityUser(owner);
  await store.ensureIdentityUser(otherOwner);
  if (createDefaultVault) await createVault(store, owner, vaultId);
  return { directory, store };
}

async function createVault(
  store: ReturnType<typeof createNodeApplicationStore>,
  identity: Identity,
  id: string,
) {
  expect(await store.sync.withIdentity(identity, (sync) => sync.commitVaultManifest({
    vaultId: id,
    name: "Vault",
    createdAt: new Date("2026-09-02T00:00:00Z"),
    projects: [],
  }))).toBe(true);
}

function manifestBody(screenshots: Array<{
  screenshotId: string;
  capturedAt: string;
  ocrText: string | null;
  caption: string | null;
}>) {
  return {
    projectId: null,
    name: "Meeting",
    description: "",
    status: "READY",
    duration: 60,
    recordingStartedAt: "2026-09-02T00:00:00.000Z",
    createdAt: "2026-09-02T00:00:00.000Z",
    updatedAt: "2026-09-02T00:00:00.000Z",
    summary: null,
    activeTranscriptGeneration: null,
    screenshots,
  };
}

function manifest(
  activeTranscriptGeneration: string | null,
  screenshots: Array<{ screenshotId: string; capturedAt: Date; ocrText: string | null; caption: string | null }> = [],
) {
  const now = new Date("2026-09-02T00:00:00Z");
  return {
    vaultId,
    meetingId,
    projectId: null,
    name: "Meeting",
    description: "",
    status: "READY",
    duration: 60,
    recordingStartedAt: now,
    createdAt: now,
    updatedAt: now,
    summaryTitle: "Summary",
    summaryDocument: "Document",
    summaryCreatedAt: now,
    activeTranscriptGeneration,
    searchText: "meeting",
    embeddingText: null,
    embeddingContentHash: null,
    screenshots: screenshots.map((screenshot) => ({
      ...screenshot,
      searchText: screenshot.ocrText ?? "",
      embeddingText: screenshot.ocrText,
      embeddingContentHash: screenshot.ocrText ? "screenshot-hash" : null,
    })),
  };
}

function testConfig(path: string): AppConfig {
  return {
    authProvider: "header",
    authHeader: "X-Forwarded-Email",
    databaseType: "sqlite",
    databaseUrl: `file:${path}`,
    baseUrl: "http://localhost:5173",
    oauthRedirectUris: [],
    maxRequestBytes: 1024,
    syncSharingEnabled: true,
  };
}

function accountIdentity(userId: string): Identity {
  return { userId, workspaceId: `personal:${userId}`, source: "accounts" };
}

function seedOrganization(database: DatabaseSync, organizationId: string, userIds: string[]): void {
  const now = Date.now();
  const insertUser = database.prepare(`
    INSERT OR IGNORE INTO user (id, name, email, email_verified, created_at, updated_at)
    VALUES (?, ?, ?, 1, ?, ?)
  `);
  const insertMember = database.prepare(`
    INSERT INTO member (id, organization_id, user_id, role, created_at)
    VALUES (?, ?, ?, 'member', ?)
  `);
  for (const userId of userIds) {
    insertUser.run(userId, userId, `${userId}@example.com`, now, now);
  }
  database.prepare("INSERT INTO organization (id, name, slug, created_at) VALUES (?, ?, ?, ?)")
    .run(organizationId, organizationId, organizationId, now);
  for (const userId of userIds) insertMember.run(`${organizationId}:${userId}`, organizationId, userId, now);
}

function seedTeam(database: DatabaseSync, teamId: string, organizationId: string, userIds: string[]): void {
  const now = Date.now();
  database.prepare(`
    INSERT INTO team (id, name, organization_id, created_at, updated_at, member_count)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(teamId, teamId, organizationId, now, now, userIds.length);
  const insert = database.prepare(`
    INSERT INTO team_member (id, team_id, user_id, created_at)
    VALUES (?, ?, ?, ?)
  `);
  for (const userId of userIds) insert.run(`${teamId}:${userId}`, teamId, userId, now);
}
