import { and, asc, eq, gt, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { SQLiteDatabase } from "../db/client";
import * as postgres from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import { EncryptionError, unwrapDataKey, wrapDataKey, type EncryptionConfig } from "./crypto";

export async function rotateVaultKeys(database: NodePgDatabase | SQLiteDatabase, isPostgres: boolean, config: EncryptionConfig | undefined, apply: boolean) {
  if (!config) throw new EncryptionError();
  const db = database as NodePgDatabase;
  const schema = (isPostgres ? postgres : sqlite) as typeof postgres;
  const counts = { checked: 0, pending: 0, rotated: 0 };
  let afterVault: string | undefined;
  while (true) {
        const page = await db.transaction(async (transaction) => {
          if (isPostgres) await transaction.execute(sql`select set_config('app.maintenance', 'rotation', true)`);
          const rows = await transaction.select().from(schema.vaultKey).where(afterVault ? gt(schema.vaultKey.vaultId, afterVault) : undefined).orderBy(asc(schema.vaultKey.vaultId)).limit(100);
          for (const row of rows) {
            const raw = await unwrapDataKey(config, row.vaultId, row.wrappedKey);
            try {
              counts.checked++;
              if ((JSON.parse(row.wrappedKey) as { keyId: string }).keyId === config.activeKeyId) continue;
              counts.pending++;
              if (!apply) continue;
              const changed = await transaction.update(schema.vaultKey).set({ wrappedKey: await wrapDataKey(config, row.vaultId, raw) })
                .where(and(eq(schema.vaultKey.vaultId, row.vaultId), eq(schema.vaultKey.wrappedKey, row.wrappedKey))).returning({ id: schema.vaultKey.vaultId });
              if (changed.length !== 1) throw new EncryptionError();
              counts.rotated++;
            } finally { raw.fill(0); }
          }
          return rows;
        });
    if (!page.length) return counts;
    afterVault = page.at(-1)!.vaultId;
  }
}
