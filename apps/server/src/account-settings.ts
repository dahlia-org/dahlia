import { eq, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { PostgresDatabase, SQLiteDatabase } from "./db/client";
import * as postgresSchema from "./db/auth-schema";
import * as sqliteSchema from "./db/sqlite-schema";

import { accountSettingsSchema, type AccountSettings, type AccountSettingsPatch } from "./account-settings-model";
export { accountSettingsPatchSchema, DEFAULT_ACCOUNT_SETTINGS, type AccountSettings, type AccountSettingsPatch } from "./account-settings-model";

export interface AccountSettingsStore {
  getRevision(userId: string): Promise<number | null>;
  get(userId: string): Promise<AccountSettings | null>;
  update(userId: string, patch: AccountSettingsPatch, initialize?: boolean): Promise<AccountSettings>;
}

export function createAccountSettingsStore(
  database: PostgresDatabase | SQLiteDatabase,
  isPostgres: boolean,
): AccountSettingsStore {
  const db = database as NodePgDatabase;
  const table = (isPostgres ? postgresSchema : sqliteSchema).accountSettings as typeof postgresSchema.accountSettings;
  const withUser = <T>(userId: string, action: (connection: NodePgDatabase) => Promise<T>) => isPostgres
    ? db.transaction(async (transaction) => {
      await transaction.execute(sql`select set_config('app.user_id', ${userId}, true)`);
      return action(transaction);
    })
    : action(db);
  const read = async (connection: NodePgDatabase, userId: string): Promise<AccountSettings | null> => {
    const [row] = await connection.select({
      analysisLanguages: table.analysisLanguages,
    }).from(table).where(eq(table.userId, userId));
    if (!row) return null;
    return accountSettingsSchema.parse(row);
  };
  return {
    getRevision: (userId) => withUser(userId, async (connection) => {
      const [row] = await connection.select({ revision: table.revision }).from(table).where(eq(table.userId, userId));
      return row?.revision ?? null;
    }),
    get: (userId) => withUser(userId, (connection) => read(connection, userId)),
    update: (userId, patch, initialize = false) => withUser(userId, async (connection) => {
      const values = { userId, analysisLanguages: patch.analysisLanguages };
      const insert = connection.insert(table).values(values);
      if (initialize) await insert.onConflictDoNothing();
      else await insert.onConflictDoUpdate({ target: table.userId, set: {
        analysisLanguages: patch.analysisLanguages, revision: sql`${table.revision} + 1`,
      }, setWhere: isPostgres
        ? sql`${table.analysisLanguages} IS DISTINCT FROM ${JSON.stringify(patch.analysisLanguages)}::jsonb`
        : sql`json(${table.analysisLanguages}) <> json(${JSON.stringify(patch.analysisLanguages)})` });
      return (await read(connection, userId))!;
    }),
  };
}
