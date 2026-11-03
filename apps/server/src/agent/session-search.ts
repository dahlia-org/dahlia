import { drizzle } from "drizzle-orm/node-postgres";
import type { MastraDBMessage } from "@mastra/core/agent";
import type { Pool, PoolClient } from "pg";
import * as schema from "../db/auth-schema";
import type { Identity } from "../auth/identity";
import { enqueueJob } from "../jobs/state";
import { chunkText } from "../search/chunk";
import {
  analyzerInput, analyzerResolver, contentHash, LAKEBASE_TOKENIZER_VERSION_SQL, lexemeQuery, queryTokens, type SearchAnalyzer,
} from "../search/lexical";
import { reciprocalRankFusion, SEARCH_CANDIDATE_LIMIT } from "../search/ranking";
import type { EmbeddingConfig, SearchBackend } from "../memory/search";
import { messageText, withIdentityTransaction } from "./history";

export interface SessionChunk { messageId: string; chunkNo: number; text: string; hash: string }
export interface SessionHit { threadId: string; title: string; workspaceId: string; messageId: string; role: string; createdAt: Date; text: string }
const INDEX_PAGE = 200;
const as = (userId: string): Identity => ({ userId, source: "header" });

/** Search projection of saved dahlia-chat threads (agent.session_search_chunks), owner-only through RLS. */
export function createSessionSearchStore(pool: Pool, backend: Exclude<SearchBackend, "sqlite">, embedding?: EmbeddingConfig) {
  const analyzer = analyzerResolver(backend === "lakebase", async () =>
    (await pool.query<{ extversion: string }>(LAKEBASE_TOKENIZER_VERSION_SQL)).rows[0]?.extversion);
  const staleEmbedding = (config: EmbeddingConfig, offset: number) => `chunk_text <> '' AND (embedding IS NULL OR embedding_model IS DISTINCT FROM $${offset}
    OR cardinality(embedding) <> $${offset + 1})`;
  const enqueue = (client: PoolClient, userId: string, threadId: string) => enqueueJob(drizzle({ client }), schema, `memory-index:session:${threadId}`,
    "memory-index", userId, `chat-search:${threadId}`, { source: "session", ownerUserId: userId, threadId, ...embedding });

  return {
    /** Queues indexing of a thread after a run; Mastra owns the messages, so the projection follows asynchronously. */
    enqueue: (identity: Identity, threadId: string) => withIdentityTransaction(pool, identity, async (client) => {
      const thread = await client.query("SELECT 1 FROM agent.mastra_threads WHERE id = $1 AND metadata->>'kind' = 'dahlia-chat'", [threadId]);
      if (thread.rowCount) await enqueue(client, identity.userId, threadId);
    }),
    /** Rewrites chunks of messages whose text or analyzer changed; returns whether more messages remain. */
    async index(userId: string, threadId: string, application: SearchAnalyzer, after?: string): Promise<string | undefined> {
      const current = await analyzer(application);
      return withIdentityTransaction(pool, as(userId), async (client) => {
        const { rows: [thread] } = await client.query<{ workspaceId: string | null }>(`SELECT metadata->>'workspaceId' AS "workspaceId"
          FROM agent.mastra_threads WHERE id = $1 AND metadata->>'kind' = 'dahlia-chat'`, [threadId]);
        if (!thread?.workspaceId) return undefined;
        const { rows } = await client.query<{ id: string; role: string; content: string; createdAt: Date; analyzer: string | null; hash: string | null }>(
          `SELECT m.id, m.role, m.content, COALESCE(m."createdAtZ", m."createdAt") AS "createdAt", c.analyzer, c.content_hash AS hash
          FROM agent.mastra_messages m LEFT JOIN agent.session_search_chunks c ON c.message_id = m.id AND c.chunk_no = 0
          WHERE m.thread_id = $1 AND m.role IN ('user', 'assistant') AND ($2::text IS NULL OR m.id > $2) ORDER BY m.id LIMIT ${INDEX_PAGE}`,
          [threadId, after ?? null]);
        for (const row of rows) {
          let text = "";
          try { text = messageText(JSON.parse(row.content) as MastraDBMessage["content"]); } catch { /* non-text message */ }
          const hash = await contentHash(text);
          if (row.analyzer === current.id && row.hash === hash) continue;
          await client.query("DELETE FROM agent.session_search_chunks WHERE message_id = $1", [row.id]);
          // Messages without text keep one empty chunk, so reconciliation sees them as indexed.
          for (const [chunkNo, chunk] of (text ? chunkText(text) : [""]).entries()) {
            const searchText = current.tokenizer ? analyzerInput(current, chunk) : "";
            await client.query(`INSERT INTO agent.session_search_chunks (message_id, chunk_no, thread_id, user_id, workspace_id, role, created_at,
              chunk_text, search_text, search_vector, analyzer, content_hash)
              VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, to_tsvector($10::regconfig, $11), $12, $13)`,
            [row.id, chunkNo, threadId, userId, thread.workspaceId, row.role, row.createdAt, chunk, searchText,
              current.config, current.tokenizer ? searchText : chunk, current.id, hash]);
          }
        }
        return rows.length === INDEX_PAGE ? rows.at(-1)!.id : undefined;
      });
    },
    async pendingEmbeddings(userId: string, threadId: string, config: EmbeddingConfig, limit: number): Promise<SessionChunk[]> {
      return withIdentityTransaction(pool, as(userId), async (client) => (await client.query<SessionChunk>(`SELECT message_id AS "messageId",
        chunk_no AS "chunkNo", chunk_text AS text, content_hash AS hash FROM agent.session_search_chunks
        WHERE thread_id = $1 AND ${staleEmbedding(config, 2)} ORDER BY message_id, chunk_no LIMIT $4`,
      [threadId, config.model, config.dimensions, limit])).rows);
    },
    async saveEmbeddings(userId: string, model: string, rows: Array<SessionChunk & { vector: number[] }>) {
      await withIdentityTransaction(pool, as(userId), async (client) => {
        for (const row of rows) await client.query(`UPDATE agent.session_search_chunks SET embedding = $1, embedding_model = $2
          WHERE message_id = $3 AND chunk_no = $4 AND content_hash = $5`, [row.vector, model, row.messageId, row.chunkNo, row.hash]);
      });
    },
    /** Queues threads with messages missing chunks of the current analyzer or current embeddings, 100 threads at a time. */
    async reconcilePage(userId: string, application: SearchAnalyzer, after?: string): Promise<string | undefined> {
      const current = await analyzer(application);
      return withIdentityTransaction(pool, as(userId), async (client) => {
        const values: unknown[] = [current.id, after ?? null];
        const stale = embedding ? `OR (EXISTS (SELECT 1 FROM agent.session_search_chunks c WHERE c.thread_id = t.id AND ${staleEmbedding(embedding, 3)})
          AND NOT EXISTS (SELECT 1 FROM jobs.queue q WHERE q.dedupe_key = 'memory-index:session:' || t.id AND q.payload->>'model' = $3))` : "";
        if (embedding) values.push(embedding.model, embedding.dimensions);
        const { rows } = await client.query<{ id: string }>(`SELECT t.id FROM agent.mastra_threads t
          WHERE t.metadata->>'kind' = 'dahlia-chat' AND ($2::text IS NULL OR t.id > $2) AND (EXISTS (SELECT 1 FROM agent.mastra_messages m
            WHERE m.thread_id = t.id AND m.role IN ('user', 'assistant') AND NOT EXISTS (SELECT 1 FROM agent.session_search_chunks c
              WHERE c.message_id = m.id AND c.analyzer = $1)) ${stale})
          ORDER BY t.id LIMIT 100`, values);
        for (const { id } of rows) await enqueue(client, userId, id);
        return rows.length === 100 ? rows.at(-1)!.id : undefined;
      });
    },
    /** Hybrid search of the caller's saved chats in the given readable Workspaces; chunk hits collapse to their message. */
    async search(identity: Identity, query: string, workspaceIds: readonly string[], application: SearchAnalyzer, limit: number,
      vector?: number[]): Promise<{ hits: SessionHit[]; partial: boolean }> {
      if (!workspaceIds.length) return { hits: [], partial: false };
      const current = await analyzer(application);
      return withIdentityTransaction(pool, identity, async (client) => {
        const input = current.tokenizer ? queryTokens(current, query).join(" ") : query;
        const lexemes = input ? (await client.query<{ lexeme: string }>(`SELECT lexeme FROM unnest(to_tsvector($1::regconfig, $2))
          ORDER BY positions[1] NULLS LAST, lexeme LIMIT 16`, [current.config, input])).rows.map((row) => row.lexeme) : [];
        const scope = "user_id = $1 AND workspace_id = ANY($2::uuid[]) AND EXISTS (SELECT 1 FROM agent.mastra_threads t WHERE t.id = thread_id AND t.metadata->>'kind' = 'dahlia-chat')";
        let lexical: string[] = [];
        if (lexemes.length) {
          let rank = "-ts_rank_cd(search_vector, $4::tsquery)";
          if (backend === "lakebase") {
            await client.query("SELECT set_config('lakebase_bm25.prefilter', 'on', true), set_config('lakebase_bm25.enable_scan', 'false', true)");
            rank = "search_vector <@> to_bm25query(array_to_tsvector($5::text[]), 'agent.session_search_chunks_bm25'::regclass)";
          }
          lexical = (await client.query<{ messageId: string }>(`SELECT message_id AS "messageId" FROM agent.session_search_chunks
            WHERE ${scope} AND analyzer = $3 AND search_vector @@ $4::tsquery ORDER BY ${rank}, message_id, chunk_no LIMIT ${SEARCH_CANDIDATE_LIMIT}`,
          [identity.userId, workspaceIds, current.id, lexemeQuery(lexemes, current.matchAll), ...(backend === "lakebase" ? [lexemes] : [])])).rows.map((row) => row.messageId);
        }
        let semantic: string[] = [];
        if (vector && embedding) {
          const type = `public.vector(${embedding.dimensions})`;
          semantic = (await client.query<{ messageId: string }>(`SELECT message_id AS "messageId" FROM agent.session_search_chunks
            WHERE ${scope} AND chunk_text <> '' AND embedding_model = $3 AND cardinality(embedding) = $4
            ORDER BY embedding::${type} <=> $5::${type}, message_id LIMIT ${SEARCH_CANDIDATE_LIMIT}`,
          [identity.userId, workspaceIds, embedding.model, embedding.dimensions, JSON.stringify(vector)])).rows.map((row) => row.messageId);
        }
        const ids = reciprocalRankFusion([...new Set(lexical)], [...new Set(semantic)]).slice(0, limit).map(({ documentId }) => documentId);
        // Lexical results are partial while messages of this thread set lack chunks of the current analyzer.
        const { rows: [gap] } = await client.query<{ partial: boolean }>(`SELECT EXISTS (SELECT 1 FROM agent.mastra_messages m
          JOIN agent.mastra_threads t ON t.id = m.thread_id WHERE t."resourceId" = $1 AND t.metadata->>'kind' = 'dahlia-chat'
            AND t.metadata->>'workspaceId' = ANY($2::text[]) AND m.role IN ('user', 'assistant')
            AND NOT EXISTS (SELECT 1 FROM agent.session_search_chunks c WHERE c.message_id = m.id AND c.analyzer = $3)) AS partial`,
        [identity.userId, workspaceIds, current.id]);
        if (!ids.length) return { hits: [], partial: Boolean(gap?.partial) };
        const { rows } = await client.query<SessionHit>(`SELECT DISTINCT ON (c.message_id) c.thread_id AS "threadId", t.title,
          c.workspace_id AS "workspaceId", c.message_id AS "messageId", c.role, c.created_at AS "createdAt", c.chunk_text AS text
          FROM agent.session_search_chunks c JOIN agent.mastra_threads t ON t.id = c.thread_id
          WHERE c.message_id = ANY($1::text[]) ORDER BY c.message_id, c.chunk_no`, [ids]);
        const byId = new Map(rows.map((row) => [row.messageId, row]));
        return { hits: ids.flatMap((id) => byId.get(id) ?? []), partial: Boolean(gap?.partial) };
      });
    },
  };
}
export type SessionSearchStore = ReturnType<typeof createSessionSearchStore>;
