import { afterAll, describe, expect, it } from "vitest";
import { Memory } from "@mastra/memory";
import { createMockModel } from "@mastra/core/test-utils/llm-mock";
import { createPostgresAuthStore } from "../src/auth/store";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";
import { createAiHistoryService, withIdentityTransaction } from "../src/agent/history";
import { ChatMemoryStore } from "../src/agent/context-store";
import { emptyPreferences, preferencesSchema } from "../src/agent/context-model";
import { connectPostgresUrl } from "../src/db/postgres";
import { uuidV7 } from "../src/id";

const url = process.env.TEST_DATABASE_URL;
const connection = url ? connectPostgresUrl(url, 1) : undefined;
afterAll(async () => connection?.close());

describe.runIf(url)("Chat memory PostgreSQL", () => {
  it("merges queued preferences in source order, preserving manual invalidation and lease ownership", async () => {
    const store = new ChatMemoryStore(connection!.pool), history = createAiHistoryService(connection!.pool);
    const owner = { userId: uuidV7(), source: "header" as const };
    const thread = await history.create(owner, uuidV7(), "Queued preferences");
    try {
      const ids = [uuidV7(), uuidV7(), uuidV7(), uuidV7()];
      const now = Date.now();
      await history.memory(owner).saveMessages({ messages: ids.map((id, index) => ({
        id, threadId: thread.id, resourceId: owner.userId, role: "user", createdAt: new Date(now + index),
        content: { format: 2, parts: [{ type: "text", text: "Persistent preference" }] },
      })) });
      const jobs = [];
      for (const id of ids) {
        await store.enqueuePreferences(owner, thread.id, id, 0);
        jobs.push((await store.claim(owner, `preference:${id}`))!);
      }
      await store.applyPreferences(owner, jobs[0]!, { language: "ja" });
      await store.applyPreferences(owner, jobs[1]!, { detail: "detailed" });
      expect((await store.settings(owner)).preferences).toMatchObject({ language: "ja", detail: "detailed" });
      await store.applyPreferences(owner, jobs[2]!, { language: "en" });
      const latest = await store.settings(owner);
      await store.applyPreferences(owner, jobs[0]!, { language: "ja" });
      await store.applyPreferences(owner, jobs[2]!, { language: "ja" });
      expect(await store.settings(owner)).toEqual(latest);
      const manual = await store.editSettings(owner, { ...latest, automatic: false });
      const resumed = await store.editSettings(owner, { ...manual, automatic: true });
      await store.applyPreferences(owner, { ...jobs[3]!, revision: manual.revision }, { format: "bullets" });
      expect(await store.settings(owner)).toEqual(resumed);
      const job = jobs[3]!;
      expect(await store.finish(owner, job, 0)).toBe(0);
      const replacement = (await store.claim(owner, job.id))!;
      expect(replacement.lease).not.toBe(job.lease);
      expect(await store.finish(owner, job, 30)).toBeUndefined();
      expect(await store.finish(owner, replacement, 30)).toBe(30);
      expect(await store.claim(owner, job.id)).toBeUndefined();
      await history.delete(owner, thread.id);
      expect(await store.finish(owner, replacement, 30)).toBeUndefined();
      await store.applyPreferences(owner, { ...jobs[0]!, revision: (await store.settings(owner)).revision }, { explanation: "Explain terms" });
      expect((await store.settings(owner)).preferences.explanation).toBeNull();
    } finally { await history.delete(owner, thread.id); }
  });
  it("deletes only the source thread's preferences without invalidating other queued learning", async () => {
    const store = new ChatMemoryStore(connection!.pool), history = createAiHistoryService(connection!.pool);
    const owner = { userId: uuidV7(), source: "header" as const };
    const source = await history.create(owner, uuidV7(), "Source");
    const retained = await history.create(owner, uuidV7(), "Retained");
    const unrelated = await history.create(owner, uuidV7(), "Unrelated");
    try {
      const jobs = [];
      for (const threadId of [source.id, retained.id, retained.id]) {
        const id = uuidV7();
        await history.memory(owner).saveMessages({ messages: [{ id, threadId, resourceId: owner.userId,
          role: "user", createdAt: new Date(), content: { format: 2, parts: [{ type: "text", text: "Persistent preference" }] } }] });
        await store.enqueuePreferences(owner, threadId, id, 0);
        jobs.push((await store.claim(owner, `preference:${id}`))!);
      }
      await store.applyPreferences(owner, jobs[0]!, { language: "ja" });
      await history.delete(owner, unrelated.id);
      await store.applyPreferences(owner, jobs[1]!, { detail: "detailed" });
      expect((await store.settings(owner)).preferences).toMatchObject({ language: "ja", detail: "detailed" });
      await history.delete(owner, source.id);
      await store.applyPreferences(owner, jobs[2]!, { format: "bullets" });
      await store.applyPreferences(owner, jobs[0]!, { language: "en" });
      expect((await store.settings(owner)).preferences).toMatchObject({ language: null, detail: "detailed", format: "bullets" });
    } finally {
      for (const thread of [source, retained, unrelated]) await history.delete(owner, thread.id);
    }
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
  it("protects edits and forgotten preferences, isolates OM, and cascades deleted thread memory", async () => {
    const { pool } = connection!;
    expect((await pool.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).rows[0])
      .toEqual({ rolsuper: false, rolbypassrls: false });
    const store = new ChatMemoryStore(pool), history = createAiHistoryService(pool);
    const owner = { userId: uuidV7(), source: "header" as const }, other = { userId: uuidV7(), source: "header" as const };
    const thread = await history.create(owner, uuidV7(), "Private memory");
    const otherThread = await history.create(other, uuidV7(), "Other owner");
    const messageId = uuidV7();
    const memory = history.memory(owner);
    await memory.saveMessages({ messages: [{ id: messageId, threadId: thread.id, resourceId: owner.userId,
      role: "user", createdAt: new Date(), content: { format: 2, parts: [{ type: "text", text: "今後は日本語で回答して" }] } }] });
    expect(await store.settings(owner)).toEqual({ revision: 0, automatic: true, preferences: emptyPreferences });
    await store.enqueuePreferences(owner, thread.id, messageId, 0);
    const [a, b] = await Promise.all([store.claim(owner, `preference:${messageId}`), store.claim(owner, `preference:${messageId}`)]);
    const job = a ?? b;
    expect([a, b].filter(Boolean)).toHaveLength(1);
    await store.applyPreferences(owner, job!, { language: "ja" });
    const learned = await store.settings(owner);
    expect(learned.preferences.language).toBe("ja");
    expect((await store.settings(other)).preferences.language).toBeNull();
    const cleared = await store.editSettings(owner, { ...learned, preferences: emptyPreferences });
    await store.applyPreferences(owner, job!, { language: "en" });
    await store.applyPreferences(owner, { ...job!, revision: cleared.revision }, { language: "en", explanation: "専門用語は初出時に説明" });
    expect((await store.settings(owner)).preferences.language).toBeNull();
    expect((await store.settings(owner)).preferences.explanation).toBe("専門用語は初出時に説明");
    await expect(store.editSettings(owner, learned)).rejects.toMatchObject({ code: "memory_revision_conflict" });
    await expect(store.enqueuePreferences(other, thread.id, uuidV7(), 0)).rejects.toThrow();
    expect(await store.claim(other, job!.id)).toBeUndefined();
    expect((await pool.query("SELECT * FROM agent.mastra_resources WHERE id = $1", [owner.userId])).rows).toEqual([]);
    expect((await pool.query("SELECT * FROM agent.memory_jobs WHERE id = $1", [job!.id])).rows).toEqual([]);
    expect((await store.due()).every((job) => !('content' in job))).toBe(true);

    const memoryDomain = (await memory.storage.getStore("memory"))!;
    const record = await memoryDomain.initializeObservationalMemory({ threadId: thread.id, resourceId: owner.userId, scope: "thread", config: {} });
    expect(record.id).toBeTruthy();
    expect((await memoryDomain.getObservationalMemory(thread.id, owner.userId))?.id).toBe(record.id);
    const otherDomain = (await history.memory(other).storage.getStore("memory"))!;
    expect(await otherDomain.getObservationalMemory(thread.id, owner.userId)).toBeNull();
    await expect(otherDomain.initializeObservationalMemory({ threadId: thread.id, resourceId: other.userId, scope: "thread", config: {} })).rejects.toThrow();
    await expect(memoryDomain.initializeObservationalMemory({ threadId: null, resourceId: owner.userId, scope: "resource", config: {} })).rejects.toThrow();
    const configured = new Memory({ storage: memory.storage, vector: false, options: {
      semanticRecall: false, workingMemory: { enabled: true, scope: "resource", schema: preferencesSchema, agentManaged: false },
      observationalMemory: { scope: "thread", model: createMockModel({ version: "v2", mockText: "<observations>\nUser prefers Japanese replies.\n</observations>" }), retrieval: { scope: "thread" }, observation: { messageTokens: 1, bufferTokens: false } },
    } });
    expect(await configured.getWorkingMemory({ threadId: thread.id, resourceId: owner.userId })).toContain("専門用語");
    const engine = await configured.omEngine;
    expect(engine).toBeTruthy();
    const observed = await engine!.observe({ threadId: thread.id, resourceId: owner.userId });
    expect(observed.observed).toBe(true);
    expect(observed.record.activeObservations).toContain("Japanese");
    await configured.settled();
    expect((await history.get(owner, thread.id))?.messages.some((message) => message.id === messageId)).toBe(true);
    await history.delete(owner, thread.id);
    expect(await memoryDomain.getObservationalMemory(thread.id, owner.userId)).toBeNull();
    expect((await store.settings(owner)).preferences.explanation).toBeNull();
    expect(await store.claim(owner, job!.id)).toBeUndefined();
    expect((await pool.query("SELECT nullif(current_setting('app.user_id', true), '') AS user_id")).rows).toEqual([{ user_id: null }]);
    expect((await pool.query("SELECT nullif(current_setting('app.maintenance', true), '') AS maintenance")).rows).toEqual([{ maintenance: null }]);
    await history.delete(other, otherThread.id);
  });
});
