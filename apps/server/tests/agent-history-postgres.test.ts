import type { MastraDBMessage } from "@mastra/core/agent";
import { describe, expect, it } from "vitest";

import { createAiHistoryService } from "../src/agent/history";
import type { Identity } from "../src/auth/identity";
import { connectPostgresUrl } from "../src/db/postgres";
import { uuidV7 } from "../src/id";

const databaseUrl = process.env.TEST_DATABASE_URL;

describe.runIf(databaseUrl)("PostgreSQL Agent history", () => {
  it("persists and isolates history without leaking identity or deadlocking a one-connection pool", async () => {
    const connection = connectPostgresUrl(databaseUrl!, 1);
    const history = createAiHistoryService(connection.pool);
    const owner: Identity = { userId: uuidV7(), source: "header" };
    const stranger: Identity = { userId: uuidV7(), source: "header" };
    const workspaceId = uuidV7();
    const resourceId = owner.userId;
    const cleanup: { identity: Identity; threadId: string }[] = [];
    try {
      const thread = await history.create(owner, workspaceId, "Persistent history");
      const otherWorkspaceThread = await history.create(owner, uuidV7(), "Other workspace");
      const strangerThread = await history.create(stranger, uuidV7(), "Stranger history");
      cleanup.push({ identity: owner, threadId: thread.id }, { identity: owner, threadId: otherWorkspaceThread.id },
        { identity: stranger, threadId: strangerThread.id });
      expect((await history.list(owner, 0)).items.map(({ id }) => id))
        .toEqual(expect.arrayContaining([thread.id, otherWorkspaceThread.id]));
      const ownerClient = await connection.pool.connect();
      try {
        await ownerClient.query("BEGIN");
        await ownerClient.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
        expect((await ownerClient.query<{ resourceId: string }>(
          'SELECT "resourceId" FROM agent.mastra_threads WHERE id = $1', [thread.id],
        )).rows).toEqual([{ resourceId: owner.userId }]);
        await ownerClient.query(`INSERT INTO agent.mastra_resources
          (id, "createdAt", "updatedAt") VALUES ($1, now(), now())`, [owner.userId]);
        expect((await ownerClient.query<{ id: string }>(
          "SELECT id FROM agent.mastra_resources WHERE id = $1", [owner.userId],
        )).rows).toEqual([{ id: owner.userId }]);
        await ownerClient.query("COMMIT");
      } finally {
        ownerClient.release();
      }
      for (const table of ["mastra_threads", "mastra_messages", "mastra_resources", "ai_thread_runs"]) {
        expect((await connection.pool.query<{ count: string }>(`SELECT count(*) FROM agent.${table}`))
          .rows[0]?.count).toBe("0");
      }
      await expect(connection.pool.query(`INSERT INTO agent.mastra_threads
        (id, "resourceId", title, "createdAt", "updatedAt") VALUES ($1, $2, 'Forbidden', now(), now())`,
      [uuidV7(), resourceId])).rejects.toThrow();
      const rlsClient = await connection.pool.connect();
      try {
        await rlsClient.query("BEGIN");
        await rlsClient.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
        const rejectSpoof = async (sql: string, values: unknown[]) => {
          await rlsClient.query("SAVEPOINT reject_spoof");
          try {
            await expect(rlsClient.query(sql, values)).rejects.toThrow();
          } finally {
            await rlsClient.query("ROLLBACK TO SAVEPOINT reject_spoof");
            await rlsClient.query("RELEASE SAVEPOINT reject_spoof");
          }
        };
        await rejectSpoof(`INSERT INTO agent.mastra_threads
          (id, "resourceId", title, "createdAt", "updatedAt") VALUES ($1, $2, 'Spoofed', now(), now())`,
        [uuidV7(), stranger.userId]);
        await rejectSpoof(`INSERT INTO agent.mastra_resources
          (id, "createdAt", "updatedAt") VALUES ($1, now(), now())`, [stranger.userId]);
        await rejectSpoof(`INSERT INTO agent.mastra_messages
          (id, thread_id, content, role, type, "createdAt", "resourceId")
          VALUES ($1, $2, '{}', 'user', 'v2', now(), $3)`, [uuidV7(), thread.id, stranger.userId]);
        await rejectSpoof(`INSERT INTO agent.ai_thread_runs
          (thread_id, run_id, resource_id, expires_at) VALUES ($1, $2, $3, now() + interval '1 minute')`,
        [thread.id, uuidV7(), stranger.userId]);
        await rejectSpoof(`INSERT INTO agent.ai_thread_runs
          (thread_id, run_id, resource_id, expires_at) VALUES ($1, $2, $3, now() + interval '1 minute')`,
        [strangerThread.id, uuidV7(), owner.userId]);
        await rlsClient.query("ROLLBACK");
      } finally {
        rlsClient.release();
      }
      const initialCreatedAt = new Date();
      const messages: MastraDBMessage[] = ["Question", "Answer", "Follow-up"].map((text, index) => ({
        id: uuidV7(), threadId: thread.id, resourceId,
        createdAt: index < 2 ? initialCreatedAt : new Date(initialCreatedAt.getTime() + 1),
        role: index === 1 ? "assistant" : "user", content: { format: 2, parts: [{ type: "text", text }] },
      }));
      await history.memory(owner).saveMessages({ messages: messages.slice(0, 2) });
      await history.memory(owner).saveMessages({ messages: messages.slice(2) });

      expect((await history.get(owner, thread.id))?.messages.map(({ content }) => content))
        .toEqual(["Question", "Answer", "Follow-up"]);
      expect(await history.get(stranger, thread.id)).toBeNull();
      expect((await history.list(stranger, 0)).items.map(({ id }) => id)).toEqual([strangerThread.id]);
      expect(await history.startRun(stranger, thread.id)).toBeNull();
      expect(await history.delete(stranger, thread.id)).toBe("missing");
      expect(await history.startRun(owner, strangerThread.id)).toBeNull();
      await expect(history.memory(stranger).saveMessages({ messages: [{
        id: uuidV7(), threadId: thread.id, resourceId: stranger.userId, createdAt: new Date(),
        role: "user", content: { format: 2, parts: [{ type: "text", text: "Forbidden continuation" }] },
      }] })).rejects.toThrow();

      const later = new Date(Date.now() + 10_000);
      const sameTime = Array.from({ length: 60 }, (_, index) => ({
        id: uuidV7(), threadId: thread.id, resourceId, createdAt: later,
        role: index % 2 ? "assistant" as const : "user" as const,
        content: { format: 2 as const, parts: [{ type: "text" as const, text: `History ${index}` }] },
      }));
      await history.memory(owner).saveMessages({ messages: sameTime });
      const latest = await history.get(owner, thread.id);
      expect(latest?.messages).toHaveLength(50);
      expect(latest?.hasMore).toBe(true);
      const before = latest!.messages[0]!;
      await history.memory(owner).saveMessages({ messages: [{
        id: uuidV7(), threadId: thread.id, resourceId, createdAt: new Date(later.getTime() + 100), role: "user",
        content: { format: 2, parts: [{ type: "text", text: "Concurrent question" }] },
      }, {
        id: uuidV7(), threadId: thread.id, resourceId, createdAt: new Date(later.getTime() + 101), role: "assistant",
        content: { format: 2, parts: [{ type: "text", text: "Concurrent answer" }] },
      }] });
      const earlier = await history.get(owner, thread.id, {
        createdAt: new Date(before.createdAt), id: before.id, role: before.role,
      });
      expect(earlier?.hasMore).toBe(false);
      const paged = [...earlier!.messages, ...latest!.messages];
      expect(new Set(paged.map(({ id }) => id)).size).toBe(63);
      expect(paged.map(({ content }) => content)).not.toContain("Concurrent question");

      const claims = await Promise.all([history.startRun(owner, thread.id), history.startRun(owner, thread.id)]);
      expect(claims.filter(Boolean)).toHaveLength(1);
      const firstRun = claims.find(Boolean)!;
      expect(firstRun).toBeTruthy();
      await history.finishRun(owner, thread.id, uuidV7());
      expect(await history.startRun(owner, thread.id)).toBeNull();
      await history.finishRun(owner, thread.id, firstRun);
      const secondRun = await history.startRun(owner, thread.id);
      expect(secondRun).toBeTruthy();
      await history.finishRun(owner, thread.id, firstRun);
      expect(await history.startRun(owner, thread.id)).toBeNull();

      const client = await connection.pool.connect();
      try {
        await client.query("BEGIN");
        await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
        await client.query("UPDATE agent.ai_thread_runs SET expires_at = timestamp '1970-01-01' WHERE thread_id = $1", [thread.id]);
        await client.query("COMMIT");
      } finally {
        client.release();
      }
      expect(await history.delete(owner, thread.id)).toBe("deleted");
      cleanup.splice(cleanup.findIndex((item) => item.threadId === thread.id), 1);
      expect(await history.get(owner, thread.id)).toBeNull();
      expect(await history.get(owner, otherWorkspaceThread.id)).not.toBeNull();
      expect((await connection.pool.query<{ user_id: string | null }>(
        "SELECT nullif(current_setting('app.user_id', true), '') AS user_id",
      )).rows).toEqual([{ user_id: null }]);
    } finally {
      for (const item of cleanup) await history.delete(item.identity, item.threadId).catch(() => undefined);
      const client = await connection.pool.connect();
      try {
        await client.query("BEGIN");
        await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
        await client.query("DELETE FROM agent.mastra_resources WHERE id = $1", [owner.userId]);
        await client.query("COMMIT");
      } catch {
        await client.query("ROLLBACK").catch(() => undefined);
      } finally {
        client.release();
      }
      await connection.close();
    }
  });
});
