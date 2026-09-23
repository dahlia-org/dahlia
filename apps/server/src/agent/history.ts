import type { MastraDBMessage } from "@mastra/core/agent";
import { Memory } from "@mastra/memory";
import { PostgresStore } from "@mastra/pg";
import type { Pool, PoolClient, QueryResult } from "pg";
import { z } from "zod";

import type { Identity } from "../auth/identity";
import { uuidV7 } from "../id";

const AGENT_SCHEMA = "agent";
const PAGE_SIZE = 50;
export const AI_HISTORY_RUN_TIMEOUT_MS = 10 * 60 * 1000;
const RUN_LEASE = "11 minutes";

export const aiThreadCreateSchema = z.object({
  workspaceId: z.string().uuid(),
  title: z.string().trim().min(1).max(16_000),
}).strict();
export const aiThreadMessageSchema = z.object({
  model: z.string().min(1).max(200),
  reasoningEffort: z.enum(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]),
  content: z.string().trim().min(1).max(16_000),
}).strict();
export const aiThreadHistoryQuerySchema = z.object({
  before: z.iso.datetime().optional(),
  beforeId: z.string().min(1).max(200).optional(),
  beforeRole: z.enum(["user", "assistant"]).optional(),
}).strict();

export interface AiThread {
  id: string;
  title: string;
  workspaceId: string;
  createdAt: string;
  updatedAt: string;
}

export interface AiHistoryMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
  createdAt: string;
}

export interface AiHistoryCursor {
  createdAt: Date;
  id: string;
  role: AiHistoryMessage["role"];
}

export interface AiHistoryService {
  memory(identity: Identity): Memory;
  create(identity: Identity, workspaceId: string, title: string): Promise<AiThread>;
  list(identity: Identity, page: number): Promise<{ items: AiThread[]; hasMore: boolean }>;
  get(identity: Identity, threadId: string, before?: AiHistoryCursor): Promise<{ thread: AiThread; messages: AiHistoryMessage[]; hasMore: boolean } | null>;
  delete(identity: Identity, threadId: string): Promise<"deleted" | "missing" | "busy">;
  startRun(identity: Identity, threadId: string): Promise<string | null>;
  finishRun(identity: Identity, threadId: string, runId: string): Promise<void>;
}

function threadValue(thread: { id: string; title?: string; metadata?: Record<string, unknown>; createdAt: Date; updatedAt: Date }): AiThread {
  const workspaceId = thread.metadata?.workspaceId;
  if (typeof workspaceId !== "string") throw new Error("invalid_ai_thread_metadata");
  return { id: thread.id, title: thread.title || "New chat", workspaceId,
    createdAt: thread.createdAt.toISOString(), updatedAt: thread.updatedAt.toISOString() };
}

function messageText(content: MastraDBMessage["content"]): string {
  return content.parts.filter((part): part is Extract<typeof part, { type: "text" }> => part.type === "text")
    .map((part) => part.text).join("");
}

function compareHistoryMessages(left: AiHistoryMessage, right: AiHistoryMessage): number {
  const time = left.createdAt.localeCompare(right.createdAt);
  if (time || left.role === right.role) return time || left.id.localeCompare(right.id);
  return left.role === "user" ? -1 : 1;
}

function configureIdentity(client: PoolClient, identity: Identity) {
  return client.query("SELECT set_config('app.user_id', $1, true)", [identity.userId]);
}

export async function withIdentityTransaction<T>(pool: Pool, identity: Identity,
  action: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  let releaseError: Error | undefined;
  try {
    await client.query("BEGIN");
    await configureIdentity(client, identity);
    const result = await action(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch (rollbackError) {
      releaseError = rollbackError instanceof Error ? rollbackError : new Error(String(rollbackError));
      throw new AggregateError([error, rollbackError], "Agent history transaction and rollback both failed", { cause: rollbackError });
    }
    throw error;
  } finally {
    client.release(releaseError);
  }
}

async function lockThreadRunState(client: PoolClient, threadId: string): Promise<void> {
  await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [threadId]);
  await client.query("DELETE FROM agent.ai_thread_runs WHERE thread_id = $1 AND expires_at <= now()", [threadId]);
}

function scopedPool(pool: Pool, identity: Identity): Pool {
  return {
    async query(text: string, values?: unknown[]): Promise<QueryResult> {
      return withIdentityTransaction(pool, identity, (client) => client.query(text, values));
    },
    async connect() {
      const client = await pool.connect();
      const scopedClient = Object.create(client) as PoolClient;
      let inTransaction = false;
      let connectionError: Error | undefined;
      scopedClient.query = (async (text: string, values?: unknown[]) => {
        const command = text.trimStart().toUpperCase();
        const endsTransaction = command.startsWith("COMMIT") || command.startsWith("ROLLBACK");
        if (command.startsWith("BEGIN")) {
          const result = await client.query(text, values);
          inTransaction = true;
          try {
            await configureIdentity(scopedClient, identity);
          } catch (error) {
            try { await client.query("ROLLBACK"); inTransaction = false; }
            catch (rollbackError) { connectionError = rollbackError instanceof Error ? rollbackError : new Error(String(rollbackError)); }
            throw error;
          }
          return result;
        }
        if (!inTransaction) throw new Error("agent_history_query_outside_transaction");
        try {
          const result = await client.query(text, values);
          if (endsTransaction) inTransaction = false;
          return result;
        } catch (error) {
          if (endsTransaction) connectionError = error instanceof Error ? error : new Error(String(error));
          throw error;
        }
      }) as PoolClient["query"];
      scopedClient.release = (error) => client.release(error || connectionError || inTransaction);
      return scopedClient;
    },
  } as Pool;
}

