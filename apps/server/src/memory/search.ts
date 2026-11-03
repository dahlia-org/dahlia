import { and, asc, eq, exists, gt, inArray, isNull, ne, notExists, or, sql, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as pg from "../db/auth-schema";
import { enqueueJob, payloadField } from "../jobs/state";
import { chunkText } from "../search/chunk";
import {
  analyzerInput, contentHash, cosineSimilarity, decodeFloat32, encodeFloat32, fts5Query, lexemeQuery, queryTokens, type SearchAnalyzer,
} from "../search/lexical";
import { reciprocalRankFusion, SEARCH_CANDIDATE_LIMIT } from "../search/ranking";

export type SearchBackend = "postgres" | "lakebase" | "sqlite";
export interface EmbeddingConfig { model: string; dimensions: number }
export interface PendingChunk { chunkNo: number; text: string; hash: string }
type Schema = typeof pg;
type Note = typeof pg.sharedMemory.$inferSelect;

/** Strings a lexical query matches against: the analyzer's query lexemes. */
async function queryLexemes(tx: NodePgDatabase, backend: SearchBackend, analyzer: SearchAnalyzer, query: string): Promise<string[]> {
  if (backend === "sqlite") return queryTokens(analyzer, query);
  const input = analyzer.tokenizer ? queryTokens(analyzer, query).join(" ") : query;
  if (!input) return [];
  // The index side applies the same configuration, so query lexemes match stored lexemes exactly.
  const result = await tx.execute<{ lexeme: string }>(sql`SELECT lexeme FROM unnest(to_tsvector(${analyzer.config}::regconfig, ${input}))
    ORDER BY positions[1] NULLS LAST, lexeme LIMIT 16`);
  return result.rows.map((row) => row.lexeme);
}

function searchVectorSql(analyzer: SearchAnalyzer, chunkTextValue: string, searchText: string): SQL {
  return analyzer.tokenizer ? sql`to_tsvector('simple', ${searchText})` : sql`to_tsvector(${analyzer.config}::regconfig, ${chunkTextValue})`;
}

/** Search projection of one Memory store table; every function runs inside the caller's authorized transaction. */
export function memoryProjection(schema: Schema, backend: SearchBackend, personal: boolean) {
  const isPostgres = backend !== "sqlite";
  const notes = personal ? schema.personalMemory : schema.sharedMemory;
  const chunks = personal ? schema.personalMemoryChunk : schema.sharedMemoryChunk;
  const table = personal ? "personal_memory_chunks" : "shared_memory_chunks";
  const source = personal ? "personal" as const : "workspace" as const;
  const jobKey = (id: string) => `memory-index:${source}:${id}`;
  const embeddingStale = (embedding: EmbeddingConfig) => and(ne(chunks.chunkText, ""), or(isNull(chunks.embedding), isNull(chunks.embeddingModel),
    ne(chunks.embeddingModel, embedding.model), sql`${isPostgres ? sql`cardinality(${chunks.embedding})` : sql`length(${chunks.embedding}) / 4`} <> ${embedding.dimensions}`));
  const hasCurrentChunk = (tx: NodePgDatabase, analyzer: SearchAnalyzer) => tx.select({ value: sql`1` }).from(chunks)
    .where(and(eq(chunks.memoryId, notes.id), eq(chunks.analyzer, analyzer.id)));

  /** Replaces the memory's chunks unless they already match its content and the analyzer; queues their embeddings. */
  async function index(tx: NodePgDatabase, note: Pick<Note, "id" | "scopeId" | "content">, analyzer: SearchAnalyzer, embedding?: EmbeddingConfig) {
    const hash = await contentHash(note.content);
    const [current] = await tx.select({ analyzer: chunks.analyzer, contentHash: chunks.contentHash }).from(chunks)
      .where(eq(chunks.memoryId, note.id)).limit(1);
    if (current?.analyzer === analyzer.id && current.contentHash === hash) return;
    await tx.delete(chunks).where(eq(chunks.memoryId, note.id));
    await tx.insert(chunks).values(chunkText(note.content).map((text, chunkNo) => {
      const searchText = analyzer.tokenizer ? analyzerInput(analyzer, text) : "";
      return { memoryId: note.id, chunkNo, scopeId: note.scopeId, chunkText: text, searchText, analyzer: analyzer.id, contentHash: hash,
        ...(isPostgres ? { searchVector: searchVectorSql(analyzer, text, searchText) as never } : {}) };
    }));
    if (embedding) await enqueueJob(tx, schema, jobKey(note.id), "memory-index", note.scopeId, `memory:${note.id}`,
      { source, scopeId: note.scopeId, documentId: note.id, ...embedding });
  }

  async function lexicalIds(tx: NodePgDatabase, scopeId: string, analyzer: SearchAnalyzer, lexemes: string[]): Promise<string[]> {
    if (!lexemes.length) return [];
    const scope = and(eq(chunks.scopeId, scopeId), eq(chunks.analyzer, analyzer.id));
    if (!isPostgres) {
      const fts = sql.identifier(`${table}_fts`);
      const rows = await tx.select({ id: chunks.memoryId }).from(chunks)
        .where(and(scope, sql`${chunks}.rowid IN (SELECT rowid FROM ${fts} WHERE ${fts} MATCH ${fts5Query(lexemes, analyzer.matchAll)})`))
        .orderBy(sql`(SELECT bm25(${fts}) FROM ${fts} WHERE rowid = ${chunks}.rowid AND ${fts} MATCH ${fts5Query(lexemes, analyzer.matchAll)})`, asc(chunks.memoryId))
        .limit(SEARCH_CANDIDATE_LIMIT);
      return [...new Set(rows.map((row) => row.id))];
    }
    const query = sql`${lexemeQuery(lexemes, analyzer.matchAll)}::tsquery`;
    let rank: SQL;
    if (backend === "lakebase") {
      // Mirrors meeting search: score every row that passes the filter instead of a BM25 index scan.
      await tx.execute(sql`select set_config('lakebase_bm25.prefilter', 'on', true), set_config('lakebase_bm25.enable_scan', 'false', true)`);
      rank = sql`${chunks.searchVector} <@> to_bm25query(array_to_tsvector(ARRAY[${sql.join(lexemes.map((lexeme) => sql`${lexeme}`), sql`, `)}]::text[]), ${`search.${table}_bm25`}::regclass)`;
    } else rank = sql`-ts_rank_cd(${chunks.searchVector}, ${query})`;
    const rows = await tx.select({ id: chunks.memoryId }).from(chunks).where(and(scope, sql`${chunks.searchVector} @@ ${query}`))
      .orderBy(rank, asc(chunks.memoryId), asc(chunks.chunkNo)).limit(SEARCH_CANDIDATE_LIMIT);
    return [...new Set(rows.map((row) => row.id))];
  }

  async function vectorIds(tx: NodePgDatabase, scopeId: string, embedding: EmbeddingConfig & { vector: number[] }): Promise<string[]> {
    const current = and(eq(chunks.scopeId, scopeId), eq(chunks.embeddingModel, embedding.model), ne(chunks.chunkText, ""),
      sql`${isPostgres ? sql`cardinality(${chunks.embedding})` : sql`length(${chunks.embedding}) / 4`} = ${embedding.dimensions}`);
    if (!isPostgres) {
      // shortcut: exact cosine over the scope's chunks; SQLite has no vector index.
      const rows = await tx.select({ id: chunks.memoryId, vector: chunks.embedding }).from(chunks).where(current);
      return [...new Set(rows.map(({ id, vector }) => ({ id, similarity: cosineSimilarity(decodeFloat32(vector), embedding.vector) }))
        .filter(({ similarity }) => Number.isFinite(similarity))
        .sort((left, right) => right.similarity - left.similarity || left.id.localeCompare(right.id))
        .slice(0, SEARCH_CANDIDATE_LIMIT).map(({ id }) => id))];
    }
    const type = sql.raw(`public.vector(${embedding.dimensions})`);
    const distance = sql`${chunks.embedding}::${type} <=> ${JSON.stringify(embedding.vector)}::${type}`;
    const rows = await tx.select({ id: chunks.memoryId }).from(chunks).where(current)
      .orderBy(distance, asc(chunks.memoryId)).limit(SEARCH_CANDIDATE_LIMIT);
    return [...new Set(rows.map((row) => row.id))];
  }

  // Memories without chunks of the current analyzer (before reconciliation) fall back to the canonical substring match.
  async function unindexedIds(tx: NodePgDatabase, scopeId: string, analyzer: SearchAnalyzer, terms: string[]): Promise<string[]> {
    const matches: Array<{ id: string; count: number; updatedAt: Date }> = [];
    for (let after: string | undefined; ;) {
      const page = await tx.select({ id: notes.id, content: notes.content, updatedAt: notes.updatedAt }).from(notes)
        .where(and(eq(notes.scopeId, scopeId), notExists(hasCurrentChunk(tx, analyzer)), after ? gt(notes.id, after) : undefined))
        .orderBy(asc(notes.id)).limit(500);
      for (const note of page) {
        const text = note.content.normalize("NFKC").toLowerCase();
        const count = terms.filter((term) => text.includes(term)).length;
        if (count) matches.push({ id: note.id, count, updatedAt: note.updatedAt });
      }
      if (page.length < 500) break;
      after = page.at(-1)!.id;
    }
    return matches.sort((a, b) => b.count - a.count || b.updatedAt.getTime() - a.updatedAt.getTime() || b.id.localeCompare(a.id))
      .slice(0, SEARCH_CANDIDATE_LIMIT).map(({ id }) => id);
  }

  return {
    index,
    /** Hybrid recall: lexical and vector candidates per best chunk, fused with RRF, then the canonical rows. */
    async search(tx: NodePgDatabase, scopeId: string, query: string, analyzer: SearchAnalyzer, limit: number,
      embedding?: EmbeddingConfig & { vector: number[] }): Promise<Note[]> {
      const lexemes = await queryLexemes(tx, backend, analyzer, query);
      const terms = [...new Set([...lexemes, ...query.normalize("NFKC").toLowerCase().split(/\s+/u).filter(Boolean)])].slice(0, 32);
      const lexical = [...new Set([...await lexicalIds(tx, scopeId, analyzer, lexemes), ...await unindexedIds(tx, scopeId, analyzer, terms)])];
      const vector = embedding ? await vectorIds(tx, scopeId, embedding) : [];
      const ids = reciprocalRankFusion(lexical, vector).slice(0, limit).map(({ documentId }) => documentId);
      if (!ids.length) return [];
      const rows = await tx.select().from(notes).where(and(eq(notes.scopeId, scopeId), inArray(notes.id, ids)));
      const byId = new Map(rows.map((row) => [row.id, row]));
      return ids.flatMap((id) => byId.get(id) ?? []);
    },
    async pending(tx: NodePgDatabase, memoryId: string, embedding: EmbeddingConfig): Promise<PendingChunk[]> {
      return (await tx.select({ chunkNo: chunks.chunkNo, text: chunks.chunkText, hash: chunks.contentHash }).from(chunks)
        .where(and(eq(chunks.memoryId, memoryId), embeddingStale(embedding))).orderBy(asc(chunks.chunkNo)));
    },
    async saveEmbeddings(tx: NodePgDatabase, memoryId: string, model: string, rows: Array<PendingChunk & { vector: number[] }>) {
      for (const row of rows) {
        // The content hash discards a vector computed for text that changed meanwhile.
        await tx.update(chunks).set({ embedding: (isPostgres ? row.vector : encodeFloat32(row.vector)) as never, embeddingModel: model })
          .where(and(eq(chunks.memoryId, memoryId), eq(chunks.chunkNo, row.chunkNo), eq(chunks.contentHash, row.hash)));
      }
    },
    /** Rebuilds chunks of another analyzer and queues missing embeddings, 100 memories at a time. */
    async reconcilePage(tx: NodePgDatabase, scopeId: string, analyzer: SearchAnalyzer, embedding: EmbeddingConfig | undefined, after?: string) {
      const q = schema.backgroundJob;
      const queued = tx.select({ value: sql`1` }).from(q).where(and(eq(q.dedupeKey, sql`${`memory-index:${source}:`} || ${notes.id}`),
        embedding ? eq(payloadField(schema, "model"), embedding.model) : undefined));
      const needsEmbedding = embedding ? and(notExists(queued), exists(tx.select({ value: sql`1` }).from(chunks)
        .where(and(eq(chunks.memoryId, notes.id), embeddingStale(embedding))))) : sql`false`;
      const page = await tx.select({ id: notes.id, scopeId: notes.scopeId, content: notes.content, indexed: sql<unknown>`${exists(hasCurrentChunk(tx, analyzer))}` })
        .from(notes).where(and(eq(notes.scopeId, scopeId), or(notExists(hasCurrentChunk(tx, analyzer)), needsEmbedding), after ? gt(notes.id, after) : undefined))
        .orderBy(asc(notes.id)).limit(100);
      for (const note of page) {
        if (!note.indexed) await index(tx, note, analyzer, embedding);
        else if (embedding) await enqueueJob(tx, schema, jobKey(note.id), "memory-index", note.scopeId, `memory:${note.id}`,
          { source, scopeId: note.scopeId, documentId: note.id, ...embedding });
      }
      return page.length === 100 ? page.at(-1)!.id : undefined;
    },
  };
}
export type MemoryProjection = ReturnType<typeof memoryProjection>;
