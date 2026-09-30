import { beginSyncTiming, type SyncTimingPhase } from "./diagnostics";
import { sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

type Mode = "shared" | "exclusive";

/** Transaction-scoped locks. The authorization key and lifecycle key retain old-server compatibility. */
export function createSyncLocks(db: NodePgDatabase, postgres: boolean) {
  const held = new Map<string, Mode>();
  async function acquire(key: string, mode: Mode, phase: SyncTimingPhase) {
    if (!postgres) return;
    const previous = held.get(key);
    if (previous === "exclusive" || previous === mode) return;
    if (previous) throw new Error("sync_lock_upgrade");
    const value = key === "authorization" ? sql`75047176522050` : sql`hashtextextended(${key}, 0)`;
    const finish = beginSyncTiming(phase);
    try { await db.execute(mode === "shared" ? sql`select pg_advisory_xact_lock_shared(${value})` : sql`select pg_advisory_xact_lock(${value})`); }
    finally { finish(); }
    held.set(key, mode);
  }
  return {
    authorization: (mode: Mode = "shared") => acquire("authorization", mode, "authorizationLock"),
    async workspace(id: string, lifecycle: Mode = "shared", authorization: Mode = "shared") {
      await acquire("authorization", authorization, "authorizationLock");
      await acquire(`workspace:${id}`, lifecycle, "workspaceLock");
    },
    domain: (id: string) => acquire(`domain:${id}`, "exclusive", "domainLock"),
    document: (id: string, mode: Mode) => acquire(`document:${id}`, mode, "documentLock"),
    notes: (meetingId: string, mode: Mode) => acquire(`notes:${meetingId}`, mode, "notesLock"),
  };
}
export type SyncLocks = ReturnType<typeof createSyncLocks>;
