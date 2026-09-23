import { afterAll, describe, expect, it } from "vitest";
import { Memory } from "@mastra/memory";
import { createMockModel } from "@mastra/core/test-utils/llm-mock";
import { createPostgresAuthStore } from "../src/auth/store";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";
import { createAiHistoryService, withIdentityTransaction } from "../src/agent/history";
import { ChatMemoryStore } from "../src/agent/context-store";
import { workingMemoryTemplate } from "../src/agent/context-store";
import { connectPostgresUrl } from "../src/db/postgres";
import { uuidV7 } from "../src/id";

const url = process.env.TEST_DATABASE_URL;
const connection = url ? connectPostgresUrl(url, 1) : undefined;
afterAll(async () => connection?.close());

describe.runIf(url)("Chat memory PostgreSQL", () => {
  it("keeps distinct learned lines from queued jobs and ignores exact duplicates", async () => {
    const store = new ChatMemoryStore(connection!.pool), history = createAiHistoryService(connection!.pool);
    const owner = { userId: uuidV7(), source: "header" as const };
    const thread = await history.create(owner, uuidV7(), "Queued learning");
    const messages = [uuidV7(), uuidV7()];
    await history.memory(owner).saveMessages({ messages: messages.map((id) => ({ id, threadId: thread.id, resourceId: owner.userId,
      role: "user" as const, createdAt: new Date(), content: { format: 2 as const, parts: [{ type: "text" as const, text: "Remember this" }] } })) });
    for (const id of messages) await store.enqueueLearned(owner, thread.id, id, 0);
    const first = (await store.claim(owner, `working:${messages[0]}`))!;
    const second = (await store.claim(owner, `working:${messages[1]}`))!;
    await store.applyLearned(owner, first, "Prefers concise replies");
    await store.applyLearned(owner, second, "Prefers concise");
    await store.applyLearned(owner, second, "Prefers concise");
    expect((await store.settings(owner)).learned).toBe("- Prefers concise replies\n- Prefers concise");
    await history.delete(owner, thread.id);
  });
  it("keeps manual and learned Markdown across chat deletion and isolates the owner", async () => {
    const store = new ChatMemoryStore(connection!.pool), history = createAiHistoryService(connection!.pool);
    const owner = { userId: uuidV7(), source: "header" as const }, other = { userId: uuidV7(), source: "header" as const };
    const thread = await history.create(owner, uuidV7(), "Working memory");
    const messageId = uuidV7();
    await history.memory(owner).saveMessages({ messages: [{ id: messageId, threadId: thread.id, resourceId: owner.userId,
      role: "user", createdAt: new Date(), content: { format: 2, parts: [{ type: "text", text: "今後は日本語で回答して" }] } }] });
    expect(await store.settings(owner)).toEqual({ revision: 0, automatic: true, capacityReached: false, manual: "", learned: "" });
    await expect(store.editSettings({ ...owner, impersonated: true }, { section: "manual", content: "blocked", revision: 0, explicit: true }))
      .rejects.toMatchObject({ code: "impersonation_read_only" });
    const manual = await store.editSettings(owner, { section: "manual", content: "## Profile\nI use Dahlia", revision: 0, explicit: true });
    await expect(store.editSettings(owner, { section: "manual", content: "stale", revision: 0, explicit: true }))
      .rejects.toMatchObject({ code: "memory_revision_conflict" });
    const learned = await store.editSettings(owner, { section: "learned", content: "- Existing note", revision: 0, explicit: true });
    expect(learned.revision).toBe(manual.revision + 1);
    await expect(store.editSettings(owner, { section: "learned", content: "injected", revision: learned.revision, explicit: false }))
      .rejects.toMatchObject({ code: "memory_explicit_instruction_required" });
    await store.enqueueLearned(owner, thread.id, messageId, learned.revision);
    const job = (await store.claim(owner, `working:${messageId}`))!;
    await store.applyLearned(owner, job, "日本語で回答してほしい");
    expect((await store.settings(owner)).learned).toContain("日本語");
    await expect(store.editSettings(owner, { section: "learned", content: "stale", revision: learned.revision, explicit: true }))
      .rejects.toMatchObject({ code: "memory_revision_conflict" });
    await store.editSettings(owner, { section: "manual", content: "## Profile\nI use Dahlia, updated", revision: learned.revision, explicit: true });
    expect((await store.settings(other)).manual).toBe("");
    const beforeEdit = await store.settings(owner);
    await store.editSettings(owner, { section: "learned", content: beforeEdit.learned, revision: beforeEdit.revision, explicit: true });
    await store.applyLearned(owner, job, "Stale queued note");
    expect((await store.settings(owner)).learned).not.toContain("Stale queued note");
    await history.delete(owner, thread.id);
    expect((await store.settings(owner)).manual).toContain("Dahlia");
    expect((await store.settings(owner)).learned).toContain("日本語");
    expect(await store.claim(owner, job.id)).toBeUndefined();
    await store.applyLearned(owner, job, "Deleted message");
    expect((await store.settings(owner)).learned).not.toContain("Deleted message");
  });
  it("pauses learning visibly at capacity without replacing saved notes", async () => {
    const store = new ChatMemoryStore(connection!.pool), history = createAiHistoryService(connection!.pool);
    const owner = { userId: uuidV7(), source: "header" as const };
    const thread = await history.create(owner, uuidV7(), "Capacity");
    const messageId = uuidV7();
    await history.memory(owner).saveMessages({ messages: [{ id: messageId, threadId: thread.id, resourceId: owner.userId,
      role: "user", createdAt: new Date(), content: { format: 2, parts: [{ type: "text", text: "Remember my preference" }] } }] });
    const full = await store.editSettings(owner, { section: "learned", content: "x".repeat(5999), revision: 0, explicit: true });
    await store.enqueueLearned(owner, thread.id, messageId, full.revision);
    const job = (await store.claim(owner, `working:${messageId}`))!;
    await store.applyLearned(owner, job, "New preference");
    const paused = await store.settings(owner);
    expect(paused).toMatchObject({ automatic: false, capacityReached: true, learned: full.learned, revision: full.revision + 1 });
    const shorter = await store.editSettings(owner, { section: "learned", content: "Shortened notes", revision: paused.revision, explicit: true });
    expect(shorter).toMatchObject({ automatic: false, capacityReached: false });
    const resumed = await store.editSettings(owner, { section: "settings", automatic: true, revision: shorter.revision, explicit: true });
    await store.applyLearned(owner, { ...job, revision: resumed.revision }, "New preference");
    expect((await store.settings(owner)).learned).toBe("Shortened notes\n- New preference");
    await history.delete(owner, thread.id);
  });
  it("shares only meeting context with current readers and hides it on revocation or meeting deletion", async () => {
    const { db, pool } = connection!;
    const app = createPostgresAuthStore(db, "postgres"), memory = new ChatMemoryStore(pool);
    const owner = { userId: uuidV7(), source: "header" as const }, viewer = { userId: uuidV7(), source: "header" as const };
    await seedPostgresIdentity(app, url!, owner); await seedPostgresIdentity(app, url!, viewer);
    const workspaceId = uuidV7(), meetingId = uuidV7(), now = new Date();
    await app.sync.withIdentity(owner, (sync) => sync.commitTransaction({ schemaVersion: 3, workspaceId,
      id: uuidV7(), createdAt: now, requestHash: uuidV7(), operations: [
        { id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
          data: { organizationId: testOrganizationID, name: "Live context", createdAt: now } },
        { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
          data: { name: "Meeting", description: "", status: "READY", projectId: null, createdAt: now, updatedAt: now } },
      ] }));
    const lease = await memory.claimMeeting(owner, meetingId);
    expect(lease).toBeTruthy();
    const snapshot = { after: "checkpoint", truncated: false, notes: { topics: [], decisions: [], questions: [] }, recent: [], processedThrough: null, updatedAt: now.toISOString() };
    await memory.saveSnapshot(owner, meetingId, lease!, snapshot);
    expect(await memory.snapshot(viewer, meetingId)).toBeNull();
    await withIdentityTransaction(pool, owner, (client) => client.query("UPDATE agent.live_contexts SET snapshot = snapshot - 'truncated' WHERE meeting_id = $1", [meetingId]));
    expect(await memory.snapshot(owner, meetingId)).toBeNull();
    await memory.saveSnapshot(owner, meetingId, lease!, snapshot);
    await app.sync.withIdentity(owner, (sync) => sync.putPermission(workspaceId, "user", viewer.userId, "viewer"));
    expect(await memory.snapshot(viewer, meetingId)).toEqual(snapshot);
    await app.sync.withIdentity(owner, (sync) => sync.deletePermission(workspaceId, "user", viewer.userId));
    expect(await memory.snapshot(viewer, meetingId)).toBeNull();
    await expect(memory.claimMeeting(viewer, meetingId)).rejects.toThrow();
    await app.sync.withIdentity(owner, (sync) => sync.commitTransaction({ schemaVersion: 3, workspaceId,
      id: uuidV7(), createdAt: now, requestHash: uuidV7(), operations: [
        { id: uuidV7(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} },
      ] }));
    expect(await memory.snapshot(owner, meetingId)).toBeNull();
    expect((await pool.query("SELECT * FROM agent.live_contexts WHERE meeting_id = $1", [meetingId])).rows).toEqual([]);
  });
  it("shares the Markdown Working Memory with Mastra while retaining private observational memory", async () => {
    const { pool } = connection!;
    const store = new ChatMemoryStore(pool), history = createAiHistoryService(pool);
    const owner = { userId: uuidV7(), source: "header" as const }, other = { userId: uuidV7(), source: "header" as const };
    const thread = await history.create(owner, uuidV7(), "Private memory");
    await store.editSettings(owner, { section: "manual", content: "I prefer short answers", revision: 0, explicit: true });
    const memory = history.memory(owner);
    const configured = new Memory({ storage: memory.storage, vector: false, options: {
      semanticRecall: false, workingMemory: { enabled: true, scope: "resource", template: workingMemoryTemplate, agentManaged: false },
      observationalMemory: { scope: "thread", model: createMockModel({ version: "v2", mockText: "<observations>\nUser prefers Japanese replies.\n</observations>" }), retrieval: { scope: "thread" }, observation: { messageTokens: 1, bufferTokens: false } },
    } });
    expect(await configured.getWorkingMemory({ threadId: thread.id, resourceId: owner.userId })).toContain("short answers");
    const memoryDomain = (await memory.storage.getStore("memory"))!;
    const record = await memoryDomain.initializeObservationalMemory({ threadId: thread.id, resourceId: owner.userId, scope: "thread", config: {} });
    expect(record.id).toBeTruthy();
    const otherDomain = (await history.memory(other).storage.getStore("memory"))!;
    expect(await otherDomain.getObservationalMemory(thread.id, owner.userId)).toBeNull();
    await history.delete(owner, thread.id);
    expect(await memoryDomain.getObservationalMemory(thread.id, owner.userId)).toBeNull();
    expect((await store.settings(owner)).manual).toContain("short answers");
  });
});
