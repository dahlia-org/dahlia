import { eq, sql, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { PostgresDatabase, SQLiteDatabase } from "./db/client";
import * as postgresSchema from "./db/auth-schema";
import * as sqliteSchema from "./db/sqlite-schema";

import { accountSettingsSchema, DEFAULT_ACCOUNT_SETTINGS, type AccountSettings, type AccountSettingsPatch } from "./account-settings-model";
export { accountSettingsPatchSchema, DEFAULT_ACCOUNT_SETTINGS, type AccountSettings, type AccountSettingsPatch } from "./account-settings-model";

export interface AccountSettingsStore {
  getChangeVersion(userId: string): Promise<number | null>;
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
      outputLanguage: table.outputLanguage,
      summary: table.summary,
      analysisLanguages: table.analysisLanguages,
    }).from(table).where(eq(table.userId, userId));
    return row ? accountSettingsSchema.parse(row) : null;
  };
  return {
    getChangeVersion: (userId) => withUser(userId, async (connection) => {
      const [row] = await connection.select({ version: table.changeVersion }).from(table).where(eq(table.userId, userId));
      return row?.version ?? null;
    }),
    get: (userId) => withUser(userId, (connection) => read(connection, userId)),
    update: (userId, patch, initialize = false) => withUser(userId, async (connection) => {
      const transcript = patch.summary?.methodSettings?.transcript;
      const audio = patch.summary?.methodSettings?.audio;
      const values = {
        userId, outputLanguage: patch.outputLanguage ?? DEFAULT_ACCOUNT_SETTINGS.outputLanguage,
        analysisLanguages: patch.analysisLanguages ?? DEFAULT_ACCOUNT_SETTINGS.analysisLanguages,
        summary: { ...DEFAULT_ACCOUNT_SETTINGS.summary, ...patch.summary, methodSettings: {
          transcript: { ...DEFAULT_ACCOUNT_SETTINGS.summary.methodSettings.transcript, ...transcript },
          audio: { ...DEFAULT_ACCOUNT_SETTINGS.summary.methodSettings.audio, ...audio },
        } },
      };
      // Update only supplied leaves against the locked current row, never a fetched snapshot.
      let summary: SQL = sql`${table.summary}`;
      const differences: SQL[] = [];
      const setLeaf = (path: string[], value: string) => {
        if (isPostgres) {
          const jsonPath = sql`ARRAY[${sql.join(path.map((part) => sql`${part}`), sql`, `)}]::text[]`;
          differences.push(sql`${table.summary} #>> ${jsonPath} IS DISTINCT FROM ${value}`);
          summary = sql`jsonb_set(${summary}, ${jsonPath}, ${JSON.stringify(value)}::jsonb)`;
        } else {
          const jsonPath = "$." + path.join(".");
          differences.push(sql`json_extract(${table.summary}, ${jsonPath}) IS NOT ${value}`);
          summary = sql`json_set(${summary}, ${jsonPath}, ${value})`;
        }
      };
      if (patch.summary?.method !== undefined) setLeaf(["method"], patch.summary.method);
      if (patch.summary?.detail !== undefined) setLeaf(["detail"], patch.summary.detail);
      for (const [method, fields] of Object.entries(patch.summary?.methodSettings ?? {})) {
        for (const [key, value] of Object.entries(fields)) setLeaf(["methodSettings", method, key], value);
      }
      if (patch.outputLanguage !== undefined) differences.push(sql`${table.outputLanguage} <> ${patch.outputLanguage}`);
      if (patch.analysisLanguages !== undefined) differences.push(isPostgres
        ? sql`${table.analysisLanguages} IS DISTINCT FROM ${JSON.stringify(patch.analysisLanguages)}::jsonb`
        : sql`json(${table.analysisLanguages}) <> json(${JSON.stringify(patch.analysisLanguages)})`);
      const changes = {
        ...(patch.outputLanguage !== undefined ? { outputLanguage: patch.outputLanguage } : {}),
        ...(patch.analysisLanguages !== undefined ? { analysisLanguages: patch.analysisLanguages } : {}),
        ...(patch.summary !== undefined ? { summary } : {}),
        changeVersion: sql`${table.changeVersion} + 1`,
      };
      const insert = connection.insert(table).values(values);
      if (initialize || !differences.length) await insert.onConflictDoNothing();
      else await insert.onConflictDoUpdate({ target: table.userId, set: changes,
        setWhere: sql.join(differences, sql` OR `) });
      return (await read(connection, userId))!;
    }),
  };
}
