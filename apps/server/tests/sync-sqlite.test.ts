import { encodeId } from "../src/typeid";
import { wireValue } from "../src/public-wire";
import { seedHeaderIdentity, testUserID } from "./public-test-client";
import { z } from "zod";
import { afterEach, describe, expect, it, vi } from "vitest";

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import type { Identity } from "../src/auth/identity";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { LocalObjectStorage } from "../src/storage/local";
import { createContractApp as createApp } from "./api-test-client";
import { createWorkerHandler } from "../src/worker";
import type { AppConfig } from "../src/config";
import { MeetingSyncService } from "../src/sync/service";
import { transformScreenshot } from "../src/sync/node-screenshot-transformer";
import { fileStorageKey, fileVariantKey } from "../src/files/model";
import sharp from "sharp";
import { SCREENSHOT_VARIANTS } from "../src/sync/screenshot-variants";
import type { SyncTransaction } from "../src/sync/types";
import { ImageAnalysisWorker } from "../src/image-analysis/node-worker";
import type { ImageCaptioner } from "../src/image-analysis/captioner";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings } from "../src/account-settings";
import { ImageAnalysisError } from "../src/image-analysis/model";

const directories: string[] = [];
const owner: Identity = { userId: testUserID("owner"), workspaceId: `personal:${testUserID("owner")}`, source: "header" };
const other: Identity = { userId: testUserID("other"), workspaceId: `personal:${testUserID("other")}`, source: "header" };
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
  it("round trips calendar occurrence identity and preserves it when an editor omits it", async () => {
    const { store } = await setup();
    await createVault(store);
    const service = new MeetingSyncService(store.sync);
    const identity = { icalUid: "shared@example.com", recurrenceId: "20260903T000000Z",
      calendarEvent: { start: "2026-09-03T09:00:00+09:00", end: "2026-09-03T10:00:00+09:00", is_all_day: false } };
    const data = { ...meetingData(), projectId: null, createdAt: now.toISOString(), updatedAt: now.toISOString(), recordingStartedAt: now.toISOString() };
    try {
      const receipt = await service.commitTransaction(owner, wire([{ entity: "meeting", action: "create", entityId: meetingId,
        baseRevision: null, data: { ...data, ...identity } }]));
      expect(receipt.records.find((record) => record.entity === "meeting")?.record).toMatchObject(identity);
      const read = () => store.sync.withIdentity(owner, (scoped) => scoped.getMeeting(vaultId, meetingId));
      expect(await read()).toMatchObject(identity);
      expect((await service.listSnapshot(owner, vaultId)).items.find((record) => record.entity === "meeting")?.record).toMatchObject(identity);
      expect((await service.listChanges(owner, vaultId)).items.find((record) => record.entity === "meeting")?.record).toMatchObject(identity);
      const update: Partial<typeof data> = { ...data };
      delete update.createdAt;
      await service.commitTransaction(owner, wire([{ entity: "meeting", action: "update", entityId: meetingId,
        baseRevision: 1, data: { ...update, name: "Renamed" } }]));
      expect(await read()).toMatchObject(identity);
      for (const recurrence of [identity.recurrenceId, "20260910T000000Z", "20260910", ""]) {
        const id = freshId();
        await service.commitTransaction(owner, wire([{ entity: "meeting", action: "create", entityId: id,
          baseRevision: null, data: { ...data, ...identity, recurrenceId: recurrence } }]));
        expect(await store.sync.withIdentity(owner, (scoped) => scoped.getMeeting(vaultId, id)))
          .toMatchObject({ ...identity, recurrenceId: recurrence });
      }
      await expect(service.commitTransaction(owner, wire([{ entity: "meeting", action: "update", entityId: meetingId,
        baseRevision: 2, data: { ...update, icalUid: "incomplete" } }]))).rejects.toThrow();
      for (const calendarEvent of [
        { start: "invalid", end: identity.calendarEvent.end, is_all_day: false },
        { start: identity.calendarEvent.end, end: identity.calendarEvent.start, is_all_day: false },
        { start: "2026-09-03T00:00:00.0009Z", end: "2026-09-03T00:00:00.0001Z", is_all_day: false },
        { ...identity.calendarEvent, is_all_day: "false" },
        { ...identity.calendarEvent, title: "not part of the snapshot" },
      ]) {
        await expect(service.commitTransaction(owner, wire([{ entity: "meeting", action: "update", entityId: meetingId,
          baseRevision: 2, data: { ...update, calendarEvent } }]))).rejects.toThrow();
      }
      const equalEvent = { start: "2026-09-03T00:00:00.123456Z", end: "2026-09-03T09:00:00.123456+09:00", is_all_day: false };
      await service.commitTransaction(owner, wire([{ entity: "meeting", action: "update", entityId: meetingId,
        baseRevision: 2, data: { ...update, calendarEvent: equalEvent } }]));
      expect(await read()).toMatchObject({ calendarEvent: equalEvent });
      await service.commitTransaction(owner, wire([{ entity: "meeting", action: "update", entityId: meetingId,
        baseRevision: 3, data: { ...update, icalUid: null, recurrenceId: null, calendarEvent: null } }]));
      expect(await read()).toMatchObject({ icalUid: null, recurrenceId: null, calendarEvent: null });
    } finally { await store.close?.(); }
  });

  it("invalidates embeddings by current search input and rejects stale models and deleted results", async () => {
    const { store, databasePath } = await setup({ model: "model", dimensions: 32 });
    await createVault(store);
    const service = new MeetingSyncService(store.sync);
    const raw = new DatabaseSync(databasePath);
    const vector = [1, ...new Array<number>(31).fill(0)];
    const index = store.searchIndex!;
    const claim = async (model = "model") => {
      raw.exec("UPDATE jobs_search_index SET available_at = 0");
      const jobs = await index.claim(model, 32, 100);
      return (await index.load(jobs.find((job) => job.documentId === meetingId)!))!;
    };
    const projection = () => raw.prepare("SELECT * FROM search_documents WHERE document_id = ?").get(meetingId)!;
    const search = (model: string) => store.sync.withIdentity(owner, (scoped) => scoped.listMeetings(vaultId,
      { text: "absent", tokens: ["absent"], embedding: { model, dimensions: 32, vector } }, 10));
    try {
      await service.commitTransaction(owner, wire([{ entity: "meeting", action: "create", entityId: meetingId,
        baseRevision: null, data: { ...meetingData(), createdAt: now.toISOString(), updatedAt: now.toISOString(), recordingStartedAt: now.toISOString(), projectId: null } }]));
      const first = await claim();
      expect(first.embeddingText).toBe("meeting");
      expect(await index.save(first, "model", 32, vector)).toBe(true);
      expect(await search("model")).toHaveLength(1);
      await service.commitTransaction(owner, wire([{ entity: "meeting", action: "update", entityId: meetingId,
        baseRevision: 1, data: { updatedAt: now.toISOString(), recordingStartedAt: now.toISOString(), projectId: null, name: "Renamed", description: "", status: "READY", duration: 60 } }]));
      expect(projection()).toMatchObject({ embedding: null, embedding_model: null });
      expect(await index.save(first, "model", 32, vector)).toBe(false);
      const renamed = await claim();
      expect(renamed.embeddingText).toBe("renamed");
      expect(renamed.contentHash).not.toBe(first.contentHash);
      await service.commitTransaction(owner, wire([{ entity: "summary", action: "upsert", entityId: meetingId,
        baseRevision: 0, data: { title: "Summary", document: JSON.stringify({ description: "New summary", sections: [] }), createdAt: now.toISOString() } }]));
      expect(await index.save(renamed, "model", 32, vector)).toBe(false);
      const summary = await claim();
      expect(summary.embeddingText).toContain("new summary");
      await expect(index.save(summary, "model", 32, [1])).rejects.toThrow("embedding_dimensions_invalid");
      expect(await index.save(summary, "model", 32, vector)).toBe(true);
      expect(await search("next-model")).toEqual([]);
      await index.reconcile("next-model", 32);
      const next = await claim("next-model");
      expect(await index.save(summary, "model", 32, vector)).toBe(false);
      expect(await index.save(next, "next-model", 32, vector)).toBe(true);
      expect(await search("next-model")).toHaveLength(1);
      expect(await search("model")).toEqual([]);
      await index.reconcile("third-model", 32);
      const delayed = await claim("third-model");
      await service.commitTransaction(owner, wire([{ entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 2, data: {} }]));
      expect(await index.save(delayed, "third-model", 32, vector)).toBe(false);
      expect(projection()).toBeUndefined();
      const columns = raw.prepare("PRAGMA table_info(search_documents)").all().map((row) => row.name);
      expect(columns).toEqual(expect.arrayContaining(["embedding", "embedding_model", "embedding_content_hash"]));
      expect(columns).not.toEqual(expect.arrayContaining(["embedding_text"]));
      expect(columns).not.toContain("embedding_dimensions");
      expect(raw.prepare("SELECT name FROM sqlite_master WHERE name = 'search_embeddings'").get()).toBeUndefined();
    } finally { raw.close(); await store.close?.(); }
  });

  it("uses current OCR and caption hashes for image embeddings and rejects late attachment results", async () => {
    const { store, service, publish, attach, file, databasePath } = await fileSetup("caption-model");
    await publish(); await attach();
    const raw = new DatabaseSync(databasePath);
    const vector = [1, ...new Array<number>(31).fill(0)];
    const index = store.searchIndex!;
    const claim = async () => {
      raw.exec("UPDATE jobs_search_index SET available_at = 0");
      const jobs = await index.claim("embedding", 32, 100);
      return (await index.load(jobs.find((job) => job.documentId === file.id)!))!;
    };
    try {
      await service.patchFile(owner, file.id, { baseRevision: 1, metadata: { ocrText: "Revenue", caption: "Diagram" } });
      const first = await claim();
      expect(first.embeddingText).toBe("revenue diagram");
      expect(await index.save(first, "embedding", 32, vector)).toBe(true);
      await service.patchFile(owner, file.id, { baseRevision: 2, metadata: { ocrText: "Budget" } });
      expect(raw.prepare("SELECT embedding FROM search_documents WHERE document_id = ?").get(file.id)).toMatchObject({ embedding: null });
      const ocr = await claim();
      expect(ocr.contentHash).not.toBe(first.contentHash);
      expect(ocr.embeddingText).toBe("budget diagram");
      await service.patchFile(owner, file.id, { baseRevision: 3, metadata: { caption: "New caption" } });
      expect(await index.save(ocr, "embedding", 32, vector)).toBe(false);
      const caption = await claim();
      expect(caption.contentHash).not.toBe(ocr.contentHash);
      expect(caption.embeddingText).toBe("budget new caption");
      await service.commitTransaction(owner, wire([{ entity: "meeting_attachment", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
      expect(await index.save(caption, "embedding", 32, vector)).toBe(false);
    } finally { raw.close(); await store.close?.(); }
  });


  it("updates separate OCR and caption fields", async () => {
    const { store, service, publish, attach, file, databasePath } = await fileSetup("caption-model");
    await publish(); await attach();
    await service.patchFile(owner, file.id, { baseRevision: 1, metadata: { ocrText: "Revenue", caption: "Architecture diagram" } });
    const raw = new DatabaseSync(databasePath);
    try {
      const before = raw.prepare("SELECT * FROM search_documents WHERE kind = 'screenshot'").get();
      expect(before).toMatchObject({ ocr_text: "revenue", caption_text: "architecture diagram", title_text: "", tags_text: "" });
      expect((await service.searchAll(owner, { vaultId, query: "Revenue architecture", kind: "screenshot" })).screenshots).toHaveLength(1);
      await service.patchFile(owner, file.id, { baseRevision: 2, metadata: { ocrText: "Budget", caption: "" } });
      expect((await service.searchAll(owner, { vaultId, query: "Revenue", kind: "screenshot" })).screenshots).toEqual([]);
      expect((await service.searchAll(owner, { vaultId, query: "Architecture", kind: "screenshot" })).screenshots).toEqual([]);
      expect((await service.searchAll(owner, { vaultId, query: "Budget", kind: "screenshot" })).screenshots).toHaveLength(1);
    } finally { raw.close(); await store.close?.(); }
  });

  it.each(["node", "worker"])("validates transfer requests and stops stale sync clients through %s", async (runtime) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const destinationVaultId = freshId();
    await commit(store, owner, { ...transaction(freshId(), [{ id: freshId(), entity: "vault", action: "create",
      entityId: destinationVaultId, baseRevision: null, data: { name: "Destination", createdAt: now } }]), vaultId: destinationVaultId });
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (path: string, init?: RequestInit) => {
      const request = new Request(`http://localhost:5173/api/v1/${path}`, { ...init, headers: { ...headers(), ...init?.headers } });
      return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    const audience: { audienceHash: string } = await (await send(`vaults/${vaultId}/transfer-audience?destinationVaultId=${destinationVaultId}`)).json();
    const input = { method: "POST", headers: { "Idempotency-Key": freshId() },
      body: JSON.stringify({ destinationVaultId, sourceRevision: 1, destinationRevision: 1, audienceHash: audience.audienceHash }) };
    expect((await send(`vaults/${vaultId}/transfer`, { ...input, headers: {} })).status).toBe(400);
    expect((await send(`vaults/${vaultId}/transfer`, { ...input, body: JSON.stringify({ destinationVaultId, sourceRevision: 1, destinationRevision: 1 }) })).status).toBe(400);
    const first = await send(`vaults/${vaultId}/transfer`, input);
    expect(first.status).toBe(200);
    const response: Record<string, unknown> = await first.json();
    expect(response).toMatchObject({ status: "committed", sourceVaultId: vaultId, destinationVaultId });
    expect(Object.keys(response).sort()).toEqual(["destinationVaultId", "id", "sourceVaultId", "status"]);
    expect(await (await send(`vaults/${vaultId}/transfer`, input)).json()).toEqual(response);
    for (const collection of ["changes", "snapshot"]) {
      expect((await send(`vaults/${vaultId}/${collection}`)).status).toBe(426);
      expect((await send(`vaults/${destinationVaultId}/${collection}`, { headers: { "X-Dahlia-Vault-Transfers": "1" } })).status).toBe(200);
    }
    const history: { items: unknown[] } = await (await send(`vaults/${vaultId}/relocations`)).json();
    expect(history.items).toHaveLength(0);
    expect((await send(`vaults/${destinationVaultId}/snapshot`, { headers: { "X-Dahlia-Vault-Transfers": "1" } })).status).toBe(200);
    const stale = wire([{ entity: "vault", action: "update", entityId: vaultId, baseRevision: 2, data: { name: "Stale client" } }]);
    expect((await send("transactions", { method: "POST", body: JSON.stringify(stale) })).status).toBe(426);
    await store.close?.();
  });

  it("transfers 5000 meetings and 1000 files without changing file keys", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const destinationVaultId = freshId();
    await commit(store, owner, { ...transaction(freshId(), [{ id: freshId(), entity: "vault", action: "create", entityId: destinationVaultId,
      baseRevision: null, data: { name: "Destination", createdAt: now } }]), vaultId: destinationVaultId });
    const database = new DatabaseSync(databasePath);
    database.exec("BEGIN");
    const meeting = database.prepare("INSERT INTO meetings (meeting_id, vault_id, name, status, created_at, updated_at, active) VALUES (?, ?, 'Volume', 'READY', ?, ?, 1)");
    for (let index = 0; index < 5000; index++) meeting.run(freshId(), vaultId, now.getTime(), now.getTime());
    const file = database.prepare("INSERT INTO files (file_id, vault_id, uri, size, content_type, checksum, name, metadata, active, uploaded_at, revision) VALUES (?, ?, ?, 1, 'text/plain', ?, 'file', ?, 1, ?, 1)");
    for (let index = 0; index < 1000; index++) { const id = freshId(); file.run(id, vaultId, `files/${id}/original`, `SHA-256:${"a".repeat(64)}`, JSON.stringify({ source: "file" }), now.getTime()); }
    database.exec("COMMIT");
    const before = database.prepare("SELECT file_id, uri, checksum FROM files ORDER BY file_id").all();
    const started = performance.now();
    const result = await store.sync.withIdentity(owner, async (sync) => sync.transferVault({ sourceVaultId: vaultId, destinationVaultId,
      audienceHash: (await sync.vaultTransferAudience(vaultId, destinationVaultId)).audienceHash,
      sourceRevision: 1, destinationRevision: 1, idempotencyKey: freshId(), requestHash: freshId() }));
    console.info(`Vault transfer: 5000 meetings + 1000 files in ${Math.round(performance.now() - started)} ms (disposable SQLite)`);
    expect(result.manifest.meetings).toHaveLength(5000);
    expect(result.manifest.files).toHaveLength(1000);
    expect(database.prepare("SELECT file_id, uri, checksum FROM files ORDER BY file_id").all()).toEqual(before);
    expect(database.prepare("SELECT count(*) AS count FROM meetings WHERE vault_id = ?").get(destinationVaultId)).toMatchObject({ count: 5000 });
    expect(database.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    database.close();
    await store.close?.();
  });

  it.each(["permission", "organization", "team"])("rejects changed %s readers until the owner reconfirms", async (kind) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const destinationVaultId = freshId();
    await commit(store, owner, { ...transaction(freshId(), [{ id: freshId(), entity: "vault", action: "create",
      entityId: destinationVaultId, baseRevision: null, data: { name: "Destination", createdAt: now } }]), vaultId: destinationVaultId });
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "create", entityId: meetingId,
      baseRevision: null, data: { ...meetingData(), projectId: null } }]));
    const database = new DatabaseSync(databasePath);
    database.exec(`INSERT INTO organization(id, name, slug, created_at) VALUES ('audience-org', 'Audience', 'audience', 0);
      INSERT INTO team(id, organization_id, name, created_at) VALUES ('audience-team', 'audience-org', 'Audience', 0);`);
    const grant = database.prepare("INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, ?, ?, 'member', ?)");
    if (kind !== "permission") grant.run(destinationVaultId, kind, kind === "team" ? "audience-team" : "audience-org", owner.userId);
    const preview = () => store.sync.withIdentity(owner, (sync) => sync.vaultTransferAudience(vaultId, destinationVaultId));
    const request = { sourceVaultId: vaultId, destinationVaultId, sourceRevision: 1, destinationRevision: 1,
      audienceHash: (await preview()).audienceHash, idempotencyKey: freshId(), requestHash: "original" };
    if (kind === "permission") grant.run(destinationVaultId, "user", other.userId, owner.userId);
    else if (kind === "organization") database.prepare("INSERT INTO member(id, organization_id, user_id, role, created_at) VALUES ('audience-member', 'audience-org', ?, 'member', 0)").run(other.userId);
    else database.prepare("INSERT INTO team_member(id, team_id, user_id, created_at) VALUES ('audience-member', 'audience-team', ?, 0)").run(other.userId);
    await expect(store.sync.withIdentity(owner, (sync) => sync.transferVault(request)))
      .rejects.toMatchObject({ status: 409, code: "transfer_audience_changed" });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId))).not.toBeNull();
    const refreshed = await preview();
    expect(refreshed.added.map((person) => person.id)).toContain(other.userId);
    const confirmed = { ...request, audienceHash: refreshed.audienceHash, requestHash: "reconfirmed", idempotencyKey: freshId() };
    const receipt = await store.sync.withIdentity(owner, (sync) => sync.transferVault(confirmed));
    expect(await store.sync.withIdentity(owner, (sync) => sync.transferVault(confirmed))).toEqual(receipt);
    database.close();
    await store.close?.();
  });

  it("previews reader changes and resumes relocation lookup after access is restored", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const destinationVaultId = freshId();
    await commit(store, owner, { ...transaction(freshId(), [{ id: freshId(), entity: "vault", action: "create", entityId: destinationVaultId,
      baseRevision: null, data: { name: "Destination", createdAt: now } }]), vaultId: destinationVaultId });
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "create", entityId: meetingId,
      baseRevision: null, data: { ...meetingData(), projectId: null } }]));
    const database = new DatabaseSync(databasePath);
    const grant = database.prepare("INSERT INTO vault_permissions (vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, 'user', ?, 'member', ?)");
    grant.run(vaultId, other.userId, owner.userId);
    const audience = await store.sync.withIdentity(owner, (sync) => sync.vaultTransferAudience(vaultId, destinationVaultId));
    expect(audience.removed.map((person) => person.id)).toEqual([other.userId]);
    expect(audience.added).toEqual([]);
    await store.sync.withIdentity(owner, async (sync) => sync.transferVault({ sourceVaultId: vaultId, destinationVaultId,
      audienceHash: (await sync.vaultTransferAudience(vaultId, destinationVaultId)).audienceHash,
      sourceRevision: 1, destinationRevision: 1, idempotencyKey: freshId(), requestHash: freshId() }));
    await expect(store.sync.withIdentity(other, (sync) => sync.getVaultRelocations(vaultId))).rejects.toMatchObject({ status: 403, code: "transfer_access_required" });
    grant.run(destinationVaultId, other.userId, owner.userId);
    const resumed = await store.sync.withIdentity(other, (sync) => sync.getVaultRelocations(vaultId));
    expect(resumed.items).toContainEqual({ entity: "meeting", id: meetingId, vaultId: destinationVaultId });
    expect(resumed.vaults[0]?.role).toBe("member");
    database.close();
    await store.close?.();
  });

  it.each([["Straße", "STRASSE"], ["Café", "Cafe\u0301"], ["Σ", "ς"]])("blocks normalized project name collision %s / %s", async (sourceName, destinationName) => {
    const { store } = await setup();
    await createVault(store);
    const destinationVaultId = freshId();
    await commit(store, owner, { ...transaction(freshId(), [{ id: freshId(), entity: "vault", action: "create", entityId: destinationVaultId,
      baseRevision: null, data: { name: "Destination", createdAt: now } }, { id: freshId(), entity: "project", action: "create", entityId: freshId(),
      baseRevision: null, data: projectData(destinationName) }]), vaultId: destinationVaultId });
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "project", action: "create", entityId: projectId,
      baseRevision: null, data: projectData(sourceName) }]));
    await expect(store.sync.withIdentity(owner, async (sync) => sync.transferVault({ sourceVaultId: vaultId, destinationVaultId,
      audienceHash: (await sync.vaultTransferAudience(vaultId, destinationVaultId)).audienceHash,
      sourceRevision: 1, destinationRevision: 1, idempotencyKey: freshId(), requestHash: freshId() }))).rejects.toMatchObject({ status: 409, code: "transfer_name_conflict" });
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toHaveLength(1);
    await store.close?.();
  });

  it("transfers stable IDs atomically and retains its replay history after source deletion", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const destinationVaultId = freshId();
    await commit(store, owner, { ...transaction(freshId(), [{ id: freshId(), entity: "vault", action: "create",
      entityId: destinationVaultId, baseRevision: null, data: { name: "Destination", createdAt: now } }]), vaultId: destinationVaultId });
    const childId = freshId();
    await commit(store, owner, transaction(freshId(), [
      { id: freshId(), entity: "project", action: "create", entityId: projectId, baseRevision: null, data: projectData("Root") },
      { id: freshId(), entity: "project", action: "create", entityId: childId, baseRevision: null,
        data: { ...projectData("Child"), parentProjectId: projectId, projectType: null } },
      { id: freshId(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { ...meetingData(), projectId: childId } },
    ]));
    const request = { sourceVaultId: vaultId, destinationVaultId, sourceRevision: 1, destinationRevision: 1,
      audienceHash: (await store.sync.withIdentity(owner, (sync) => sync.vaultTransferAudience(vaultId, destinationVaultId))).audienceHash,
      idempotencyKey: freshId(), requestHash: "transfer" };
    await expect(store.sync.withIdentity(other, (sync) => sync.transferVault(request))).rejects.toMatchObject({ status: 404 });
    await expect(store.sync.withIdentity(owner, async (sync) => {
      await sync.transferVault(request);
      throw new Error("rollback");
    })).rejects.toThrow("rollback");
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId))).not.toBeNull();
    const result = await store.sync.withIdentity(owner, (sync) => sync.transferVault(request));
    expect(result.manifest.projects.sort()).toEqual([projectId, childId].sort());
    expect(result.manifest.meetings).toEqual([meetingId]);
    expect(result.manifest.files).toEqual([]);
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId))).toBeNull();
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(destinationVaultId, meetingId))).toMatchObject({ meetingId, projectId: childId });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).toMatchObject({ hasResources: false, revision: 2 });
    const changes = await store.sync.withIdentity(owner, async (sync) => sync.listChanges(destinationVaultId, 0, await sync.latestChangeSequence(destinationVaultId), 100));
    expect(changes.some((change) => change.entity === "meeting" && change.entityId === meetingId && change.action === "upsert")).toBe(true);
    expect(await store.sync.withIdentity(owner, (sync) => sync.transferVault(request))).toEqual(result);
    await expect(store.sync.withIdentity(owner, (sync) => sync.transferVault({ ...request, requestHash: "different" })))
      .rejects.toMatchObject({ status: 409, code: "idempotency_key_reused" });
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "vault", action: "reset", entityId: vaultId, baseRevision: 2, data: {} }]));
    expect((await store.sync.withIdentity(owner, (sync) => sync.getVaultRelocations(vaultId))).items).toEqual(expect.arrayContaining([expect.objectContaining({ entity: "meeting", id: meetingId, vaultId: destinationVaultId })]));
    const database = new DatabaseSync(databasePath);
    expect(database.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(database.prepare("SELECT count(*) AS count FROM jobs_storage_delete").get()).toMatchObject({ count: 0 });
    database.close();
    await store.close?.();
  });

  it("syncs collection appearance and preserves it when older clients omit it", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const appearance = { icon: "book.closed", color: "green" };
    const first = await commit(store, owner, transaction(freshId(), [
      { id: freshId(), entity: "vault", action: "update", entityId: vaultId, baseRevision: 1, data: { name: "Styled", ...appearance } },
      { id: freshId(), entity: "project", action: "create", entityId: projectId, baseRevision: null, data: { ...projectData("Styled project"), ...appearance } },
    ]));
    expect(first.records.find((item) => item.entity === "vault")?.record).toMatchObject({ ...appearance });
    expect(first.records.find((item) => item.entity === "project")?.record).toMatchObject({ ...appearance });
    await commit(store, owner, transaction(freshId(), [
      { id: freshId(), entity: "vault", action: "update", entityId: vaultId, baseRevision: 2, data: { name: "Renamed" } },
      { id: freshId(), entity: "project", action: "update", entityId: projectId, baseRevision: 1, data: { parentProjectId: null, name: "Renamed project", description: "", projectType: "undefined" } },
    ]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).toMatchObject({ ...appearance, revision: 3 });
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toEqual(expect.arrayContaining([expect.objectContaining({ ...appearance, revision: 2 })]));
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const response = await app.request("http://localhost:5173/api/v1/transactions", { method: "POST", headers: headers(), body: JSON.stringify(transaction(freshId(), [
      { id: freshId(), entity: "vault", action: "update", entityId: vaultId, baseRevision: 3, data: { name: "Unsafe", icon: "<svg>", color: "red" } },
    ])) });
    expect(response.status).toBe(400);
  });

  it("rejects child appearance and clears it when a root becomes a child", async () => {
    const { store } = await setup();
    await createVault(store);
    const childId = freshId();
    const appearance = { icon: "book.closed", color: "green" };
    await commit(store, owner, transaction(freshId(), [
      { id: freshId(), entity: "project", action: "create", entityId: projectId, baseRevision: null, data: { ...projectData("Parent"), ...appearance } },
      { id: freshId(), entity: "project", action: "create", entityId: childId, baseRevision: null, data: { ...projectData("Child"), ...appearance } },
    ]));
    const service = new MeetingSyncService(store.sync);
    for (const action of ["create", "update"] as const) {
      const data = { ...projectData("Child"), parentProjectId: projectId, projectType: null, ...appearance };
      if (action === "update") delete (data as { createdAt?: Date }).createdAt;
      await expect(service.commitTransaction(owner, JSON.parse(JSON.stringify(wire([
        { entity: "project", action, entityId: action === "create" ? freshId() : childId, baseRevision: action === "create" ? null : 1, data },
      ]))))).rejects.toMatchObject({ status: 400, code: "invalid_sync_operation" });
    }
    await service.commitTransaction(owner, JSON.parse(JSON.stringify(wire([
      { entity: "project", action: "update", entityId: childId, baseRevision: 1,
        data: { parentProjectId: projectId, name: "Child", description: "", projectType: null } },
    ]))));
    const projects = await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId));
    expect(projects.find((project) => project.projectId === childId)).toMatchObject({ icon: null, color: null });
    expect(projects.find((project) => project.projectId === projectId)).toMatchObject({ ...appearance });
  });

  it.each(["node", "worker"])("round-trips appearance with revision checks and partial updates through %s", async (runtime) => {
    const { store, databasePath } = await setup();
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (body: unknown, user = owner.userId) => {
      const request = new Request("http://localhost:5173/api/v1/transactions", { method: "POST",
        headers: { ...headers(), "x-forwarded-user": user, "x-forwarded-email": `${user}@example.com` }, body: JSON.stringify(body) });
      return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    const project = { parentProjectId: null, name: "Project", description: "", projectType: "internal" };
    try {
      const created = await send(wire([
        { entity: "vault", action: "create", entityId: vaultId, baseRevision: null,
          data: { name: "Vault", createdAt: now.toISOString(), icon: "folder", color: "blue" } },
        { entity: "project", action: "create", entityId: projectId, baseRevision: null,
          data: { ...project, createdAt: now.toISOString(), icon: "music.note", color: "purple" } },
      ]));
      expect(created.status).toBe(200);
      expect(await created.json()).toMatchObject({ records: [
        { entity: "vault", revision: 1, record: { icon: "folder", color: "blue" } },
        { entity: "project", revision: 1, record: { icon: "music.note", color: "purple" } },
      ] });
      const update = (baseRevision: number, fields: Record<string, unknown> = {}) => wire([
        { entity: "project", action: "update", entityId: projectId, baseRevision, data: { ...project, ...fields } },
      ]);
      const rename = update(1, { name: "Renamed" });
      expect((await send(rename)).status).toBe(200);
      expect((await send(rename)).status).toBe(200); // An offline retry is idempotent.
      const clear = await send(update(2, { icon: null }));
      expect(clear.status).toBe(200);
      expect(await clear.json()).toMatchObject({ records: [{ revision: 3, record: { icon: null, color: "purple" } }] });
      expect((await send(update(2, { color: "red" }))).status).toBe(409);
      expect((await send(update(3, { icon: "not-an-icon" }))).status).toBe(400);
      expect((await send(update(3, { color: "not-a-color" }))).status).toBe(400);
      const service = new MeetingSyncService(store.sync);
      const snapshot = await service.listSnapshot(owner, vaultId);
      expect(snapshot.items.find((item) => item.entity === "vault")).toMatchObject({ record: { icon: "folder", color: "blue" } });
      expect(snapshot.items.find((item) => item.entity === "project")).toMatchObject({ revision: 3, record: { icon: null, color: "purple" } });
      await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
      const shared = await service.listSnapshot(other, vaultId);
      expect(shared.items.find((item) => item.entity === "project")).toMatchObject({ record: { color: "purple" } });
      expect((await send(update(3, { color: "red" }), other.userId)).status).toBe(409);
      expect((await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId)))[0]).toMatchObject({ icon: null, color: "purple", revision: 3 });
    } finally { await store.close?.(); }
  });

  it.each(["node", "worker"].flatMap((runtime) => ["none", "server"].map((mode) => [runtime, mode] as const)))("serves the common POST search with prefiltered candidates through %s (%s)", async (runtime, mode) => {
    const encryption: AppConfig["encryption"] = mode === "server" ? { activeKeyId: "1", masterKeys: new Map([["1", new Uint8Array(32).fill(1)]]) } : undefined;
    const { store, databasePath } = await setup(undefined, undefined, encryption);
    await createVault(store, mode);
    const app = createApp({ config: { ...testConfig(databasePath), encryption }, authStore: store });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (body: unknown, user = owner.userId) => {
      const request = new Request(`http://localhost:5173/api/v1/vaults/${vaultId}/search`, { method: "POST",
        headers: { ...headers(), "x-forwarded-user": user, "x-forwarded-email": `${user}@example.com` }, body: JSON.stringify(Object.fromEntries(Object.entries(body as Record<string, unknown>).filter(([key]) => key !== "vaultId"))) });
      return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    // More than 100 higher-ranked documents outside the selected project must not consume its candidates.
    await commit(store, owner, transaction(freshId(), [
      { id: freshId(), entity: "project", action: "create", entityId: projectId, baseRevision: null, data: projectData("契約更新") },
      ...Array.from({ length: 110 }, (_, index) => ({ id: freshId(), entity: "meeting" as const, action: "create" as const,
        entityId: index === 0 ? meetingId : freshId(), baseRevision: null,
        data: { ...meetingData(), projectId: index === 0 ? projectId : null, name: "契約更新", updatedAt: now } })),
    ]));
    // Commit through the service to generate the search projection, like canonical API writes.
    const service = new MeetingSyncService(store.sync);
    for (const meeting of await service.listMeetings(owner, vaultId).then((page) => page.items)) {
      await service.commitTransaction(owner, JSON.parse(JSON.stringify(wire([{ entity: "meeting", action: "update", entityId: meeting.meetingId,
        baseRevision: 1, data: { projectId: meeting.projectId, name: "契約更新", description: "", status: "READY", duration: 60, recordingStartedAt: now, updatedAt: now } }]))));
    }
    const response = await send({ vaultId, query: "契約更新", projectId, from: "2026-09-03T09:00:00+09:00", to: "2026-09-04T00:00:00Z" });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toMatchObject({ vaultId, meetings: [{ id: meetingId, title: "契約更新", projectId }], projects: [{ id: projectId, date: now.toISOString() }] });
    expect(await (await send({ vaultId, query: "契約更新", projectId, limit: 1 })).json())
      .toMatchObject({ limited: { meeting: false, screenshot: false, project: false } });
    expect(await (await send({ vaultId, kind: "meeting", limit: 100 })).json())
      .toMatchObject({ limited: { meeting: true } });
    const mcpParams = { name: "search", arguments: { vaultId: encodeId("vault", vaultId), query: "契約更新", projectId: encodeId("project", projectId), from: "2026-09-03T09:00:00+09:00", to: "2026-09-04T00:00:00Z" },
      _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "Search test", version: "1" }, "io.modelcontextprotocol/protocolVersion": "2026-07-28" } };
    const mcpBody = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: mcpParams });
    const mcp = await app.request("/mcp", { method: "POST", headers: { ...headers(), "content-length": String(new TextEncoder().encode(mcpBody).length),
      "mcp-method": "tools/call", "mcp-name": "search", "mcp-protocol-version": "2026-07-28" }, body: mcpBody });
    const mcpResult = z.object({ result: z.object({ content: z.array(z.object({ text: z.string() })) }) }).parse(await mcp.json());
    expect(wireValue(JSON.parse(mcpResult.result.content[0]!.text), "search", "decode")).toEqual(await (await send(mcpParams.arguments)).json());
    expect((await send({ vaultId, query: "契約更新" }, other.userId)).status).toBe(404);
    const recent = await (await send({ vaultId, query: "", limit: 6 })).json();
    expect(z.object({ meetings: z.array(z.unknown()) }).parse(recent).meetings).toHaveLength(6);
    expect(recent).toMatchObject({ limited: { meeting: true } });
    const cutoff = await (await send({ vaultId, to: now.toISOString(), kind: "meeting" })).json();
    expect(cutoff).toMatchObject({ meetings: [] });
    for (const invalid of [{ query: 1 }, { query: null }, { query: "a".repeat(501) }, { q: "x" }, { limit: 101 },
      { from: "2026-09-03" }, { from: "2026-09-04T00:00:00Z", to: "2026-09-03T00:00:00Z" }]) {
      expect((await send({ vaultId, ...invalid })).status).toBe(400);
    }
    expect((await send({ vaultId, query: "x".repeat(17000) })).status).toBe(413);
    const childProjectId = freshId();
    const childMeetingId = freshId();
    await service.commitTransaction(owner, JSON.parse(JSON.stringify(wire([
      { entity: "project", action: "create", entityId: childProjectId, baseRevision: null, data: { ...projectData("下位"), parentProjectId: projectId, projectType: null } },
      { entity: "meeting", action: "create", entityId: childMeetingId, baseRevision: null, data: { ...meetingData(), name: "子孫限定", projectId: childProjectId } },
    ]))));
    expect(await (await send({ vaultId, query: "子孫限定", projectId, kind: "meeting" })).json())
      .toMatchObject({ meetings: [{ id: childMeetingId, projectId: childProjectId }], screenshots: [], projects: [] });

    expect(await (await send({ vaultId, projectId, limit: 1 })).json())
      .toMatchObject({ limited: { meeting: true, project: true } });
    const prepare = vi.spyOn(DatabaseSync.prototype, "prepare");
    try {
      const projects = await store.sync.withIdentity(owner, (scoped) => scoped.listProjects(vaultId));
      expect(projects.find((project) => project.projectId === projectId)).toMatchObject({ directMeetingCount: 1, subtreeMeetingCount: 2 });
      expect(projects.find((project) => project.projectId === childProjectId)).toMatchObject({ directMeetingCount: 1, subtreeMeetingCount: 1 });
      const countQuery = prepare.mock.calls.map(([query]) => query).find((query) => query.includes('from "meetings"'));
      expect(countQuery).toMatch(/count\(\*\).*group by .*project_id/s);
    } finally { prepare.mockRestore(); }

    await store.close?.();
  }, 30_000);

  it("runs storage maintenance on the timer without Vault requests", async () => {
    const { store, directory } = await setup();
    const targets = vi.spyOn(store.sync, "listHistoryTargets");
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      const service = new MeetingSyncService(store.sync, new LocalObjectStorage(join(directory, "objects")));
      await service.runStorageMaintenance();
      targets.mockClear();
      await vi.advanceTimersByTimeAsync(60_000);
      expect(targets).toHaveBeenCalledTimes(1);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
      await store.close?.();
    }
  });

  it.each(["node", "worker"])("stores raw recording uploads, hides staging and retains source identity through %s", async (runtime) => {
    const { store, directory, databasePath } = await setup();
    await createVault(store);
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { ...meetingData(), projectId: null } }]));
    const sessionId = freshId();
    for (const kind of ["recording_started", "recording_ended"]) {
      await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting_event", action: "create", entityId: freshId(), baseRevision: null, data: { meetingId, sessionId, kind, occurredAt: now } }]));
    }
    const storage = new LocalObjectStorage(join(directory, "objects"));
    const app = createApp({ config: testConfig(databasePath), authStore: store, objectStorage: storage });
    const worker = createWorkerHandler(async () => app);
    const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (path: string, init: RequestInit = {}) => {
      const request = new Request(`http://localhost:5173${path}`, { ...init, headers: { ...headers(), ...init.headers } });
      return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    const base = `/api/v1/meetings/${meetingId}/recordings`;
    // Minimal ISO BMFF fixture: server validates the container; Desktop validates full audio decoding.
    const bytes = new Uint8Array([0, 0, 0, 20, 102, 116, 121, 112, 77, 52, 65, 32, 0, 0, 0, 0, 77, 52, 65, 32]);
    const post = (source: string, body = bytes) => send(`/api/v1/meetings/${meetingId}/recording-uploads/${sessionId}/audio/${source}`, {
      method: "PUT", headers: { "content-type": "audio/mp4", "content-length": String(body.length) }, body,
    });
    const [first, systemUpload] = await Promise.all([post("mic"), post("system")]);
    expect(systemUpload.status).toBe(201);
    expect(await systemUpload.json()).toMatchObject({ id: 1 });
    expect(first.status).toBe(201);
    const uploaded: { id: number; size: number; checksum: string; contentUrl: string } = await first.json();
    expect(uploaded).toMatchObject({ id: 1, size: bytes.length, contentType: "audio/mp4" });
    expect(await (await send(base)).json()).toEqual({ items: [], nextCursor: null });
    expect((await post("mic")).status).toBe(200);
    const changed = bytes.slice(); changed[19] = 33;
    expect((await post("mic", changed)).status).toBe(409);
    expect((await post("video")).status).toBe(400);
    expect((await send(`/api/v1/meetings/${meetingId}/recording-uploads/${sessionId}/audio/mic`, { method: "PUT", body: bytes,
      headers: { "content-type": "audio/mp4", "content-length": String(1024 ** 3 + 1) } })).status).toBe(413);
    expect((await post("mic", new Uint8Array(20))).status).toBe(415);
    expect((await send(`/api/v1/meetings/${meetingId}/recording-uploads/${sessionId}/audio/mic`, { method: "PUT", body: bytes,
      headers: { "content-type": "audio/mp4", "content-length": "21" } })).status).toBe(400);
    expect((await send(uploaded.contentUrl, { method: "HEAD" })).status).toBe(200);
    expect(await (await post("system")).json()).toMatchObject({ id: 1 });
    const manifest = { sampleRate: 16000, frameCount: 16000, ranges: [{ startFrame: 0, frameCount: 16000, sessionOffsetSeconds: 0, localeIdentifier: "ja-JP" }] };
    const badConfirmation = await send("/api/v1/transactions", { method: "POST", body: JSON.stringify(wire([{
      entity: "recording", action: "upsert", entityId: sessionId, baseRevision: null,
      data: { source: "mic", checksum: "SHA-256:" + "0".repeat(64), manifest },
    }])) });
    expect(badConfirmation.status).toBe(409);
    const confirmed = await send("/api/v1/transactions", { method: "POST", body: JSON.stringify(wire([{
      entity: "recording", action: "upsert", entityId: sessionId, baseRevision: null, data: { source: "mic", checksum: uploaded.checksum, manifest },
    }])) });
    expect(confirmed.status).toBe(200);
    const list = await (await send(base)).json();
    expect(list).toMatchObject({ items: [{ id: 1, audio: { mic: { checksum: uploaded.checksum } } }] });
    expect(JSON.stringify(list)).not.toContain(sessionId);
    expect(JSON.stringify(list)).not.toContain("system");
    const download = await send(uploaded.contentUrl, { headers: { range: "bytes=0-3" } });
    expect(download.status).toBe(206);
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(bytes.slice(0, 4));
    expect(await storage.exists(`meetings/${meetingId}/recordings/audio_mic_01.m4a`)).toBe(true);
    const denied = await send(uploaded.contentUrl, { headers: { "x-forwarded-user": other.userId, "x-forwarded-email": "other@example.com" } });
    expect(denied.status).toBe(404);
    const snapshot = await store.sync.withIdentity(owner, (scoped) => scoped.listSnapshot(vaultId, undefined, 100));
    expect(snapshot.items.find((record) => record.entity === "recording")?.record).toMatchObject({ sessionId, audio: { mic: { manifest } } });
    const staged = await store.sync.withIdentity(owner, (scoped) => scoped.getRecording(meetingId, 1, true));
    const oldGeneration = staged!.audio.system!.generation;
    const database = new DatabaseSync(databasePath);
    try {
      database.prepare("UPDATE recordings SET audio = json_set(audio, '$.system.createdAt', ?, '$.mic.createdAt', ?) WHERE session_id = ?")
        .run("2020-01-01T00:00:00.000Z", "2020-01-01T00:00:00.000Z", sessionId);
    } finally { database.close(); }
    // No further request to this Vault: Node maintenance or a cold Worker cron must find the upload.
    const maintain = async () => {
      if (runtime === "node") return app.runStorageMaintenance();
      const coldWorker = createWorkerHandler(async () => app);
      const pending: Promise<unknown>[] = [];
      const scheduled = coldWorker.scheduled!.bind(coldWorker) as unknown as (
        controller: ScheduledController, env: Cloudflare.Env, context: ExecutionContext,
      ) => Promise<void>;
      await scheduled({} as ScheduledController, {} as Cloudflare.Env, { waitUntil: (task: Promise<unknown>) => pending.push(task) } as unknown as ExecutionContext);
      await Promise.all(pending);
    };
    await maintain();
    expect(await storage.exists(`meetings/${meetingId}/recordings/audio_system_01.m4a`)).toBe(false);
    expect(await storage.exists(`meetings/${meetingId}/recordings/audio_mic_01.m4a`)).toBe(true);
    const cleaned = await store.sync.withIdentity(owner, (scoped) => scoped.getRecording(meetingId, 1, true));
    expect(cleaned!.audio.system).toBeUndefined();
    expect(cleaned!.audio.mic!.active).toBe(true);
    expect((await post("system")).status).toBe(201);
    await maintain();
    expect(await store.sync.withIdentity(owner, (scoped) => scoped.markRecordingUploaded(sessionId, "system", oldGeneration, bytes.length, uploaded.checksum))).toBeNull();
    expect(await storage.exists(`meetings/${meetingId}/recordings/audio_system_01.m4a`)).toBe(true);
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]));
    expect(await store.sync.hasStorageDelete(`meetings/${meetingId}/recordings/audio_mic_01.m4a`)).toBe(true);
    expect((await send(uploaded.contentUrl)).status).toBe(404);
    await store.close?.();
  });

  it.each(["node", "worker"])("projects recording events without heartbeats and handles out-of-order delivery through %s", async (runtime) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { ...meetingData(), projectId: null } }]));
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (path: string, body?: unknown) => {
      const request = new Request(`http://localhost:5173/api/v1/${path}`, { method: body ? "POST" : "GET", headers: headers(), body: body ? JSON.stringify(body, (key, value: unknown) => key === "requestHash" ? undefined : value) : undefined });
      return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    const event = (kind: string, sessionId: string, occurredAt: Date) => ({ id: freshId(), entity: "meeting_event" as const, action: "create" as const, entityId: freshId(), baseRevision: null, data: { meetingId, kind, sessionId, occurredAt } });
    const write = (operation: SyncTransaction["operations"][number]) => send("transactions", transaction(freshId(), [operation]));
    const detail = async () => (await send(`meetings/${meetingId}`)).json();
    const capabilities = await send("capabilities");
    expect(capabilities.status).toBe(200);
    expect(await capabilities.json()).toEqual({ sync: { version: 4 }, vaultTransfers: { version: 1 }, recordingArchive: { version: 1 }, meetingEvents: { version: 1 }, search: { version: 1 } });
    const enabledApp = createApp({ config: testConfig(databasePath), authStore: store, imageAnalysisEnabled: true });
    expect(await (await enabledApp.request("http://localhost:5173/api/v1/capabilities", { headers: headers() })).json())
      .toEqual({ sync: { version: 4 }, vaultTransfers: { version: 1 }, recordingArchive: { version: 1 }, meetingEvents: { version: 1 }, search: { version: 1 }, imageAnalysis: { version: 1 } });
    expect((await send("sync-content")).status).toBe(404);
    const availability = vi.spyOn(store.sync, "isAvailable").mockResolvedValueOnce(false);
    const unsupported = await send("capabilities");
    expect(unsupported.status).toBe(200);
    expect(await unsupported.json()).toEqual({});
    availability.mockRestore();
    const session = freshId();
    expect((await write(event("recording_ended", session, new Date(now.getTime() + 60000)))).status).toBe(200);
    expect((await write(event("recording_started", session, now))).status).toBe(200);
    expect(await detail()).toMatchObject({ isRecording: false });
    const next = freshId();
    const start = transaction(freshId(), [event("recording_started", next, now)]);
    expect((await send("transactions", start)).status).toBe(200);
    expect((await send("transactions", start)).status).toBe(200);
    expect((await send("transactions", { ...start, id: freshId() })).status).toBe(200);
    expect(await detail()).toMatchObject({ isRecording: true, revision: 1 });
    expect(await (await send(`vaults/${vaultId}/meetings`)).json()).toMatchObject({ items: [expect.objectContaining({ isRecording: true })] });
    const idleMeetingId = freshId();
    expect((await write({ id: freshId(), entity: "meeting", action: "create", entityId: idleMeetingId, baseRevision: null, data: { ...meetingData(), projectId: null } })).status).toBe(200);
    expect(await (await send(`meetings/${idleMeetingId}`)).json()).toMatchObject({ isRecording: false });
    expect(await (await send(`vaults/${vaultId}/meetings`)).json()).toMatchObject({ items: expect.arrayContaining([
      expect.objectContaining({ meetingId, isRecording: true }),
      expect.objectContaining({ meetingId: idleMeetingId, isRecording: false }),
    ]) as unknown });
    const db = new DatabaseSync(databasePath);
    expect(db.prepare("SELECT count(*) AS count FROM meeting_events WHERE kind = 'recording_started'").get()).toMatchObject({ count: 2 });
    expect(db.prepare("SELECT started_at, ended_at FROM recording_sessions WHERE session_id = ?").get(session)).toMatchObject({ started_at: now.getTime(), ended_at: now.getTime() + 60000 });
    expect((await write(event("recording_ended", next, new Date(now.getTime() + 120000)))).status).toBe(200);
    expect(await detail()).toMatchObject({ isRecording: false });
    db.close();
    await store.close?.();
  });

  it.each(["node", "worker"])("blocks Vault deletion with an empty Project or staged File through %s", async (runtime) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const remove = async () => {
      const request = new Request("http://localhost:5173/api/v1/transactions", { method: "POST", headers: headers(), body: JSON.stringify(transaction(freshId(), [{ id: freshId(), entity: "vault", action: "reset", entityId: vaultId, baseRevision: 1, data: { preservePermissions: false } }]), (key, value: unknown) => key === "requestHash" ? undefined : value) });
      return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).toMatchObject({ hasResources: false });
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "project", action: "create", entityId: projectId, baseRevision: null, data: projectData("Empty") }]));
    const db = new DatabaseSync(databasePath);
    for (const kind of ["project", "staged file"]) {
      const response = await remove();
      expect(response.status, kind).toBe(409);
      expect(await response.json()).toMatchObject({ code: "vault_not_empty" });
      expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).toMatchObject({ hasResources: true, revision: 1 });
      expect(db.prepare("SELECT count(*) AS count FROM jobs_storage_delete").get()).toMatchObject({ count: 0 });
      if (kind === "project") {
        expect(db.prepare("SELECT count(*) AS count FROM projects").get()).toMatchObject({ count: 1 });
        await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "project", action: "delete", entityId: projectId, baseRevision: 1, data: {} }]));
        db.prepare("INSERT INTO files (file_id, vault_id, uri, size, content_type, checksum, name, metadata) VALUES (?, ?, ?, 0, 'text/plain', '', 'staged', '{}')").run(freshId(), vaultId, "pending");
      }
    }
    expect(db.prepare("SELECT count(*) AS count FROM files").get()).toMatchObject({ count: 1 });
    db.close();
    await store.close?.();
  });

  it("keeps content-free history after meeting deletion and removes it with the Vault", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { ...meetingData(), projectId: null } }]));
    const data = { ...meetingData(), projectId: null, name: "Private renamed title" };
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "update", entityId: meetingId, baseRevision: 1, data }]));
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "update", entityId: meetingId, baseRevision: 2, data }]));
    const db = new DatabaseSync(databasePath);
    expect(db.prepare("SELECT changed_fields FROM meeting_events WHERE kind = 'meeting_updated'").all()).toEqual([{ changed_fields: '["name"]' }]);
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting_event", action: "create", entityId: freshId(), baseRevision: null, data: { meetingId, kind: "tag_added", relatedId: "42", occurredAt: now } }]));
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting_event", action: "create", entityId: freshId(), baseRevision: null, data: { meetingId, kind: "recording_started", sessionId: freshId(), occurredAt: now } }]));
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 3, data: {} }]));
    const rows = db.prepare("SELECT * FROM meeting_events").all();
    expect(rows.map((row) => row.kind).sort()).toEqual(["meeting_created", "meeting_deleted", "meeting_updated", "recording_started", "tag_added"]);
    expect(JSON.stringify(rows)).not.toContain("Private renamed title");
    for (const row of rows) expect(row).toMatchObject({ session_id: null, related_id: null, changed_fields: null, audio_source: null, segment_index: null });
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const lateEvent = transaction(freshId(), [{ id: freshId(), entity: "meeting_event", action: "create", entityId: freshId(), baseRevision: null, data: { meetingId, kind: "tag_added", relatedId: "42", occurredAt: now } }]);
    const response = await app.request("/api/v1/transactions", { method: "POST", headers: headers(), body: JSON.stringify(lateEvent, (key, value: unknown) => key === "requestHash" ? undefined : value) });
    expect(response.status).toBe(410);
    expect(await response.json()).toMatchObject({ code: "meeting_event_parent_unavailable" });
    expect(db.prepare("SELECT * FROM meeting_events").all()).toEqual(rows);
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { ...meetingData(), projectId: null } }]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId))).toMatchObject({ isRecording: false });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).toMatchObject({ hasResources: true });
    await expect(commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "vault", action: "reset", entityId: vaultId, baseRevision: 1, data: {} }]))).rejects.toMatchObject({ status: 409, code: "vault_not_empty" });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId))).not.toBeNull();
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).toMatchObject({ hasResources: false });
    await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "vault", action: "reset", entityId: vaultId, baseRevision: 1, data: {} }]));
    expect(db.prepare("SELECT count(*) AS count FROM meeting_events").get()).toMatchObject({ count: 0 });
    db.close();
    await store.close?.();
  });

  it("validates event payloads, ownership, session relationships and immutable IDs", async () => {
    const { store } = await setup();
    await createVault(store);
    const secondMeeting = freshId();
    await commit(store, owner, transaction(freshId(), [meetingId, secondMeeting].map((id) => ({ id: freshId(), entity: "meeting", action: "create", entityId: id, baseRevision: null, data: { ...meetingData(), projectId: null } }))));
    const service = new MeetingSyncService(store.sync);
    const sessionId = freshId();
    const operation = { id: freshId(), entity: "meeting_event" as const, action: "create" as const, entityId: freshId(), baseRevision: null, data: { meetingId, kind: "recording_started", sessionId, occurredAt: now } };
    const send = (op: typeof operation, identity = owner) => service.commitTransaction(identity, JSON.parse(JSON.stringify(transaction(freshId(), [op]), (key, value: unknown) => key === "requestHash" ? undefined : value)));
    await send(operation);
    await expect(send({ ...operation, data: { ...operation.data, occurredAt: new Date(now.getTime() + 1) } })).rejects.toMatchObject({ code: "event_id_reused" });
    await expect(send({ ...operation, entityId: freshId(), data: { ...operation.data, meetingId: secondMeeting } })).rejects.toMatchObject({ code: "recording_session_meeting_mismatch" });
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    expect(await store.sync.withIdentity(other, (sync) => sync.getMeeting(vaultId, meetingId))).toMatchObject({ isRecording: true });
    await expect(send({ ...operation, entityId: freshId() }, other)).rejects.toBeDefined();
    await expect(send({ ...operation, data: { ...operation.data, kind: "meeting_deleted" } })).rejects.toBeDefined();
    await expect(service.commitTransaction(owner, JSON.parse(JSON.stringify(transaction(freshId(), [{ ...operation, data: { ...operation.data, privateText: "must reject" } }]), (key, value: unknown) => key === "requestHash" ? undefined : value)))).rejects.toBeDefined();
    await store.close?.();
  });

  it.each(["node", "worker"])("resolves canonical detail IDs only for readable active records through %s", async (runtime) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    await commit(store, owner, transaction(freshId(), [
      { id: freshId(), entity: "project", action: "create", entityId: projectId, baseRevision: null, data: projectData("Planning") },
      { id: freshId(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: meetingData() },
    ]));
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const get = async (path: string, user = owner) => {
      const request = new Request(`http://localhost:5173${path}`, { headers: { ...headers(), "x-forwarded-user": user.userId, "x-forwarded-email": `${user.userId}@example.com` } });
      return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    const paths = [`/api/v1/projects/${projectId}`, `/api/v1/meetings/${meetingId}`];
    for (const path of paths) {
      expect((await get(path)).status).toBe(200);
      expect(await (await get(path)).json()).toMatchObject({ vaultId });
      expect((await get(path, other)).status).toBe(404);
    }
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    for (const path of paths) expect((await get(path, other)).status).toBe(200);
    await store.sync.withIdentity(owner, (sync) => sync.deleteMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    for (const path of paths) expect((await get(path, other)).status).toBe(404);
    expect((await get(`/api/v1/projects/${freshId()}`)).status).toBe(404);
    expect((await get(`/api/v1/meetings/${freshId()}`)).status).toBe(404);
    expect((await get("/api/v1/projects/invalid")).status).toBe(400);
    const db = new DatabaseSync(databasePath);
    db.prepare("UPDATE meetings SET active = 0 WHERE meeting_id = ?").run(meetingId);
    expect((await get(paths[1]!)).status).toBe(404);
    db.prepare("UPDATE vaults SET deleting_at = ? WHERE vault_id = ?").run(now.getTime(), vaultId);
    expect((await get(paths[0]!)).status).toBe(404);
    db.close();
    await store.close?.();
  });

  it("notifies setting changes without exposing content or a settings revision", async () => {
    const { store, databasePath } = await setup();
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const abort = new AbortController();
    const response = await app.request("/api/v1/events", {
      headers: { "x-forwarded-email": "owner@example.com", "x-forwarded-user": owner.userId }, signal: abort.signal,
    });
    const reader = response.body!.getReader();
    const nextSettingsEvent = async () => {
      let text = "";
      while (!text.includes("event: account_settings")) {
        const chunk = await reader.read();
        if (chunk.done) throw new Error("Settings stream ended");
        text += new TextDecoder().decode(chunk.value);
      }
      return text;
    };
    try {
      expect(await nextSettingsEvent()).toContain("data: {}");
      await store.accountSettings.update(owner.userId, { outputLanguage: "fr" });
      const event = await nextSettingsEvent();
      expect(event).toContain("data: {}");
      expect(event).not.toContain("outputLanguage");
      expect(event).not.toContain("id:");
    } finally {
      abort.abort();
      await reader.cancel();
      await store.close?.();
    }
  });


  it("reopening and rerunning migrations preserves canonical files", async () => {
    const { store, service, publish, attach, file, databasePath } = await fileSetup();
    await publish();
    await attach();
    const original = await service.getFile(owner, file.id);
    await store.close?.();
    const reopened = createNodeApplicationStore(testConfig(databasePath));
    await reopened.migrate();
    const restored = new MeetingSyncService(reopened.sync);
    expect(await restored.getFile(owner, file.id)).toMatchObject({ ...original, variants: {} });
    expect(await reopened.accountSettings.get(owner.userId)).toBeNull();
    await reopened.close?.();
  });

  it("initializes account settings once and merges only specified fields across clients", async () => {
    const { store } = await setup();
    expect(await store.accountSettings.get(owner.userId)).toBeNull();
    const initial = { ...DEFAULT_ACCOUNT_SETTINGS, outputLanguage: "en" as const, analysisLanguages: { scope: "selected" as const, identifiers: ["en", "ja"] } };
    await store.accountSettings.update(owner.userId, initial, true);
    expect(await store.accountSettings.update(owner.userId, { ...initial, outputLanguage: "ja" }, true)).toEqual(initial);
    await Promise.all([
      store.accountSettings.update(owner.userId, { outputLanguage: "fr" }),
      store.accountSettings.update(owner.userId, { analysisLanguages: { scope: "all", identifiers: [] } }),
    ]);
    expect(await store.accountSettings.get(owner.userId)).toEqual({ ...DEFAULT_ACCOUNT_SETTINGS, outputLanguage: "fr", analysisLanguages: { scope: "all", identifiers: [] } });
    await Promise.all([
      store.accountSettings.update(owner.userId, { processing: { remote: { summaryModel: "saved-model" } } }),
      store.accountSettings.update(owner.userId, { summary: { style: "concise" } }),
    ]);
    expect(await store.accountSettings.get(owner.userId)).toMatchObject({ summary: { style: "concise" }, processing: {
      location: "local", remote: { ...DEFAULT_ACCOUNT_SETTINGS.processing.remote, summaryModel: "saved-model" },
    } });
    const version = await store.accountSettings.getRevision(owner.userId);
    await store.accountSettings.update(owner.userId, { summary: { style: "concise" } });
    expect(await store.accountSettings.getRevision(owner.userId)).toBe(version);
    await Promise.all([
      store.accountSettings.update(owner.userId, { processing: { remote: { summaryModel: "audio-model" } } }),
      store.accountSettings.update(owner.userId, { processing: { remote: { reasoningEffort: "high" } } }),
    ]);
    expect((await store.accountSettings.get(owner.userId))?.processing.remote).toMatchObject({ summaryModel: "audio-model", reasoningEffort: "high" });
    expect(await store.accountSettings.getRevision(owner.userId)).toBe(version! + 2);
    await store.accountSettings.update(owner.userId, { summary: { style: "standard" } });
    await store.accountSettings.update(owner.userId, { summary: { style: "detailed" } });
    expect((await store.accountSettings.get(owner.userId))?.summary.style).toBe("detailed");
    expect(await store.accountSettings.get(other.userId)).toBeNull();
    await store.close?.();
  });

  it("analyzes only published attached files and commits text, delta and embeddings atomically", async () => {
    const { store, service, publish, attach, file, databasePath } = await fileSetup("catalog.ai.gpt-5-6-luna");
    const jobs = store.imageAnalysis!;
    const analyze = vi.fn(async (_bytes: Uint8Array, settings: AccountSettings) => {
      expect(settings.outputLanguage).toBe("en");
      return { ocr_text: "", caption: "Architecture diagram" };
    });
    const captioner: ImageCaptioner = { model: "catalog.ai.gpt-5-6-luna", analyze };
    await store.accountSettings.update(owner.userId, { outputLanguage: "en" });
    const worker = new ImageAnalysisWorker(jobs, captioner, store.sync, service, store.accountSettings);
    await jobs.reconcile(captioner.model);
    expect(await worker.processOne()).toBe(false);
    await publish();
    await jobs.reconcile(captioner.model);
    expect(await worker.processOne()).toBe(false);
    await attach();
    const secondMeeting = freshId();
    await service.commitTransaction(owner, wire([
      { entity: "meeting", action: "create", entityId: secondMeeting, baseRevision: null, data: { projectId: null, name: "Second", status: "READY", duration: null,
        recordingStartedAt: null, createdAt: now.toISOString(), updatedAt: now.toISOString() } },
      { entity: "meeting_attachment", action: "upsert", entityId: freshId(), baseRevision: null,
        data: { fileId: file.id, meetingId: secondMeeting, capturedAt: now.toISOString(), sessionId: null, createdAt: now.toISOString() } },
    ]));
    const cursor = await service.latestCursor(owner);
    await jobs.reconcile(captioner.model);
    expect(await worker.processOne()).toBe(true);
    expect(analyze).toHaveBeenCalledTimes(1);
    expect(await service.getFile(owner, file.id)).toMatchObject({ revision: 2, metadata: { ocrText: "", caption: "Architecture diagram" } });
    expect(await service.latestCursor(owner)).not.toBe(cursor);
    const database = new DatabaseSync(databasePath);
    expect(database.prepare("SELECT caption_text FROM search_documents WHERE kind = 'screenshot'").all())
      .toEqual([{ caption_text: "architecture diagram" }, { caption_text: "architecture diagram" }]);
    expect(database.prepare("SELECT count(*) AS n FROM jobs_search_index WHERE document_id IN (SELECT document_id FROM search_documents WHERE kind = 'screenshot')").get()).toMatchObject({ n: 2 });
    expect(database.prepare("SELECT count(*) AS n FROM jobs_image_analysis").get()).toMatchObject({ n: 0 });
    database.close();
    await jobs.reconcile(captioner.model);
    expect(await worker.processOne()).toBe(false);
    await store.close?.();
  });

  it("preserves existing captions while backfilling OCR and excludes other identities", async () => {
    const { store, service, publish, attach, file } = await fileSetup("model");
    await publish();
    await attach();
    await service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id, baseRevision: 1,
      data: { checksum: file.checksum, metadata: { caption: "Existing caption" } } }]));
    await store.imageAnalysis!.reconcile("model");
    const claim = (await store.imageAnalysis!.claim("model"))!;
    expect(await store.sync.withIdentity(other, (scoped) => scoped.loadImageAnalysis(claim))).toBeNull();
    const input = (await store.sync.withIdentity(owner, (scoped) => scoped.loadImageAnalysis(claim)))!;
    expect(await service.completeImageAnalysis(other, input, { ocr_text: "OCR", caption: "Replacement" })).toBe(false);
    expect(await service.completeImageAnalysis(owner, input, { ocr_text: "OCR", caption: "Replacement" })).toBe(true);
    expect(await service.getFile(owner, file.id)).toMatchObject({ metadata: { caption: "Existing caption", ocrText: "OCR" } });
    await store.close?.();
  });

  it.each(["edit", "detach", "delete", "lease", "permission"])("rejects an image result after concurrent %s", async (change) => {
    const { store, service, publish, attach, file, databasePath } = await fileSetup("model");
    await publish();
    await attach();
    await store.imageAnalysis!.reconcile("model");
    const claim = (await store.imageAnalysis!.claim("model"))!;
    const input = (await store.sync.withIdentity(owner, (scoped) => scoped.loadImageAnalysis(claim)))!;
    if (change === "edit") {
      await service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id, baseRevision: 1,
        data: { checksum: file.checksum, metadata: { caption: "Concurrent caption" } } }]));
    } else if (change === "permission") {
      const database = new DatabaseSync(databasePath);
      database.prepare("DELETE FROM vault_permissions WHERE principal_id = ?").run(owner.userId);
      database.close();
    } else if (change === "lease") {
      const database = new DatabaseSync(databasePath);
      database.prepare("UPDATE jobs_image_analysis SET lease_expires_at = 0").run();
      database.close();
      const nextClaim = await store.imageAnalysis!.claim("model");
      expect(nextClaim).not.toBeNull();
    } else {
      await service.commitTransaction(owner, wire([{ entity: "meeting_attachment", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
      if (change === "delete") await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    }
    expect(await service.completeImageAnalysis(owner, input, { ocr_text: "stale", caption: "stale" })).toBe(false);
    if (change !== "delete" && change !== "permission") expect((await service.getFile(owner, file.id)).metadata).not.toHaveProperty("ocrText", "stale");
    await store.close?.();
  });

  it("retries transient captioning failures after reopening the database", async () => {
    const { store, service, publish, attach, databasePath } = await fileSetup("model");
    await publish();
    await attach();
    await store.imageAnalysis!.reconcile("model");
    const captioner: ImageCaptioner = { model: "model", analyze: async () => { throw new ImageAnalysisError("captioning_http_429", true); } };
    const worker = new ImageAnalysisWorker(store.imageAnalysis!, captioner, store.sync, service, store.accountSettings);
    expect(await worker.processOne()).toBe(true);
    await store.close?.();
    const database = new DatabaseSync(databasePath);
    expect(database.prepare("SELECT status, attempts, last_error_code FROM jobs_image_analysis").get())
      .toEqual({ status: "pending", attempts: 1, last_error_code: "captioning_http_429" });
    database.prepare("UPDATE jobs_image_analysis SET available_at = 0").run();
    database.close();
    const reopened = createNodeApplicationStore({ ...testConfig(databasePath), captioningModel: "model" });
    expect(await reopened.imageAnalysis!.claim("model")).toMatchObject({ attempts: 1 });
    await reopened.close?.();
  });

  it.each([{ deleted: "file", reserveAgain: true }, { deleted: "vault", reserveAgain: true }, { deleted: "file", reserveAgain: false }])("rejects stale upload completion after $deleted deletion (reserved again=$reserveAgain) and permits a clean retry", async ({ deleted, reserveAgain }) => {
    const { store, service, storage, file, bytes } = await fileSetup();
    const replacement = { ...file, id: freshId() };
    await reservePendingFile(store, replacement);
    let started!: () => void;
    let release!: () => void;
    const didStart = new Promise<void>((resolve) => { started = resolve; });
    const canFinish = new Promise<void>((resolve) => { release = resolve; });
    const put = storage.put.bind(storage);
    vi.spyOn(storage, "put").mockImplementationOnce(async (...args) => {
      started();
      await canFinish;
      await put(...args);
    });
    const upload = () => uploadFile(service, owner, fileUploadRequest(replacement, bytes));
    const uploading = upload();
    const rejected = expect(uploading).rejects.toMatchObject({ status: 503, code: "file_storage_delete_pending" });
    await didStart;
    await service.commitTransaction(owner, wire(deleted === "file"
      ? [{ entity: "file", action: "delete", entityId: replacement.id, baseRevision: null, data: {} }]
      : [{ entity: "vault", action: "reset", entityId: vaultId, baseRevision: 1, data: { preservePermissions: true } }]));
    if (reserveAgain) await reservePendingFile(store, replacement);
    release();
    await rejected;
    const current = await store.sync.withIdentity(owner, (sync) => sync.getFile(replacement.id));
    if (reserveAgain) expect(current).toMatchObject({ active: false, uploadedAt: null });
    else expect(current).toBeNull();
    await vi.waitFor(async () => expect(await store.sync.hasStorageDelete(fileStorageKey(replacement.id))).toBe(false));
    expect(await storage.exists(fileStorageKey(replacement.id))).toBe(false);
    await reservePendingFile(store, replacement);
    await upload();
    await service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: replacement.id, baseRevision: null,
      data: { checksum: file.checksum, metadata: {} } }]));
    expect(await service.getFile(owner, replacement.id)).toMatchObject({ checksum: file.checksum, revision: 1 });
    expect(new Uint8Array(await (await service.readFile(owner, replacement.id, "GET", new Request("https://test.invalid"))).arrayBuffer())).toEqual(bytes);
    await store.close?.();
  });

  it("does not activate an uploaded reservation while original deletion is pending", async () => {
    const { store, service, file, publish } = await fileSetup();
    await store.sync.enqueueStorageDelete(fileStorageKey(file.id));
    await expect(publish()).rejects.toMatchObject({ status: 503, code: "file_storage_delete_pending" });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getFile(file.id))).toMatchObject({ active: false });
    await expect(service.getFile(owner, file.id)).rejects.toMatchObject({ status: 404 });
    await store.close?.();
  });

  it("keeps a deleted file deleted in the delta while its ID is reserved again", async () => {
    const { store, service, storage, file, bytes, publish } = await fileSetup();
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    const published = await publish();
    await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    await vi.waitFor(async () => {
      expect(await storage.exists(fileStorageKey(file.id))).toBe(false);
      expect(await store.sync.hasStorageDelete(fileStorageKey(file.id))).toBe(false);
    });
    await uploadFile(service, owner, fileUploadRequest({ ...file, name: "Private pending replacement" }, bytes));
    for (const identity of [owner, other]) {
      const delta = await service.listChanges(identity, vaultId, published.cursor);
      expect(delta.items.filter((item) => item.entity === "file")).toMatchObject([
        { entityId: file.id, action: "delete", record: null },
      ]);
    }
    expect(await store.sync.withIdentity(owner, (sync) => sync.getFile(file.id))).toMatchObject({ active: false });
    await store.close?.();
  });

  it.each([false, true])("reports a deleted meeting dependency for a new or stale association (existing=%s)", async (existing) => {
    const { store, service, file, publish, attach } = await fileSetup();
    await publish();
    if (existing) await attach();
    await service.commitTransaction(owner, wire([{ entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]));
    const link = { entity: "meeting_attachment" as const, action: "upsert" as const, entityId: file.id,
      baseRevision: existing ? 1 : null,
      data: { fileId: file.id, meetingId, capturedAt: now.toISOString(), sessionId: null, createdAt: now.toISOString() } };
    await expect(service.commitTransaction(owner, wire([link]))).rejects.toMatchObject({ status: 409, code: "revision_conflict",
      conflicts: expect.arrayContaining([{ entity: "meeting", id: meetingId, clientBaseRevision: null, serverRevision: null, record: null }]) as unknown });
    await service.commitTransaction(owner, wire([
      { entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { ...meetingData(), projectId: null, recordingStartedAt: now.toISOString(), createdAt: now.toISOString(), updatedAt: now.toISOString() } },
      { ...link, baseRevision: null },
    ]));
    expect(await service.listFiles(owner, vaultId, undefined, meetingId)).toMatchObject({ items: [{ id: file.id }] });
    await store.close?.();
  });

  it("keeps uploads private until commit, merges metadata, and preserves an unlinked original", async () => {
    const { store, service, storage, file, publish, attach } = await fileSetup();
    await expect(service.getFile(other, file.id)).rejects.toMatchObject({ status: 404 });
    await expect(service.getFile(owner, file.id)).rejects.toMatchObject({ status: 404 });
    expect(await service.listFiles(owner, vaultId)).toMatchObject({ items: [] });
    await publish();
    await attach();
    expect(await service.getFile(owner, file.id)).toMatchObject({ metadata: { source: "screenshot", width: 1800 } });
    await service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id, baseRevision: 1,
      data: { checksum: file.checksum, metadata: { ocrText: "Searchable text" } } }]));
    expect(await service.getFile(owner, file.id)).toMatchObject({ metadata: { source: "screenshot", width: 1800, ocrText: "Searchable text" }, revision: 2 });
    const fileMetadata = await service.getFile(owner, file.id);
    expect(fileMetadata).toMatchObject({ revision: 2,
      contentUrl: `/api/v1/files/${file.id}/content`, metadata: { source: "screenshot", width: 1800 },
      variants: { thumb_480: `/api/v1/files/${file.id}/variants/thumb_480`, thumb_1280: `/api/v1/files/${file.id}/variants/thumb_1280`,
        thumb_1568: `/api/v1/files/${file.id}/variants/thumb_1568`, thumb_1920: `/api/v1/files/${file.id}/variants/thumb_1920` } });
    expect(fileMetadata.metadata).toHaveProperty("ocrText", "Searchable text");
    expect((await service.listScreenshots(owner, vaultId, meetingId, "Searchable")).items).toHaveLength(1);
    await expect(service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id, baseRevision: 1,
      data: { checksum: file.checksum, metadata: { caption: "stale" } } }]))).rejects.toMatchObject({ status: 409 });
    await expect(service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id, baseRevision: 2,
      data: { checksum: file.checksum, metadata: { source: "upload" } } }]))).rejects.toMatchObject({ code: "file_source_immutable" });
    await expect(service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 2, data: {} }]))).rejects.toMatchObject({ code: "file_in_use" });
    await service.commitTransaction(owner, wire([{ entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]));
    expect(await service.listFiles(owner, vaultId)).toMatchObject({ items: [{ id: file.id }] });
    expect(await storage.exists(fileStorageKey(file.id))).toBe(true);
    await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 2, data: {} }]));
    await vi.waitFor(async () => expect(await storage.exists(fileStorageKey(file.id))).toBe(false));
    await store.close?.();
  });

  it.each(Object.entries(SCREENSHOT_VARIANTS))("transforms %s without cropping or enlargement", async (_variant, longEdge) => {
    for (const [width, height] of [[3400, 2200], [2200, 3400], [160, 80]] as const) {
      const bytes = new Uint8Array(await sharp({ create: { width, height, channels: 3, background: "white" } }).png().toBuffer());
      const result = await transformScreenshot(new Response(bytes).body!, longEdge);
      const metadata = await sharp(result).metadata();
      const scale = Math.min(1, longEdge / Math.max(width, height));
      expect(metadata).toMatchObject({ format: "webp", width: Math.round(width * scale), height: Math.round(height * scale) });
    }
  });

  it("advertises, serves and deletes all four variants with distinct caches", async () => {
    const { store, service, storage, file, publish, attach, transformer, databasePath } = await fileSetup();
    await publish();
    await attach();
    const variants = Object.fromEntries(Object.keys(SCREENSHOT_VARIANTS).map((variant) => [variant, `/api/v1/files/${file.id}/variants/${variant}`]));
    expect((await service.getFile(owner, file.id)).variants).toEqual(variants);
    expect((await service.listFiles(owner, vaultId, undefined, meetingId)).items[0]).toMatchObject({ file: { variants } });
    const app = createApp({ config: testConfig(databasePath), authStore: store, objectStorage: storage, screenshotTransformer: transformer });
    const etags = new Set<string | null>();
    for (const variant of Object.keys(SCREENSHOT_VARIANTS) as Array<keyof typeof SCREENSHOT_VARIANTS>) {
      const url = variants[variant]!;
      const response = await app.request(url, { headers: headers() });
      expect(response.status).toBe(200);
      expect(response.headers.get("x-dahlia-image-variant")).toBe(variant);
      etags.add(response.headers.get("etag"));
      await response.arrayBuffer();
      const head = await app.request(url, { method: "HEAD", headers: headers() });
      expect(head.status).toBe(200);
      expect(await head.text()).toBe("");
      expect(head.headers.get("etag")).toBe(response.headers.get("etag"));
      const range = await app.request(url, { headers: { ...headers(), range: "bytes=1-3" } });
      expect(range.status).toBe(206);
      expect((await range.arrayBuffer()).byteLength).toBe(3);
      const internal = await service.readFileContent(owner, file.id, variant);
      expect(internal.contentType).toBe("image/webp");
      await internal.upstream.arrayBuffer();
      await expect(service.readFileContent(other, file.id, variant)).rejects.toMatchObject({ status: 404 });
    }
    expect(etags.size).toBe(4);
    expect(transformer).toHaveBeenCalledTimes(4);
    for (const name of ["thumbnail", "thumb_360", "unknown", "toString"]) {
      expect((await app.request(`/api/v1/files/${file.id}/variants/${name}`, { headers: headers() })).status).toBe(400);
    }
    const portable = createApp({ config: testConfig(databasePath), authStore: store, objectStorage: storage });
    expect((await portable.request(variants.thumb_1280!, { headers: headers() })).status).toBe(404);
    await service.commitTransaction(owner, wire([{ entity: "meeting_attachment", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    await vi.waitFor(async () => {
      for (const variant of Object.keys(SCREENSHOT_VARIANTS) as Array<keyof typeof SCREENSHOT_VARIANTS>) {
        expect(await storage.exists(fileVariantKey(file.id, variant))).toBe(false);
      }
    });
    await store.close?.();
  });

  it.each([undefined, ...Object.keys(SCREENSHOT_VARIANTS)] as Array<keyof typeof SCREENSHOT_VARIANTS | undefined>)(
    "revalidates cached %s content without reading storage and checks current access first", async (variant) => {
      const { store, service, storage, file, publish, transformer, databasePath } = await fileSetup();
      await publish();
      const app = createApp({ config: testConfig(databasePath), authStore: store, objectStorage: storage, screenshotTransformer: transformer });
      const url = `/api/v1/files/${file.id}${variant ? `/variants/${variant}` : "/content"}`;
      const metadata = await app.request(`/api/v1/files/${file.id}`, { headers: headers() });
      expect(metadata.headers.get("cache-control")).toBe("no-store");
      const original = await app.request(url, { headers: headers() });
      expect(original.status).toBe(200);
      expect(original.headers.get("cache-control")).toBe("private, no-cache");
      expect(original.headers.get("vary")).toContain("Authorization");
      expect(original.headers.get("vary")).toContain("Cookie");
      const etag = original.headers.get("etag")!;
      await original.arrayBuffer();
      const read = vi.spyOn(storage, "read");
      const exists = vi.spyOn(storage, "exists");
      transformer.mockClear();
      for (const method of ["GET", "HEAD"]) {
        for (const condition of [etag, `W/${etag}`, `"other,tag", W/${etag}`, "*"]) {
          const response = await app.request(url, { method, headers: { ...headers(), "if-none-match": condition, range: "bytes=1-3" } });
          expect(response.status).toBe(304);
          expect(await response.text()).toBe("");
          expect(response.headers.get("etag")).toBe(etag);
          expect(response.headers.get("cache-control")).toBe("private, no-cache");
          expect(response.headers.has("content-length")).toBe(false);
          expect(response.headers.has("content-range")).toBe(false);
        }
      }
      expect(read).not.toHaveBeenCalled();
      expect(exists).not.toHaveBeenCalled();
      expect(transformer).not.toHaveBeenCalled();
      const changed = await app.request(url, { headers: { ...headers(), "if-none-match": '"different-variant"' } });
      expect(changed.status).toBe(200);
      expect((await changed.arrayBuffer()).byteLength).toBeGreaterThan(0);
      const invalidRange = await app.request(url, { headers: { ...headers(), range: "bytes=999999999-" } });
      expect(invalidRange.status).toBe(416);
      expect(invalidRange.headers.get("cache-control")).toBe("no-store");
      const conditional = new Request("https://test.invalid", { headers: { "if-none-match": etag } });
      await expect(service.readFile(other, file.id, "GET", conditional, variant)).rejects.toMatchObject({ status: 404 });
      const database = new DatabaseSync(databasePath);
      database.prepare("INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, 'user', ?, 'member', ?)")
        .run(vaultId, other.userId, owner.userId);
      const memberHeaders = { ...headers(), "x-forwarded-user": other.userId, "x-forwarded-email": "other@example.com", "if-none-match": etag };
      expect((await app.request(url, { headers: memberHeaders })).status).toBe(304);
      database.prepare("DELETE FROM vault_permissions WHERE principal_id = ?").run(other.userId);
      database.close();
      const revoked = await app.request(url, { headers: memberHeaders });
      expect(revoked.status).toBe(404);
      expect(revoked.headers.get("cache-control")).toBe("no-store");
      if (variant) {
        const portable = createApp({ config: testConfig(databasePath), authStore: store, objectStorage: storage });
        expect((await portable.request(url, { headers: { ...headers(), "if-none-match": etag } })).status).toBe(404);
      }
      await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
      expect((await app.request(url, { headers: { ...headers(), "if-none-match": etag } })).status).toBe(404);
      await store.close?.();
    },
  );

  it.each(["node", "worker"])("honors public validators for files and recording audio through %s", async (runtime) => {
    const { store, service, storage, file, publish, databasePath } = await fileSetup();
    try {
      await publish();
      const sessionId = freshId();
      for (const kind of ["recording_started", "recording_ended"]) {
        await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting_event", action: "create",
          entityId: freshId(), baseRevision: null, data: { meetingId, sessionId, kind, occurredAt: now } }]));
      }
      const audio = new Uint8Array([0, 0, 0, 20, 102, 116, 121, 112, 77, 52, 65, 32, 0, 0, 0, 0, 77, 52, 65, 32]);
      const uploaded = await uploadRecording(service, owner, meetingId, new Request(
        `http://localhost:5173/api/v1/meetings/${meetingId}/recordings?sessionId=${sessionId}&source=mic`, {
          method: "POST", headers: { "content-type": "audio/mp4", "content-length": String(audio.length) }, body: audio,
        }));
      const app = createApp({ config: testConfig(databasePath), authStore: store, objectStorage: storage });
      const worker = createWorkerHandler(async () => app);
      const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
      const send = (path: string, extra: Record<string, string> = {}, method = "GET") => {
        const request = new Request(`http://localhost:5173${path}`, { method, headers: { ...headers(), ...extra } });
        return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
      };
      for (const url of [`/api/v1/files/${file.id}/content`, uploaded.record.contentUrl]) {
        const original = await send(url);
        expect(original.status).toBe(200);
        const bytes = new Uint8Array(await original.arrayBuffer());
        const etag = original.headers.get("etag")!;
        expect((await send(url, { "if-match": '"wrong"', "if-none-match": etag })).status).toBe(412);
        const cached = await send(url, { "if-none-match": etag });
        expect(cached.status).toBe(304);
        expect(await cached.text()).toBe("");
        const resumed = await send(url, { range: "bytes=1-3", "if-range": etag });
        expect(resumed.status).toBe(206);
        expect(new Uint8Array(await resumed.arrayBuffer())).toEqual(bytes.slice(1, 4));
        const replaced = await send(url, { range: "bytes=999999-", "if-range": '"wrong"' });
        expect(replaced.status).toBe(200);
        expect(new Uint8Array(await replaced.arrayBuffer())).toEqual(bytes);
        const head = await send(url, { range: "bytes=999999-" }, "HEAD");
        expect(head.status).toBe(200);
        expect(head.headers.get("content-length")).toBe(String(bytes.length));
        expect(await head.text()).toBe("");
        expect((await send(url, { "if-none-match": etag, "x-forwarded-user": other.userId,
          "x-forwarded-email": "other@example.com" })).status).toBe(404);
      }
      for (const method of ["POST", "PUT"]) {
        const response = await send(`/api/v1/files/${file.id}`, {}, method);
        expect(response.status).toBe(405);
        expect(response.headers.get("allow")?.split(", ").sort()).toEqual(["GET", "HEAD", "PATCH"]);
      }
    } finally { await store.close?.(); }
  });

  it("rejects a file replaced between cache metadata lookup and content read", async () => {
    const { store, service, file, publish } = await fileSetup();
    await publish();
    const withIdentity = store.sync.withIdentity.bind(store.sync);
    const lookup = vi.spyOn(store.sync, "withIdentity");
    lookup.mockImplementationOnce(async (identity, body) => {
      const result = await withIdentity(identity, body);
      // The first lookup models a snapshot taken before deletion and recreation of this ID.
      return { ...result as object, checksum: `SHA-256:${"0".repeat(64)}` };
    });
    await expect(service.readFile(owner, file.id, "GET", new Request("https://test.invalid")))
      .rejects.toMatchObject({ status: 404, code: "file_not_found" });
    lookup.mockRestore();
    await store.close?.();
  });

  it.each([undefined, "thumb_480"] as const)("checks If-Unmodified-Since before cache validation for %s", async (variant) => {
    const { store, service, file, publish } = await fileSetup();
    await publish();
    const original = await service.readFile(owner, file.id, "GET", new Request("https://test.invalid"), variant);
    const etag = original.headers.get("etag")!;
    const lastModified = original.headers.get("last-modified")!;
    await original.arrayBuffer();
    for (const method of ["GET", "HEAD"] as const) {
      for (const [since, status] of [["Thu, 01 Jan 1970 00:00:00 GMT", 412], [lastModified, 304]] as const) {
        const response = await service.readFile(owner, file.id, method, new Request("https://test.invalid", {
          headers: { "if-none-match": etag, "if-unmodified-since": since, range: "bytes=999999999-" },
        }), variant);
        expect(response.status).toBe(status);
        expect(await response.text()).toBe("");
        expect(response.headers.get("cache-control")).toBe(status === 304 ? "private, no-cache" : "no-store");
      }
    }
    await store.close?.();
  });

  it("generates thumbnails only on request, coalesces requests and reuses persisted variants", async () => {
    const { store, service, storage, file, publish, transformer, bytes } = await fileSetup();
    await publish();
    expect(transformer).not.toHaveBeenCalled();
    const read = (value = service) => value.readFile(owner, file.id, "GET", new Request("https://test.invalid"), "thumb_480");
    const results = await Promise.all([read(), read()]);
    expect(await sharp(await results[0].arrayBuffer()).metadata()).toMatchObject({ width: 480, height: 240, format: "webp" });
    await results[1].arrayBuffer();
    expect(transformer).toHaveBeenCalledTimes(1);
    expect(await storage.exists(fileVariantKey(file.id, "thumb_480"))).toBe(true);
    const restarted = new MeetingSyncService(store.sync, storage, undefined, undefined, transformer);
    await (await read(restarted)).arrayBuffer();
    expect(transformer).toHaveBeenCalledTimes(1);
    expect(new Uint8Array(await (await service.readFile(owner, file.id, "GET", new Request("https://test.invalid"))).arrayBuffer())).toEqual(bytes);
    const portable = new MeetingSyncService(store.sync, storage);
    expect(await portable.getFile(owner, file.id)).toMatchObject({ variants: {} });
    await expect(read(portable)).rejects.toMatchObject({ code: "file_variant_unavailable" });
    await expect(service.readFile(other, file.id, "GET", new Request("https://test.invalid"), "thumb_480")).rejects.toMatchObject({ status: 404 });
    await store.close?.();
  });

  it("fails and retries a thumbnail when durable storage fails", async () => {
    const { store, service, storage, file, publish, transformer } = await fileSetup();
    await publish();
    const put = vi.spyOn(storage, "put").mockRejectedValueOnce(new Error("storage failure"));
    const read = () => service.readFile(owner, file.id, "GET", new Request("https://test.invalid"), "thumb_480");
    await expect(read()).rejects.toMatchObject({ status: 502 });
    expect(await storage.exists(fileVariantKey(file.id, "thumb_480"))).toBe(false);
    put.mockRestore();
    await (await read()).arrayBuffer();
    expect(transformer).toHaveBeenCalledTimes(2);
    await store.close?.();
  });

  it("does not publish a variant after its original is deleted during generation", async () => {
    const { store, service, storage, file, publish, transformer } = await fileSetup();
    await publish();
    let started!: () => void;
    let release!: () => void;
    const didStart = new Promise<void>((resolve) => { started = resolve; });
    const canFinish = new Promise<void>((resolve) => { release = resolve; });
    transformer.mockImplementationOnce(async (...args) => {
      started();
      await canFinish;
      return transformScreenshot(...args);
    });
    const reading = service.readFile(owner, file.id, "GET", new Request("https://test.invalid"), "thumb_480");
    const rejected = expect(reading).rejects.toMatchObject({ code: "file_not_found" });
    await didStart;
    await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    release();
    await rejected;
    await vi.waitFor(async () => expect(await storage.exists(fileStorageKey(file.id))).toBe(false));
    expect(await storage.exists(fileVariantKey(file.id, "thumb_480"))).toBe(false);
    await store.close?.();
  });

  it("shares one original across meetings and serves bounded GET and HEAD reads", async () => {
    const { store, service, file, bytes, publish, attach } = await fileSetup();
    await publish();
    await attach();
    const secondMeeting = freshId();
    const linkId = freshId();
    await service.commitTransaction(owner, wire([
      { entity: "meeting", action: "create", entityId: secondMeeting, baseRevision: null, data: { projectId: null, name: "Second", status: "READY", duration: null,
        recordingStartedAt: null, createdAt: now.toISOString(), updatedAt: now.toISOString() } },
      { entity: "meeting_attachment", action: "upsert", entityId: linkId, baseRevision: null,
        data: { fileId: file.id, meetingId: secondMeeting, capturedAt: null, sessionId: null, createdAt: now.toISOString() } },
      { entity: "meeting_attachment", action: "delete", entityId: file.id, baseRevision: 1, data: {} },
    ]));
    expect(await service.listFiles(owner, vaultId, undefined, secondMeeting)).toMatchObject({ items: [{ id: linkId, file: { id: file.id } }] });
    expect(await service.listFiles(owner, vaultId, undefined, meetingId)).toMatchObject({ items: [] });
    const request = new Request("https://test.invalid", { headers: { range: "bytes=1-3" } });
    const range = await service.readFile(owner, file.id, "GET", request);
    expect(range.status).toBe(206);
    expect(new Uint8Array(await range.arrayBuffer())).toEqual(bytes.slice(1, 4));
    const head = await service.readFile(owner, file.id, "HEAD", request);
    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");
    expect(head.headers.get("content-range")).toBeNull();
    expect(head.headers.get("content-length")).toBe(String(bytes.length));
    await store.close?.();
  });

  it("keeps rejected file reservations retryable and expires only unpublished originals", async () => {
    const { store, service, file, bytes, storage, publish } = await fileSetup();
    await expect(service.commitTransaction(owner, wire([
      { entity: "file", action: "upsert", entityId: file.id, baseRevision: null, data: { checksum: file.checksum, metadata: {} } },
      { entity: "vault", action: "update", entityId: vaultId, baseRevision: 0, data: { name: "Conflict" } },
    ]))).rejects.toMatchObject({ status: 409 });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getFile(file.id))).toMatchObject({ active: false });
    expect(await storage.exists(fileStorageKey(file.id))).toBe(true);
    await publish();
    await store.sync.withIdentity(owner, (sync) => sync.expireFileUploads(vaultId, new Date(Date.now() + 86_400_000)));
    expect(await service.getFile(owner, file.id)).toMatchObject({ id: file.id });
    const pending = { ...file, id: freshId() };
    await uploadFile(service, owner, fileUploadRequest(pending, bytes));
    await store.sync.withIdentity(owner, (sync) => sync.expireFileUploads(vaultId, new Date(Date.now() + 86_400_000)));
    expect(await store.sync.withIdentity(owner, (sync) => sync.getFile(pending.id))).toBeNull();
    expect(await store.sync.hasStorageDelete(fileStorageKey(pending.id))).toBe(true);
    await store.close?.();
  });

  it("shares SQLite storage locks across connections without blocking canonical writes", async () => {
    const { store, databasePath } = await setup();
    const second = createNodeApplicationStore(testConfig(databasePath));
    let entered!: () => void;
    let release!: () => void;
    const didEnter = new Promise<void>((resolve) => { entered = resolve; });
    const canFinish = new Promise<void>((resolve) => { release = resolve; });
    const first = store.sync.withStorageKeyLock("original", async () => {
      entered();
      await canFinish;
      throw new Error("failed storage operation");
    });
    const rejected = expect(first).rejects.toThrow("failed storage operation");
    await didEnter;
    let secondEntered = false;
    const next = second.sync.withStorageKeyLock("variant", async () => { secondEntered = true; });
    try {
      await createVault(store);
      expect(secondEntered).toBe(false);
    } finally {
      release();
      await rejected;
      await next;
      await second.close?.();
      await store.close?.();
    }
    expect(secondEntered).toBe(true);
  });

  it.each([false, true])("preserves immutable uploads across SQLite instances (different bytes: %s)", async (different) => {
    const { store, service, storage, file, bytes } = await fileSetup();
    const second = new MeetingSyncService(store.sync, storage, undefined, undefined, undefined, "/Volumes/test/app/files");
    const pending = { ...file, id: freshId() };
    try {
      const results = await Promise.allSettled([
        uploadFile(service, owner, fileUploadRequest(pending, bytes)),
        uploadFile(second, owner, fileUploadRequest(pending, different ? new Uint8Array(bytes.length) : bytes)),
      ]);
      const record = await store.sync.withIdentity(owner, (scoped) => scoped.getFile(pending.id));
      expect(record?.uploadedAt).not.toBeNull();
      const response = await storage.read(fileStorageKey(pending.id), "GET", new Request("http://localhost"));
      expect(response.status).toBe(200);
      expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(different ? 1 : 2);
      if (different) expect(results.find((result) => result.status === "rejected")).toMatchObject({ reason: { status: 409 } });
      const stored = await response.arrayBuffer();
      expect(`SHA-256:${Buffer.from(await crypto.subtle.digest("SHA-256", stored)).toString("hex")}`).toBe(record?.checksum);
    } finally {
      await store.close?.();
    }
  });

  it.each(["node", "worker"].flatMap((runtime) => ["PATCH"].map((method) => [runtime, method])))("uploads raw bytes and updates canonical metadata through %s %s", async (runtime, method) => {
    const { store, service, file, bytes, databasePath, storage, publish, attach } = await fileSetup();
    const app = createApp({ config: { ...testConfig(databasePath), storageBackend: "databricks", storageDatabricksVolumePath: "/Volumes/test/app/files" }, authStore: store, objectStorage: storage });
    const worker = createWorkerHandler(async () => app);
    const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (request: Request) => {
      for (const [key, value] of Object.entries(headers())) if (!request.headers.has(key)) request.headers.set(key, value);
      return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
    const patch = (body: unknown, id = file.id) => send(new Request(`http://localhost:5173/api/v1/files/${id}`, {
      method, headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    }));
    const reservation = (file: Parameters<typeof fileUploadRequest>[0]) => ({ id: file.id, vaultId: file.vaultId, name: file.name, contentType: file.content_type, metadata: file.metadata });
    const reserve = (body: unknown, extraHeaders: Record<string, string> = {}) => send(new Request("http://localhost:5173/api/v1/file-uploads", {
      method: "POST", headers: { "content-type": "application/json", ...extraHeaders }, body: JSON.stringify(body),
    }));
    const upload = async (file: Parameters<typeof fileUploadRequest>[0], bytes: Uint8Array<ArrayBuffer>, size: number | undefined = bytes.length, extraHeaders: Record<string, string> = {}) => {
      const reserved = await reserve(reservation(file), extraHeaders);
      if (!reserved.ok) return reserved;
      return send(new Request(`http://localhost:5173/api/v1/file-uploads/${file.id}/content`, { method: "PUT", body: bytes,
        headers: { "content-type": "application/octet-stream", ...(size === -1 ? {} : { "content-length": String(size) }), ...extraHeaders } }));
    };
    const fresh = { ...file, id: freshId(), name: "会議 + 売上&#?.png" };
    const created = await upload(fresh, bytes);
    expect(created.status).toBe(201);
    const createdBody = await created.json();
    expect(createdBody).toMatchObject({ id: fresh.id, name: fresh.name, size: bytes.length, checksum: file.checksum,
      contentUrl: `/api/v1/files/${fresh.id}/content`, metadata: { source: "screenshot", width: 1800, height: 900 } });
    expect(createdBody).not.toHaveProperty("uri");
    expect(createdBody).not.toHaveProperty("offset");
    expect(await service.listFiles(owner, vaultId)).toMatchObject({ items: [] });
    expect((await patch({ baseRevision: 1, metadata: { caption: "pending" } }, fresh.id)).status).toBe(404);
    const put = vi.spyOn(storage, "put");
    expect((await upload(file, bytes)).status).toBe(200);
    expect((await upload(file, new Uint8Array(bytes.length))).status).toBe(409);
    expect((await upload(file, bytes, 1)).status).toBe(409);
    expect((await upload(file, new Uint8Array(bytes.length + 1), bytes.length)).status).toBe(413);
    expect((await upload(file, bytes.subarray(1), bytes.length)).status).toBe(400);
    expect(put).not.toHaveBeenCalled();
    for (const value of [{ ...reservation(file), metadata: { source: "other" } }, { ...reservation(file), id: crypto.randomUUID() }, { ...reservation(file), size: 1 }]) {
      expect((await reserve(value)).status).toBe(400);
    }
    expect((await send(new Request("http://localhost:5173/api/v1/file-uploads?id=x&id=y", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(reservation(file)) }))).status).toBe(400);
    expect((await send(new Request("http://localhost:5173/api/v1/file-uploads", { method: "POST", body: JSON.stringify(reservation(file)) }))).status).toBe(415);
    expect((await send(new Request(`http://localhost:5173/api/v1/files/${file.id}/content`, { method: "PUT", body: bytes }))).status).toBe(405);
    expect((await upload(fresh, bytes, -1)).status).toBe(411);
    expect((await upload(fresh, bytes, 64 * 1024 * 1024 + 1)).status).toBe(413);
    expect((await upload({ ...file, id: freshId() }, bytes, bytes.length, { "x-forwarded-user": other.userId, "x-forwarded-email": "other@example.com" })).status).toBe(404);
    expect((await upload(fresh, bytes, bytes.length, { origin: "https://other.example" })).status).toBe(403);
    const empty = await upload({ ...fresh, id: freshId() }, new Uint8Array());
    expect(empty.status).toBe(201);
    expect(await empty.json()).toMatchObject({ size: 0, checksum: `SHA-256:${Buffer.from(await crypto.subtle.digest("SHA-256", new Uint8Array())).toString("hex")}` });
    await publish();
    await attach();
    const originalURL = `http://localhost:5173/api/v1/files/${file.id}/content`;
    const original = await send(new Request(originalURL));
    expect(original.status).toBe(200);
    expect(new Uint8Array(await original.arrayBuffer())).toEqual(bytes);
    const readOriginal = vi.spyOn(storage, "read");
    const head = await send(new Request(originalURL, { method: "HEAD", headers: { range: "bytes=1-3" } }));
    expect(head.status).toBe(200);
    expect(head.headers.get("content-length")).toBe(String(bytes.length));
    expect(head.headers.get("content-type")).toBe("image/png");
    expect(head.headers.get("etag")).toBe(original.headers.get("etag"));
    expect(await head.text()).toBe("");
    expect(head.headers.has("content-range")).toBe(false);
    expect(readOriginal).toHaveBeenCalledTimes(1);
    expect(readOriginal.mock.calls[0]![1]).toBe("HEAD");
    readOriginal.mockClear();
    const deniedHead = new Request(originalURL, { method: "HEAD", headers: { "x-forwarded-user": other.userId, "x-forwarded-email": "other@example.com" } });
    const denied = await send(deniedHead);
    expect(denied.status).toBe(404);
    expect(await denied.text()).toBe("");
    expect(readOriginal).not.toHaveBeenCalled();
    readOriginal.mockRestore();
    expect((await send(new Request(`${originalURL}/content`))).status).toBe(404);
    expect((await send(new Request(originalURL, { method: "PATCH", body: "{}" }))).status).toBe(405);
    const metadata = await send(new Request(`http://localhost:5173/api/v1/files/${file.id}`));
    expect(metadata.status).toBe(200);
    expect(await metadata.json()).toMatchObject({ id: file.id, revision: 1, metadata: { source: "screenshot", ocrText: null, caption: null } });
    const cursor = await service.latestCursor(owner);
    const updated = await patch({ baseRevision: 1, metadata: { ocrText: "QuarterlyRevenue", caption: "Quarterly chart" } });
    expect(updated.status).toBe(200);
    expect(await updated.json()).toMatchObject({ id: file.id, size: bytes.length, checksum: file.checksum, revision: 2,
      contentUrl: `/api/v1/files/${file.id}/content`, metadata: { source: "screenshot", width: 1800, height: 900, ocrText: "QuarterlyRevenue", caption: "Quarterly chart" } });
    expect((await service.listChanges(owner, vaultId, cursor)).items).toEqual(expect.arrayContaining([
      expect.objectContaining({ entity: "file", entityId: file.id, revision: 2, record: expect.objectContaining({ contentOmitted: true, metadata: { source: "screenshot", width: 1800, height: 900 } }) as unknown }),
    ]));
    for (const route of ["snapshot", "changes"]) {
      const response = await send(new Request(`http://localhost:5173/api/v1/vaults/${vaultId}/${route}`));
      expect(response.status).toBe(200);
      const page: { items: Array<{ entity: string; record: Record<string, unknown> }> } = await response.json();
      expect(page).not.toHaveProperty("contentMode");
      expect(page.items.find((item) => item.entity === "file")?.record).toMatchObject({
        revision: 2, contentOmitted: true, contentPresent: true,
        metadata: { source: "screenshot", width: 1800, height: 900 },
      });
      expect(JSON.stringify(page)).not.toContain("QuarterlyRevenue");
      expect(JSON.stringify(page)).not.toContain("Quarterly chart");
    }
    expect((await send(new Request(`http://localhost:5173/api/v1/vaults/${vaultId}/text/file/${file.id}?revision=2`))).status).toBe(404);
    expect(await service.searchText(owner, vaultId, "QuarterlyRevenue", "screenshot")).toMatchObject({ items: [expect.anything()] });
    expect(await service.searchAll(owner, { vaultId, query: "QuarterlyRevenue", kind: "screenshot", limit: 1 }))
      .toMatchObject({ meetings: [], screenshots: [{ meetingId, fileId: file.id, snippet: expect.stringContaining("QuarterlyRevenue") as unknown }], limited: { screenshot: false } });
    expect(await service.searchAll(owner, { vaultId, query: "QuarterlyRevenue", kind: "screenshot", to: "2000-01-01T00:00:00Z" }))
      .toMatchObject({ screenshots: [] });

    expect(await (await send(new Request(`http://localhost:5173/api/v1/files/${file.id}`))).json()).toMatchObject({ revision: 2,
      metadata: { ocrText: "QuarterlyRevenue", caption: "Quarterly chart" } });
    const stale = await patch({ baseRevision: 1, metadata: { caption: "stale" } });
    expect(stale.status).toBe(409);
    expect(await stale.json()).toMatchObject({ conflicts: [{ serverRevision: 2, record: { metadata: { caption: "Quarterly chart" } } }] });
    const cleared = await patch({ baseRevision: 2, metadata: { caption: null } });
    expect(cleared.status).toBe(200);
    expect(await cleared.json()).toMatchObject({ revision: 3, metadata: { caption: null, ocrText: "QuarterlyRevenue", width: 1800 } });
    for (const metadata of [{ source: "upload" }, { width: 0 }, { caption: "x".repeat(501) }, { ocrText: "x".repeat(20001) }, { unexpected: "value" }]) {
      expect((await patch({ baseRevision: 3, metadata })).status).toBe(400);
    }
    expect((await patch({ metadata: { caption: "missing revision" } })).status).toBe(400);
    expect((await patch({ baseRevision: 3, size: 0, metadata: {} })).status).toBe(400);
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    const memberPatch = new Request(`http://localhost:5173/api/v1/files/${file.id}`, { method,
      headers: { ...headers(), "x-forwarded-user": other.userId, "x-forwarded-email": "other@example.com" },
      body: JSON.stringify({ baseRevision: 3, metadata: { caption: "member" } }) });
    expect((await send(memberPatch)).status).toBe(404);
    expect((await upload({ ...file, name: "different", metadata: { ...file.metadata, width: 1 } }, bytes)).status).toBe(409);
    expect(await service.getFile(owner, file.id)).toMatchObject({ name: file.name, revision: 3, metadata: { width: 1800, ocrText: "QuarterlyRevenue", caption: null } });
    expect(new Uint8Array(await (await service.readFile(owner, file.id, "GET", new Request("http://localhost:5173"))).arrayBuffer())).toEqual(bytes);
    await store.close?.();
  });

  it.each(["short", "long", "interrupted", "storage", "cleanup"])("keeps a failed raw upload retryable (%s)", async (failure) => {
    const { store, service, storage, file, bytes } = await fileSetup();
    const pending = { ...file, id: freshId() };
    const key = fileStorageKey(pending.id);
    let request = fileUploadRequest(pending, bytes);
    if (failure === "short") request = fileUploadRequest(pending, bytes.subarray(1), bytes.length);
    if (failure === "long") request = fileUploadRequest(pending, bytes, bytes.length - 1);
    if (failure === "interrupted") {
      const body = new ReadableStream<Uint8Array>({ start(controller) {
        controller.enqueue(bytes.subarray(0, 1));
        controller.error(new Error("interrupted upload"));
      } });
      request = new Request(request.url, { method: "POST", headers: request.headers, body, duplex: "half" } as RequestInit);
    }
    const cancelled = vi.fn();
    if (failure === "storage" || failure === "cleanup") {
      const body = new ReadableStream<Uint8Array>({ pull(controller) { controller.enqueue(bytes); }, cancel: cancelled });
      request = new Request(request.url, { method: "POST", headers: request.headers, body, duplex: "half" } as RequestInit);
      vi.spyOn(storage, "put").mockRejectedValueOnce(new Error("storage failed before consuming the stream"));
    }
    if (failure === "cleanup") vi.spyOn(storage, "delete").mockRejectedValueOnce(new Error("cleanup failed"));
    await expect(uploadFile(service, owner, request)).rejects.toBeDefined();
    expect(await store.sync.withIdentity(owner, (scoped) => scoped.getFile(pending.id))).toMatchObject({ active: false, uploadedAt: null, size: 0, checksum: "" });
    if (failure === "storage" || failure === "cleanup") await vi.waitFor(() => expect(cancelled).toHaveBeenCalled());
    await vi.waitFor(async () => expect(await store.sync.hasStorageDelete(key)).toBe(false));
    expect(await storage.exists(key)).toBe(false);
    const retried = await uploadFile(service, owner, fileUploadRequest(pending, bytes));
    expect(retried.file).toMatchObject({ id: pending.id, size: bytes.length, checksum: file.checksum });
    await store.close?.();
  });

  it.each(["storage", "cleanup", "interrupted"])("keeps a failed recording upload retryable (%s)", async (failure) => {
    const { store, service, storage } = await fileSetup();
    const sessionId = freshId();
    for (const kind of ["recording_started", "recording_ended"]) {
      await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting_event", action: "create",
        entityId: freshId(), baseRevision: null, data: { meetingId, sessionId, kind, occurredAt: now } }]));
    }
    const bytes = new Uint8Array([0, 0, 0, 20, 102, 116, 121, 112, 77, 52, 65, 32, 0, 0, 0, 0, 77, 52, 65, 32]);
    const url = `http://localhost:5173/api/v1/meetings/${meetingId}/recordings?sessionId=${sessionId}&source=mic`;
    const headers = { "content-type": "audio/mp4", "content-length": String(bytes.length) };
    const cancelled = vi.fn();
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (failure === "interrupted") controller.error(new Error("interrupted upload"));
        else controller.enqueue(bytes);
      },
      cancel: cancelled,
    });
    if (failure !== "interrupted") vi.spyOn(storage, "put").mockRejectedValueOnce(new Error("storage failed before consuming the stream"));
    if (failure === "cleanup") vi.spyOn(storage, "delete").mockRejectedValueOnce(new Error("cleanup failed"));
    await expect(uploadRecording(service, owner, meetingId,
      new Request(url, { method: "POST", headers, body, duplex: "half" } as RequestInit))).rejects.toBeDefined();
    const key = `meetings/${meetingId}/recordings/audio_mic_01.m4a`;
    const record = await store.sync.withIdentity(owner, (scoped) => scoped.getRecording(meetingId, 1, true));
    expect(record?.audio.mic?.uploadedAt).toBeNull();
    if (failure !== "interrupted") await vi.waitFor(() => expect(cancelled).toHaveBeenCalled());
    await vi.waitFor(async () => expect(await store.sync.hasStorageDelete(key)).toBe(false));
    expect(await storage.exists(key)).toBe(false);
    const retried = await uploadRecording(service, owner, meetingId, new Request(url, { method: "POST", headers, body: bytes }));
    expect(retried).toMatchObject({ created: true, record: { id: 1, size: bytes.length } });
    await store.close?.();
  });

  it("serializes competing uploads without replacing the first completed bytes", async () => {
    const { store, service, storage, file, bytes } = await fileSetup();
    const pending = { ...file, id: freshId() };
    const put = vi.spyOn(storage, "put");
    const results = await Promise.allSettled([
      uploadFile(service, owner, fileUploadRequest(pending, bytes)),
      uploadFile(service, owner, fileUploadRequest(pending, bytes)),
      uploadFile(service, owner, fileUploadRequest(pending, new Uint8Array(bytes.length))),
    ]);
    expect(results).toMatchObject([
      { status: "fulfilled", value: { created: true, file: { checksum: file.checksum } } },
      { status: "fulfilled", value: { created: false, file: { checksum: file.checksum } } },
      { status: "rejected", reason: { status: 409 } },
    ]);
    expect(put).toHaveBeenCalledTimes(1);
    await store.close?.();
  });

  it("streams exactly 64 MiB without accepting an extra byte", async () => {
    const { store, service, storage, file } = await fileSetup();
    const maximum = 64 * 1024 * 1024;
    const chunk = new Uint8Array(1024 * 1024);
    vi.spyOn(storage, "put").mockImplementation(async (_key, body) => {
      if (body instanceof Uint8Array) throw new Error("upload must stream");
      const reader = body.getReader();
      while (!(await reader.read()).done) { /* Drain without buffering. */ }
    });
    for (const extra of [false, true]) {
      const pending = { ...file, id: freshId() };
      const request = fileUploadRequest(pending, new Uint8Array(), maximum);
      let sent = 0;
      const body = new ReadableStream<Uint8Array>({ pull(controller) {
        if (sent < maximum) { sent += chunk.byteLength; controller.enqueue(chunk); }
        else { if (extra) controller.enqueue(new Uint8Array(1)); controller.close(); }
      } });
      const uploading = uploadFile(service, owner, new Request(request.url, { method: "POST", headers: request.headers, body, duplex: "half" } as RequestInit));
      if (extra) await expect(uploading).rejects.toMatchObject({ status: 413, code: "file_size_mismatch" });
      else expect((await uploading).file).toMatchObject({ size: maximum, checksum: `SHA-256:${Buffer.from(await crypto.subtle.digest("SHA-256", new Uint8Array(maximum))).toString("hex")}` });
    }
    await store.close?.();
  }, 15000);

  it.each(["node", "worker"])("pages through identically named sharing targets on %s so every grant remains revocable", async (runtime) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const teamIds: string[] = [];
    for (let index = 0; index < 51; index++) {
      const team = (await store.createExternalTeam(owner.userId, "Repeated team"))!;
      teamIds.push(team.id);
    }
    const lastTeamId = teamIds.toSorted().at(-1)!;
    const service = new MeetingSyncService(store.sync);
    await service.putMemberPermission(owner, vaultId, "team", lastTeamId);
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const request = (path: string, method = "GET"): Promise<Response> => {
      const req = new Request(`http://localhost:5173/api/v1/vaults/${vaultId}/${path}`, { method, headers: headers() });
      return Promise.resolve(runtime === "node" ? app.request(req) : fetchWorker(req, {} as Cloudflare.Env, {} as ExecutionContext));
    };
    const pageSchema = z.object({ items: z.array(z.object({ principalId: z.string() })), nextCursor: z.string().nullable() });
    const first = pageSchema.parse(await (await request("permission-targets?q=Repeated%20team")).json());
    expect(first.items).toHaveLength(50);
    expect(first.nextCursor).not.toBeNull();
    expect(first.items.map((item) => item.principalId)).not.toContain(lastTeamId);
    const second = pageSchema.parse(await (await request(`permission-targets?q=Repeated%20team&cursor=${first.nextCursor}`)).json());
    expect(second.items).toEqual([{ principalId: lastTeamId }]);
    expect(second.nextCursor).toBeNull();
    expect(new Set([...first.items, ...second.items].map((item) => item.principalId)).size).toBe(51);
    expect((await request(`permissions/teams/${second.items[0]!.principalId}`, "DELETE")).status).toBe(204);
    expect((await service.listPermissions(owner, vaultId)).some((permission) => permission.principalId === lastTeamId)).toBe(false);
    for (const cursor of ["-1", "1.5", "abc", "9007199254740992"]) {
      expect((await request(`permission-targets?cursor=${cursor}`)).status).toBe(400);
    }
    await store.close?.();
  });

  it.each(["node", "worker"])("searches scoped sharing targets and protects direct grants on %s", async (runtime) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const team = (await store.createExternalTeam(owner.userId, "Design 100%"))!;
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const request = async (path: string, method = "GET", user = owner.userId, origin = "http://localhost:5173"): Promise<Response> => {
      const req = new Request(`http://localhost:5173/api/v1/vaults/${vaultId}/${path}`, { method,
        headers: { ...headers(), origin, "x-forwarded-user": user, "x-forwarded-email": `${user}@example.com` } });
      return Promise.resolve(runtime === "node" ? app.request(req) : fetchWorker(req, {} as Cloudflare.Env, {} as ExecutionContext));
    };
    expect(await (await request("permission-targets")).json()).toHaveProperty("items", expect.arrayContaining([
      expect.objectContaining({ principalType: "organization" }),
      expect.objectContaining({ principalType: "team", principalId: team.id }),
      expect.objectContaining({ principalType: "user", principalId: other.userId }),
    ]));
    expect(await (await request("permission-targets?q=100%25")).json()).toMatchObject({ items: [{ principalId: team.id }] });
    expect(await (await request("permission-targets?q=does-not-exist")).json()).toEqual({ items: [], nextCursor: null });
    expect((await request(`permission-targets?q=${"a".repeat(201)}`)).status).toBe(400);
    expect((await request("permission-targets", "GET", other.userId)).status).toBe(404);
    expect((await request(`permissions/users/${other.userId}`, "PUT", owner.userId, "https://evil.example")).status).toBe(403);
    expect((await request(`permissions/users/${other.userId}`, "PUT", other.userId)).status).toBe(404);
    expect((await request(`permissions/users/${owner.userId}`, "PUT")).status).toBe(404);
    expect((await request(`permissions/users/${owner.userId}`, "DELETE")).status).toBe(404);
    expect((await request(`permissions/users/${other.userId}`, "PUT")).status).toBe(204);
    expect(await store.sync.withIdentity(other, (scoped) => scoped.listVaults())).toMatchObject([{ vaultId, role: "member" }]);
    expect((await request("permission-targets", "GET", other.userId)).status).toBe(404);
    const raw = new DatabaseSync(databasePath);
    raw.prepare("DELETE FROM member WHERE user_id = ?").run(other.userId);
    // Existing direct grants can be found and revoked after leaving the organization.
    expect(await (await request("permission-targets")).json()).toHaveProperty("items", expect.arrayContaining([
      expect.objectContaining({ principalType: "user", principalId: other.userId }),
    ]));
    expect((await request(`permissions/users/${other.userId}`, "DELETE")).status).toBe(204);
    expect((await request(`permissions/users/${other.userId}`, "PUT")).status).toBe(404);
    const targets = z.object({ items: z.array(z.object({ principalId: z.string() })) }).parse(await (await request("permission-targets")).json());
    expect(targets.items.some((item) => item.principalId === other.userId || item.principalId === owner.userId)).toBe(false);
    expect(await store.sync.withIdentity(other, (scoped) => scoped.listVaults())).toEqual([]);
    expect(await store.sync.withIdentity(owner, (scoped) => scoped.listVaults())).toMatchObject([{ vaultId, role: "owner" }]);
    raw.close();
    await store.close?.();
  });

  it("filters Vaults by owner or current organization and Team membership", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const service = new MeetingSyncService(store.sync);
    expect(await service.listVaults(owner)).toHaveLength(1);
    expect(await service.listVaults(other)).toEqual([]);
    expect(await service.listVaults(owner, undefined, "01990ab0-0000-7000-8000-000000000001")).toEqual([]);
    const team = (await store.createExternalTeam(owner.userId, "Private team"))!;
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "team", team.id));
    expect(await service.listVaults(other, undefined, "01990ab0-0000-7000-8000-000000000001")).toEqual([]);
    await store.addExternalTeamMember(owner.userId, team.id, other.userId);
    expect(await service.listVaults(other, undefined, "01990ab0-0000-7000-8000-000000000001")).toMatchObject([{ vaultId, role: "member" }]);
    // Two access paths must still produce one Vault.
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    expect(await service.listVaults(other, undefined, "01990ab0-0000-7000-8000-000000000001")).toHaveLength(1);
    expect(await service.listVaults(other, other.userId)).toEqual([]);
    expect(await service.listVaults(other)).toMatchObject([{ vaultId, role: "member" }]);
    const database = new DatabaseSync(databasePath);
    database.exec(`
      INSERT INTO organization (id, name, slug, created_at) VALUES ('another', 'Another', 'another', 0);
      INSERT INTO member (id, organization_id, user_id, role, created_at)
        VALUES ('another-member', 'another', '${other.userId}', 'member', 0);
    `);
    expect(await service.listVaults(other, undefined, "another")).toEqual([]);
    // A stale Team row cannot bypass loss of organization membership.
    database.prepare("DELETE FROM member WHERE user_id = ? AND organization_id = ?").run(other.userId, "01990ab0-0000-7000-8000-000000000001");
    await expect(service.listVaults(other, undefined, "01990ab0-0000-7000-8000-000000000001")).rejects.toMatchObject({ status: 403 });
    expect(await service.listOrganizations(other)).toMatchObject([{ id: "another" }]);
    database.close();
    await store.close?.();
  });

  it.each(["node", "worker"])("lists all accessible Vaults by default and filters their owner on %s", async (runtime) => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const database = new DatabaseSync(databasePath);
    database.prepare("INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES (?, 'user', ?, 'member', ?)")
      .run(vaultId, other.userId, owner.userId);
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const list = async (query: string, user = other.userId) => {
      const request = new Request(`http://localhost:5173/api/v1/vaults${query}`, { headers: {
        ...headers(), "x-forwarded-user": user, "x-forwarded-email": `${user}@example.com`,
      } });
      const response = await (runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext));
      expect(response.status).toBe(200);
      return response.json();
    };
    expect(await list("")).toMatchObject({ items: [{ vaultId, role: "member" }] });
    expect(await list("", owner.userId)).toMatchObject({ items: [{ vaultId, role: "owner" }] });
    expect(await list("", "unrelated")).toMatchObject({ items: [] });
    expect(await list(`?owner=${owner.userId}`)).toMatchObject({ items: [{ vaultId, role: "member" }] });
    expect(await list(`?owner=${other.userId}`)).toMatchObject({ items: [] });
    expect(await list(`?owner=${owner.userId}`, "unrelated")).toMatchObject({ items: [] });
    database.prepare("DELETE FROM vault_permissions WHERE principal_id = ? AND role = 'member'").run(other.userId);
    expect(await list("")).toMatchObject({ items: [] });
    database.close();
    await store.close?.();
  });

  it("validates the exclusive Vault query at the HTTP boundary", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    for (const query of ["", `?owner=${owner.userId}`]) {
      const response = await app.request("/api/v1/vaults" + query, { headers: headers() });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ items: [{ vaultId }] });
    }
    for (const query of ["?owner=", "?organizationId=", "?owner=%20owner", "?organizationId=%00", "?scope=accessible",
      `?userId=${owner.userId}`, `?owner=${owner.userId}&organizationId=${freshId()}`]) {
      expect((await app.request("/api/v1/vaults" + query, { headers: headers() })).status).toBe(400);
    }
    expect((await app.request(`/api/v1/vaults?organizationId=${freshId()}`, { headers: headers() })).status).toBe(403);
    const session = await app.request("/api/v1/session", { headers: headers() });
    expect(await session.json()).toMatchObject({ capabilities: { sharing: true } });
    const organizations = await app.request("/api/v1/organizations", { headers: headers() });
    expect(await organizations.json()).toMatchObject({ items: [{ id: "01990ab0-0000-7000-8000-000000000001" }], nextCursor: null });
    await store.close?.();
  });

  it("paginates direct and unassigned meetings without including child Project meetings", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const childId = "019d3f46-8c00-7000-8000-000000000002";
    const childMeetingId = "019d3f46-8c00-7000-8000-000000000003";
    const unassignedId = "019d3f46-8c00-7000-8000-000000000004";
    await commit(store, owner, transaction("019d4a01-9000-7000-8000-000000000001", [
      { id: projectId, entity: "project", action: "create", entityId: projectId, baseRevision: null, data: projectData("Parent") },
      { id: childId, entity: "project", action: "create", entityId: childId, baseRevision: null, data: { ...projectData("Child"), parentProjectId: projectId, projectType: null } },
      ...Array.from({ length: 201 }, (_, index) => {
        const id = `019d4a01-9100-7000-8000-${String(index).padStart(12, "0")}`;
        return { id, entity: "meeting" as const, action: "create" as const, entityId: id, baseRevision: null, data: meetingData() };
      }),
      { id: childMeetingId, entity: "meeting", action: "create", entityId: childMeetingId, baseRevision: null, data: { ...meetingData(), projectId: childId } },
      { id: unassignedId, entity: "meeting", action: "create", entityId: unassignedId, baseRevision: null, data: { ...meetingData(), projectId: null } },
    ]));
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    const get = async (query: string) => app.request(`/api/v1/vaults/${vaultId}/meetings?${query}`, { headers: headers() });
    const pageSchema = z.object({ items: z.array(z.object({ meetingId: z.string(), projectId: z.string().nullable() })), nextCursor: z.string().nullable() });
    const first = pageSchema.parse(await (await get(`projectId=${projectId}&projectScope=direct`)).json());
    expect(first.items).toHaveLength(200);
    expect(first.items.every((item) => item.projectId === projectId)).toBe(true);
    expect(first.nextCursor).toBeDefined();
    const last = pageSchema.parse(await (await get(`projectId=${projectId}&projectScope=direct&cursor=${encodeURIComponent(first.nextCursor!)}`)).json());
    expect(last.items).toHaveLength(1);
    expect(last.nextCursor).toBeNull();
    expect(new Set([...first.items, ...last.items].map(({ meetingId }) => meetingId)).size).toBe(201);
    expect(await (await get("projectScope=unassigned")).json()).toMatchObject({ items: [{ meetingId: unassignedId }] });
    expect(await (await get(`projectId=${childId}&projectScope=direct`)).json()).toMatchObject({ items: [{ meetingId: childMeetingId }] });
    const legacy = await store.sync.withIdentity(owner, (sync) => sync.listMeetings(vaultId, undefined, 300, projectId));
    expect(legacy).toHaveLength(202);
    for (const query of ["projectScope=direct", "projectScope=unknown", `projectScope=subtree&projectId=${projectId}`, `projectScope=unassigned&projectId=${projectId}`]) {
      expect((await get(query)).status).toBe(400);
    }
    await store.close?.();
  });

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

    const sameNamedProjects = transaction("019d4a01-0000-7000-8000-000000000003", [
      {
        id: "019d4a01-0000-7000-8000-000000000004",
        entity: "project",
        action: "create",
        entityId: projectId,
        baseRevision: null,
        data: projectData("Same name"),
      },
      {
        id: "019d4a01-0000-7000-8000-000000000005",
        entity: "project",
        action: "create",
        entityId: "019d3f46-8c00-7000-8000-000000000002",
        baseRevision: null,
        data: projectData("Same name"),
      },
    ]);
    await expect(commit(store, owner, sameNamedProjects)).resolves.toMatchObject({ status: "committed" });
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId)))
      .toHaveLength(2);

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
    await commit(store, owner, transaction("019d4a01-1000-7000-8000-000000000005", [{
      id: "019d4a01-1000-7000-8000-000000000006",
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: projectData("Existing"),
    }]));
    const duplicateCreateOperationId = "019d4a01-1000-7000-8000-000000000008";
    await expect(commit(store, owner, transaction("019d4a01-1000-7000-8000-000000000007", [{
      id: duplicateCreateOperationId,
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: projectData("Local"),
    }]))).rejects.toMatchObject({
      status: 409,
      code: "revision_conflict",
      operationId: duplicateCreateOperationId,
      conflicts: [{ entity: "project", serverRevision: 1, record: { name: "Existing" } }],
    });
    expect(await store.sync.withIdentity(other, (sync) => sync.getVault(vaultId))).toBeNull();
    await store.close?.();
  });

  it("revision-fences destructive Vault resets", async () => {
    const { store } = await setup();
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-1001-7000-8000-000000000001", [{
      id: "019d4a01-1001-7000-8000-000000000002",
      entity: "vault",
      action: "update",
      entityId: vaultId,
      baseRevision: 1,
      data: { name: "Newer" },
    }]));
    await expect(commit(store, owner, transaction("019d4a01-1001-7000-8000-000000000003", [{
      id: "019d4a01-1001-7000-8000-000000000004",
      entity: "vault",
      action: "reset",
      entityId: vaultId,
      baseRevision: 1,
      data: { preservePermissions: true },
    }]))).rejects.toMatchObject({
      status: 409,
      code: "revision_conflict",
      conflicts: [{ entity: "vault", serverRevision: 2 }],
    });
    await expect(commit(store, owner, transaction("019d4a01-1001-7000-8000-000000000005", [{
      id: "019d4a01-1001-7000-8000-000000000006",
      entity: "vault",
      action: "reset",
      entityId: vaultId,
      baseRevision: 2,
      data: { preservePermissions: true },
    }]))).resolves.toMatchObject({ status: "committed" });
    await store.close?.();
  });

  it.each(["node", "worker"])("rejects non-owner Vault restoration atomically through %s", async (runtime) => {
    const { store, databasePath } = await setup();
    const database = new DatabaseSync(databasePath);
    try {
      await createVault(store);
      await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "vault", action: "reset",
        entityId: vaultId, baseRevision: 1, data: { preservePermissions: true } }]));
      const app = createApp({ config: testConfig(databasePath), authStore: store });
      const worker = createWorkerHandler(async () => app);
      const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
      const send = (body: unknown, user: Identity) => {
        const request = new Request("http://localhost:5173/api/v1/transactions", { method: "POST",
          headers: { ...headers(), "x-forwarded-user": user.userId, "x-forwarded-email": `${user.userId}@example.com` },
          body: JSON.stringify(body) });
        return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
      };
      const restore = () => wire([
        { entity: "vault", action: "create", entityId: vaultId, baseRevision: null, data: { name: "Restored", createdAt: now } },
        { entity: "project", action: "create", entityId: projectId, baseRevision: null, data: projectData("Restored project") },
        { entity: "meeting", action: "create", entityId: meetingId, baseRevision: null, data: { ...meetingData(), projectId: null } },
      ]);
      const snapshot = () => ["vaults", "vault_permissions", "projects", "meetings", "meeting_events",
        "sync_changes", "sync_vault_state", "transaction_receipts", "search_documents", "jobs_search_index"]
        .map((table) => database.prepare(`SELECT * FROM ${table} ORDER BY rowid`).all());
      for (const shared of [false, true]) {
        if (shared) await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
        const before = snapshot();
        const rejected = restore();
        const response = await send(rejected, other);
        expect(response.status).toBe(404);
        expect(await response.json()).toMatchObject({ code: "vault_not_found", conflicts: [] });
        expect(snapshot()).toEqual(before);
        expect(await new MeetingSyncService(store.sync).resolveTransaction(other, JSON.parse(JSON.stringify(rejected))))
          .toEqual({ id: rejected.id, status: "unknown" });
      }
      const restored = restore();
      const response = await send(restored, owner);
      expect(response.status).toBe(200);
      const receipt = await response.json();
      const after = snapshot();
      expect(await (await send(restored, owner)).json()).toEqual(receipt);
      expect(snapshot()).toEqual(after);
      expect(await store.sync.withIdentity(other, (sync) => sync.getMeeting(vaultId, meetingId))).toMatchObject({ name: "Meeting" });
      await store.sync.withIdentity(owner, (sync) => sync.deleteMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
      expect(await store.sync.withIdentity(other, (sync) => sync.getMeeting(vaultId, meetingId))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId))).toMatchObject({ revision: 1, name: "Restored" });
    } finally {
      database.close();
      await store.close?.();
    }
  });

  it("rejects destructive Vault resets from shared members", async () => {
    const { store } = await setup();
    await createVault(store);
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    const operationId = "019d4a01-1002-7000-8000-000000000002";

    await expect(commit(store, other, transaction("019d4a01-1002-7000-8000-000000000001", [{
      id: operationId,
      entity: "vault",
      action: "reset",
      entityId: vaultId,
      baseRevision: 1,
      data: { preservePermissions: true },
    }]))).rejects.toMatchObject({ status: 409, code: "revision_conflict", operationId });
    await expect(store.sync.withIdentity(owner, (sync) => sync.getVault(vaultId)))
      .resolves.toMatchObject({ vaultId, revision: 1 });
    await store.close?.();
  });

  it("fences expired storage-delete claims by attempt", async () => {
    const { databasePath, store } = await setup();
    const storageKey = "meetings/m/screenshots/s.png";
    await store.sync.enqueueStorageDelete(storageKey);
    const first = (await store.sync.claimStorageDeletes(1))[0]!;
    const database = new DatabaseSync(databasePath);
    database.prepare("update jobs_storage_delete set lease_expires_at = 0 where storage_key = ?")
      .run(storageKey);
    database.close();
    const second = (await store.sync.claimStorageDeletes(1))[0]!;

    expect(second.attempt).toBe(first.attempt + 1);
    expect(await store.sync.isStorageDeleteClaimCurrent(first)).toBe(false);
    expect(await store.sync.isStorageDeleteClaimCurrent(second)).toBe(true);
    await store.sync.completeStorageDelete(first);
    expect(await store.sync.hasStorageDelete(storageKey)).toBe(true);
    await store.sync.completeStorageDelete(second);
    expect(await store.sync.hasStorageDelete(storageKey)).toBe(false);
    await store.close?.();
  });

  it("returns a structured missing-Vault conflict for dependent transactions", async () => {
    const { store } = await setup();
    const operationId = "019d4a01-1020-7000-8000-000000000002";
    await expect(commit(store, owner, transaction("019d4a01-1020-7000-8000-000000000001", [{
      id: operationId,
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: projectData("Orphan"),
    }]))).rejects.toMatchObject({
      status: 409,
      code: "revision_conflict",
      operationId,
      conflicts: [{ entity: "vault", id: vaultId, serverRevision: null, record: null }],
    });
    await store.close?.();
  });

  it("accepts Desktop text fields without Server-only character caps", async () => {
    const { store } = await setup();
    await createVault(store);
    const name = "m".repeat(501);
    const description = "d".repeat(20_001);
    const title = "s".repeat(501);
    await commit(store, owner, transaction("019d4a01-1050-7000-8000-000000000001", [
      {
        id: "019d4a01-1050-7000-8000-000000000002",
        entity: "vault",
        action: "update",
        entityId: vaultId,
        baseRevision: 1,
        data: { name },
      },
      {
        id: "019d4a01-1050-7000-8000-000000000003",
        entity: "meeting",
        action: "create",
        entityId: meetingId,
        baseRevision: null,
        data: { ...meetingData(), projectId: null, name, description },
      },
      {
        id: "019d4a01-1050-7000-8000-000000000004",
        entity: "summary",
        action: "upsert",
        entityId: meetingId,
        baseRevision: 0,
        data: { title, document: "{}", createdAt: now },
      },
    ]));

    expect(await store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId)))
      .toMatchObject({ name, description, summaryTitle: title });
    await store.close?.();
  });

  it("rejects unknown meeting statuses and normalizes the legacy recording value", async () => {
    const { store } = await setup();
    await createVault(store);
    const service = new MeetingSyncService(store.sync);
    const body = (id: string, status: string) => ({
      schemaVersion: 2,
      id,
      vaultId,
      createdAt: now.toISOString(),
      operations: [{
        id: id.replace(/1$/, "2"),
        entity: "meeting",
        action: "create",
        entityId: meetingId,
        baseRevision: null,
        data: { ...meetingData(), projectId: null, status, createdAt: now.toISOString(), updatedAt: now.toISOString(), recordingStartedAt: now.toISOString() },
      }],
    });

    await expect(service.commitTransaction(
      owner,
      body("019d4a01-1200-7000-8000-000000000001", "ARCHIVED"),
    )).rejects.toMatchObject({ status: 400, code: "invalid_sync_operation" });
    await service.commitTransaction(owner, body("019d4a01-1200-7000-8000-000000000011", "RECORDING"));
    await expect(store.sync.withIdentity(owner, (sync) => sync.getMeeting(vaultId, meetingId)))
      .resolves.toMatchObject({ status: "READY" });
    await store.close?.();
  });

  it("starts a recreated Vault change feed after its latest reset", async () => {
    const { store } = await setup();
    await createVault(store);
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "01990ab0-0000-7000-8000-000000000001"));
    await commit(store, owner, transaction("019d4a01-1100-7000-8000-000000000001", [{
      id: "019d4a01-1100-7000-8000-000000000002",
      entity: "vault",
      action: "reset",
      entityId: vaultId,
      baseRevision: 1,
      data: { preservePermissions: true },
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

    const changes = await store.sync.withIdentity(owner, (sync) => sync.listChanges(vaultId, 0, 100, 100));
    expect(changes).toHaveLength(2);
    expect(changes[0]).toMatchObject({ action: "reset", entity: "vault", record: { name: "Restored" } });
    expect(changes[1]).toMatchObject({ transactionId: recreatedId, action: "upsert", entity: "vault" });
    const existingClientChanges = await store.sync.withIdentity(owner, (sync) => sync.listChanges(vaultId, 1, 100, 100));
    expect(existingClientChanges.map(({ action }) => action)).toEqual(["reset", "upsert"]);
    expect(await store.sync.withIdentity(owner, (sync) => sync.listPermissions(vaultId)))
      .toContainEqual(expect.objectContaining({ principalType: "organization", principalId: "01990ab0-0000-7000-8000-000000000001" }));
    await store.close?.();
  });

  it("reports a deleted Vault reset after the previous owner cursor", async () => {
    const { store } = await setup();
    await createVault(store);
    const service = new MeetingSyncService(store.sync);
    const beforeReset = await service.listChanges(owner, vaultId);
    const resetId = "019d4a01-1150-7000-8000-000000000001";
    await commit(store, owner, transaction(resetId, [{
      id: "019d4a01-1150-7000-8000-000000000002",
      entity: "vault",
      action: "reset",
      entityId: vaultId,
      baseRevision: 1,
      data: {},
    }]));

    const afterReset = await service.listChanges(owner, vaultId, beforeReset.cursor);
    expect(afterReset.items).toHaveLength(1);
    expect(afterReset.items[0]).toMatchObject({
      transactionId: resetId,
      action: "reset",
      entity: "vault",
      record: null,
    });
    expect(afterReset.cursor).not.toBe(beforeReset.cursor);
    await store.close?.();
  });

  it("pages a stable high-water delta with one canonical state per entity", async () => {
    const { store } = await setup();
    await createVault(store);
    const projectOperations = Array.from({ length: 101 }, (_, index) => ({
      id: `019d4a01-1160-7000-8000-${(index + 10).toString(16).padStart(12, "0")}`,
      entity: "project" as const,
      action: "create" as const,
      entityId: `019d3f47-0000-7000-8000-${index.toString(16).padStart(12, "0")}`,
      baseRevision: null,
      data: projectData(`Project ${index}`),
    }));
    await commit(store, owner, transaction("019d4a01-1160-7000-8000-000000000001", [
      ...projectOperations,
      {
        id: "019d4a01-1160-7000-8000-000000000111",
        entity: "meeting",
        action: "create",
        entityId: meetingId,
        baseRevision: null,
        data: { ...meetingData(), projectId: null },
      },
    ]));
    await commit(store, owner, transaction("019d4a01-1160-7000-8000-000000000112", [{
      id: "019d4a01-1160-7000-8000-000000000113",
      entity: "meeting",
      action: "delete",
      entityId: meetingId,
      baseRevision: 1,
      data: {},
    }]));
    await commit(store, owner, transaction("019d4a01-1160-7000-8000-000000000114", [{
      id: "019d4a01-1160-7000-8000-000000000115",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: { ...meetingData(), projectId: null, name: "Recreated" },
    }]));

    const service = new MeetingSyncService(store.sync);
    const first = await service.listChanges(owner, vaultId);
    const second = await service.listChanges(owner, vaultId, first.cursor, first.highWaterCursor);
    const changes = [...first.items, ...second.items];

    expect(first.items).toHaveLength(100);
    expect(first.hasMore).toBe(true);
    expect(second.hasMore).toBe(false);
    expect(second.highWaterCursor).toBe(first.highWaterCursor);
    const meetingChanges = changes.filter(({ entity }) => entity === "meeting");
    expect(meetingChanges).toHaveLength(1);
    expect(meetingChanges[0]?.action).toBe("upsert");
    expect(meetingChanges[0]?.record?.name).toBe("Recreated");
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
      meetingId,
      patchId,
      0,
      chunkHash,
      {
        segments: [{
          segmentId,
          startedAt: now,
          endedAt: null,
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
        startedAt: now,
        endedAt: null,
        text: "original",
        createdAt: null,
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
        transcript: { id: patchId, startedAt: null, endedAt: null, metadata: null }, mode: "replace", patchId,
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

  it("removes staged transcript chunks after a rejected transaction", async () => {
    const { databasePath, store } = await setup();
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-2100-7000-8000-000000000001", [{
      id: "019d4a01-2100-7000-8000-000000000002",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: { ...meetingData(), projectId: null },
    }]));
    const patchId = "019d4a01-2100-7000-8000-000000000003";
    const chunkHash = "b".repeat(64);
    const service = new MeetingSyncService(store.sync);
    await service.putTranscriptChunk(owner, meetingId, patchId, 0, chunkHash, {
      segments: [{
        segmentId,
        startedAt: now.toISOString(),
        endedAt: null,
        text: "staged",
        createdAt: null,
        audioSource: "mic",
        speakerLabel: null,
      }],
      deletions: [],
    });

    await expect(service.commitTransaction(owner, {
      schemaVersion: 2,
      id: "019d4a01-2100-7000-8000-000000000004",
      vaultId,
      createdAt: now.toISOString(),
      operations: [{
        id: patchId,
        entity: "transcript",
        action: "patch",
        entityId: meetingId,
        baseRevision: 99,
        data: {
          transcript: { id: patchId, startedAt: null, endedAt: null, metadata: null }, mode: "replace", patchId,
          segmentCount: 1,
          deletionCount: 0,
          chunks: [{ index: 0, sha256: chunkHash, segmentCount: 1, deletionCount: 0 }],
        },
      }],
    })).rejects.toMatchObject({ status: 409, code: "revision_conflict" });

    const database = new DatabaseSync(databasePath);
    expect(database.prepare("SELECT count(*) AS count FROM transcript_patch_chunks").get()).toMatchObject({ count: 0 });
    database.close();
    await store.close?.();
  });

  it("rejects deep project hierarchies and reports missing project dependencies as conflicts", async () => {
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
      status: 409,
      code: "revision_conflict",
      operationId: "019d4a01-2800-7000-8000-000000000008",
      conflicts: [{ entity: "project", id: projectId, serverRevision: null }],
    });
    await store.close?.();
  });

  it("rejects self-parenting Project creates and updates without rejecting valid roots and children", async () => {
    const { store } = await setup();
    await createVault(store);
    const childId = "019d4a01-2850-7000-8000-000000000001";
    const createOperationId = "019d4a01-2850-7000-8000-000000000002";
    await expect(commit(store, owner, transaction("019d4a01-2850-7000-8000-000000000003", [{
      id: createOperationId,
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: { ...projectData("Self"), parentProjectId: projectId, projectType: null },
    }]))).rejects.toMatchObject({
      status: 422,
      code: "invalid_project_parent",
      operationId: createOperationId,
    });

    await commit(store, owner, transaction("019d4a01-2850-7000-8000-000000000004", [{
      id: "019d4a01-2850-7000-8000-000000000005",
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: projectData("Root"),
    }, {
      id: "019d4a01-2850-7000-8000-000000000006",
      entity: "project",
      action: "create",
      entityId: childId,
      baseRevision: null,
      data: { ...projectData("Child"), parentProjectId: projectId, projectType: null },
    }]));

    const updateOperationId = "019d4a01-2850-7000-8000-000000000007";
    await expect(commit(store, owner, transaction("019d4a01-2850-7000-8000-000000000008", [{
      id: updateOperationId,
      entity: "project",
      action: "update",
      entityId: childId,
      baseRevision: 1,
      data: { ...projectData("Self"), parentProjectId: childId, projectType: null },
    }]))).rejects.toMatchObject({
      status: 422,
      code: "invalid_project_parent",
      operationId: updateOperationId,
    });

    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toEqual([
      expect.objectContaining({ projectId, parentProjectId: null }),
      expect.objectContaining({ projectId: childId, parentProjectId: projectId }),
    ]);
    await store.close?.();
  });

  it("includes a missing parent when a deleted child Project is reapplied", async () => {
    const { store } = await setup();
    await createVault(store);
    const childId = "019d4a01-2900-7000-8000-000000000001";
    await commit(store, owner, transaction("019d4a01-2900-7000-8000-000000000002", [{
      id: "019d4a01-2900-7000-8000-000000000003",
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: projectData("Root"),
    }, {
      id: "019d4a01-2900-7000-8000-000000000004",
      entity: "project",
      action: "create",
      entityId: childId,
      baseRevision: null,
      data: { ...projectData("Child"), parentProjectId: projectId, projectType: null },
    }]));
    await commit(store, owner, transaction("019d4a01-2900-7000-8000-000000000005", [{
      id: "019d4a01-2900-7000-8000-000000000006",
      entity: "project",
      action: "delete",
      entityId: childId,
      baseRevision: 1,
      data: {},
    }, {
      id: "019d4a01-2900-7000-8000-000000000007",
      entity: "project",
      action: "delete",
      entityId: projectId,
      baseRevision: 1,
      data: {},
    }]));

    await expect(commit(store, owner, transaction("019d4a01-2900-7000-8000-000000000008", [{
      id: "019d4a01-2900-7000-8000-000000000009",
      entity: "project",
      action: "update",
      entityId: childId,
      baseRevision: 1,
      data: { ...projectData("Child"), parentProjectId: projectId, projectType: null },
    }]))).rejects.toMatchObject({
      status: 409,
      code: "revision_conflict",
      conflicts: [
        { entity: "project", id: childId, serverRevision: null },
        { entity: "project", id: projectId, serverRevision: null },
      ],
    });
    await store.close?.();
  });

  it("reports concurrent Project dependents as revision conflicts before deletion", async () => {
    const { store } = await setup();
    await createVault(store);
    const childId = "019d4a01-2950-7000-8000-000000000001";
    await commit(store, owner, transaction("019d4a01-2950-7000-8000-000000000002", [{
      id: "019d4a01-2950-7000-8000-000000000003",
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: projectData("Root"),
    }, {
      id: "019d4a01-2950-7000-8000-000000000004",
      entity: "project",
      action: "create",
      entityId: childId,
      baseRevision: null,
      data: { ...projectData("Child"), parentProjectId: projectId, projectType: null },
    }, {
      id: "019d4a01-2950-7000-8000-000000000005",
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: { ...meetingData(), projectId },
    }]));

    const operationId = "019d4a01-2950-7000-8000-000000000006";
    await expect(commit(store, owner, transaction("019d4a01-2950-7000-8000-000000000007", [{
      id: operationId,
      entity: "project",
      action: "delete",
      entityId: projectId,
      baseRevision: 1,
      data: {},
    }]))).rejects.toMatchObject({
      status: 409,
      code: "revision_conflict",
      operationId,
      conflicts: [
        { entity: "project", id: childId, serverRevision: 1 },
        { entity: "meeting", id: meetingId, serverRevision: 1 },
      ],
    });
    expect(await store.sync.withIdentity(owner, (sync) => sync.getProject(vaultId, projectId)))
      .toMatchObject({ projectId });
    await store.close?.();
  });

  it("reports the rejected operation ID and removes obsolete manifest routes", async () => {
    const { directory, store } = await setup();
    const app = createApp({
      config: testConfig(join(directory, "server.sqlite")),
      authStore: store,
      objectStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    const operationId = "019d4a01-3000-7000-8000-000000000002";
    const response = await app.request("/api/v1/transactions", {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({
        schemaVersion: 2,
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
    expect(await response.json()).toMatchObject({ code: "invalid_sync_operation", operationId });
    expect((await app.request(`/api/v1/vaults/${vaultId}/manifest`, { method: "PUT", headers: headers() })).status)
      .toBe(404);
    await expect(new MeetingSyncService(store.sync).commitTransaction(
      { ...owner, impersonated: true },
      {},
    )).rejects.toMatchObject({ status: 403, code: "impersonated_session_read_only" });
    await store.close?.();
  });

  it("accepts trusted header transactions without a browser Origin header", async () => {
    const { directory, store } = await setup();
    const app = createApp({
      config: testConfig(join(directory, "server.sqlite")),
      authStore: store,
      objectStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    const requestHeaders: Record<string, string> = headers();
    delete requestHeaders.origin;
    const response = await app.request("/api/v1/transactions", {
      method: "POST",
      headers: requestHeaders,
      body: JSON.stringify({
        schemaVersion: 2,
        id: "019d4a01-3050-7000-8000-000000000001",
        vaultId,
        createdAt: now,
        operations: [{
          id: "019d4a01-3050-7000-8000-000000000002",
          entity: "vault",
          action: "create",
          entityId: vaultId,
          baseRevision: null,
          data: { name: "Vault", createdAt: now },
        }],
      }),
    });
    expect(response.status).toBe(200);
    expect((await app.request("/api/v1/transactions", {
      method: "POST",
      headers: { ...headers(), origin: "https://attacker.example" },
      body: "{}",
    })).status).toBe(403);

    const accountsConfig: AppConfig = {
      ...testConfig(join(directory, "server.sqlite")),
      authProvider: "accounts",
      betterAuthSecret: "test-only-better-auth-secret-value",
      googleClientId: "google-client",
      googleClientSecret: "google-secret",
    };
    const accountsApp = createApp({
      config: accountsConfig,
      auth: await initializeDahliaAuth(accountsConfig, store),
      authStore: store,
      objectStorage: new LocalObjectStorage(join(directory, "objects")),
    });
    expect((await accountsApp.request("/api/v1/transactions", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    })).status).toBe(403);
    await store.close?.();
  });

  it("accepts Foundation-style uppercase UUIDv7 transaction identifiers", async () => {
    const { store } = await setup();
    const service = new MeetingSyncService(store.sync);
    const response = await service.commitTransaction(owner, {
      schemaVersion: 2,
      id: "019D4A01-3100-7000-8000-000000000001",
      vaultId: vaultId.toUpperCase(),
      createdAt: now.toISOString(),
      operations: [{
        id: "019D4A01-3100-7000-8000-000000000002",
        entity: "vault",
        action: "create",
        entityId: vaultId.toUpperCase(),
        baseRevision: null,
        data: { name: "Uppercase UUIDs", createdAt: now.toISOString() },
      }],
    });

    expect(response.id).toBe("019d4a01-3100-7000-8000-000000000001");
    expect(response.records[0]?.id).toBe(vaultId);
    await store.close?.();
  });

  it("bounds summary documents by their serialized byte size", async () => {
    const { store } = await setup();
    const operationId = "019d4a01-3500-7000-8000-000000000002";
    await expect(new MeetingSyncService(store.sync).commitTransaction(owner, {
      schemaVersion: 2,
      id: "019d4a01-3500-7000-8000-000000000001",
      vaultId,
      createdAt: now.toISOString(),
      operations: [{
        id: operationId,
        entity: "summary",
        action: "upsert",
        entityId: meetingId,
        baseRevision: 0,
        data: { title: "Summary", document: "界".repeat(2_100_000), createdAt: now.toISOString() },
      }],
    })).rejects.toMatchObject({ status: 400, code: "invalid_sync_operation", operationId });
    await store.close?.();
  });

  it("stores canonical transcript rows without a generation and keeps FTS projection", async () => {
    const { databasePath, store } = await setup();
    const database = new DatabaseSync(databasePath);
    const transcriptColumns = database.prepare("pragma table_info('transcript_segments')").all()
      .map((row) => (row as { name: string }).name);
    expect(transcriptColumns).not.toContain("generation");
    expect(database.prepare("pragma table_info('meetings')").all()
      .map((row) => (row as { name: string }).name)).toContain("active");
    expect(database.prepare("select name from sqlite_master where name = 'search_documents_fts'").get())
      .toBeTruthy();
    database.close();
    await store.close?.();
  });

  it("commits search reconciliation one page at a time", async () => {
    const { databasePath, store } = await setup({ model: "model", dimensions: 32 });
    await createVault(store);
    await commit(store, owner, transaction("019d4a01-4400-7000-8000-000000000001", [
      {
        id: "019d4a01-4400-7000-8000-000000000002",
        entity: "project",
        action: "create",
        entityId: projectId,
        baseRevision: null,
        data: projectData("Project"),
      },
      {
        id: "019d4a01-4400-7000-8000-000000000003",
        entity: "meeting",
        action: "create",
        entityId: meetingId,
        baseRevision: null,
        data: meetingData(),
      },
    ]));
    const database = new DatabaseSync(databasePath);
    const insert = database.prepare(`
      INSERT INTO search_documents
        (document_id, vault_id, meeting_id, kind, search_text, summary_text, embedding_content_hash)
      VALUES (?, ?, ?, 'meeting', '', 'summary', 'hash')
    `);
    database.exec("BEGIN");
    for (let index = 0; index < 501; index += 1) {
      insert.run(`document-${index.toString().padStart(3, "0")}`, vaultId, meetingId);
    }
    database.exec("COMMIT");
    database.close();

    const prepare = vi.spyOn(DatabaseSync.prototype, "prepare");
    await store.searchIndex!.reconcile("model", 32);
    expect(prepare.mock.calls.filter(([statement]) => statement === "begin")).toHaveLength(2);
    prepare.mockRestore();
    await store.close?.();
  });
});

async function setup(searchEmbedding?: AppConfig["searchEmbedding"], captioningModel?: string, encryption?: AppConfig["encryption"]) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-sync-"));
  directories.push(directory);
  const databasePath = join(directory, "server.sqlite");
  const store = createNodeApplicationStore({ ...testConfig(databasePath), searchEmbedding, captioningModel, encryption });
  await store.migrate();
  await seedHeaderIdentity(store, databasePath, owner);
  await seedHeaderIdentity(store, databasePath, other);
  return { databasePath, directory, store };
}

async function createVault(store: ReturnType<typeof createNodeApplicationStore>, encryption = "none") {
  return commit(store, owner, transaction("019d4a00-0000-7000-8000-000000000001", [{
    id: "019d4a00-0000-7000-8000-000000000002",
    entity: "vault",
    action: "create",
    entityId: vaultId,
    baseRevision: null,
    data: { name: "Vault", createdAt: now, encryption },
  }]));
}

function transaction(id: string, operations: SyncTransaction["operations"]): SyncTransaction {
  return { schemaVersion: 2, id, vaultId, createdAt: now, requestHash: id, operations };
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
  };
}

function freshId() {
  const id = crypto.randomUUID();
  return `${id.slice(0, 14)}7${id.slice(15)}`;
}

function wire(operations: Omit<SyncTransaction["operations"][number], "id">[]) {
  return { schemaVersion: 2, id: freshId(), vaultId, createdAt: new Date().toISOString(),
    operations: operations.map((operation) => ({ ...operation, id: freshId() })) };
}

async function fileSetup(captioningModel?: string) {
  const setupValue = await setup(captioningModel ? { model: "embedding", dimensions: 32 } : undefined, captioningModel);
  const { store, directory } = setupValue;
  await createVault(store);
  await commit(store, owner, transaction(freshId(), [{ id: freshId(), entity: "meeting", action: "create", entityId: meetingId,
    baseRevision: null, data: { ...meetingData(), projectId: null } }]));
  const storage = new LocalObjectStorage(join(directory, "objects"));
  const transformer = vi.fn(transformScreenshot);
  const service = new MeetingSyncService(store.sync, storage, undefined, undefined, transformer, "/Volumes/test/app/files");
  const bytes = new Uint8Array(await sharp({ create: { width: 1800, height: 900, channels: 3, background: "white" } }).png().toBuffer());
  const hash = Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
  const file = { id: screenshotId, vaultId, name: "capture.png", offset: 0, size: bytes.length,
    content_type: "image/png", checksum: `SHA-256:${hash}`, metadata: { source: "screenshot", width: 1800, height: 900 } };
  await uploadFile(service, owner, fileUploadRequest(file, bytes));
  const publish = () => service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id,
    baseRevision: null, data: { checksum: file.checksum, metadata: {} } }]));
  const attach = () => service.commitTransaction(owner, wire([{ entity: "meeting_attachment", action: "upsert", entityId: file.id,
    baseRevision: null, data: { fileId: file.id, meetingId, capturedAt: now.toISOString(), sessionId: null, createdAt: now.toISOString() } }]));
  return { ...setupValue, service, storage, transformer, file, bytes, publish, attach };
}

