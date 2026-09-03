import { afterEach, describe, expect, it } from "vitest";

import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import type { Identity } from "../src/auth/identity";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { LocalObjectStorage } from "../src/artifacts/local";
import { createApp } from "../src/app";
import type { AppConfig } from "../src/config";
import { MeetingSyncService } from "../src/sync/service";
import type { SyncTransaction } from "../src/sync/types";

const directories: string[] = [];
const owner: Identity = { userId: "owner", workspaceId: "personal:owner", source: "header" };
const other: Identity = { userId: "other", workspaceId: "personal:other", source: "header" };
const vaultId = "019d3f46-7e0d-7d21-98d9-f1456c0bfb58";
const meetingId = "019d3f46-8b72-77f1-b232-93726eec3e9e";
const projectId = "019d3f46-8c00-7000-8000-000000000001";
const segmentId = "019d3f46-8d00-7000-8000-000000000001";
const screenshotId = "019d3f46-91e8-7ce0-ad52-bdd72825a61a";
const now = new Date("2026-09-03T00:00:00.000Z");

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true });
});

describe("SQLite canonical sync", () => {
  it("commits atomic domain transactions and replays the same idempotency key", async () => {
    const { store } = await setup();
    const create = transaction("019d4a01-0000-7000-8000-000000000001", [{
      id: "019d4a01-0000-7000-8000-000000000002",
      entity: "vault",
      action: "create",
      entityId: vaultId,
      baseRevision: null,
      data: { name: "Offline Vault", createdAt: now },
    }]);
    const first = await commit(store, owner, create);
    expect(await commit(store, owner, create)).toEqual(first);
    expect(first).toMatchObject({ status: "committed", records: [{ entity: "vault", revision: 1 }] });

    const failed = transaction("019d4a01-0000-7000-8000-000000000003", [
      {
        id: "019d4a01-0000-7000-8000-000000000004",
        entity: "project",
        action: "create",
        entityId: projectId,
        baseRevision: null,
        data: projectData("Duplicate"),
      },
      {
        id: "019d4a01-0000-7000-8000-000000000005",
        entity: "project",
        action: "create",
        entityId: "019d3f46-8c00-7000-8000-000000000002",
        baseRevision: null,
        data: projectData("duplicate"),
      },
    ]);
    await expect(commit(store, owner, failed)).rejects.toThrow();
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toEqual([]);

    await expect(commit(store, owner, { ...create, requestHash: "different-payload" }))
      .rejects.toMatchObject({ status: 409, code: "idempotency_key_reused" });
    await store.close?.();
  });

  it("returns canonical revision conflicts, including a deleted canonical record", async () => {
    const { store } = await setup();
    await createVault(store);
    await expect(commit(store, owner, transaction("019d4a01-1000-7000-8000-000000000001", [{
      id: "019d4a01-1000-7000-8000-000000000002",
      entity: "vault",
      action: "update",
      entityId: vaultId,
      baseRevision: 0,
      data: { name: "Wrong base" },
    }]))).rejects.toMatchObject({
      status: 409,
      code: "revision_conflict",
      conflicts: [{ entity: "vault", serverRevision: 1 }],
    });
    await expect(commit(store, owner, transaction("019d4a01-1000-7000-8000-000000000003", [{
      id: "019d4a01-1000-7000-8000-000000000004",
      entity: "project",
      action: "update",
      entityId: projectId,
      baseRevision: 1,
      data: projectData("Missing"),
    }]))).rejects.toMatchObject({
      status: 409,
      code: "revision_conflict",
      conflicts: [{ entity: "project", serverRevision: null, record: null }],
    });
    expect(await store.sync.withIdentity(other, (sync) => sync.getVault(vaultId))).toBeNull();
    await store.close?.();
  });

  it("starts a recreated Vault change feed after its latest reset", async () => {
    const { store } = await setup();
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-1100-7000-8000-000000000001", [{
      id: "019d4a01-1100-7000-8000-000000000002",
      entity: "vault",
      action: "reset",
      entityId: vaultId,
      baseRevision: 1,
      data: {},
    }]));
    const recreatedId = "019d4a01-1100-7000-8000-000000000003";
    await commit(store, owner, transaction(recreatedId, [{
      id: "019d4a01-1100-7000-8000-000000000004",
      entity: "vault",
      action: "create",
      entityId: vaultId,
      baseRevision: null,
      data: { name: "Restored", createdAt: now },
    }]));

    const changes = await store.sync.withIdentity(owner, (sync) => sync.listChanges(vaultId, 0, 100));
    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({ transactionId: recreatedId, action: "upsert", entity: "vault" });
    const existingClientChanges = await store.sync.withIdentity(owner, (sync) => sync.listChanges(vaultId, 1, 100));
    expect(existingClientChanges.map(({ action }) => action)).toEqual(["reset", "upsert"]);
    await store.close?.();
  });

  it("applies explicit project, meeting, summary, and transcript patch operations", async () => {
    const { store } = await setup();
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-2000-7000-8000-000000000001", [
      {
        id: "019d4a01-2000-7000-8000-000000000002",
        entity: "project",
        action: "create",
        entityId: projectId,
        baseRevision: null,
        data: projectData("Project"),
      },
      {
        id: "019d4a01-2000-7000-8000-000000000003",
        entity: "meeting",
        action: "create",
        entityId: meetingId,
        baseRevision: null,
        data: meetingData(),
      },
      {
        id: "019d4a01-2000-7000-8000-000000000004",
        entity: "summary",
        action: "upsert",
        entityId: meetingId,
        baseRevision: 0,
        data: { title: "Summary", document: "body", createdAt: now },
      },
    ]));

    const patchId = "019d4a01-2000-7000-8000-000000000005";
    const chunkHash = "a".repeat(64);
    await expect(new MeetingSyncService(store.sync).putTranscriptChunk(
      owner,
      vaultId,
      meetingId,
      patchId,
      0,
      chunkHash,
      {
        segments: [{
          segmentId,
          startTime: now,
          endTime: null,
          text: "preview",
          isConfirmed: false,
          audioSource: "system",
          speakerLabel: null,
        }],
        deletions: [],
      },
    )).rejects.toMatchObject({ status: 400, code: "invalid_transcript_chunk" });
    expect(await store.sync.withIdentity(owner, (sync) => sync.putTranscriptChunk(
      vaultId,
      meetingId,
      patchId,
      0,
      chunkHash,
      [{
        segmentId,
        startTime: now,
        endTime: null,
        text: "original",
        isConfirmed: true,
        audioSource: "system",
        speakerLabel: null,
      }],
      [],
    ))).toBe(true);
    await commit(store, owner, transaction("019d4a01-2000-7000-8000-000000000006", [{
      id: patchId,
      entity: "transcript",
      action: "patch",
      entityId: meetingId,
      baseRevision: 0,
      data: {
        patchId,
        segmentCount: 1,
        deletionCount: 0,
        chunks: [{ index: 0, sha256: chunkHash, segmentCount: 1, deletionCount: 0 }],
      },
    }]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.listTranscript(vaultId, meetingId, 10)))
      .toEqual([expect.objectContaining({ segmentId, text: "original", audioSource: "system" })]);

    await commit(store, owner, transaction("019d4a01-2000-7000-8000-000000000007", [
      {
        id: "019d4a01-2000-7000-8000-000000000008",
        entity: "meeting",
        action: "update",
        entityId: meetingId,
        baseRevision: 1,
        data: { ...meetingData(), projectId: null },
      },
      {
        id: "019d4a01-2000-7000-8000-000000000009",
        entity: "project",
        action: "delete",
        entityId: projectId,
        baseRevision: 1,
        data: {},
      },
    ]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toEqual([]);
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId)))
      .toMatchObject({ projectId: null, summaryTitle: "Summary" });
    await store.close?.();
  });

  it("rejects project hierarchies deeper than two levels and missing meeting projects", async () => {
    const { store } = await setup();
    await createVault(store);
    const childId = "019d4a01-2800-7000-8000-000000000001";
    const grandchildId = "019d4a01-2800-7000-8000-000000000002";
    await expect(commit(store, owner, transaction("019d4a01-2800-7000-8000-000000000003", [
      {
        id: "019d4a01-2800-7000-8000-000000000004",
        entity: "project",
        action: "create",
        entityId: projectId,
        baseRevision: null,
        data: projectData("Root"),
      },
      {
        id: "019d4a01-2800-7000-8000-000000000005",
        entity: "project",
        action: "create",
        entityId: childId,
        baseRevision: null,
        data: { ...projectData("Child"), parentProjectId: projectId, projectType: null },
      },
      {
        id: "019d4a01-2800-7000-8000-000000000006",
        entity: "project",
        action: "create",
        entityId: grandchildId,
        baseRevision: null,
        data: { ...projectData("Grandchild"), parentProjectId: childId, projectType: null },
      },
    ]))).rejects.toMatchObject({
      status: 422,
      code: "invalid_project_parent",
      operationId: "019d4a01-2800-7000-8000-000000000006",
    });
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toEqual([]);

    await expect(commit(store, owner, transaction("019d4a01-2800-7000-8000-000000000007", [{
      id: "019d4a01-2800-7000-8000-000000000008",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: meetingData(),
    }]))).rejects.toMatchObject({
      status: 422,
      code: "project_not_found",
      operationId: "019d4a01-2800-7000-8000-000000000008",
    });
    await store.close?.();
  });

  it("reports the rejected operation ID and removes obsolete manifest routes", async () => {
    const { directory, store } = await setup();
    const app = createApp({
      config: testConfig(join(directory, "server.sqlite")),
      authStore: store,
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    const operationId = "019d4a01-3000-7000-8000-000000000002";
    const response = await app.request("/api/v1/transactions", {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({
        schemaVersion: 1,
        id: "019d4a01-3000-7000-8000-000000000001",
        vaultId,
        createdAt: now,
        operations: [{
          id: operationId,
          entity: "vault",
          action: "update",
          entityId: vaultId,
          baseRevision: 1,
          data: { unexpected: true },
        }],
      }),
    });
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "invalid_sync_operation", operationId });
    expect((await app.request(`/api/v1/vaults/${vaultId}/manifest`, { method: "PUT", headers: headers() })).status)
      .toBe(404);
    await expect(new MeetingSyncService(store.sync).commitTransaction(
      { ...owner, impersonated: true },
      {},
    )).rejects.toMatchObject({ status: 403, code: "impersonated_session_read_only" });
    await store.close?.();
  });

  it("verifies screenshot bytes against the immutable content hash", async () => {
    const { directory, store } = await setup();
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-4000-7000-8000-000000000001", [{
      id: "019d4a01-4000-7000-8000-000000000002",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: { ...meetingData(), projectId: null },
    }]));
    const objectRoot = join(directory, "objects");
    const app = createApp({
      config: testConfig(join(directory, "server.sqlite")),
      authStore: store,
      artifactStorage: new LocalObjectStorage(objectRoot),
    });
    const response = await app.request(
      `/api/v1/vaults/${vaultId}/meetings/${meetingId}/screenshots/${screenshotId}/content`,
      {
        method: "PUT",
        headers: {
          ...headers(),
          "content-length": "3",
          "content-type": "image/png",
          "x-dahlia-captured-at": now.toISOString(),
          "x-dahlia-content-sha256": "0".repeat(64),
        },
        body: new Uint8Array([1, 2, 3]),
      },
    );
    expect(response.status).toBe(409);
    expect(existsSync(join(objectRoot, `meetings/${meetingId}/screenshots/${screenshotId}.png`))).toBe(false);
    await store.close?.();
  });

  it("rejects and removes stale stored screenshot bytes before accepting a retry", async () => {
    const { directory, store } = await setup();
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-4100-7000-8000-000000000001", [{
      id: "019d4a01-4100-7000-8000-000000000002",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: { ...meetingData(), projectId: null },
    }]));
    const objectRoot = join(directory, "objects");
    const objectPath = join(objectRoot, `meetings/${meetingId}/screenshots/${screenshotId}.png`);
    const app = createApp({
      config: testConfig(join(directory, "server.sqlite")),
      authStore: store,
      artifactStorage: new LocalObjectStorage(objectRoot),
    });
    const bytes = new Uint8Array([1, 2, 3]);
    const contentHash = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
    const upload = () => app.request(
      `/api/v1/vaults/${vaultId}/meetings/${meetingId}/screenshots/${screenshotId}/content`,
      {
        method: "PUT",
        headers: {
          ...headers(),
          "content-length": String(bytes.length),
          "content-type": "image/png",
          "x-dahlia-captured-at": now.toISOString(),
          "x-dahlia-content-sha256": contentHash,
        },
        body: bytes,
      },
    );

    expect((await upload()).status).toBe(200);
    writeFileSync(objectPath, new Uint8Array([4, 5, 6]));
    expect((await upload()).status).toBe(503);
    expect(existsSync(objectPath)).toBe(false);
    expect((await upload()).status).toBe(200);
    expect(readFileSync(objectPath)).toEqual(Buffer.from(bytes));
    await store.close?.();
  });

  it("does not accept a restored screenshot while its old storage deletion is pending", async () => {
    const { store } = await setup();
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-4200-7000-8000-000000000001", [{
      id: "019d4a01-4200-7000-8000-000000000002",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: { ...meetingData(), projectId: null },
    }]));
    const storageKey = `meetings/${meetingId}/screenshots/${screenshotId}.png`;
    expect(await store.sync.withIdentity(owner, (sync) => sync.createScreenshot({
      screenshotId,
      vaultId,
      meetingId,
      capturedAt: now,
      contentType: "image/png",
      storageKey,
      contentLength: 3,
      contentHash: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
      ocrText: null,
      caption: null,
      revision: 0,
    }))).toBe(true);
    await commit(store, owner, transaction("019d4a01-4200-7000-8000-000000000003", [{
      id: "019d4a01-4200-7000-8000-000000000004",
      entity: "vault",
      action: "reset",
      entityId: vaultId,
      baseRevision: 1,
      data: {},
    }]));
    await commit(store, owner, transaction("019d4a01-4200-7000-8000-000000000005", [{
      id: "019d4a01-4200-7000-8000-000000000006",
      entity: "vault",
      action: "create",
      entityId: vaultId,
      baseRevision: null,
      data: { name: "Restored", createdAt: now },
    }, {
      id: "019d4a01-4200-7000-8000-000000000007",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: { ...meetingData(), projectId: null },
    }]));
    const storage = {
      put: async () => undefined,
      exists: async () => true,
      read: async () => new Response(new Uint8Array([1, 2, 3])),
      delete: () => new Promise<void>(() => undefined),
    };
    const service = new MeetingSyncService(store.sync, storage);
    await expect(service.putScreenshot(owner, vaultId, meetingId, screenshotId, new Request("https://server.test", {
      method: "PUT",
      headers: {
        "content-length": "3",
        "content-type": "image/png",
        "x-dahlia-captured-at": now.toISOString(),
        "x-dahlia-content-sha256": "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
      },
      body: new Uint8Array([1, 2, 3]),
    }))).rejects.toMatchObject({ status: 503, code: "screenshot_storage_delete_pending" });
    expect(await store.sync.hasStorageDelete(storageKey)).toBe(true);
    await store.close?.();
  });

  it("stores canonical transcript rows without a generation and keeps FTS projection", async () => {
    const { databasePath, store } = await setup();
    const database = new DatabaseSync(databasePath);
    const transcriptColumns = database.prepare("pragma table_info('content_transcript_segments')").all()
      .map((row) => (row as { name: string }).name);
    expect(transcriptColumns).not.toContain("generation");
    expect(database.prepare("pragma table_info('content_meetings')").all()
      .map((row) => (row as { name: string }).name)).toContain("active");
    expect(database.prepare("select name from sqlite_master where name = 'content_search_documents_fts'").get())
      .toBeTruthy();
    database.close();
    await store.close?.();
  });
});

