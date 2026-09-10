import { afterEach, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createVaultCipher, encodeBase64, encryptionConfig, unwrapDataKey, wrapDataKey } from "../src/encryption/crypto";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";
import type { Identity } from "../src/auth/identity";
import type { SyncTransaction } from "../src/sync/types";
import { uuidV7 } from "../src/id";
import { seedHeaderIdentity, testUserID } from "./public-test-client";
import type { SummaryJob } from "../src/summary/model";

const owner: Identity = { userId: testUserID("encryption-owner"), workspaceId: "personal:encryption-owner", source: "header" };
const outsider: Identity = { userId: testUserID("encryption-outsider"), workspaceId: "personal:encryption-outsider", source: "header" };
const key1 = encodeBase64(new Uint8Array(32).fill(1));
const key3 = encodeBase64(new Uint8Array(32).fill(3));
const config1 = encryptionConfig({ DAHLIA_ENCRYPTION_MASTER_KEY_1: key1, DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "1" })!;
const config3 = encryptionConfig({ DAHLIA_ENCRYPTION_MASTER_KEY_1: key1, DAHLIA_ENCRYPTION_MASTER_KEY_3: key3, DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "3" })!;
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });

it("validates numbered secrets without echoing secret values", () => {
  expect(encryptionConfig({})).toBeUndefined();
  expect(config3.activeKeyId).toBe("3");
  expect([...config3.masterKeys.keys()]).toEqual(["1", "3"]);
  for (const env of [
    { DAHLIA_ENCRYPTION_MASTER_KEY_1: key1 },
    { DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "2" },
    { DAHLIA_ENCRYPTION_MASTER_KEY_01: key1 },
    { DAHLIA_ENCRYPTION_MASTER_KEY_1: "private-invalid-secret" },
    { DAHLIA_ENCRYPTION_MASTER_KEY_1: encodeBase64(new Uint8Array(31)), DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "1" },
  ]) {
    expect(() => encryptionConfig(env)).toThrow();
    try { encryptionConfig(env); } catch (error) { expect(String(error)).not.toContain("private-invalid-secret"); }
  }
});

it("authenticates ciphertext identity and rewraps without changing the data key", async () => {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  const wrapped = await wrapDataKey(config1, "vault", raw);
  expect(await unwrapDataKey(config3, "vault", wrapped)).toEqual(raw);
  await expect(unwrapDataKey(config1, "other-vault", wrapped)).rejects.toThrow("vault_encryption_unavailable");
  const cipher = await createVaultCipher("vault", raw);
  const encrypted = await cipher.encrypt("table", "row", "field", { text: "secret" });
  expect(await cipher.encrypt("table", "row", "field", { text: "secret" })).not.toBe(encrypted);
  expect(await cipher.decrypt("table", "row", "field", encrypted)).toEqual({ text: "secret" });
  await expect(cipher.decrypt("table", "other-row", "field", encrypted)).rejects.toThrow();
  await expect(cipher.decrypt("table", "row", "other-field", encrypted)).rejects.toThrow();
  const corrupt = JSON.parse(encrypted) as { ciphertext: string };
  corrupt.ciphertext = (corrupt.ciphertext[0] === "A" ? "B" : "A") + corrupt.ciphertext.slice(1);
  await expect(cipher.decrypt("table", "row", "field", JSON.stringify(corrupt))).rejects.toThrow();
  expect(await unwrapDataKey(config3, "vault", await wrapDataKey(config3, "vault", raw))).toEqual(raw);
  expect(await cipher.hash("a", "value")).not.toBe(await cipher.hash("b", "value"));
});

