import { captureSyncTimings } from "../src/sync/diagnostics";
import { expect, it } from "vitest";
import { Client } from "pg";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { MeetingSyncService } from "../src/sync/service";
import { DocumentCore } from "../src/documents/core";
import { uuidV7 } from "../src/id";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";

it.runIf(process.env.TEST_SYNC_LOCKS_DATABASE_URL)("Notes bypass the domain lane but wait for authorization and parent deletion", async () => {
  const url = process.env.TEST_SYNC_LOCKS_DATABASE_URL!;
  const tagged = new URL(url); const application = `sync-lock-test-${uuidV7()}`;
  tagged.searchParams.set("application_name", application);
  const store = createNodeApplicationStore({ authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "postgres",
    databaseUrl: tagged.toString(), baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 });
  const blocker = new Client({ connectionString: url });
  const owner = { userId: uuidV7(), source: "header" as const }, editor = { userId: uuidV7(), source: "header" as const };
  const workspaceId = uuidV7(), meetingId = uuidV7(), id = uuidV7();
  const parallelMeeting = uuidV7();
  const otherWorkspace = uuidV7(), otherMeeting = uuidV7(), otherDocument = uuidV7();
  const core = new DocumentCore(); core.insertText("concurrent", uuidV7);
  async function waitingForLock() {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      const result = await blocker.query("SELECT 1 FROM pg_stat_activity WHERE application_name = $1 AND cardinality(pg_blocking_pids(pid)) > 0", [application]);
      if (result.rowCount) return;
    }
    throw new Error("document_did_not_wait_for_lifecycle_lock");
  }
  async function bounded<T>(value: Promise<T>): Promise<T> {
    let timer: ReturnType<typeof setTimeout>;
    try { return await Promise.race([value, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("document_blocked_by_domain")), 3000); })]); }
    finally { clearTimeout(timer!); }
  }
  try {
    await blocker.connect();
    await seedPostgresIdentity(store, url, owner); await seedPostgresIdentity(store, url, editor);
    const sync = new MeetingSyncService(store.sync);
    await sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
        data: { organizationId: testOrganizationID, name: "Lock fixture", encryption: "none", createdAt: new Date().toISOString() } },
      { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
        data: { name: "Meeting", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null,
          createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
    ] });
    await sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: otherWorkspace, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "workspace", action: "create", entityId: otherWorkspace, baseRevision: null,
        data: { organizationId: testOrganizationID, name: "Lock fixture", encryption: "none", createdAt: new Date().toISOString() } },
      { id: uuidV7(), entity: "meeting", action: "create", entityId: otherMeeting, baseRevision: null,
        data: { name: "Meeting", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null,
          createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } },
    ] });
    const meetingData = { name: "Parallel", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null,
      createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    const mutation = (target: string, name: string) => ({ id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: new Date().toISOString(), operations: [
      { id: uuidV7(), entity: "meeting", action: "update", entityId: target, baseRevision: 1, data: { name, projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null, updatedAt: new Date().toISOString() } },
    ] });
    await sync.commitTransaction(owner, { ...mutation(parallelMeeting, "Parallel"), operations: [
      { id: uuidV7(), entity: "meeting", action: "create", entityId: parallelMeeting, baseRevision: null, data: meetingData },
    ] });
    let announce!: () => void, release!: () => void;
    const ready = new Promise<void>((resolve) => { announce = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const input = mutation(meetingId, "Slow");
    const firstRequest = { ...input, createdAt: new Date(), requestHash: uuidV7(), operations: input.operations.map((op) => ({ ...op, data: { ...op.data, updatedAt: new Date() } })) };
    const first = store.sync.withIdentity(owner, async (s) => {
      await s.resolveTransaction(firstRequest as Parameters<typeof s.resolveTransaction>[0]);
      announce(); await gate;
      return s.commitTransaction(firstRequest as Parameters<typeof s.commitTransaction>[0]);
    });
    try {
      await bounded(ready);
      const second = await bounded(sync.commitTransaction(owner, mutation(parallelMeeting, "Fast")));
      // A read can observe the last committed version while another meeting is still processing.
      await bounded(store.sync.withIdentity(owner, async (s) => { await s.lockWorkspace(workspaceId); return s.latestChangeSequence(workspaceId); }));
      const conflict = sync.commitTransaction(owner, mutation(meetingId, "Must conflict"))
        .then(() => "unexpected", (error: Error) => error.message);
      await waitingForLock();
      release();
      const slow = await first;
      expect(slow.cursor).not.toBe(second.cursor);
      expect(await conflict).toBe("revision_conflict");
      const changes = await sync.listChanges(owner, workspaceId, second.cursor);
      expect(changes.items.some((change) => change.entityId === meetingId)).toBe(true);
      expect(changes.items.some((change) => change.entityId === parallelMeeting)).toBe(false);
    } finally { release(); await first.catch(() => undefined); }
    const pair = [mutation(meetingId, "Pair A").operations[0]!, mutation(parallelMeeting, "Pair B").operations[0]!]
      .map((operation) => ({ ...operation, baseRevision: 2 }));
    const ordered = await bounded(Promise.allSettled([pair, [...pair].reverse()].map((operations) => sync.commitTransaction(owner,
      { ...mutation(meetingId, "Pair"), operations }))));
    expect(ordered.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = ordered.find((result) => result.status === "rejected");
    expect(rejected).toMatchObject({ status: "rejected", reason: { message: "revision_conflict" } });
    await store.sync.withIdentity(owner, (s) => s.initializeMeetingNotes(otherWorkspace, otherMeeting, otherDocument));
    const document = await store.sync.withIdentity(owner, (s) => s.initializeMeetingNotes(workspaceId, meetingId, id));
    await store.sync.withIdentity(owner, (s) => s.putPermission(workspaceId, "user", editor.userId, "editor"));
    // Holding either per-request cleanup transaction must not block the independent document lane.
    for (const kind of ["file", "recording"] as const) {
      let entered!: () => void, finish!: () => void;
      const cleaning = new Promise<void>((resolve) => { entered = resolve; });
      const hold = new Promise<void>((resolve) => { finish = resolve; });
      const expiry = store.sync.withIdentity(owner, async (s) => {
        const before = new Date(Date.now() - 86_400_000);
        if (kind === "file") await s.expireFileUploads(workspaceId, before);
        else await s.expireRecordingUploads(workspaceId, before);
        entered(); await hold;
      });
      try {
        await bounded(cleaning);
        await bounded(store.sync.withIdentity(editor, (s) => s.exchangeDocument(workspaceId, id,
          { generation: document.generation, vector: core.vector(), update: core.checkpoint() })));
      } finally { finish(); await expiry; }
    }
    await blocker.query("BEGIN");
    await blocker.query("SELECT pg_advisory_xact_lock_shared(75047176522050)");
    await blocker.query("SELECT pg_advisory_xact_lock_shared(hashtextextended($1,0)), pg_advisory_xact_lock(hashtextextended($2,0))", [`workspace:${workspaceId}`, `domain:${workspaceId}`]);
    const exchanged = await bounded(store.sync.withIdentity(editor, (s) => s.exchangeDocument(workspaceId, id,
      { generation: document.generation, vector: core.vector(), update: core.checkpoint() })));
    expect(exchanged.revision).toBe(1);
    async function measureExchanges(label: "domain_busy" | "idle") {
      const timings = captureSyncTimings();
      let result: ReturnType<typeof timings.stop>;
      try {
        for (let index = 0; index < 30; index++) {
          await bounded(store.sync.withIdentity(editor, (s) => s.exchangeDocument(workspaceId, id,
            { generation: document.generation, vector: core.vector(), update: core.checkpoint() })));
        }
      } finally {
        result = timings.stop();
      }
      expect(result.connectionAndBegin?.count).toBe(30);
      expect(result.documentLock?.count).toBe(30);
      console.info(`sync_lock_fixture_${label}_ms`, JSON.stringify(result));
    }
    await measureExchanges("domain_busy");
    expect((await bounded(store.sync.withIdentity(owner, (s) => s.getDocument(otherWorkspace, otherDocument))))?.id).toBe(otherDocument);
    await blocker.query("ROLLBACK");
    await measureExchanges("idle");
    // Observe the actual advisory-lock waiter, then revoke access before releasing it.
    await blocker.query("BEGIN");
    await blocker.query("SELECT pg_advisory_xact_lock(75047176522050), set_config('app.user_id', $1, true)", [owner.userId]);
    const denied = store.sync.withIdentity(editor, (s) => s.getDocument(workspaceId, id)).then(() => "unexpected", (error: Error) => error.message);
    await waitingForLock();
    await blocker.query("DELETE FROM app.workspace_permissions WHERE workspace_id = $1 AND principal_id = $2", [workspaceId, editor.userId]);
    await blocker.query("COMMIT");
    expect(await denied).toBe("document_unavailable");
    await blocker.query("BEGIN");
    await blocker.query("SELECT pg_advisory_xact_lock_shared(75047176522050), set_config('app.user_id', $1, true)", [owner.userId]);
    await blocker.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [`1:meeting:${meetingId}`]);
    const deleted = store.sync.withIdentity(owner, (s) => s.exchangeDocument(workspaceId, id,
      { generation: document.generation, vector: core.vector(), update: core.checkpoint() })).then(() => "unexpected", (error: Error) => error.message);
    await waitingForLock();
    await blocker.query("UPDATE app.meetings SET deleted_at = now() WHERE meeting_id = $1", [meetingId]);
    await blocker.query("COMMIT");
    expect(await deleted).toBe("document_unavailable");
    const audience = await store.sync.withIdentity(owner, (s) => s.workspaceTransferAudience(otherWorkspace, workspaceId));
    const destination = await store.sync.withIdentity(owner, (s) => s.getWorkspace(workspaceId));
    await blocker.query("BEGIN");
    await blocker.query("SELECT pg_advisory_xact_lock_shared(75047176522050)");
    await blocker.query("SELECT pg_advisory_xact_lock_shared(hashtextextended($1,0)), pg_advisory_xact_lock(hashtextextended($2,0))", [`workspace:${otherWorkspace}`, `document:${otherDocument}`]);
    const transfer = store.sync.withIdentity(owner, (s) => s.transferWorkspace({ sourceWorkspaceId: otherWorkspace, destinationWorkspaceId: workspaceId,
      sourceRevision: 1, destinationRevision: destination!.revision!, audienceHash: audience.audienceHash,
      idempotencyKey: uuidV7(), requestHash: "document-transfer-lock" }));
    await waitingForLock();
    await blocker.query("COMMIT");
    await transfer;
    await expect(store.sync.withIdentity(owner, (s) => s.getDocument(otherWorkspace, otherDocument))).rejects.toThrow("document_unavailable");
    expect((await store.sync.withIdentity(owner, (s) => s.getDocument(workspaceId, otherDocument)))?.meetingId).toBe(otherMeeting);
  } finally {
    await blocker.query("ROLLBACK"); await blocker.end(); await store.close?.(); core.destroy();
  }
}, 20_000);
