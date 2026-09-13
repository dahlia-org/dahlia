import { and, asc, eq, gt, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { SQLiteDatabase } from "../db/client";
import * as postgres from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { EncryptionError, unwrapDataKey, wrapDataKey, type EncryptionConfig } from "./crypto";

export async function rotateWorkspaceKeys(database: NodePgDatabase | SQLiteDatabase, isPostgres: boolean, config: EncryptionConfig | undefined, apply: boolean) {
  if (!config) throw new EncryptionError();
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgres : sqlite) as typeof postgres;
  const counts = { checked: 0, pending: 0, rotated: 0 };
  let afterWorkspace: string | undefined;
  while (true) {
        const page = await db.transaction(async (transaction) => {
          if (isPostgres) await transaction.execute(sql`select set_config('app.maintenance', 'rotation', true)`);
          const rows = await transaction.select().from(schema.workspaceKey).where(afterWorkspace ? gt(schema.workspaceKey.workspaceId, afterWorkspace) : undefined).orderBy(asc(schema.workspaceKey.workspaceId)).limit(100);
          for (const row of rows) {
            const raw = await unwrapDataKey(config, row.workspaceId, row.wrappedKey);
            try {
              counts.checked++;
              if ((JSON.parse(row.wrappedKey) as { keyId: string }).keyId === config.activeKeyId) continue;
              counts.pending++;
              if (!apply) continue;
              const changed = await transaction.update(schema.workspaceKey).set({ wrappedKey: await wrapDataKey(config, row.workspaceId, raw) })
                .where(and(eq(schema.workspaceKey.workspaceId, row.workspaceId), eq(schema.workspaceKey.wrappedKey, row.wrappedKey))).returning({ id: schema.workspaceKey.workspaceId });
              if (changed.length !== 1) throw new EncryptionError();
              counts.rotated++;
            } finally { raw.fill(0); }
          }
          return rows;
        });
    if (!page.length) return counts;
    afterWorkspace = page.at(-1)!.workspaceId;
  }
}