async function setup(mode: "none" | "server" = "server") {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-encryption-"));
  const path = join(directory, "server.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${path}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024, encryption: config1,
    searchEmbedding: { model: "test", dimensions: 32 } };
  let store = createNodeApplicationStore(config);
  cleanups.push(async () => { await store.close?.(); rmSync(directory, { recursive: true, force: true }); });
  await store.migrate();
  await seedHeaderIdentity(store, path, owner);
  await seedHeaderIdentity(store, path, outsider);
  const vaultId = uuidV7();
  const transaction = (operations: SyncTransaction["operations"], vault = vaultId): SyncTransaction => ({
    schemaVersion: 2, id: uuidV7(), vaultId: vault, createdAt: new Date(), requestHash: uuidV7(), operations,
  });
  const commit = (tx: SyncTransaction) => store.sync.withIdentity(owner, (sync) => sync.commitTransaction(tx));
  await commit(transaction([{ id: uuidV7(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null,
    data: { name: "PRIVATE_VAULT_MARKER", encryption: mode, createdAt: new Date() } }]));
  const db = new DatabaseSync(path);
  cleanups.push(async () => db.close());
  return { db, path, directory, vaultId, transaction, commit, config,
    get store() { return store; },
    async reopen(encryption: AppConfig["encryption"]) { await store.close?.(); store = createNodeApplicationStore({ ...config, encryption }); },
  };
}

it("encrypts canonical content, patches and receipts while preserving plaintext search data", async () => {
  const f = await setup();
  const meetingId = uuidV7();
  const now = new Date();
  await f.commit(f.transaction([{ id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
    data: { name: "PRIVATE_MEETING_MARKER", description: "PRIVATE_DESCRIPTION_MARKER", projectId: null, status: "READY", duration: null,
      recordingStartedAt: null, createdAt: now, updatedAt: now, searchText: "allowed search", embeddingContentHash: "public-search-hash" } }]));
  const summaryTx = f.transaction([{ id: uuidV7(), entity: "summary", action: "update", entityId: meetingId, baseRevision: 0,
    data: { title: "PRIVATE_SUMMARY_MARKER", document: JSON.stringify({ description: "PRIVATE_SUMMARY_BODY_MARKER", sections: [] }), createdAt: now } }]);
  await f.commit(summaryTx);
  expect((await f.commit(summaryTx)).records[0]?.record?.title).toBe("PRIVATE_SUMMARY_MARKER");
  await expect(f.commit({ ...summaryTx, requestHash: "different" })).rejects.toMatchObject({ code: "idempotency_key_reused" });
  const metadata = { provider: "PRIVATE_PROVIDER_MARKER", request: { model: "PRIVATE_MODEL_MARKER" }, runs: [{ generatedBy: "desktop", inputTypes: ["audio"] }] };
  const patchId = uuidV7(); const segmentId = uuidV7(); const hash = "a".repeat(64);
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.putTranscriptChunk(f.vaultId, meetingId, patchId, 0, hash,
    [{ segmentId, startedAt: now, endedAt: null, createdAt: now, text: "PRIVATE_TRANSCRIPT_MARKER", speakerLabel: "PRIVATE_SPEAKER_MARKER", audioSource: "mic" }], []))).toBe(true);
  expect(JSON.stringify(f.db.prepare("SELECT * FROM transcript_patch_chunks").all())).not.toContain("PRIVATE_");
  await f.commit(f.transaction([{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 0,
    data: { transcript: { id: patchId, startedAt: now, endedAt: null, metadata }, mode: "replace", patchId,
      segmentCount: 1, deletionCount: 0, chunks: [{ index: 0, sha256: hash, segmentCount: 1, deletionCount: 0 }] } }]));
  const read = () => f.store.sync.withIdentity(owner, (sync) => sync.listTranscript(f.vaultId, meetingId, 10));
  expect(await read()).toMatchObject([{ text: "PRIVATE_TRANSCRIPT_MARKER", speakerLabel: "PRIVATE_SPEAKER_MARKER" }]);
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.getMeeting(f.vaultId, meetingId))).toMatchObject({ name: "PRIVATE_MEETING_MARKER", summaryTitle: "PRIVATE_SUMMARY_MARKER" });
  expect(await f.store.sync.withIdentity(outsider, (sync) => sync.getMeeting(f.vaultId, meetingId))).toBeNull();
  f.db.exec("UPDATE jobs_search_index SET available_at = 0");
  const [job] = await f.store.searchIndex!.claim("test", 32, 1);
  const document = await f.store.searchIndex!.load(job!);
  expect(document?.embeddingText).toBe("allowed search");
  expect(f.db.prepare("PRAGMA table_info(search_documents)").all()).not.toEqual(
    expect.arrayContaining([expect.objectContaining({ name: "embedding_text" })]));
  expect(await f.store.searchIndex!.save(document!, "test", 32, [1, ...new Array<number>(31).fill(0)])).toBe(true);
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.listMeetings(f.vaultId,
    { text: "allowed", tokens: ["allowed"], embedding: { model: "test", dimensions: 32, vector: [1, ...new Array<number>(31).fill(0)] } }, 10))).toHaveLength(1);
  expect(f.db.prepare("SELECT search_text, embedding_model, length(embedding) AS bytes FROM search_documents").get())
    .toMatchObject({ search_text: "allowed search", embedding_model: "test", bytes: 128 });
  for (const table of ["vaults", "meetings", "summaries", "transcripts", "transcript_segments", "transaction_receipts"]) {
    expect(JSON.stringify(f.db.prepare(`SELECT * FROM ${table}`).all()), table).not.toContain("PRIVATE_");
  }
  const nextPatch = uuidV7();
  await f.commit(f.transaction([{ id: nextPatch, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 1,
    data: { transcript: { id: nextPatch, startedAt: now, endedAt: null, metadata }, mode: "append", patchId: nextPatch,
      segmentCount: 0, deletionCount: 0, chunks: [] } }]));
  expect(await read()).toMatchObject([{ text: "PRIVATE_TRANSCRIPT_MARKER", speakerLabel: "PRIVATE_SPEAKER_MARKER" }]);
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.listTranscript(f.vaultId, meetingId, 10, undefined, 1)))
    .toMatchObject([{ text: "PRIVATE_TRANSCRIPT_MARKER" }]);
  const original = f.db.prepare("SELECT encrypted_payload FROM transcript_segments WHERE transcript_id = ?").get(nextPatch)!.encrypted_payload;
  f.db.prepare("UPDATE transcript_segments SET encrypted_payload = ? WHERE transcript_id = ?").run("{}", nextPatch);
  await expect(read()).rejects.toThrow("vault_encryption_unavailable");
  f.db.prepare("UPDATE transcript_segments SET encrypted_payload = ? WHERE transcript_id = ?").run(original!, nextPatch);
  await f.reopen(undefined);
  await expect(read()).rejects.toThrow("vault_encryption_unavailable");
  await f.reopen(config3);
  expect(await f.store.rotateEncryptionKeys(false)).toMatchObject({ pending: 1, rotated: 0 });
  expect(await f.store.rotateEncryptionKeys(true)).toMatchObject({ rotated: 1 });
  expect(await f.store.rotateEncryptionKeys(true)).toMatchObject({ pending: 0, rotated: 0 });
  await f.reopen(encryptionConfig({ DAHLIA_ENCRYPTION_MASTER_KEY_3: key3, DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "3" }));
  expect(await read()).toMatchObject([{ text: "PRIVATE_TRANSCRIPT_MARKER" }]);
});

