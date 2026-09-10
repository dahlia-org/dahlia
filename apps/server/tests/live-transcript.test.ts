import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { createWorkerHandler } from "../src/worker";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { Identity } from "../src/auth/identity";
import type { AppConfig } from "../src/config";
import { uuidV7 } from "../src/id";
import { MeetingSyncService } from "../src/sync/service";
import { livePage, visibleLiveState, type LiveState } from "../src/live/model";

import { seedHeaderIdentity, testUserID } from "./public-test-client";
import { encodeId } from "../src/typeid";
import { wireValue } from "../src/public-wire";

const directories: string[] = [];
afterEach(() => { for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true }); });
const owner: Identity = { userId: testUserID("owner"), workspaceId: `personal:${testUserID("owner")}`, source: "header" };
const reader: Identity = { userId: testUserID("reader"), workspaceId: `personal:${testUserID("reader")}`, source: "header" };
async function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-live-")); directories.push(directory);
  const databasePath = join(directory, "db.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
    databaseUrl: `file:${databasePath}`, baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 };
  const store = createNodeApplicationStore(config);
  await store.migrate(); await seedHeaderIdentity(store, databasePath, owner); await seedHeaderIdentity(store, databasePath, reader);
  const sync = new MeetingSyncService(store.sync);
  const vaultId = uuidV7(), meetingId = uuidV7(), sessionId = uuidV7(), now = new Date().toISOString();
  const transaction = (operations: unknown[]) => ({ schemaVersion: 2, id: uuidV7(), vaultId, createdAt: now, operations });
  await sync.commitTransaction(owner, transaction([
    { id: uuidV7(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null, data: { name: "Vault", createdAt: now } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { name: "Meeting", status: "READY", projectId: null, duration: null, recordingStartedAt: null, createdAt: now, updatedAt: now } },
  ]));
  const db = new DatabaseSync(databasePath);
  db.prepare("INSERT INTO meeting_events (id,vault_id,owner_user_id,meeting_id,kind,occurred_at,received_at,session_id) VALUES (?,?,?,?,?,?,?,?)")
    .run(uuidV7(), vaultId, owner.userId, meetingId, "recording_started", new Date(now).getTime(), Date.now(), sessionId);
  db.close();
  const state: LiveState = { vaultId, meetingId, sessionId, startedAt: now, updatedAt: now, status: "recording", sequence: 1,
    previews: [{ id: uuidV7(), startedAt: now, text: "partial", audioSource: "mic" }] };
  const patchId = uuidV7();
  const segments = [{ segmentId: uuidV7(), startedAt: now, endedAt: null, text: "confirmed", createdAt: now, audioSource: "mic", speakerLabel: null }];
  const chunk = { segments, deletions: [] };
  const sha256 = createHash("sha256").update(JSON.stringify(chunk)).digest("hex");
  await sync.putTranscriptChunk(owner, meetingId, patchId, 0, sha256, chunk);
  await sync.commitTransaction(owner, transaction([{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: 0,
    data: { patchId, mode: "replace", transcript: { id: uuidV7(), startedAt: now, endedAt: null,
      metadata: { provider: "apple", request: { model: "apple-speech-live" }, runs: [{ generatedBy: "desktop", inputTypes: ["audio"],
        startedAt: new Date(new Date(now).getTime() + 1000).toISOString(), recordingSessionId: sessionId.toUpperCase() }] } }, segmentCount: 1, deletionCount: 0,
      chunks: [{ index: 0, sha256, segmentCount: 1, deletionCount: 0 }] } }]));
  const share = (enabled: boolean) => {
    const db = new DatabaseSync(databasePath);
    if (enabled) db.prepare("INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id, created_at) VALUES (?, 'user', ?, 'member', ?, ?)").run(vaultId, reader.userId, owner.userId, Date.now());
    else db.prepare("DELETE FROM vault_permissions WHERE vault_id = ? AND principal_id = ?").run(vaultId, reader.userId);
    db.close();
  };
  return { store, sync, config, state, vaultId, meetingId, share, databasePath };
}

it("rejects stale preview writes, scopes read access and expires previews", async () => {
  const { store, sync, state, vaultId, meetingId, share } = await fixture();
  try {
    await sync.putLiveState(owner, meetingId, state);
    await sync.putLiveState(owner, meetingId, { ...state, previews: [], sequence: 0 });
    const page = await sync.getLiveTranscript(owner, vaultId, meetingId, {});
    expect(page.state.previews[0]?.text).toBe("partial");
    expect(page.confirmed.map((speech) => speech.text)).toEqual(["confirmed"]);
    const next = await sync.getLiveTranscript(owner, vaultId, meetingId, { cursor: page.cursor });
    expect(next.confirmed).toEqual([]);
    await expect(sync.listLiveMeetings(reader, vaultId)).rejects.toMatchObject({ status: 404 });
    await expect(sync.getLiveTranscript(reader, vaultId, meetingId, {})).rejects.toMatchObject({ status: 404 });
    await expect(sync.putLiveState(reader, meetingId, state)).rejects.toMatchObject({ status: 404 });
    share(true);
    expect((await sync.getLiveTranscript(reader, vaultId, meetingId, {})).state.sessionId).toBe(state.sessionId);
    const expired = visibleLiveState({ ...state, startedAt: new Date(state.startedAt), updatedAt: new Date(0) });
    expect(expired.status).toBe("disconnected"); expect(expired.previews).toEqual([]);
    const reset = await livePage(page.state, "replacement", [], page.cursor, 200);
    expect(reset.resetRequired).toBe(true);
    await expect(livePage({ ...page.state, vaultId: uuidV7() }, "replacement", [], page.cursor, 200)).rejects.toMatchObject({ status: 400 });
    await sync.putLiveState(owner, meetingId, { ...state, status: "stopped", previews: [], sequence: 2 });
    await sync.putLiveState(owner, meetingId, { ...state, sequence: 3 });
    expect((await sync.getLiveTranscript(owner, vaultId, meetingId, {})).state.status).toBe("stopped");
  } finally { await store.close?.(); }
});