async function setup() {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-sync-"));
  directories.push(directory);
  const databasePath = join(directory, "server.sqlite");
  const store = createNodeApplicationStore(testConfig(databasePath));
  await store.migrate();
  await store.ensureIdentityUser(owner);
  await store.ensureIdentityUser(other);
  return { databasePath, directory, store };
}

async function createVault(store: ReturnType<typeof createNodeApplicationStore>) {
  return commit(store, owner, transaction("019d4a00-0000-7000-8000-000000000001", [{
    id: "019d4a00-0000-7000-8000-000000000002",
    entity: "vault",
    action: "create",
    entityId: vaultId,
    baseRevision: null,
    data: { name: "Vault", createdAt: now },
  }]));
}

function transaction(id: string, operations: SyncTransaction["operations"]): SyncTransaction {
  return { schemaVersion: 1, id, vaultId, createdAt: now, requestHash: id, operations };
}

function commit(
  store: ReturnType<typeof createNodeApplicationStore>,
  identity: Identity,
  value: SyncTransaction,
) {
  return store.sync.withIdentity(identity, (sync) => sync.commitTransaction(value));
}

function projectData(name: string) {
  return { parentProjectId: null, name, description: "", projectType: "internal", createdAt: now };
}

function meetingData() {
  return {
    projectId,
    name: "Meeting",
    description: "",
    status: "READY",
    duration: 60,
    recordingStartedAt: now,
    createdAt: now,
    updatedAt: now,
  };
}

function headers() {
  return {
    "content-type": "application/json",
    origin: "http://localhost:5173",
    "x-forwarded-email": "owner@example.com",
    "x-forwarded-user": owner.userId,
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
    maxRequestBytes: 1024 * 1024,
    syncSharingEnabled: true,
  };
}