it("preserves protected file metadata and job input across partial updates and claims", async () => {
  const f = await setup();
  const meetingId = uuidV7(), fileId = uuidV7(), now = new Date();
  await f.commit(f.transaction([{ id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
    data: { projectId: null, name: "Meeting", description: "", status: "READY", createdAt: now, updatedAt: now } }]));
  const pending = await f.store.sync.withIdentity(owner, (sync) => sync.reserveFile({ fileId, vaultId: f.vaultId,
    name: "PRIVATE_FILENAME_MARKER", uri: "PRIVATE_URI_MARKER", offset: 0, size: 0, checksum: "", contentType: "image/png",
    metadata: { source: "screenshot", width: 10, height: 10, ocr_text: "PRIVATE_OCR_MARKER", caption: "PRIVATE_CAPTION_MARKER" },
    active: false, uploadedAt: null, revision: 0, createdAt: now, updatedAt: now }));
  const checksum = `SHA-256:${"a".repeat(64)}`;
  const uploaded = await f.store.sync.withIdentity(owner, (sync) => sync.markFileUploaded(pending!, 100, checksum));
  expect(uploaded).toMatchObject({ name: "PRIVATE_FILENAME_MARKER", checksum, metadata: { ocr_text: "PRIVATE_OCR_MARKER" } });
  await f.commit(f.transaction([
    { id: uuidV7(), entity: "file", action: "upsert", entityId: fileId, baseRevision: null, data: { checksum, metadata: {} } },
    { id: uuidV7(), entity: "meeting_attachment", action: "upsert", entityId: fileId, baseRevision: null,
      data: { fileId, meetingId, capturedAt: now, sessionId: null, createdAt: now } },
  ]));
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.getScreenshot(f.vaultId, meetingId, fileId)))
    .toMatchObject({ ocrText: "PRIVATE_OCR_MARKER", caption: "PRIVATE_CAPTION_MARKER", contentHash: "a".repeat(64) });
  expect((await f.store.sync.withIdentity(owner, (sync) => sync.listMeetingAttachments(f.vaultId, meetingId, undefined, 10)))[0]?.file.name)
    .toBe("PRIVATE_FILENAME_MARKER");
  const job: SummaryJob = { id: uuidV7(), vaultId: f.vaultId, meetingId, ownerUserId: owner.userId, method: "transcript",
    settings: { detail: "medium", model: "PRIVATE_MODEL_MARKER", reasoningEffort: "low" }, input: { type: "transcript", version: "PRIVATE_INPUT_MARKER" },
    inputVersion: "PRIVATE_VERSION_MARKER", requestHash: "PRIVATE_REQUEST_MARKER", outputLanguage: "ja", status: "pending", attempts: 0,
    createdAt: now, availableAt: now, claimedAt: null, leaseExpiresAt: null, lastErrorCode: null, summaryRevision: 0 };
  await f.store.sync.withIdentity(owner, (sync) => sync.insertSummaryJob(job));
  const claimed = await f.store.summaryJobs.claim();
  expect(claimed).toMatchObject({ settings: job.settings, input: job.input, inputVersion: job.inputVersion, requestHash: job.requestHash });
  expect(claimed).not.toHaveProperty("encryptedPayload");
  const cancelled = await f.store.sync.withIdentity(owner, (sync) => sync.cancelSummaryJob(f.vaultId, meetingId, job.id));
  expect(cancelled).toMatchObject({ status: "cancelled", settings: job.settings, input: job.input });
  for (const table of ["files", "jobs_summary", "transaction_receipts"]) {
    expect(JSON.stringify(f.db.prepare(`SELECT * FROM ${table}`).all()), table).not.toContain("PRIVATE_");
  }
});

