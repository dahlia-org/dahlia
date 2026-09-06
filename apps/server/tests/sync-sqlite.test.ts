import { z } from "zod";
import { afterEach, describe, expect, it, vi } from "vitest";

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import type { Identity } from "../src/auth/identity";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { LocalObjectStorage } from "../src/artifacts/local";
import { createApp } from "../src/app";
import type { AppConfig } from "../src/config";
import { MeetingSyncService } from "../src/sync/service";
import { transformScreenshot } from "../src/sync/node-screenshot-transformer";
import { fileStorageKey, fileVariantKey } from "../src/files/model";
import sharp from "sharp";
import { SCREENSHOT_VARIANTS } from "../src/sync/screenshot-variants";
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
  it.each([{ deleted: "file", reserveAgain: true }, { deleted: "vault", reserveAgain: true }, { deleted: "file", reserveAgain: false }])("rejects stale upload completion after $deleted deletion (reserved again=$reserveAgain) and permits a clean retry", async ({ deleted, reserveAgain }) => {
    const { store, service, storage, file, bytes } = await fileSetup();
    const replacement = { ...file, id: freshId() };
    await service.reserveFile(owner, replacement);
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
    const upload = () => service.putFile(owner, replacement.id, new Request("https://test.invalid", { method: "PUT", body: bytes,
      headers: { "content-type": "image/png", "content-length": String(bytes.length) } }));
    const uploading = upload();
    const rejected = expect(uploading).rejects.toMatchObject(reserveAgain
      ? { status: 503, code: "file_storage_delete_pending" }
      : { status: 404, code: "file_not_found" });
    await didStart;
    await service.commitTransaction(owner, wire(deleted === "file"
      ? [{ entity: "file", action: "delete", entityId: replacement.id, baseRevision: null, data: {} }]
      : [{ entity: "vault", action: "reset", entityId: vaultId, baseRevision: 1, data: { preservePermissions: true } }]));
    if (reserveAgain) await service.reserveFile(owner, replacement);
    release();
    await rejected;
    const current = await store.sync.withIdentity(owner, (sync) => sync.getFile(replacement.id));
    if (reserveAgain) expect(current).toMatchObject({ active: false, uploadedAt: null });
    else expect(current).toBeNull();
    await vi.waitFor(async () => expect(await store.sync.hasStorageDelete(fileStorageKey(replacement.id))).toBe(false));
    expect(await storage.exists(fileStorageKey(replacement.id))).toBe(false);
    await service.reserveFile(owner, replacement);
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
    const { store, service, storage, file, publish } = await fileSetup();
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "external"));
    const published = await publish();
    await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    await vi.waitFor(async () => {
      expect(await storage.exists(fileStorageKey(file.id))).toBe(false);
      expect(await store.sync.hasStorageDelete(fileStorageKey(file.id))).toBe(false);
    });
    await service.reserveFile(owner, { ...file, name: "Private pending replacement" });
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
    const link = { entity: "meeting_file" as const, action: "upsert" as const, entityId: file.id,
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
    expect(await service.getFile(owner, file.id)).toMatchObject({ uri: `/Volumes/test/app/files/${fileStorageKey(file.id)}`, metadata: { source: "screenshot", width: 1800 } });
    await service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id, baseRevision: 1,
      data: { checksum: file.checksum, metadata: { ocr_text: "Searchable text" } } }]));
    expect(await service.getFile(owner, file.id)).toMatchObject({ metadata: { source: "screenshot", width: 1800, ocr_text: "Searchable text" }, revision: 2 });
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

  it("advertises, serves and deletes both variants with distinct caches", async () => {
    const { store, service, storage, file, publish, attach, transformer, databasePath } = await fileSetup();
    await publish();
    await attach();
    const variants = Object.fromEntries(Object.keys(SCREENSHOT_VARIANTS).map((variant) => [variant, `/api/v1/files/${file.id}/variants/${variant}`]));
    expect((await service.getFile(owner, file.id)).variants).toEqual(variants);
    expect((await service.listFiles(owner, vaultId, undefined, meetingId)).items[0]).toMatchObject({ file: { variants } });
    const app = createApp({ config: testConfig(databasePath), authStore: store, artifactStorage: storage, screenshotTransformer: transformer });
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
    expect(etags.size).toBe(2);
    expect(transformer).toHaveBeenCalledTimes(2);
    for (const name of ["thumbnail", "unknown", "toString"]) {
      expect((await app.request(`/api/v1/files/${file.id}/variants/${name}`, { headers: headers() })).status).toBe(404);
    }
    const portable = createApp({ config: testConfig(databasePath), authStore: store, artifactStorage: storage });
    expect((await portable.request(variants.thumb_1280!, { headers: headers() })).status).toBe(404);
    await service.commitTransaction(owner, wire([{ entity: "meeting_file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    await vi.waitFor(async () => {
      for (const variant of Object.keys(SCREENSHOT_VARIANTS) as Array<keyof typeof SCREENSHOT_VARIANTS>) {
        expect(await storage.exists(fileVariantKey(file.id, variant))).toBe(false);
      }
    });
    await store.close?.();
  });

  it("generates thumbnails only on request, coalesces requests and reuses persisted variants", async () => {
    const { store, service, storage, file, publish, transformer, bytes } = await fileSetup();
    await publish();
    expect(transformer).not.toHaveBeenCalled();
    const read = (value = service) => value.readFile(owner, file.id, "GET", new Request("https://test.invalid"), "thumb_360");
    const results = await Promise.all([read(), read()]);
    expect(await sharp(await results[0].arrayBuffer()).metadata()).toMatchObject({ width: 360, height: 180, format: "webp" });
    await results[1].arrayBuffer();
    expect(transformer).toHaveBeenCalledTimes(1);
    expect(await storage.exists(fileVariantKey(file.id, "thumb_360"))).toBe(true);
    const restarted = new MeetingSyncService(store.sync, storage, undefined, undefined, transformer);
    await (await read(restarted)).arrayBuffer();
    expect(transformer).toHaveBeenCalledTimes(1);
    expect(new Uint8Array(await (await service.readFile(owner, file.id, "GET", new Request("https://test.invalid"))).arrayBuffer())).toEqual(bytes);
    const portable = new MeetingSyncService(store.sync, storage);
    expect(await portable.getFile(owner, file.id)).toMatchObject({ variants: {} });
    await expect(read(portable)).rejects.toMatchObject({ code: "file_variant_unavailable" });
    await expect(service.readFile(other, file.id, "GET", new Request("https://test.invalid"), "thumb_360")).rejects.toMatchObject({ status: 404 });
    await store.close?.();
  });

  it("fails and retries a thumbnail when durable storage fails", async () => {
    const { store, service, storage, file, publish, transformer } = await fileSetup();
    await publish();
    const put = vi.spyOn(storage, "put").mockRejectedValueOnce(new Error("storage failure"));
    const read = () => service.readFile(owner, file.id, "GET", new Request("https://test.invalid"), "thumb_360");
    await expect(read()).rejects.toMatchObject({ status: 502 });
    expect(await storage.exists(fileVariantKey(file.id, "thumb_360"))).toBe(false);
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
    const reading = service.readFile(owner, file.id, "GET", new Request("https://test.invalid"), "thumb_360");
    const rejected = expect(reading).rejects.toMatchObject({ code: "file_not_found" });
    await didStart;
    await service.commitTransaction(owner, wire([{ entity: "file", action: "delete", entityId: file.id, baseRevision: 1, data: {} }]));
    release();
    await rejected;
    await vi.waitFor(async () => expect(await storage.exists(fileStorageKey(file.id))).toBe(false));
    expect(await storage.exists(fileVariantKey(file.id, "thumb_360"))).toBe(false);
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
      { entity: "meeting_file", action: "upsert", entityId: linkId, baseRevision: null,
        data: { fileId: file.id, meetingId: secondMeeting, capturedAt: null, sessionId: null, createdAt: now.toISOString() } },
      { entity: "meeting_file", action: "delete", entityId: file.id, baseRevision: 1, data: {} },
    ]));
    expect(await service.listFiles(owner, vaultId, undefined, secondMeeting)).toMatchObject({ items: [{ id: linkId, file: { id: file.id } }] });
    expect(await service.listFiles(owner, vaultId, undefined, meetingId)).toMatchObject({ items: [] });
    const request = new Request("https://test.invalid", { headers: { range: "bytes=1-3" } });
    const range = await service.readFile(owner, file.id, "GET", request);
    expect(range.status).toBe(206);
    expect(new Uint8Array(await range.arrayBuffer())).toEqual(bytes.slice(1, 4));
    const head = await service.readFile(owner, file.id, "HEAD", request);
    expect(head.status).toBe(206);
    expect(await head.text()).toBe("");
    expect(head.headers.get("content-range")).toBe(`bytes 1-3/${bytes.length}`);
    await store.close?.();
  });

  it("keeps rejected file reservations retryable and expires only unpublished originals", async () => {
    const { store, service, file, storage, publish } = await fileSetup();
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
    await service.reserveFile(owner, pending);
    await store.sync.withIdentity(owner, (sync) => sync.expireFileUploads(vaultId, new Date(Date.now() + 86_400_000)));
    expect(await store.sync.withIdentity(owner, (sync) => sync.getFile(pending.id))).toBeNull();
    expect(await store.sync.hasStorageDelete(fileStorageKey(pending.id))).toBe(true);
    await store.close?.();
  });

  it("validates immutable bytes, lengths, ownership and reservation IDs at the HTTP boundary", async () => {
    const { store, service, file, bytes, databasePath, storage } = await fileSetup();
    const app = createApp({ config: { ...testConfig(databasePath), storageBackend: "databricks", storageDatabricksVolumePath: "/Volumes/test/app/files" }, authStore: store, artifactStorage: storage });
    const reserve = (body: unknown) => app.request("/api/v1/files", { method: "POST", headers: headers(), body: JSON.stringify(body) });
    expect((await reserve(file)).status).toBe(200);
    expect((await reserve({ ...file, checksum: `SHA-256:${"b".repeat(64)}` })).status).toBe(409);
    expect((await reserve({ ...file, metadata: { source: "other" } })).status).toBe(400);
    expect((await reserve({ ...file, id: crypto.randomUUID() })).status).toBe(400);
    const request = (body: Uint8Array<ArrayBuffer>, size = file.size) => new Request("https://test.invalid", {
      method: "PUT", headers: { "content-type": file.content_type, "content-length": String(size) }, body,
    });
    await expect(service.putFile(owner, file.id, request(bytes))).resolves.toMatchObject({ checksum: file.checksum });
    const wrong = new Uint8Array(bytes.length);
    await expect(service.putFile(owner, file.id, request(wrong))).rejects.toMatchObject({ code: "file_checksum_mismatch" });
    await expect(service.putFile(owner, file.id, request(bytes, 1))).rejects.toMatchObject({ code: "file_id_conflict" });
    await expect(service.putFile(owner, file.id, request(new Uint8Array(bytes.length + 1)))).rejects.toMatchObject({ code: "file_size_mismatch" });
    await expect(service.putFile(other, file.id, request(bytes))).rejects.toMatchObject({ status: 404 });
    expect(await storage.exists(fileStorageKey(file.id))).toBe(true);
    await store.close?.();
  });

  it("filters Vaults by owner or current organization and Team membership", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const service = new MeetingSyncService(store.sync);
    expect(await service.listVaults(owner)).toHaveLength(1);
    expect(await service.listVaults(other)).toEqual([]);
    expect(await service.listVaults(owner, undefined, "external")).toEqual([]);
    const team = (await store.createExternalTeam(owner.userId, "Private team"))!;
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "team", team.id));
    expect(await service.listVaults(other, undefined, "external")).toEqual([]);
    await store.addExternalTeamMember(owner.userId, team.id, other.userId);
    expect(await service.listVaults(other, undefined, "external")).toMatchObject([{ vaultId, role: "member" }]);
    // Two access paths must still produce one Vault.
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "external"));
    expect(await service.listVaults(other, undefined, "external")).toHaveLength(1);
    expect(await service.listVaults(other)).toEqual([]);
    const database = new DatabaseSync(databasePath);
    database.exec(`
      INSERT INTO organization (id, name, slug, created_at) VALUES ('another', 'Another', 'another', 0);
      INSERT INTO member (id, organization_id, user_id, role, created_at)
        VALUES ('another-member', 'another', 'other', 'member', 0);
    `);
    expect(await service.listVaults(other, undefined, "another")).toEqual([]);
    // A stale Team row cannot bypass loss of organization membership.
    database.prepare("DELETE FROM member WHERE user_id = ? AND organization_id = ?").run(other.userId, "external");
    await expect(service.listVaults(other, undefined, "external")).rejects.toMatchObject({ status: 403 });
    expect(await service.listOrganizations(other)).toMatchObject([{ id: "another" }]);
    database.close();
    await store.close?.();
  });

  it("validates the exclusive Vault query at the HTTP boundary", async () => {
    const { store, databasePath } = await setup();
    await createVault(store);
    const app = createApp({ config: testConfig(databasePath), authStore: store });
    for (const query of ["", "?userId=owner"]) {
      const response = await app.request("/api/v1/vaults" + query, { headers: headers() });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ items: [{ vaultId }] });
    }
    for (const query of ["?userId=owner&organizationId=external", "?userId=", "?organizationId=", "?userId=%20owner", "?organizationId=%00"]) {
      expect((await app.request("/api/v1/vaults" + query, { headers: headers() })).status).toBe(400);
    }
    for (const query of ["?userId=other", "?organizationId=unknown"]) {
      expect((await app.request("/api/v1/vaults" + query, { headers: headers() })).status).toBe(403);
    }
    const organizations = await app.request("/api/v1/organizations", { headers: headers() });
    expect(await organizations.json()).toMatchObject([{ id: "external" }]);
    const disabled = createNodeApplicationStore({ ...testConfig(databasePath), syncSharingEnabled: false });
    const disabledService = new MeetingSyncService(disabled.sync);
    expect(await disabledService.listVaults(owner)).toHaveLength(1);
    expect(await disabledService.listOrganizations(owner)).toEqual([]);
    await expect(disabledService.listVaults(owner, undefined, "external")).rejects.toMatchObject({ status: 403 });
    await disabled.close?.();
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
    const pageSchema = z.object({ items: z.array(z.object({ meetingId: z.string(), projectId: z.string().nullable() })), nextCursor: z.string().optional() });
    const first = pageSchema.parse(await (await get(`projectId=${projectId}&projectScope=direct`)).json());
    expect(first.items).toHaveLength(200);
    expect(first.items.every((item) => item.projectId === projectId)).toBe(true);
    expect(first.nextCursor).toBeDefined();
    const last = pageSchema.parse(await (await get(`projectId=${projectId}&projectScope=direct&cursor=${encodeURIComponent(first.nextCursor!)}`)).json());
    expect(last.items).toHaveLength(1);
    expect(last.nextCursor).toBeUndefined();
    expect(new Set([...first.items, ...last.items].map(({ meetingId }) => meetingId)).size).toBe(201);
    expect(await (await get("projectScope=unassigned")).json()).toMatchObject({ items: [{ meetingId: unassignedId }] });
    expect(await (await get(`projectId=${childId}&projectScope=direct`)).json()).toMatchObject({ items: [{ meetingId: childMeetingId }] });
    const legacy = await store.sync.withIdentity(owner, (sync) => sync.listMeetings(vaultId, undefined, 300, projectId));
    expect(legacy).toHaveLength(202);
    for (const query of ["projectScope=direct", "projectScope=unknown", `projectScope=unassigned&projectId=${projectId}`]) {
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

  it("rejects destructive Vault resets from shared members", async () => {
    const { store } = await setup();
    await createVault(store);
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "external"));
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
    database.prepare("update storage_delete_jobs set lease_expires_at = 0 where storage_key = ?")
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
    await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", "external"));
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
      .toContainEqual(expect.objectContaining({ principalType: "organization", principalId: "external" }));
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
    await service.putTranscriptChunk(owner, vaultId, meetingId, patchId, 0, chunkHash, {
      segments: [{
        segmentId,
        startTime: now.toISOString(),
        endTime: null,
        text: "staged",
        isConfirmed: true,
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
          patchId,
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
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
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
    expect(await response.json()).toMatchObject({ error: "invalid_sync_operation", operationId });
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
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
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
      artifactStorage: new LocalObjectStorage(join(directory, "objects")),
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
        (document_id, vault_id, meeting_id, kind, search_text, embedding_text, embedding_content_hash)
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

async function setup(searchEmbedding?: AppConfig["searchEmbedding"]) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-sync-"));
  directories.push(directory);
  const databasePath = join(directory, "server.sqlite");
  const store = createNodeApplicationStore({ ...testConfig(databasePath), searchEmbedding });
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
    syncSharingEnabled: true,
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

async function fileSetup() {
  const setupValue = await setup();
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
  await service.reserveFile(owner, file);
  await service.putFile(owner, file.id, new Request("https://test.invalid", { method: "PUT", body: bytes,
    headers: { "content-type": "image/png", "content-length": String(bytes.length) } }));
  const publish = () => service.commitTransaction(owner, wire([{ entity: "file", action: "upsert", entityId: file.id,
    baseRevision: null, data: { checksum: file.checksum, metadata: {} } }]));
  const attach = () => service.commitTransaction(owner, wire([{ entity: "meeting_file", action: "upsert", entityId: file.id,
    baseRevision: null, data: { fileId: file.id, meetingId, capturedAt: now.toISOString(), sessionId: null, createdAt: now.toISOString() } }]));
  return { ...setupValue, service, storage, transformer, file, bytes, publish, attach };
}
