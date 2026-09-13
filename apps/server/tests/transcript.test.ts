import { testOrganizationID } from "./public-test-client";
import { seedHeaderIdentity, testUserID } from "./public-test-client";
import { z } from "zod";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createApp } from "./public-test-client";
import { createWorkerHandler } from "../src/worker";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { Identity } from "../src/auth/identity";
import type { AppConfig } from "../src/config";
import { uuidV7 } from "../src/id";
import { MeetingSyncService } from "../src/sync/service";
import { transcriptMetadataSchema, transcriptStatus, TRANSCRIPT_ACTIVITY_WINDOW_MS } from "../src/sync/transcript";
import transcriptPolicy from "../src/sync/transcript-policy.json";

it("ships the same activity policy as Desktop without a runtime dependency on its source tree", () => {
  const desktop: unknown = JSON.parse(readFileSync(new URL("../../desktop/Sources/DahliaRuntimeSupport/Resources/TranscriptPolicy.json", import.meta.url), "utf8"));
  expect(transcriptPolicy).toEqual(desktop);
});

const directories: string[] = [];
afterEach(() => { vi.useRealTimers(); for (const path of directories.splice(0)) rmSync(path, { recursive: true, force: true }); });
const owner: Identity = { userId: testUserID("owner"),  source: "header" };
const member: Identity = { userId: testUserID("reader"),  source: "header" };
const metadata = (model = "apple-speech-live") => ({ provider: "apple", request: { model },
  runs: [{ generatedBy: "desktop", inputTypes: ["audio"], startedAt: null, completedAt: null }] });