function fileUploadRequest(file: { id: string; vaultId: string; name: string; content_type: string; metadata: { source: string; width?: number; height?: number } }, bytes: Uint8Array<ArrayBuffer>, size = bytes.length) {
  const query = new URLSearchParams({ id: file.id, vaultId: file.vaultId, name: file.name, source: file.metadata.source });
  if (file.metadata.width !== undefined) query.set("width", String(file.metadata.width));
  if (file.metadata.height !== undefined) query.set("height", String(file.metadata.height));
  return new Request(`http://localhost:5173/api/v1/files?${query}`, { method: "POST", body: bytes,
    headers: { "content-type": file.content_type, "content-length": String(size) } });
}

async function reservePendingFile(store: Awaited<ReturnType<typeof setup>>["store"], file: { id: string; vaultId: string; name: string; content_type: string; metadata: { source: string; width?: number; height?: number } }) {
  return store.sync.withIdentity(owner, (scoped) => scoped.reserveFile({ fileId: file.id, vaultId: file.vaultId,
    uri: `/Volumes/test/app/files/${fileStorageKey(file.id)}`, offset: 0, size: 0, checksum: "", contentType: file.content_type,
    name: file.name, metadata: { ...file.metadata, source: "screenshot" }, active: false, uploadedAt: null, revision: 0,
    createdAt: new Date(), updatedAt: new Date() }));
}

async function uploadFile(service: MeetingSyncService, identity: Identity, request: Request) {
  const query = new URL(request.url).searchParams;
  const id = query.get("id")!;
  await service.reserveFileUpload(identity, { id, vaultId: query.get("vaultId"), name: query.get("name"), contentType: request.headers.get("content-type"), metadata: {
    source: query.get("source"), ...(query.has("width") ? { width: Number(query.get("width")) } : {}), ...(query.has("height") ? { height: Number(query.get("height")) } : {}),
  } });
  request.headers.set("content-type", "application/octet-stream");
  return service.putFileContent(identity, id, request);
}
async function uploadRecording(service: MeetingSyncService, identity: Identity, meetingId: string, request: Request) {
  const query = new URL(request.url).searchParams;
  return service.putRecordingContent(identity, meetingId, query.get("sessionId")!, query.get("source")!, request);
}
