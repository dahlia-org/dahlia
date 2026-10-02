import { beginSyncTiming, type SyncTimingPhase } from "./diagnostics";
import { sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

export type SyncLockMode = "shared" | "exclusive";

/** Transaction-scoped locks. The authorization key and lifecycle key retain old-server compatibility. */
export function createSyncLocks(db: NodePgDatabase, postgres: boolean) {
  const held = new Map<string, SyncLockMode>();
  function needsLock(key: string, mode: SyncLockMode): boolean {
    const previous = held.get(key);
    if (previous === "exclusive" || previous === mode) return false;
    if (previous) throw new Error("sync_lock_upgrade");
    return true;
  }
  async function acquire(key: string, mode: SyncLockMode, phase: SyncTimingPhase) {
    if (!postgres || !needsLock(key, mode)) return;
    const value = key === "authorization" ? sql`75047176522050` : sql`hashtextextended(${key}, 0)`;
    const finish = beginSyncTiming(phase);
    try { await db.execute(mode === "shared" ? sql`select pg_advisory_xact_lock_shared(${value})` : sql`select pg_advisory_xact_lock(${value})`); }
    finally { finish(); }
    held.set(key, mode);
  }
  return {
    authorization: (mode: SyncLockMode = "shared") => acquire("authorization", mode, "authorizationLock"),
    async workspace(id: string, lifecycle: SyncLockMode = "shared", authorization: SyncLockMode = "shared") {
      await acquire("authorization", authorization, "authorizationLock");
      await acquire(`workspace:${id}`, lifecycle, "workspaceLock");
    },
    // Shared compatibility gate: old domain writers remain mutually exclusive with new writers.
    domain: (id: string, mode: SyncLockMode = "exclusive") => acquire(`domain:${id}`, mode, "domainLock"),
    publication: (id: string, mode: SyncLockMode) => acquire(`publication:${id}`, mode, "publicationLock"),
    async resources(resources: ReadonlyMap<string, SyncLockMode>) {
      if (!postgres) return;
      const pending = [...resources].toSorted(([a], [b]) => a.localeCompare(b))
        .filter(([key, mode]) => needsLock(key, mode));
      if (!pending.length) return;
      const finish = beginSyncTiming("resourceLock");
      try {
        // PostgreSQL evaluates these volatile functions after the key sort, in lock order.
        await db.execute(sql`select case when mode = 'exclusive'
          then pg_advisory_xact_lock(hashtextextended(key, 0))
          else pg_advisory_xact_lock_shared(hashtextextended(key, 0)) end
          from jsonb_to_recordset(${JSON.stringify(pending.map(([key, mode]) => ({ key, mode })))}::jsonb)
            as resources(key text, mode text) order by key collate "C"`);
        for (const [key, mode] of pending) held.set(key, mode);
      } finally { finish(); }
    },
    document: (id: string, mode: SyncLockMode) => acquire(`document:${id}`, mode, "documentLock"),
    notes: (meetingId: string, mode: SyncLockMode) => acquire(`notes:${meetingId}`, mode, "notesLock"),
  };
}
export type SyncLocks = ReturnType<typeof createSyncLocks>;