async function setup() {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-transcript-")); directories.push(directory);
  const databasePath = join(directory, "db.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
    databaseUrl: `file:${databasePath}`, baseUrl: "http://localhost:5173", oauthRedirectUris: [],
    maxRequestBytes: 1_048_576 };
  const store = createNodeApplicationStore(config);
  await store.migrate(); await seedHeaderIdentity(store, databasePath, owner); await seedHeaderIdentity(store, databasePath, member);
  const sync = new MeetingSyncService(store.sync);
  const workspaceId = uuidV7(); const meetingId = uuidV7(); const now = new Date().toISOString();
  const body = (operations: unknown[]) => ({ schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: now, operations });
  await sync.commitTransaction(owner, body([
    { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Workspace", createdAt: now } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { name: "Meeting", status: "READY", projectId: null, duration: null, recordingStartedAt: null, createdAt: now, updatedAt: now } },
  ]));
  const stage = async (id: string, baseRevision: number, status: string, mode: string, texts: string[] = [], details: unknown = metadata()) => {
    const patchId = uuidV7();
    const segments = texts.map((text, index) => ({ segmentId: uuidV7(), startedAt: new Date(index).toISOString(), endedAt: null,
      text, createdAt: now, audioSource: "mic", speakerLabel: null }));
    const chunks = [];
    for (let offset = 0; offset < segments.length; offset += 500) {
      const chunk = { segments: segments.slice(offset, offset + 500), deletions: [] };
      const sha256 = createHash("sha256").update(JSON.stringify(chunk)).digest("hex");
      await sync.putTranscriptChunk(owner, meetingId, patchId, chunks.length, sha256, chunk);
      chunks.push({ index: chunks.length, sha256, segmentCount: chunk.segments.length, deletionCount: 0 });
    }
    const transaction = body([{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision,
      data: { patchId, mode, transcript: { id, startedAt: now, endedAt: status === "completed" ? now : null, metadata: details },
        segmentCount: segments.length, deletionCount: 0, chunks } }]);
    return transaction;
  };
  const write = async (...args: Parameters<typeof stage>) => {
    const transaction = await stage(...args);
    const receipt = await sync.commitTransaction(owner, transaction);
    return { transaction, receipt };
  };
  return { store, sync, config, databasePath, workspaceId, meetingId, body, stage, write };
}

describe("transcript versions", () => {
  it("stores, updates, copies, and backfills normalized character counts without a metrics version", async () => {
    const { store, sync, workspaceId, meetingId, body, databasePath } = await setup();
    const transcriptId = uuidV7();
    const segmentIds = [uuidV7(), uuidV7()];
    const write = async (segmentId: string, text: string, baseRevision: number) => {
      const patchId = uuidV7();
      const chunk = { segments: [{ segmentId, startedAt: new Date(0).toISOString(), endedAt: null,
        text, createdAt: new Date().toISOString(), audioSource: "mic", speakerLabel: null }], deletions: [] };
      const sha256 = createHash("sha256").update(JSON.stringify(chunk)).digest("hex");
      await sync.putTranscriptChunk(owner, meetingId, patchId, 0, sha256, chunk);
      await sync.commitTransaction(owner, body([{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision,
        data: { patchId, mode: "append", transcript: { id: transcriptId, startedAt: null, endedAt: null, metadata: metadata() },
          segmentCount: 1, deletionCount: 0, chunks: [{ index: 0, sha256, segmentCount: 1, deletionCount: 0 }] } }]));
    };
    try {
      await write(segmentIds[0]!, "A 👨‍👩‍👧‍👦 e\u0301", 0);
      await write(segmentIds[0]!, " 日 本 ", 1);
      await write(segmentIds[1]!, "three", 2);
      const copiedId = uuidV7();
      const copyPatchId = uuidV7();
      await sync.commitTransaction(owner, body([{ id: copyPatchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 3,
        data: { patchId: copyPatchId, mode: "append", transcript: { id: copiedId, startedAt: null, endedAt: null, metadata: metadata() },
          segmentCount: 0, deletionCount: 0, chunks: [] } }]));
      const db = new DatabaseSync(databasePath);
      const storedCounts = (id: string) => db.prepare("SELECT normalized_character_count FROM transcript_segments WHERE transcript_id = ?")
        .all(id).map((row) => row.normalized_character_count).sort();
      expect(storedCounts(transcriptId)).toEqual([2, 5]);
      expect(storedCounts(copiedId)).toEqual([2, 5]);
      db.prepare("UPDATE transcript_segments SET normalized_character_count = NULL WHERE transcript_id = ?").run(copiedId);
      expect((await store.sync.withIdentity(owner, (scoped) => scoped.listTranscriptAnalytics(workspaceId, meetingId, 2)))
        .map((row) => row.normalizedCharacterCount).sort()).toEqual([2, 5]);
      expect(storedCounts(copiedId)).toEqual([2, 5]);
      const columns = db.prepare("PRAGMA table_info(transcript_segments)").all().map((row) => row.name);
      expect(columns).not.toContain("text_metrics_version");
      db.close();
    } finally { await store.close?.(); }
  });

  it("backfills normalized character counts across bounded update batches", async () => {
    const { store, workspaceId, meetingId, databasePath, write } = await setup();
    const transcriptId = uuidV7();
    try {
      const texts = Array.from({ length: 201 }, (_, index) => index % 2 ? "一" : "two");
      await write(transcriptId, 0, "completed", "replace", texts);
      const db = new DatabaseSync(databasePath);
      db.prepare("UPDATE transcript_segments SET normalized_character_count = NULL WHERE transcript_id = ?").run(transcriptId);
      const counts = (await store.sync.withIdentity(owner, (scoped) => scoped.listTranscriptAnalytics(workspaceId, meetingId, 1)))
        .map((row) => row.normalizedCharacterCount);
      expect(counts).toHaveLength(201);
      expect(counts.filter((count) => count === 1)).toHaveLength(100);
      expect(counts.filter((count) => count === 3)).toHaveLength(101);
      expect(db.prepare("SELECT count(*) AS count FROM transcript_segments WHERE normalized_character_count IS NULL").get())
        .toMatchObject({ count: 0 });
      db.close();
    } finally { await store.close?.(); }
  });

  it("counts only the latest authorized transcript and preserves its snapshot header", async () => {
    const { store, sync, workspaceId, meetingId, write } = await setup();
    try {
      expect(await store.sync.withIdentity(owner, (scoped) => scoped.countTranscript(workspaceId, meetingId))).toBe(0);
      await write(uuidV7(), 0, "completed", "replace", ["old", "old second"]);
      const latestId = uuidV7();
      await write(latestId, 1, "completed", "replace", ["current"]);
      expect(await store.sync.withIdentity(owner, (scoped) => scoped.countTranscript(workspaceId, meetingId))).toBe(1);
      expect(await store.sync.withIdentity(member, (scoped) => scoped.countTranscript(workspaceId, meetingId))).toBe(0);
      expect(await store.sync.withIdentity(owner, (scoped) => scoped.countTranscript(uuidV7(), meetingId))).toBe(0);
      const page = await sync.listSnapshot(owner, workspaceId);
      expect(page.items.find((item) => item.entity === "transcript")?.record).toMatchObject({
        contentOmitted: true, contentCount: 1, transcript: { id: latestId, version: 2 },
      });
    } finally { await store.close?.(); }
  });

  it("publishes large snapshots atomically and replays them without another version", async () => {
    const { store, sync, workspaceId, meetingId, databasePath, stage, write } = await setup();
    try {
      await write(uuidV7(), 0, "completed", "replace", ["previous version"]);
      const texts = Array.from({ length: 50_001 }, (_, index) => `segment ${index}`);
      const failed = await stage(uuidV7(), 1, "completed", "replace", texts);
      const db = new DatabaseSync(databasePath);
      db.prepare("UPDATE transcript_patch_chunks SET payload = ? WHERE chunk_index = 100")
        .run(JSON.stringify({ segments: [], deletions: [] }));
      db.close();
      await expect(sync.commitTransaction(owner, failed)).rejects.toMatchObject({ code: "transcript_patch_count_mismatch" });
      expect((await sync.transcriptVersions(owner, workspaceId, meetingId)).items).toHaveLength(1);
      expect((await sync.transcriptContent(owner, workspaceId, meetingId, "latest")).items).toMatchObject([{ text: "previous version" }]);

      const { transaction, receipt } = await write(uuidV7(), 1, "completed", "replace", texts);
      expect(await sync.commitTransaction(owner, transaction)).toEqual(receipt);
      expect(await sync.transcriptContent(owner, workspaceId, meetingId, "latest", "1"))
        .toMatchObject({ version: 2, count: 50_001, syncRevision: 2 });
      expect((await sync.transcriptVersions(owner, workspaceId, meetingId)).items).toHaveLength(2);
      expect((await sync.transcriptContent(owner, workspaceId, meetingId, "1")).items).toMatchObject([{ text: "previous version" }]);
    } finally { await store.close?.(); }
  }, 60_000);

  it("derives every activity state and the exact inactivity boundary", () => {
    const generated = new Date("2026-09-08T10:00:00.000Z");
    expect(transcriptStatus(generated, null, generated)).toBe("ended");
    expect(transcriptStatus(null, null, generated)).toBe("unknown");
    expect(transcriptStatus(null, generated, generated)).toBe("active");
    expect(transcriptStatus(null, generated, new Date(generated.getTime() + TRANSCRIPT_ACTIVITY_WINDOW_MS))).toBe("active");
    expect(transcriptStatus(null, generated, new Date(generated.getTime() + TRANSCRIPT_ACTIVITY_WINDOW_MS + 1))).toBe("inactive");
  });

  it("preserves offline creation times and initial Server save time across retry and copy, without stored status", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-09-08T10:00:00.000Z"));
    const { store, sync, workspaceId, meetingId, write, databasePath } = await setup();
    try {
      const firstId = uuidV7();
      await write(firstId, 0, "live", "append");
      expect(await sync.transcriptContent(owner, workspaceId, meetingId, "latest")).toMatchObject({ transcript: { status: "unknown" } });
      vi.setSystemTime(new Date("2026-09-08T10:10:00.000Z"));
      const { transaction, receipt } = await write(firstId, 1, "live", "append", ["generated offline"]);
      expect(await sync.commitTransaction(owner, transaction)).toEqual(receipt);
      const first = await sync.transcriptContent(owner, workspaceId, meetingId, "latest");
      expect(first).toMatchObject({ transcript: { createdAt: new Date("2026-09-08T10:00:00.000Z"), status: "inactive", endedAt: null } });
      expect(first.items?.[0]?.createdAt).toEqual(new Date("2026-09-08T10:00:00.000Z"));
      await write(uuidV7(), 2, "live", "append");
      const copied = await sync.transcriptContent(owner, workspaceId, meetingId, "latest");
      expect(copied.items).toEqual(first.items);
      expect(copied).toMatchObject({ transcript: { createdAt: new Date("2026-09-08T10:10:00.000Z"), status: "inactive" } });
      expect((await sync.transcriptContent(owner, workspaceId, meetingId, "1")).items).toEqual(first.items);
      const db = new DatabaseSync(databasePath);
      const parent = db.prepare("pragma table_info(transcripts)").all().map((row) => row.name);
      const child = db.prepare("pragma table_info(transcript_segments)").all().map((row) => row.name);
      expect(parent).not.toContain("status"); expect(parent).not.toContain("workspace_id");
      expect(child).toEqual(expect.arrayContaining(["started_at", "ended_at", "created_at"]));
      expect(child).not.toContain("is_confirmed"); expect(child).not.toContain("start_time");
      db.close();
    } finally { await store.close?.(); }
  });

  it("keeps a single live version, copies once on append, and never mutates a completed version", async () => {
    const { store, sync, workspaceId, meetingId, write } = await setup();
    try {
      const firstId = uuidV7();
      await write(firstId, 0, "live", "append");
      await write(firstId, 1, "live", "append", ["first"]);
      await write(firstId, 2, "completed", "append");
      const first = await sync.transcriptContent(owner, workspaceId, meetingId, "1");
      expect(first).toMatchObject({ version: 1, syncRevision: 3, transcript: { id: firstId, status: "ended" }, items: [{ text: "first" }] });
      expect(first).not.toHaveProperty("revision");
      const secondId = uuidV7();
      const { transaction, receipt } = await write(secondId, 3, "live", "append", ["second"]);
      expect(await sync.commitTransaction(owner, transaction)).toEqual(receipt);
      expect((await sync.transcriptVersions(owner, workspaceId, meetingId)).items).toHaveLength(2);
      await write(secondId, 4, "completed", "append");
      expect((await sync.transcriptContent(owner, workspaceId, meetingId, "latest")).items?.map((row) => row.text)).toEqual(["first", "second"]);
      expect(await sync.transcriptContent(owner, workspaceId, meetingId, "1")).toEqual(first);
      await expect(write(firstId, 5, "live", "append", ["overwrite"])).rejects.toMatchObject({ status: 409 });
      await expect(write(secondId, 5, "completed", "append", ["overwrite"])).rejects.toMatchObject({ status: 409 });
      await expect(write(uuidV7(), 5, "live", "append", [], metadata("apple-speech"))).rejects.toMatchObject({ code: "transcript_model_changed" });
      expect(await sync.transcriptContent(owner, workspaceId, meetingId, "1")).toEqual(first);
    } finally { await store.close?.(); }
  });

  it("publishes full replacements atomically, including empty results and Server provenance", async () => {
    const { store, sync, workspaceId, meetingId, write, body } = await setup();
    try {
      await write(uuidV7(), 0, "completed", "replace", ["old"]);
      const serverMetadata = { provider: "google", request: { model: "test-gemini-model" }, runs: [{ generatedBy: "server", inputTypes: ["audio"],
        startedAt: null, completedAt: null, response: { id: "response-1", model: "resolved-test-model", usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 } } }] };
      const latestId = uuidV7();
      await write(latestId, 1, "completed", "replace", ["new"], serverMetadata);
      expect((await sync.transcriptContent(owner, workspaceId, meetingId, "latest"))).toMatchObject({ version: 2,
        transcript: { metadata: serverMetadata }, items: [{ text: "new" }] });
      const patchId = uuidV7();
      await expect(sync.commitTransaction(owner, body([
        { id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 2,
          data: { patchId, mode: "replace", transcript: { id: uuidV7(), endedAt: null, metadata: null }, segmentCount: 0, deletionCount: 0, chunks: [] } },
        { id: uuidV7(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 999, data: {} },
      ]))).rejects.toMatchObject({ status: 409 });
      expect((await sync.transcriptVersions(owner, workspaceId, meetingId)).items).toHaveLength(2);
      await write(uuidV7(), 2, "completed", "replace", []);
      expect(await sync.transcriptContent(owner, workspaceId, meetingId, "latest")).toMatchObject({ version: 3, present: true, items: [] });
      expect((await sync.transcriptContent(owner, workspaceId, meetingId, "1")).items).toMatchObject([{ text: "old" }]);
      expect((await sync.transcriptVersions(owner, workspaceId, meetingId, undefined, "2")).nextCursor).toBe("2");
      expect((await sync.transcriptVersions(owner, workspaceId, meetingId, "2")).items.map((row) => row.version)).toEqual([1]);
      expect(transcriptMetadataSchema.safeParse({ ...serverMetadata, prompt: "must not store" }).success).toBe(false);
    } finally { await store.close?.(); }
  });

  it.each(["node", "worker"])("pages bodies, reauthorizes history, and deletes all versions through %s", async (runtime) => {
    const { store, sync, config, databasePath, workspaceId, meetingId, write, body } = await setup();
    try {
      await write(uuidV7(), 0, "completed", "replace", Array.from({ length: 501 }, (_, index) => `text ${index}`));
      const app = createApp({ config, authStore: store });
      const worker = createWorkerHandler(async () => app);
      const fetch = worker.fetch!.bind(worker) as unknown as
        (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
      const send = (suffix: string, user = "reader") => {
        const request = new Request(`http://localhost:5173/api/v1/meetings/${meetingId}/transcripts${suffix}`, {
          headers: { "x-forwarded-user": testUserID(user), "x-forwarded-email": `${testUserID(user)}@example.com` },
        });
        return runtime === "node" ? app.request(request) : fetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
      };
      expect((await send("/1")).status).toBe(404);
      const grantDb = new DatabaseSync(databasePath);
      grantDb.prepare("INSERT INTO workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id, created_at) VALUES (?, 'user', ?, 'viewer', ?, ?)").run(workspaceId, member.userId, owner.userId, Date.now());
      grantDb.close();
      const page = z.object({ items: z.array(z.unknown()), nextCursor: z.string() }).parse(await (await send("/1")).json());
      expect(page.items).toHaveLength(500);
      expect(await (await send(`/1?cursor=${encodeURIComponent(page.nextCursor)}`)).json()).toMatchObject({ items: [expect.any(Object)] });
      expect(await (await send("/latest?manifest=1")).json()).toMatchObject({ count: 501, version: 1 });
      const revokeDb = new DatabaseSync(databasePath);
      revokeDb.prepare("DELETE FROM workspace_permissions WHERE workspace_id = ? AND principal_id = ?").run(workspaceId, member.userId);
      revokeDb.close();
      expect((await send("/1")).status).toBe(404);
      await sync.commitTransaction(owner, body([{ id: uuidV7(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }]));
      expect((await send("/latest", "owner")).status).toBe(404);
      const db = new DatabaseSync(databasePath);
      expect(db.prepare("SELECT count(*) AS count FROM transcripts").get()).toMatchObject({ count: 0 });
      expect(db.prepare("SELECT count(*) AS count FROM transcript_segments").get()).toMatchObject({ count: 0 });
      expect(db.prepare("pragma table_info(transcript_segments)").all().map((row) => row.name)).not.toContain("workspace_id");
      expect(db.prepare("pragma table_info(transcript_segments)").all().map((row) => row.name)).not.toContain("meeting_id");
      db.close();
    } finally { await store.close?.(); }
  });
});
