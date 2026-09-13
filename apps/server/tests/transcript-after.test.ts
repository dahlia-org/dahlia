import { testOrganizationID } from "./public-test-client";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { Identity } from "../src/auth/identity";
import type { AppConfig } from "../src/config";
import { uuidV7 } from "../src/id";
import { MeetingSyncService } from "../src/sync/service";

import { seedHeaderIdentity, testUserID } from "./public-test-client";
import { encodeId } from "../src/typeid";

const directories: string[] = [];
afterEach(() => { for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true }); });
const owner: Identity = { userId: testUserID("owner"),  source: "header" };
const reader: Identity = { userId: testUserID("reader"),  source: "header" };
async function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-live-")); directories.push(directory);
  const databasePath = join(directory, "db.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
    databaseUrl: `file:${databasePath}`, baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 };
  const store = createNodeApplicationStore(config);
  await store.migrate(); await seedHeaderIdentity(store, databasePath, owner); await seedHeaderIdentity(store, databasePath, reader);
  const sync = new MeetingSyncService(store.sync);
  const workspaceId = uuidV7(), meetingId = uuidV7(), sessionId = uuidV7(), now = new Date().toISOString();
  const transaction = (operations: unknown[]) => ({ schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: now, operations });
  await sync.commitTransaction(owner, transaction([
    { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Workspace", createdAt: now } },
    { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
      data: { name: "Meeting", status: "READY", projectId: null, duration: null, recordingStartedAt: null, createdAt: now, updatedAt: now } },
  ]));
  const db = new DatabaseSync(databasePath);
  db.prepare("INSERT INTO meeting_events (id,workspace_id,owner_user_id,meeting_id,kind,occurred_at,received_at,session_id) VALUES (?,?,?,?,?,?,?,?)")
    .run(uuidV7(), workspaceId, owner.userId, meetingId, "recording_started", new Date(now).getTime(), Date.now(), sessionId);
  db.close();
  const event = (kind: "recording_started" | "recording_ended", at: Date, id = sessionId) => {
    const db = new DatabaseSync(databasePath);
    db.prepare("INSERT INTO meeting_events (id,workspace_id,owner_user_id,meeting_id,kind,occurred_at,received_at,session_id) VALUES (?,?,?,?,?,?,?,?)")
      .run(uuidV7(), workspaceId, owner.userId, meetingId, kind, at.getTime(), Date.now(), id);
    db.close();
  };
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
    if (enabled) db.prepare("INSERT INTO workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id, created_at) VALUES (?, 'user', ?, 'viewer', ?, ?)").run(workspaceId, reader.userId, owner.userId, Date.now());
    else db.prepare("DELETE FROM workspace_permissions WHERE workspace_id = ? AND principal_id = ?").run(workspaceId, reader.userId);
    db.close();
  };
  return { store, sync, config, workspaceId, meetingId, share, databasePath, event };
}


it("returns checkpoints for pagination, empty reads and later appends", async () => {
  const { store, sync, workspaceId, meetingId, databasePath } = await fixture();
  try {
    const first = await sync.listTranscript(owner, workspaceId, meetingId, undefined, {});
    expect(first.items.map((item) => item.text)).toEqual(["confirmed"]);
    expect(first).toHaveProperty("next_after");
    expect(first).not.toHaveProperty("previews");
    const next = await sync.listTranscript(owner, workspaceId, meetingId, undefined, { after: first.next_after });
    expect(next.items).toEqual([]);
    expect(next.next_after).toBe(first.next_after);
    const db = new DatabaseSync(databasePath);
    const original = db.prepare("SELECT * FROM transcript_segments LIMIT 1").get()!;
    db.prepare("INSERT INTO transcript_segments (transcript_id, segment_id, started_at, ended_at, text, created_at, audio_source, speaker_label) SELECT transcript_id, ?, ?, NULL, 'added', ?, audio_source, speaker_label FROM transcript_segments LIMIT 1")
      .run(uuidV7(), Number(original.started_at) + 1000, Number(original.created_at) + 1000);
    db.close();
    const added = await sync.listTranscript(owner, workspaceId, meetingId, undefined, { after: next.next_after });
    expect(added.items.map((item) => item.text)).toEqual(["added"]);
    await expect(sync.listTranscript(owner, workspaceId, meetingId, "anything", { after: next.next_after })).rejects.toThrow("after_and_cursor");
    await expect(sync.listTranscript(owner, workspaceId, uuidV7(), undefined, { after: next.next_after })).rejects.toThrow("meeting_not_found");
  } finally { await store.close?.(); }
});

it("detects late inserts, edits, deletions and generation changes", async () => {
  const { transcriptCheckpoint } = await import("../src/sync/transcript-checkpoint");
  const workspace = uuidV7(), meeting = uuidV7();
  const first = await transcriptCheckpoint(workspace, meeting, "generation", ["one", "two"], undefined, 0, 1);
  expect(first.items).toEqual(["one"]);
  expect(first.hasMore).toBe(true);
  const second = await transcriptCheckpoint(workspace, meeting, "generation", ["one", "two"], first.next_after, 0, 1);
  expect(second.items).toEqual(["two"]);
  for (const records of [["late", "one", "two"], ["edited", "two"], ["one"]]) {
    await expect(transcriptCheckpoint(workspace, meeting, "generation", records, second.next_after, 0, 1)).rejects.toThrow("refetch_without_after");
  }
  await expect(transcriptCheckpoint(workspace, meeting, "new", ["one", "two"], second.next_after, 0, 1)).rejects.toThrow("refetch_without_after");
  await expect(transcriptCheckpoint(uuidV7(), meeting, "generation", [], first.next_after, 0, 1)).rejects.toThrow("invalid_transcript_after");
  const empty = await transcriptCheckpoint(workspace, meeting, "none", [], undefined, 0, 1);
  expect((await transcriptCheckpoint(workspace, meeting, "new", ["first"], empty.next_after, 0, 1)).items).toEqual(["first"]);
});