function memoryFor(pool: Pool, identity: Identity): Memory {
  const storage = new PostgresStore({ id: "dahlia-ai-history", pool: scopedPool(pool, identity),
    schemaName: AGENT_SCHEMA, disableInit: true });
  return new Memory({ storage, vector: false, options: { lastMessages: 50, semanticRecall: false } });
}

export function createAiHistoryService(pool: Pool): AiHistoryService {
  return {
    memory: (identity) => memoryFor(pool, identity),
    async create(identity, workspaceId, title) {
      const memory = memoryFor(pool, identity);
      const thread = await memory.createThread({ threadId: uuidV7(), resourceId: identity.userId,
        title: title.trim().slice(0, 80) || "New chat", metadata: { kind: "dahlia-chat", workspaceId } });
      return threadValue(thread);
    },
    async list(identity, page) {
      const result = await memoryFor(pool, identity).listThreads({ filter: { resourceId: identity.userId, metadata: { kind: "dahlia-chat" } },
        page, perPage: PAGE_SIZE, orderBy: { field: "updatedAt", direction: "DESC" } });
      return { items: result.threads.map(threadValue), hasMore: result.hasMore };
    },
    async get(identity, threadId, before) {
      const memory = memoryFor(pool, identity);
      const thread = await memory.getThreadById({ threadId, resourceId: identity.userId });
      if (!thread || thread.metadata?.kind !== "dahlia-chat") return null;
      const values: unknown[] = [threadId];
      const cursor = before ? `AND (COALESCE("createdAtZ", "createdAt"), CASE role WHEN 'user' THEN 0 ELSE 1 END, id)
        < ($2::timestamptz, $3::integer, $4::text)` : "";
      if (before) values.push(before.createdAt, before.role === "user" ? 0 : 1, before.id);
      values.push(PAGE_SIZE + 1);
      const rows = await withIdentityTransaction(pool, identity, (client) => client.query<{
        id: string; content: string; role: string; createdAt: Date;
      }>(`SELECT id, content, role, COALESCE("createdAtZ", "createdAt") AS "createdAt"
        FROM agent.mastra_messages
        WHERE thread_id = $1 AND role IN ('user', 'assistant') ${cursor}
        ORDER BY COALESCE("createdAtZ", "createdAt") DESC,
          CASE role WHEN 'user' THEN 0 ELSE 1 END DESC, id DESC
        LIMIT $${values.length}`, values));
      const messages = rows.rows.slice(0, PAGE_SIZE).map((row) => {
        const content = messageText(JSON.parse(row.content) as MastraDBMessage["content"]);
        return { id: row.id, role: row.role as AiHistoryMessage["role"], content, createdAt: row.createdAt.toISOString() };
      }).filter(({ content }) => content).sort(compareHistoryMessages);
      return { thread: threadValue(thread), messages, hasMore: rows.rows.length > PAGE_SIZE };
    },
    async delete(identity, threadId) {
      return withIdentityTransaction(pool, identity, async (client) => {
        await lockThreadRunState(client, threadId);
        const running = await client.query("SELECT 1 FROM agent.ai_thread_runs WHERE thread_id = $1", [threadId]);
        if (running.rowCount) return "busy";
        const thread = await client.query<{ id: string }>(`SELECT id FROM agent.mastra_threads
          WHERE id = $1 AND metadata->>'kind' = 'dahlia-chat'`, [threadId]);
        if (!thread.rowCount) return "missing";
        await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 1))", [identity.userId]);
        const profile = await client.query<{ workingMemory: string; metadata: { preferences?: { revision: number; sources: Record<string, { threadId: string }> } } }>(
          'SELECT "workingMemory", metadata FROM agent.mastra_resources WHERE id = $1', [identity.userId]);
        const row = profile.rows[0];
        const preferences = row?.metadata?.preferences;
        if (row?.workingMemory && preferences) {
          const values = JSON.parse(row.workingMemory) as Record<string, unknown>;
          const sourcedKeys = Object.entries(preferences.sources).filter(([, source]) => source.threadId === threadId).map(([key]) => key);
          for (const key of sourcedKeys) { values[key] = null; delete preferences.sources[key]; }
          if (sourcedKeys.length) {
            preferences.revision++;
            await client.query('UPDATE agent.mastra_resources SET "workingMemory" = $2, metadata = $3, "updatedAt" = now(), "updatedAtZ" = now() WHERE id = $1',
              [identity.userId, JSON.stringify(values), JSON.stringify(row.metadata)]);
          }
        }
        await client.query("DELETE FROM agent.mastra_messages WHERE thread_id = $1", [threadId]);
        await client.query("DELETE FROM agent.mastra_threads WHERE id = $1", [threadId]);
        return "deleted" as const;
      });
    },
    async startRun(identity, threadId) {
      return withIdentityTransaction(pool, identity, async (client) => {
        await lockThreadRunState(client, threadId);
        const runId = uuidV7();
        const result = await client.query(`INSERT INTO agent.ai_thread_runs (thread_id, run_id, resource_id, expires_at)
          SELECT $1, $2, $3, now() + $4::interval
          WHERE EXISTS (SELECT 1 FROM agent.mastra_threads WHERE id = $1)
          ON CONFLICT (thread_id) DO NOTHING RETURNING run_id`,
        [threadId, runId, identity.userId, RUN_LEASE]);
        return result.rowCount === 1 ? runId : null;
      });
    },
    async finishRun(identity, threadId, runId) {
      await scopedPool(pool, identity).query("DELETE FROM agent.ai_thread_runs WHERE thread_id = $1 AND run_id = $2", [threadId, runId]);
    },
  };
}