describe.each(["node", "worker"])("live HTTP (%s)", (runtime) => {
  it("streams a page, resumes its cursor, and rejects access after revocation", async () => {
    const { store, sync, config, state, meetingId, share } = await fixture();
    try {
      await sync.putLiveState(owner, meetingId, state);
      share(true);
      const app = createApp({ config, authStore: store });
      const published = await app.request(`/api/v1/meetings/${encodeId("meeting", meetingId)}/live-transcript`, {
        method: "PUT", headers: { "content-type": "application/json", "x-forwarded-user": owner.userId, "x-forwarded-email": "owner@example.com" },
        body: JSON.stringify(wireValue({ ...state, sequence: 2 }, "liveState", "encode")),
      });
      expect(published.status).toBe(204);
      const listed = await app.request(`/api/v1/vaults/${encodeId("vault", state.vaultId)}/live-meetings`, {
        headers: { "x-forwarded-user": reader.userId, "x-forwarded-email": "reader@example.com" },
      });
      expect(listed.status).toBe(200);
      expect(await listed.json()).toMatchObject({ meetings: [{ vaultId: encodeId("vault", state.vaultId) }] });
      const worker = createWorkerHandler(async () => app);
      const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
      const send = (suffix: string, cursor?: string) => {
        const request = new Request(`http://localhost:5173/api/v1/meetings/${encodeId("meeting", meetingId)}/live-transcript${suffix}`, {
          headers: { "x-forwarded-user": reader.userId, "x-forwarded-email": "reader@example.com", ...(cursor ? { "last-event-id": cursor } : {}) },
        });
        return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
      };
      const response = await send("/events");
      expect(response.status).toBe(200); expect(response.headers.get("content-type")).toContain("text/event-stream");
      const stream = response.body!.getReader();
      const first = new TextDecoder().decode((await stream.read()).value);
      expect(first).toContain("event: transcript"); expect(first).toContain("confirmed");
      const page = JSON.parse(first.match(/data: (.+)/)![1]!) as Awaited<ReturnType<typeof livePage>>;
      expect(page.state.meetingId).toBe(encodeId("meeting", meetingId));
      expect(page.state.sessionId).toBe(encodeId("recording", state.sessionId));
      expect(page.confirmed[0]!.id).toMatch(/^seg_/);
      expect((JSON.parse(atob(page.cursor)) as { generation: string }).generation).toMatch(/^transcript_/);
      const cursor = first.match(/id: (.+)/)![1]!;
      await stream.cancel();
      const resumed = await send("/events", cursor); const resumedStream = resumed.body!.getReader();
      const second = new TextDecoder().decode((await resumedStream.read()).value);
      expect(second).toContain('"confirmed":[]');
      share(false);
      const end = new TextDecoder().decode((await resumedStream.read()).value);
      expect(end).toContain("event: error"); await resumedStream.cancel();
      expect((await send("")).status).toBe(404);
    } finally { await store.close?.(); }
  });
});

it("binds generations to synced sessions and ignores a delayed older session", async () => {
  const { store, sync, state, vaultId, meetingId, databasePath } = await fixture();
  try {
    await sync.putLiveState(owner, meetingId, state);
    const first = await sync.getLiveTranscript(owner, vaultId, meetingId, {});
    const sessionId = uuidV7();
    await expect(sync.putLiveState(owner, meetingId, { ...state, sessionId })).rejects.toMatchObject({ status: 409 });
    const startedAt = new Date(Date.now() + 1000);
    const db = new DatabaseSync(databasePath);
    db.prepare("INSERT INTO meeting_events (id,vault_id,owner_user_id,meeting_id,kind,occurred_at,received_at,session_id) VALUES (?,?,?,?,?,?,?,?)")
      .run(uuidV7(), vaultId, owner.userId, meetingId, "recording_started", startedAt.getTime(), Date.now(), sessionId);
    db.close();
    await sync.putLiveState(owner, meetingId, { ...state, sessionId, startedAt: startedAt.toISOString(), previews: [] });
    const restarted = await sync.getLiveTranscript(owner, vaultId, meetingId, { cursor: first.cursor });
    expect(restarted.resetRequired).toBe(true);
    expect(restarted.confirmedState).toBe("not_synced");
    await sync.putLiveState(owner, meetingId, { ...state, startedAt: "2100-01-01T00:00:00.000Z", sequence: 999 });
    expect((await sync.getLiveTranscript(owner, vaultId, meetingId, {})).state.sessionId).toBe(sessionId);
    await expect(sync.putLiveState(owner, meetingId, { ...state, sessionId, previews: [...state.previews, ...state.previews] }))
      .rejects.toMatchObject({ status: 400 });
  } finally { await store.close?.(); }
});