it("rejects mode changes and transfers, rolls back failed writes, and compacts encrypted receipts", async () => {
  const f = await setup();
  await expect(f.commit(f.transaction([{ id: uuidV7(), entity: "vault", action: "update", entityId: f.vaultId, baseRevision: 1,
    data: { name: "changed", encryption: "none" } }]))).rejects.toMatchObject({ code: "vault_encryption_immutable" });
  await f.commit(f.transaction([{ id: uuidV7(), entity: "vault", action: "update", entityId: f.vaultId, baseRevision: 1,
    data: { name: "PRIVATE_UPDATED_MARKER" } }]));
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.getVault(f.vaultId))).toMatchObject({ encryption: "server", name: "PRIVATE_UPDATED_MARKER" });
  const before = f.db.prepare("SELECT count(*) AS n FROM projects").get()!.n;
  await expect(f.commit(f.transaction([
    { id: uuidV7(), entity: "project", action: "create", entityId: uuidV7(), baseRevision: null,
      data: { name: "PRIVATE_ROLLBACK_MARKER", description: "", parentProjectId: null, projectType: "personal", createdAt: new Date() } },
    { id: uuidV7(), entity: "vault", action: "update", entityId: f.vaultId, baseRevision: 999, data: { name: "stale" } },
  ]))).rejects.toMatchObject({ code: "revision_conflict" });
  expect(f.db.prepare("SELECT count(*) AS n FROM projects").get()!.n).toBe(before);
  const destination = uuidV7();
  await f.commit(f.transaction([{ id: uuidV7(), entity: "vault", action: "create", entityId: destination, baseRevision: null,
    data: { name: "Normal", createdAt: new Date() } }], destination));
  await expect(f.store.sync.withIdentity(owner, async (sync) => sync.transferVault({ sourceVaultId: f.vaultId, destinationVaultId: destination,
    sourceRevision: 2, destinationRevision: 1, idempotencyKey: uuidV7(), requestHash: uuidV7(),
    audienceHash: (await sync.vaultTransferAudience(f.vaultId, destination)).audienceHash }))).rejects.toMatchObject({ code: "encrypted_vault_transfer_unsupported" });
  f.db.exec("UPDATE transaction_receipts SET created_at = 0");
  expect(await f.store.sync.pruneHistoryBatch({ ownerUserId: owner.userId, vaultId: f.vaultId })).toMatchObject({ receiptsCompacted: 2 });
  const wrapped = f.db.prepare("SELECT wrapped_key FROM vault_keys WHERE vault_id = ?").get(f.vaultId)!.wrapped_key as string;
  const cipher = await createVaultCipher(f.vaultId, await unwrapDataKey(config1, f.vaultId, wrapped));
  const receipts = f.db.prepare("SELECT transaction_id, encrypted_payload FROM transaction_receipts WHERE vault_id = ?").all(f.vaultId);
  for (const row of receipts) expect(await cipher.decrypt("transaction_receipts", JSON.stringify([row.transaction_id]), "content", row.encrypted_payload as string))
    .toMatchObject({ responseJson: null });
});


