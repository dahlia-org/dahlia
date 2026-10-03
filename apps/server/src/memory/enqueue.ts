import { cancelJobs, enqueueJob } from "../jobs/state";
import { and, eq, getTableName, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import { memoryDocumentId } from "./ids";

// Called inside the canonical mutation transaction; no content or external I/O.
export async function enqueueMemorySource(db: NodePgDatabase, schema: typeof Schema, scopeId: string,
  kind: "meeting" | "shared", sourceId: string, reconcile = false) {
  const state = schema.workspaceMemoryState;
  const [workspace] = await db.select({ purge: state.purge }).from(state).where(eq(state.scopeId, scopeId));
  if (!workspace || workspace.purge) return;
  const jobs = schema.memorySourceJob;
  const values = { scopeId, kind, sourceId, documentId: memoryDocumentId(kind, sourceId) };
  const insert = db.insert(jobs).values(values);
  const rows = await (reconcile ? insert.onConflictDoNothing() : insert.onConflictDoUpdate({
    target: [jobs.scopeId, jobs.documentId], set: { generation: sql`${jobs.generation} + 1` },
  })).returning();
  if (rows.length) {
    await db.update(state).set({ generation: sql`${state.generation} + 1`, status: "pending" })
      .where(and(eq(state.scopeId, scopeId), eq(state.purge, false)));
    await enqueueMemoryScope(db, schema, scopeId);
  }
}

export async function enqueueMemoryScope(db: NodePgDatabase, schema: typeof Schema, scopeId: string) {
  const [state] = await db.select().from(schema.workspaceMemoryState).where(eq(schema.workspaceMemoryState.scopeId, scopeId));
  if (!state) return;
  const kind = getTableName(schema.workspaceMemoryState).includes("personal") ? "personal-memory" : "workspace-memory";
  if (!state.enabled && !state.purge) {
    await cancelJobs(db, schema, eq(schema.backgroundJob.dedupeKey, `${kind}:${scopeId}`));
    return;
  }
  await enqueueJob(db, schema, `${kind}:${scopeId}`, kind, state.requestedBy,
    `${kind === "workspace-memory" ? "memory" : "personal-memory"}:${scopeId}`, { scopeId });
}
