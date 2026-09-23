import { and, eq, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";

// Called inside the canonical mutation transaction; no content or external I/O.
export async function enqueueMemorySource(db: NodePgDatabase, schema: typeof Schema, scopeId: string,
  kind: "meeting" | "shared", sourceId: string, reconcile = false) {
  const state = schema.workspaceMemoryState;
  const [workspace] = await db.select({ purge: state.purge }).from(state).where(eq(state.scopeId, scopeId));
  if (!workspace || workspace.purge) return;
  const jobs = schema.memorySourceJob;
  const values = { scopeId, kind, sourceId, documentId: `${kind}-${sourceId}` };
  const insert = db.insert(jobs).values(values);
  const rows = await (reconcile ? insert.onConflictDoNothing() : insert.onConflictDoUpdate({
    target: [jobs.scopeId, jobs.documentId], set: { generation: sql`${jobs.generation} + 1` },
  })).returning();
  if (rows.length) await db.update(state).set({ generation: sql`${state.generation} + 1`, status: "pending",
    availableAt: new Date(), attempts: 0, errorCode: null }).where(and(eq(state.scopeId, scopeId), eq(state.purge, false)));
}
