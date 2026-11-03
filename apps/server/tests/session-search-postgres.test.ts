import type { MastraDBMessage } from "@mastra/core/agent";
import { afterAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { createAiHistoryService } from "../src/agent/history";
import { createSessionSearchStore } from "../src/agent/session-search";
import { createSessionSearchTools, searchChatHistory } from "../src/agent/session-tools";
import { meetingRequestContext } from "../src/agent/tools";
import { createPostgresAuthStore } from "../src/auth/store";
import type { Identity } from "../src/auth/identity";
import * as schema from "../src/db/auth-schema";
import { connectPostgresUrl } from "../src/db/postgres";
import { createJobStore } from "../src/jobs/store";
import { defaultJobLimits } from "../src/jobs/model";
import { processMemoryIndexJob } from "../src/memory/index-job";
import { SearchEmbeddingError, type SearchEmbedder } from "../src/search/embedding";
import { applicationAnalyzer } from "../src/search/lexical";
import { chunkText } from "../src/search/chunk";
import { createNodeSearchTokenizer } from "../src/search/node-tokenizer";
import { createIntlSearchTokenizer } from "../src/search/tokenizer";
import { MeetingSyncService } from "../src/sync/service";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";

const url = process.env.TEST_DATABASE_URL;
const connection = url ? connectPostgresUrl(url, 4) : undefined;
afterAll(async () => connection?.close());
const lindera = applicationAnalyzer(createNodeSearchTokenizer());
const signal = new AbortController().signal;
// "費用" and "予算" share an axis, so they match by meaning only.
const embedder: SearchEmbedder = { model: "test-embedding", dimensions: 32,
  async embedDocuments(input) { return input.map(vector); }, async embedQuery(input) { return vector(input); } };
function vector(text: string) {
  return Array.from({ length: 32 }, (_, axis) => axis === 0 ? Number(/予算|費用/u.test(text)) : axis === 1 ? Number(/天気/u.test(text)) : 0.01);
}

describe.runIf(url)("Saved chat hybrid search", () => {
  it("indexes Mastra messages after a run, searches only the owner's readable Workspace and returns neighbouring messages", async () => {
    const { db, pool } = connection!;
    const app = createPostgresAuthStore(db, "postgres");
    const owner: Identity = { userId: uuidV7(), source: "header" };
    const stranger: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner); await seedPostgresIdentity(app, url!, stranger);
    const sync = new MeetingSyncService(app.sync);
    const workspaceId = uuidV7();
    await sync.commitTransaction(owner, { schemaVersion: 3, workspaceId, id: uuidV7(), createdAt: new Date().toISOString(), operations: [{
      id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
      data: { organizationId: testOrganizationID, name: "Chat search", createdAt: new Date().toISOString() } }] });
    const history = createAiHistoryService(pool);
    const sessions = createSessionSearchStore(pool, "postgres", { model: embedder.model, dimensions: embedder.dimensions });
    const queue = createJobStore(db, true, defaultJobLimits);
    const deps = { sessions, history, sync, analyzer: lindera, embedder };
    const thread = await history.create(owner, workspaceId, "出張の相談");
    const strangerThread = await history.create(stranger, workspaceId, "Stranger");
    const start = Date.now();
    const messages: MastraDBMessage[] = ["来週の出張について相談したい", "予算は20万円にしましょう", "ありがとう、その金額で進めます"].map((text, index) => ({
      id: uuidV7(), threadId: thread.id, resourceId: owner.userId, createdAt: new Date(start + index),
      role: index === 1 ? "assistant" : "user", content: { format: 2, parts: [{ type: "text", text }] },
    }));
    await history.memory(owner).saveMessages({ messages });
    await history.memory(stranger).saveMessages({ messages: [{ id: uuidV7(), threadId: strangerThread.id, resourceId: stranger.userId,
      createdAt: new Date(), role: "user", content: { format: 2, parts: [{ type: "text", text: "予算の秘密" }] } }] });
    const run = async (identity: Identity, threadId: string) => {
      await sessions.enqueue(identity, threadId);
      const job = (await queue.claim(["memory-index"], [`memory-index:session:${threadId}`]))!;
      expect(job.payload).toMatchObject({ source: "session", ownerUserId: identity.userId, threadId, model: embedder.model });
      await processMemoryIndexJob({ queue, analyzer: lindera, sessions, embedder }, job, signal);
      await queue.complete(job);
    };
    try {
      // Unindexed chats are reported as partial word coverage.
      expect((await sessions.search(owner, "予算", [workspaceId], lindera, 10)).partial).toBe(true);
      await run(owner, thread.id); await run(stranger, strangerThread.id);
      const found = await searchChatHistory(deps, owner, workspaceId, "出張の費用はいくらにした？", signal);
      // "費用" matches the assistant's "予算" by meaning only; "出張" matches the first message by word.
      const answer = found.results.find((result) => result.messageId === messages[1]!.id);
      expect(found.results.slice(0, 2).map((result) => result.messageId).toSorted()).toEqual([messages[0]!.id, messages[1]!.id].toSorted());
      expect(answer).toMatchObject({ threadId: thread.id, title: "出張の相談", role: "assistant", text: "予算は20万円にしましょう" });
      expect(answer!.context.map((message) => message.text)).toEqual(["来週の出張について相談したい", "ありがとう、その金額で進めます"]);
      expect(found.instruction).toContain("meaning");
      expect(found.instruction).not.toContain("not indexed");
      // A long answer shows the chunk that matched, not its opening chunk.
      const longText = `${"前置きの説明です。".repeat(400)}\n\n結論として出張の宿泊先は大阪の駅前にしました。`;
      const longChunks = chunkText(longText);
      expect(longChunks).toHaveLength(2);
      const long: MastraDBMessage = { id: uuidV7(), threadId: thread.id, resourceId: owner.userId, createdAt: new Date(start + 10), role: "assistant",
        content: { format: 2, parts: [{ type: "text", text: longText }] } };
      await history.memory(owner).saveMessages({ messages: [long] });
      // A chunk the provider rejects is recorded without a vector and does not stop the remaining chunks.
      const rejectFirst: SearchEmbedder = { ...embedder, async embedDocuments(input) {
        if (input.includes(longChunks[0]!)) throw new SearchEmbeddingError("embedding_http_400", false);
        return embedder.embedDocuments(input);
      } };
      await sessions.enqueue(owner, thread.id);
      const longJob = (await queue.claim(["memory-index"], [`memory-index:session:${thread.id}`]))!;
      await processMemoryIndexJob({ queue, analyzer: lindera, sessions, embedder: rejectFirst }, longJob, signal);
      await queue.complete(longJob);
      expect(await sessions.pendingEmbeddings(owner.userId, thread.id, { model: embedder.model, dimensions: 32 }, 10)).toEqual([]);
      const hotel = (await sessions.search(owner, "宿泊先", [workspaceId], lindera, 10)).hits;
      expect(hotel.map((hit) => [hit.messageId, hit.text])).toEqual([[long.id, longChunks[1]]]);
      // Words alone, without embeddings: Japanese sentences match by tokens.
      expect((await sessions.search(owner, "出張について", [workspaceId], lindera, 10)).hits.map((hit) => hit.messageId).toSorted()).toEqual([messages[0]!.id, long.id].toSorted());
      // Owner-only: the stranger's chat in the same Workspace never appears, and RLS hides the projection rows.
      expect(found.results.flatMap((result) => [result.text, ...result.context.map((message) => message.text)])).not.toContain("予算の秘密");
      expect((await pool.query("SELECT * FROM agent.session_search_chunks WHERE thread_id = $1", [thread.id])).rows).toEqual([]);
      // A Workspace the caller cannot read is excluded before any lookup.
      await expect(searchChatHistory(deps, stranger, uuidV7(), "予算", signal)).rejects.toMatchObject({ status: 404 });
      // The tool is pinned to the chat's Workspace.
      const tool = createSessionSearchTools(deps).search_chat_history;
      const viaTool = await tool.execute!({ query: "予算" }, { requestContext: meetingRequestContext(owner, workspaceId), abortSignal: signal } as never) as typeof found;
      expect(viaTool.results.map((result) => result.messageId)).toContain(messages[1]!.id);
      // Another analyzer's rows are rebuilt by reconciliation.
      const intl = applicationAnalyzer(createIntlSearchTokenizer());
      expect((await sessions.search(owner, "予算", [workspaceId], intl, 10)).partial).toBe(true);
      expect(await sessions.reconcilePage(owner.userId, intl)).toBeUndefined();
      const requeued = (await queue.claim(["memory-index"], [`memory-index:session:${thread.id}`]))!;
      await processMemoryIndexJob({ queue, analyzer: intl, sessions }, requeued, signal);
      await queue.complete(requeued);
      expect(await sessions.search(owner, "予算", [workspaceId], intl, 10)).toMatchObject({ partial: false, hits: [{ messageId: messages[1]!.id }] });
      // The rewrite kept the vectors of unchanged text.
      expect(await sessions.pendingEmbeddings(owner.userId, thread.id, { model: embedder.model, dimensions: 32 }, 10)).toEqual([]);
      // Deleting the chat removes its projection.
      expect(await history.delete(owner, thread.id)).toBe("deleted");
      expect((await db.select().from(schema.backgroundJob).where(eq(schema.backgroundJob.dedupeKey, `memory-index:session:${thread.id}`)))).toEqual([]);
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
        expect((await client.query("SELECT 1 FROM agent.session_search_chunks WHERE thread_id = $1", [thread.id])).rowCount).toBe(0);
        await client.query("COMMIT");
      } finally { client.release(); }
    } finally {
      await history.delete(owner, thread.id).catch(() => undefined);
      await history.delete(stranger, strangerThread.id).catch(() => undefined);
    }
  });
  it("splits unbroken Japanese runs over the parser token limit in saved chats", async () => {
    const { db, pool } = connection!;
    const app = createPostgresAuthStore(db, "postgres");
    const owner: Identity = { userId: uuidV7(), source: "header" };
    await seedPostgresIdentity(app, url!, owner);
    const workspaceId = uuidV7();
    await new MeetingSyncService(app.sync).commitTransaction(owner, { schemaVersion: 3, workspaceId, id: uuidV7(), createdAt: new Date().toISOString(), operations: [{
      id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null,
      data: { organizationId: testOrganizationID, name: "Long runs", createdAt: new Date().toISOString() } }] });
    const history = createAiHistoryService(pool);
    const sessions = createSessionSearchStore(pool, "postgres");
    // The simple configuration stands in for tokenizer_japanese; PostgreSQL's parser has the same token limit.
    const databaseSide = { id: "test-database-side/simple", config: "simple", matchAll: false };
    const thread = await history.create(owner, workspaceId, "Long run");
    const run = ["ア", "か", "ア"].map((char) => char.repeat(600));
    const message: MastraDBMessage = { id: uuidV7(), threadId: thread.id, resourceId: owner.userId, createdAt: new Date(), role: "assistant",
      content: { format: 2, parts: [{ type: "text", text: run.join("") }] } };
    try {
      await history.memory(owner).saveMessages({ messages: [message] });
      expect(await sessions.index(owner.userId, thread.id, databaseSide)).toBeUndefined();
      expect((await sessions.search(owner, run[1]!, [workspaceId], databaseSide, 10)).hits.map((hit) => hit.messageId)).toEqual([message.id]);
    } finally { await history.delete(owner, thread.id); }
  });
});