it("waits only when empty and finishes at the deadline", async () => {
  const { store, sync, workspaceId, meetingId } = await fixture();
  try {
    const first = await sync.listTranscript(owner, workspaceId, meetingId, undefined, { wait: true });
    expect(first.items).toHaveLength(1);
    vi.useFakeTimers();
    const pending = sync.listTranscript(owner, workspaceId, meetingId, undefined, { after: first.next_after, wait: true });
    await vi.advanceTimersByTimeAsync(25_000);
    const page = await pending;
    expect(page.items).toEqual([]);
    expect(page.next_after).toBe(first.next_after);
  } finally { vi.useRealTimers(); await store.close?.(); }
});

it("rereads outside locks and returns new speech during a wait", async () => {
  const { store, sync, workspaceId, meetingId, databasePath } = await fixture();
  try {
    const first = await sync.listTranscript(owner, workspaceId, meetingId, undefined, {});
    let checks = 0;
    const pending = sync.listTranscript(owner, workspaceId, meetingId, undefined, { after: first.next_after, wait: true, authorize: () => {
      if (++checks !== 2) return;
      const db = new DatabaseSync(databasePath);
      db.prepare("INSERT INTO transcript_segments (transcript_id, segment_id, started_at, ended_at, text, created_at, audio_source, speaker_label) SELECT transcript_id, ?, started_at + 1000, NULL, 'arrived', created_at + 1000, audio_source, speaker_label FROM transcript_segments LIMIT 1").run(uuidV7());
      db.close();
    } });
    expect((await pending).items.map((item) => item.text)).toEqual(["arrived"]);
    expect(checks).toBe(2);
  } finally { await store.close?.(); }
});

it("stops waiting on disconnection and permission revocation", async () => {
  const { store, sync, workspaceId, meetingId, share } = await fixture();
  try {
    share(true);
    const first = await sync.listTranscript(reader, workspaceId, meetingId, undefined, {});
    let checks = 0;
    await expect(sync.listTranscript(reader, workspaceId, meetingId, undefined, { after: first.next_after, wait: true,
      authorize: () => { if (++checks === 2) share(false); },
    })).rejects.toThrow("meeting_not_found");
    const controller = new AbortController();
    checks = 0;
    await expect(sync.listTranscript(owner, workspaceId, meetingId, undefined, { after: first.next_after, wait: true, signal: controller.signal,
      authorize: () => { if (++checks === 2) controller.abort(new Error("disconnected")); },
    })).rejects.toThrow("disconnected");
    await expect(sync.listTranscript(owner, workspaceId, meetingId, undefined, { after: first.next_after, wait: true,
      authorize: () => { throw new Error("token revoked"); },
    })).rejects.toThrow("token revoked");
  } finally { await store.close?.(); }
});

it("removes the live HTTP routes", async () => {
  const { store, config, workspaceId, meetingId } = await fixture();
  try {
    const app = createApp({ config, authStore: store });
    for (const path of [`/api/v1/workspaces/${encodeId("workspace", workspaceId)}/live-meetings`,
      `/api/v1/meetings/${encodeId("meeting", meetingId)}/live-transcript`,
      `/api/v1/meetings/${encodeId("meeting", meetingId)}/live-transcript/events`]) {
      expect((await app.request(path, { headers: { "X-Forwarded-Email": "owner@example.com" } })).status).toBe(404);
    }
  } finally { await store.close?.(); }
});

it("exposes after/wait through MCP and cancels a disconnected request", async () => {
  const { createServerMcpHandler } = await import("../src/mcp");
  const { store, sync, config, workspaceId, meetingId } = await fixture();
  try {
    let checks = 0;
    const controller = new AbortController();
    const handler = createServerMcpHandler(config, sync, async () => {
      if (++checks === 3) controller.abort(new Error("disconnected"));
    });
    const call = (args: Record<string, unknown>, signal?: AbortSignal) => {
      const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: {
        name: "get_meeting_transcript", arguments: { workspace_id: encodeId("workspace", workspaceId), meeting_id: encodeId("meeting", meetingId), ...args },
        _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "test", version: "1" },
          "io.modelcontextprotocol/protocolVersion": "2026-07-28" },
      } });
      return handler.fetch(new Request("http://localhost:5173/mcp", { method: "POST", body, signal,
        headers: { "content-type": "application/json", "content-length": String(new TextEncoder().encode(body).length),
          "mcp-method": "tools/call", "mcp-name": "get_meeting_transcript", "mcp-protocol-version": "2026-07-28" },
      }), { authInfo: { token: "", clientId: "test", scopes: ["mcp"], extra: { identity: owner } } });
    };
    const response = await call({ wait: true });
    expect(response.status).toBe(200);
    const first: { result: { isError?: boolean; content: { text: string }[] } } = await response.json();
    expect(first.result.isError).not.toBe(true);
    const content = JSON.parse(first.result.content[0]!.text) as { next_after: string; items: { text: string }[] };
    const after = content.next_after;
    expect(typeof after).toBe("string");
    expect(content.items[0]!.text).toBe("confirmed");
    const disconnected = await call({ after, wait: true }, controller.signal);
    expect(controller.signal.aborted).toBe(true);
    expect(checks).toBe(3);
    if (disconnected.body) await disconnected.body.cancel();
  } finally { await store.close?.(); }
});
