import type { MastraDBMessage } from "@mastra/core/agent";
import { Memory } from "@mastra/memory";
import { PostgresStore } from "@mastra/pg";
import type { Pool, PoolClient, QueryResult } from "pg";
import { z } from "zod";

import type { Identity } from "../auth/identity";
import { uuidV7 } from "../id";
import { encodeId } from "../typeid";

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
export const aiThreadHistoryQuerySchema = z.object({ before: z.iso.datetime().optional() }).strict();

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

export interface AiHistoryService {
  memory(identity: Identity): Memory;
  create(identity: Identity, workspaceId: string, title: string): Promise<AiThread>;
  list(identity: Identity, page: number): Promise<{ items: AiThread[]; hasMore: boolean }>;
  get(identity: Identity, threadId: string, before?: Date): Promise<{ thread: AiThread; messages: AiHistoryMessage[]; hasMore: boolean } | null>;
  delete(identity: Identity, threadId: string): Promise<"deleted" | "missing" | "busy">;
  startRun(identity: Identity, threadId: string): Promise<string | null>;
  finishRun(identity: Identity, threadId: string, runId: string): Promise<void>;
}

function resourceId(identity: Identity): string {
  return encodeId("user", identity.userId);
}

function threadValue(thread: { id: string; title?: string; metadata?: Record<string, unknown>; createdAt: Date; updatedAt: Date }): AiThread {
  const workspaceId = thread.metadata?.workspaceId;
  if (typeof workspaceId !== "string") throw new Error("invalid_ai_thread_metadata");
  return { id: thread.id, title: thread.title || "New chat", workspaceId,
    createdAt: thread.createdAt.toISOString(), updatedAt: thread.updatedAt.toISOString() };
}

function messageText(message: MastraDBMessage): string {
  return message.content.parts.filter((part): part is Extract<typeof part, { type: "text" }> => part.type === "text")
    .map((part) => part.text).join("");
}

function historyMessage(message: MastraDBMessage): AiHistoryMessage | null {
  if (message.role !== "user" && message.role !== "assistant") return null;
  const content = messageText(message);
  return content ? { id: message.id, role: message.role, content, createdAt: message.createdAt.toISOString() } : null;
}

function compareHistoryMessages(left: AiHistoryMessage, right: AiHistoryMessage): number {
  const time = left.createdAt.localeCompare(right.createdAt);
  if (time || left.role === right.role) return time || left.id.localeCompare(right.id);
  return left.role === "user" ? -1 : 1;
}

function configureIdentity(client: PoolClient, identity: Identity) {
  return client.query(
    "SELECT set_config('app.user_id', $1, true), set_config('app.resource_id', $2, true)",
    [identity.userId, resourceId(identity)],
  );
}

async function withIdentityTransaction<T>(pool: Pool, identity: Identity,
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
      const thread = await memory.createThread({ threadId: uuidV7(), resourceId: resourceId(identity),
        title: title.trim().slice(0, 80) || "New chat", metadata: { kind: "dahlia-chat", workspaceId } });
      return threadValue(thread);
    },
    async list(identity, page) {
      const result = await memoryFor(pool, identity).listThreads({ filter: { resourceId: resourceId(identity), metadata: { kind: "dahlia-chat" } },
        page, perPage: PAGE_SIZE, orderBy: { field: "updatedAt", direction: "DESC" } });
      return { items: result.threads.map(threadValue), hasMore: result.hasMore };
    },
    async get(identity, threadId, before) {
      const memory = memoryFor(pool, identity);
      const thread = await memory.getThreadById({ threadId, resourceId: resourceId(identity) });
      if (!thread || thread.metadata?.kind !== "dahlia-chat") return null;
      const recalled = await memory.recall({ threadId, resourceId: resourceId(identity), page: 0, perPage: PAGE_SIZE,
        filter: before ? { dateRange: { end: before } } : undefined,
        orderBy: { field: "createdAt", direction: "DESC" },
        threadConfig: { lastMessages: PAGE_SIZE, semanticRecall: false } });
      const messages = recalled.messages.map(historyMessage)
        .filter((message): message is AiHistoryMessage => message !== null)
        .sort(compareHistoryMessages);
      return { thread: threadValue(thread), messages, hasMore: recalled.hasMore };
    },
    async delete(identity, threadId) {
      return withIdentityTransaction(pool, identity, async (client) => {
        await lockThreadRunState(client, threadId);
        const running = await client.query("SELECT 1 FROM agent.ai_thread_runs WHERE thread_id = $1", [threadId]);
        if (running.rowCount) return "busy";
        const thread = await client.query<{ id: string }>(`SELECT id FROM agent.mastra_threads
          WHERE id = $1 AND metadata->>'kind' = 'dahlia-chat'`, [threadId]);
        if (!thread.rowCount) return "missing";
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
        [threadId, runId, resourceId(identity), RUN_LEASE]);
        return result.rowCount === 1 ? runId : null;
      });
    },
    async finishRun(identity, threadId, runId) {
      await scopedPool(pool, identity).query("DELETE FROM agent.ai_thread_runs WHERE thread_id = $1 AND run_id = $2", [threadId, runId]);
    },
  };
}
