import { and, asc, eq, gt, isNull, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as pg from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { workspacePermissions } from "../auth/workspace-permissions";
import { lockAuthorization } from "../auth/authorization";
import { RequestError } from "../storage/upload";
import { analyzerResolver, applicationAnalyzer, LAKEBASE_TOKENIZER_VERSION_SQL, type SearchAnalyzer } from "../search/lexical";
import { memoryProjection, type EmbeddingConfig, type PendingChunk, type SearchBackend } from "./search";

export type SharedMemory = typeof pg.sharedMemory.$inferSelect;
export type MemoryStore = ReturnType<typeof createMemoryStore>;

// Dahlia Memory store: the canonical saved memories of one personal or Workspace scope.
export function createMemoryStore(database: PostgresDatabase | SQLiteDatabase | NodePgDatabase, isPostgres: boolean, personal = false,
  backend: SearchBackend = isPostgres ? "postgres" : "sqlite", embedding?: EmbeddingConfig) {
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? pg : sqlite) as typeof pg;
  const notes = personal ? schema.personalMemory : schema.sharedMemory;
  const projection = memoryProjection(schema, backend, personal);
  // lakebase_tokenizer when installed, otherwise the runtime's tokenizer.
  const analyzer = analyzerResolver(backend === "lakebase", async () =>
    (await db.execute<{ extversion: string }>(sql.raw(LAKEBASE_TOKENIZER_VERSION_SQL))).rows[0]?.extversion);
  // Background maintenance of one scope's projection, without a user identity for Workspaces.
  const maintenance = <T>(scopeId: string, fn: (tx: NodePgDatabase) => Promise<T>) => db.transaction(async (tx) => {
    if (isPostgres) await tx.execute(personal ? sql`select set_config('app.user_id', ${scopeId}, true)`
      : sql`select set_config('app.maintenance', 'search', true), set_config('app.maintenance_workspace_id', ${scopeId}, true)`);
    return fn(tx);
  });
  const contains = (term: string) => isPostgres ? sql`strpos(lower(${notes.content}), lower(${term})) > 0` : sql`instr(lower(${notes.content}), lower(${term})) > 0`;
  const scoped = <T>(userId: string, scopeId: string, role: "read" | "write" | "admin", fn: (tx: NodePgDatabase) => Promise<T>) =>
    db.transaction(async (tx) => {
      if (isPostgres) await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      // ponytail: reuse the global mutation lock; split by workspace if write throughput requires it.
      if (role !== "read") await lockAuthorization(tx, schema, isPostgres);
      if (personal) {
        if (scopeId !== userId || !(await tx.select({ id: schema.user.id }).from(schema.user).where(eq(schema.user.id, userId))).length) {
          throw new RequestError(404, "memory_scope_not_found");
        }
        return fn(tx);
      }
      const w = schema.syncedWorkspace;
      const [workspace] = await tx.select({ encryption: w.encryption }).from(w).where(and(eq(w.workspaceId, scopeId),
        isNull(w.deletingAt), workspacePermissions(tx, schema, userId)[role](w.workspaceId)));
      if (!workspace) throw new RequestError(404, "workspace_not_found");
      if (workspace.encryption === "server") throw new RequestError(409, "memory_encrypted_workspace_unsupported");
      return fn(tx);
    });
  return {
    async purge(userId: string, scopeId: string) {
      await scoped(userId, scopeId, "admin", (tx) => tx.delete(notes).where(eq(notes.scopeId, scopeId)));
    },
    async listNotes(userId: string, scopeId: string, after?: string, query?: string) {
      return scoped(userId, scopeId, "read", (tx) => tx.select().from(notes).where(and(eq(notes.scopeId, scopeId),
        query ? contains(query) : undefined, after ? gt(notes.id, after) : undefined)).orderBy(asc(notes.id)).limit(100));
    },
    /** Hybrid recall over the scope's search projection; embedding carries the shared query vector. */
    async recall(userId: string, scopeId: string, query: string, application: SearchAnalyzer, limit: number, vector?: number[]) {
      const current = await analyzer(application);
      return scoped(userId, scopeId, "read", (tx) => projection.search(tx, scopeId, query, current, limit,
        vector && embedding ? { ...embedding, vector } : undefined));
    },
    pendingEmbeddings: (scopeId: string, memoryId: string, config: EmbeddingConfig) =>
      maintenance(scopeId, (tx) => projection.pending(tx, memoryId, config)),
    saveEmbeddings: (scopeId: string, memoryId: string, model: string, rows: Array<PendingChunk & { vector?: number[] }>) =>
      maintenance(scopeId, (tx) => projection.saveEmbeddings(tx, memoryId, model, rows)),
    async reconcilePage(scopeId: string, application: SearchAnalyzer, after?: string) {
      const current = await analyzer(application);
      return maintenance(scopeId, (tx) => projection.reconcilePage(tx, scopeId, current, embedding, after));
    },
    async getNote(userId: string, scopeId: string, id: string) {
      return scoped(userId, scopeId, "read", async (tx) => (await tx.select().from(notes)
        .where(and(eq(notes.scopeId, scopeId), eq(notes.id, id))))[0] ?? null);
    },
    async saveNote(userId: string, scopeId: string, input: { id: string; revision: number; content: string },
      actor: "human" | "agent" = "human", explicit = false, application = applicationAnalyzer()) {
      const current = await analyzer(application);
      return scoped(userId, scopeId, "write", async (tx) => {
        const [existing] = await tx.select().from(notes).where(eq(notes.id, input.id));
        if (existing && existing.scopeId !== scopeId) throw new RequestError(409, "memory_revision_conflict");
        if (actor === "agent" && existing?.protected && !explicit) throw new RequestError(409, "memory_human_edit_protected");
        if (existing?.content === input.content && existing.revision === input.revision + 1
          && (actor !== "human" || existing.protected)) return existing;
        let result: SharedMemory | undefined;
        if (input.revision === 0) {
          [result] = await tx.insert(notes).values({ id: input.id, scopeId, createdBy: userId, content: input.content, protected: actor === "human", updatedAt: new Date() })
            .onConflictDoNothing().returning();
        } else {
          [result] = await tx.update(notes).set({ content: input.content, revision: input.revision + 1, protected: actor === "human" || existing?.protected === true, updatedAt: new Date() })
            .where(and(eq(notes.id, input.id), eq(notes.scopeId, scopeId), eq(notes.revision, input.revision))).returning();
        }
        if (!result) throw new RequestError(409, "memory_revision_conflict");
        // The projection commits with the memory; embeddings follow asynchronously.
        await projection.index(tx, result, current, embedding);
        return result;
      });
    },
    async deleteNote(userId: string, scopeId: string, id: string, revision: number) {
      await scoped(userId, scopeId, "write", async (tx) => {
        const rows = await tx.delete(notes).where(and(eq(notes.scopeId, scopeId), eq(notes.id, id), eq(notes.revision, revision))).returning();
        if (!rows.length) throw new RequestError(409, "memory_revision_conflict");
      });
    },
  };
}
