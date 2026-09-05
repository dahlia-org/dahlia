import type { MeetingSyncStore, SyncHistoryTarget, SyncRetentionResult } from "./types";
import { SYNC_RETENTION_BATCH_SIZE, SyncStoreUnavailableError } from "./store";

/** Operator-only maintenance. Never called by request handling or startup. */
export async function pruneSyncHistory(store: MeetingSyncStore): Promise<SyncRetentionResult> {
  if (!await store.isAvailable()) throw new SyncStoreUnavailableError();
  const total: SyncRetentionResult = { changesDeleted: 0, receiptsCompacted: 0 };
  let after: SyncHistoryTarget | undefined;
  for (;;) {
    const targets = await store.listHistoryTargets(after);
    if (!targets.length) return total;
    for (const target of targets) {
      for (;;) {
        const batch = await store.pruneHistoryBatch(target);
        total.changesDeleted += batch.changesDeleted;
        total.receiptsCompacted += batch.receiptsCompacted;
        if (batch.changesDeleted < SYNC_RETENTION_BATCH_SIZE && batch.receiptsCompacted < SYNC_RETENTION_BATCH_SIZE) break;
      }
    }
    after = targets.at(-1);
  }
}