it("restores a database backup only with its matching master key", async () => {
  const f = await setup();
  const backup = join(f.directory, "backup.sqlite");
  f.db.prepare("VACUUM INTO ?").run(backup);
  const restored = createNodeApplicationStore({ ...f.config, databaseUrl: `file:${backup}` });
  cleanups.push(async () => restored.close?.());
  expect(await restored.sync.withIdentity(owner, (sync) => sync.getVault(f.vaultId)))
    .toMatchObject({ name: "PRIVATE_VAULT_MARKER" });
  const wrong = createNodeApplicationStore({ ...f.config, databaseUrl: `file:${backup}`, encryption:
    encryptionConfig({ DAHLIA_ENCRYPTION_MASTER_KEY_1: key3, DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "1" }) });
  cleanups.push(async () => wrong.close?.());
  await expect(wrong.sync.withIdentity(owner, (sync) => sync.getVault(f.vaultId))).rejects.toThrow("vault_encryption_unavailable");
});


it.each(["none", "server"] as const)("avoids per-segment preservation lookups for full transcript writes (%s)", async (mode) => {
  const f = await setup(mode), meetingId = uuidV7(), patchId = uuidV7(), now = new Date();
  const metadata = { provider: "test", request: { model: "test" }, runs: [{ generatedBy: "desktop", inputTypes: ["audio"] }] };
  await f.commit(f.transaction([{ id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
    data: { projectId: null, name: "Meeting", description: "", status: "READY", createdAt: now, updatedAt: now } }]));
  const segments = Array.from({ length: 500 }, () => ({ segmentId: uuidV7(), startedAt: now, endedAt: null, createdAt: now,
    text: "batch transcript", speakerLabel: null, audioSource: "mic" }));
  const hash = "b".repeat(64);
  await f.store.sync.withIdentity(owner, (sync) => sync.putTranscriptChunk(f.vaultId, meetingId, patchId, 0, hash, segments, []));
  const prepare = vi.spyOn(DatabaseSync.prototype, "prepare");
  try {
    await f.commit(f.transaction([{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 0,
      data: { transcript: { id: patchId, startedAt: now, endedAt: null, metadata }, mode: "replace", patchId,
        segmentCount: segments.length, deletionCount: 0, chunks: [{ index: 0, sha256: hash, segmentCount: segments.length, deletionCount: 0 }] } }]));
    const patchQueries = prepare.mock.calls.map(([query]) => query);
    prepare.mockClear();
    const updatePatch = uuidV7();
    const updated = { ...segments[0]!, text: "updated transcript", speakerLabel: "Speaker" };
    await f.store.sync.withIdentity(owner, (sync) => sync.putTranscriptChunk(f.vaultId, meetingId, updatePatch, 0, hash, [updated], []));
    prepare.mockClear();
    await f.commit(f.transaction([{ id: updatePatch, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 1,
      data: { transcript: { id: patchId, startedAt: now, endedAt: null, metadata }, mode: "append", patchId: updatePatch,
        segmentCount: 1, deletionCount: 0, chunks: [{ index: 0, sha256: hash, segmentCount: 1, deletionCount: 0 }] } }]));
    const updateQueries = prepare.mock.calls.map(([query]) => query);
    prepare.mockClear();
    const nextPatch = uuidV7();
    await f.commit(f.transaction([{ id: nextPatch, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 2,
      data: { transcript: { id: nextPatch, startedAt: now, endedAt: null, metadata }, mode: "append", patchId: nextPatch,
        segmentCount: 0, deletionCount: 0, chunks: [] } }]));
    const copyQueries = prepare.mock.calls.map(([query]) => query);
    for (const queries of [patchQueries, updateQueries, copyQueries]) {
      expect(queries.filter((query) => /^select "meeting_id" from "transcripts"/i.test(query))).toHaveLength(0);
      expect(queries.filter((query) => /^select /i.test(query)
        && query.includes('from "transcript_segments"') && query.includes('"segment_id" = ?'))).toHaveLength(0);
    }
    if (mode === "none") expect(copyQueries.filter((query) => /^insert into "transcript_segments".* select /i.test(query))).toHaveLength(1);
    const read = (version: number) => f.store.sync.withIdentity(owner, (sync) => sync.listTranscript(f.vaultId, meetingId, 600, undefined, version));
    expect(await read(2)).toEqual(await read(1));
    expect(await read(2)).toHaveLength(500);
    expect(await read(2)).toEqual(expect.arrayContaining([expect.objectContaining({ text: "updated transcript", speakerLabel: "Speaker" })]));
  } finally { prepare.mockRestore(); }
});