it("disconnects a stalled SSE subscriber without blocking new state writes", async () => {
  const { store, sync, config, state, vaultId, meetingId } = await fixture();
  try {
    await sync.putLiveState(owner, meetingId, state);
    const app = createApp({ config, authStore: store });
    const response = await app.request(`/api/v1/meetings/${encodeId("meeting", meetingId)}/live-transcript/events`, {
      headers: { "x-forwarded-user": owner.userId, "x-forwarded-email": "owner@example.com" },
    });
    expect(response.status).toBe(200);
    // Do not consume the stream: its bounded buffers fill and the write deadline aborts it.
    await new Promise((resolve) => setTimeout(resolve, 8000));
    await sync.putLiveState(owner, meetingId, { ...state, sequence: 2, previews: [] });
    expect((await sync.getLiveTranscript(owner, vaultId, meetingId, {})).state.sequence).toBe(2);
    const reader = response.body!.getReader();
    let chunks = 0;
    while (!(await reader.read()).done) { expect(++chunks).toBeLessThanOrEqual(2); }
  } finally { await store.close?.(); }
}, 15000);

it("replaces live speech with cloud audio-input generations for the same recording", async () => {
  const { store, sync, state, vaultId, meetingId, databasePath } = await fixture();
  try {
    await sync.putLiveState(owner, meetingId, state);
    const live = await sync.getLiveTranscript(owner, vaultId, meetingId, {});
    const startedAt = new Date(state.startedAt).getTime();
    const endedAt = new Date(startedAt + 10_000).toISOString();
    const db = new DatabaseSync(databasePath);
    db.prepare("INSERT INTO meeting_events (id,vault_id,owner_user_id,meeting_id,kind,occurred_at,received_at,session_id) VALUES (?,?,?,?,?,?,?,?)")
      .run(uuidV7(), vaultId, owner.userId, meetingId, "recording_ended", new Date(endedAt).getTime(), Date.now(), state.sessionId);
    db.close();
    const recording = await store.sync.withIdentity(owner, (scoped) => scoped.reserveRecording(vaultId, meetingId, state.sessionId, "mic"));
    await sync.putLiveState(owner, meetingId, { ...state, status: "stopped", previews: [], sequence: 2 });
    const replace = async (recordingNumber: number) => {
      const previous = await store.sync.withIdentity(owner, (scoped) => scoped.getTranscript(vaultId, meetingId));
      const patchId = uuidV7();
      const segments = [-1000, 1000, 11000].map((offset) => ({ segmentId: uuidV7(),
        startedAt: new Date(startedAt + offset).toISOString(), endedAt: null, text: `cloud ${offset}`,
        createdAt: endedAt, audioSource: "mic", speakerLabel: null }));
      const chunk = { segments, deletions: [] };
      const sha256 = createHash("sha256").update(JSON.stringify(chunk)).digest("hex");
      await sync.putTranscriptChunk(owner, meetingId, patchId, 0, sha256, chunk);
      await sync.commitTransaction(owner, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: endedAt,
        operations: [{ id: patchId, entity: "transcript", action: "patch", entityId: meetingId, baseRevision: previous!.syncRevision,
          data: { patchId, mode: "replace", transcript: { id: uuidV7(), startedAt: state.startedAt, endedAt,
            metadata: { provider: "gemini", request: { model: "gemini" }, runs: [{ generatedBy: "server", inputTypes: ["audio"],
              audioInputs: [{ recordingNumber, source: "mic", checksum: `SHA-256:${"a".repeat(64)}` }], startedAt: endedAt, completedAt: endedAt }] } },
            segmentCount: segments.length, deletionCount: 0, chunks: [{ index: 0, sha256, segmentCount: segments.length, deletionCount: 0 }] } }] });
    };
    await replace(recording.number);
    const cloud = await sync.getLiveTranscript(owner, vaultId, meetingId, { cursor: live.cursor });
    expect(cloud.resetRequired).toBe(true);
    expect(cloud.confirmedState).toBe("last_synced");
    expect(cloud.confirmed.map((segment) => segment.text)).toEqual(["cloud 1000"]);
    const resumed = await sync.getLiveTranscript(owner, vaultId, meetingId, { cursor: cloud.cursor });
    expect(resumed.resetRequired).toBe(false); expect(resumed.confirmed).toEqual([]);
    await replace(recording.number + 1);
    const unrelated = await sync.getLiveTranscript(owner, vaultId, meetingId, { cursor: cloud.cursor });
    expect(unrelated.confirmedState).toBe("not_synced"); expect(unrelated.confirmed).toEqual([]);
  } finally { await store.close?.(); }
});
