import type { MastraDBMessage } from "@mastra/core/agent";
import { describe, expect, it } from "vitest";

import { createAiHistoryService } from "../src/agent/history";
import type { Identity } from "../src/auth/identity";
import { connectPostgresUrl } from "../src/db/postgres";
import { uuidV7 } from "../src/id";
import { encodeId } from "../src/typeid";

const databaseUrl = process.env.TEST_DATABASE_URL;

describe.runIf(databaseUrl)("PostgreSQL Agent history", () => {
  it("persists and isolates history without leaking identity or deadlocking a one-connection pool", async () => {
    const connection = connectPostgresUrl(databaseUrl!, 1);
    const history = createAiHistoryService(connection.pool);
    const owner: Identity = { userId: uuidV7(), source: "header" };
    const stranger: Identity = { userId: uuidV7(), source: "header" };
    const workspaceId = uuidV7();
    const resourceId = encodeId("user", owner.userId);
    let threadId: string | undefined;
    try {
      const thread = await history.create(owner, workspaceId, "Persistent history");
      threadId = thread.id;
      expect((await history.list(owner, 0)).items.map(({ id }) => id)).toContain(thread.id);
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
      expect((await history.list(stranger, 0)).items).toEqual([]);

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
        await client.query("SELECT set_config('app.resource_id', $1, true)", [resourceId]);
        await client.query("UPDATE agent.ai_thread_runs SET expires_at = timestamp '1970-01-01' WHERE thread_id = $1", [thread.id]);
        await client.query("COMMIT");
      } finally {
        client.release();
      }
      expect(await history.delete(owner, thread.id)).toBe("deleted");
      threadId = undefined;
      expect(await history.get(owner, thread.id)).toBeNull();
      expect((await connection.pool.query<{ resource: string | null }>(
        "SELECT nullif(current_setting('app.resource_id', true), '') AS resource",
      )).rows).toEqual([{ resource: null }]);
    } finally {
      if (threadId) await history.delete(owner, threadId).catch(() => undefined);
      await connection.close();
    }
  });
});
