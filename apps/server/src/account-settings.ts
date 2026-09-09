import { eq, sql, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { PostgresDatabase, SQLiteDatabase } from "./db/client";
import * as postgresSchema from "./db/auth-schema";
import * as sqliteSchema from "./db/sqlite-schema";

import { accountSettingsSchema, normalizeSummaryDetail, DEFAULT_ACCOUNT_SETTINGS, type AccountSettings, type AccountSettingsPatch } from "./account-settings-model";
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
      outputLanguage: table.outputLanguage,
      summary: table.summary,
      analysisLanguages: table.analysisLanguages,
    }).from(table).where(eq(table.userId, userId));
    if (!row) return null;
    return accountSettingsSchema.parse({ ...row, summary: { ...row.summary,
      remote: { ...row.summary.remote, detail: normalizeSummaryDetail(row.summary.remote.detail) } } });
  };
  return {
    getRevision: (userId) => withUser(userId, async (connection) => {
      const [row] = await connection.select({ revision: table.revision }).from(table).where(eq(table.userId, userId));
      return row?.revision ?? null;
    }),
    get: (userId) => withUser(userId, (connection) => read(connection, userId)),
    update: (userId, patch, initialize = false) => withUser(userId, async (connection) => {
      const remotePatch = patch.summary?.remote;
      const remote: AccountSettings["summary"]["remote"] = { ...DEFAULT_ACCOUNT_SETTINGS.summary.remote };
      if (remotePatch?.detail !== undefined) remote.detail = remotePatch.detail;
      if (remotePatch?.model !== undefined) remote.model = remotePatch.model;
      if (remotePatch?.reasoningEffort !== undefined) remote.reasoningEffort = remotePatch.reasoningEffort;
      if (remotePatch?.transcriptionModel === null) delete remote.transcriptionModel;
      else if (remotePatch?.transcriptionModel !== undefined) remote.transcriptionModel = remotePatch.transcriptionModel;
      const values = {
        userId, outputLanguage: patch.outputLanguage ?? DEFAULT_ACCOUNT_SETTINGS.outputLanguage,
        analysisLanguages: patch.analysisLanguages ?? DEFAULT_ACCOUNT_SETTINGS.analysisLanguages,
        summary: { mode: patch.summary?.mode ?? DEFAULT_ACCOUNT_SETTINGS.summary.mode, remote },
      };
      // Update only supplied leaves against the locked current row, never a fetched snapshot.
      let summary: SQL = sql`${table.summary}`;
      const differences: SQL[] = [];
      const setLeaf = (path: string[], value: string | null) => {
        if (isPostgres) {
          const jsonPath = sql`ARRAY[${sql.join(path.map((part) => sql`${part}`), sql`, `)}]::text[]`;
          if (value === null) {
            differences.push(sql`${table.summary} #> ${jsonPath} IS NOT NULL`);
            summary = sql`${summary} #- ${jsonPath}`;
          } else {
            differences.push(sql`${table.summary} #>> ${jsonPath} IS DISTINCT FROM ${value}`);
            summary = sql`jsonb_set(${summary}, ${jsonPath}, ${JSON.stringify(value)}::jsonb)`;
          }
          return;
        }
        const jsonPath = "$." + path.join(".");
        if (value === null) {
          differences.push(sql`json_type(${table.summary}, ${jsonPath}) IS NOT NULL`);
          summary = sql`json_remove(${summary}, ${jsonPath})`;
        } else {
          differences.push(sql`json_extract(${table.summary}, ${jsonPath}) IS NOT ${value}`);
          summary = sql`json_set(${summary}, ${jsonPath}, ${value})`;
        }
      };
      if (patch.summary?.mode !== undefined) setLeaf(["mode"], patch.summary.mode);
      for (const [key, value] of Object.entries(patch.summary?.remote ?? {})) setLeaf(["remote", key], value);
      if (patch.outputLanguage !== undefined) differences.push(sql`${table.outputLanguage} <> ${patch.outputLanguage}`);
      if (patch.analysisLanguages !== undefined) differences.push(isPostgres
        ? sql`${table.analysisLanguages} IS DISTINCT FROM ${JSON.stringify(patch.analysisLanguages)}::jsonb`
        : sql`json(${table.analysisLanguages}) <> json(${JSON.stringify(patch.analysisLanguages)})`);
      const changes = {
        ...(patch.outputLanguage !== undefined ? { outputLanguage: patch.outputLanguage } : {}),
        ...(patch.analysisLanguages !== undefined ? { analysisLanguages: patch.analysisLanguages } : {}),
        ...(patch.summary !== undefined ? { summary } : {}),
        revision: sql`${table.revision} + 1`,
      };
      const insert = connection.insert(table).values(values);
      if (initialize || !differences.length) await insert.onConflictDoNothing();
      else await insert.onConflictDoUpdate({ target: table.userId, set: changes,
        setWhere: sql.join(differences, sql` OR `) });
      return (await read(connection, userId))!;
    }),
  };
}