it.each(["none", "server"] as const)("preserves file and job ID conflicts across Vaults (%s source)", async (mode) => {
  const f = await setup(mode), destination = uuidV7(), meetingId = uuidV7(), targetMeetingId = uuidV7(), now = new Date();
  await f.commit(f.transaction([{ id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
    data: { projectId: null, name: "Source", description: "", status: "READY", createdAt: now, updatedAt: now } }]));
  await f.commit(f.transaction([
    { id: uuidV7(), entity: "vault", action: "create", entityId: destination, baseRevision: null,
      data: { name: "Destination", encryption: "server", createdAt: now } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: targetMeetingId, baseRevision: null,
      data: { projectId: null, name: "Target", description: "", status: "READY", createdAt: now, updatedAt: now } },
  ], destination));
  const file = { fileId: uuidV7(), vaultId: f.vaultId, name: "original.png", uri: "private", offset: 0, size: 0, checksum: "", contentType: "image/png",
    metadata: { source: "screenshot" as const }, active: false, uploadedAt: null, revision: 0, createdAt: now, updatedAt: now };
  await f.store.sync.withIdentity(owner, (sync) => sync.reserveFile(file));
  const job: SummaryJob = { id: uuidV7(), vaultId: f.vaultId, meetingId, ownerUserId: owner.userId, method: "transcript",
    settings: { detail: "medium", model: "test", reasoningEffort: "low" }, input: { type: "transcript", version: "1" }, inputVersion: "1", requestHash: "source",
    outputLanguage: "ja", status: "pending", attempts: 0, createdAt: now, availableAt: now, claimedAt: null, leaseExpiresAt: null, lastErrorCode: null, summaryRevision: 0 };
  await f.store.sync.withIdentity(owner, (sync) => sync.insertSummaryJob(job));
  await expect(f.store.sync.withIdentity(owner, (sync) => sync.reserveFile({ ...file, vaultId: destination }))).resolves.toBeNull();
  await expect(f.store.sync.withIdentity(owner, (sync) => sync.insertSummaryJob({ ...job, vaultId: destination, meetingId: targetMeetingId })))
    .rejects.toMatchObject({ code: "summary_id_reused", status: 409 });
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.getFile(file.fileId))).toMatchObject({ vaultId: f.vaultId, name: file.name });
  expect(await f.store.sync.withIdentity(owner, (sync) => sync.getSummaryJob(f.vaultId, meetingId, job.id)))
    .toMatchObject({ vaultId: f.vaultId, requestHash: "source", input: job.input });
});
