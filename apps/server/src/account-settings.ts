import { eq, sql, type SQL } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { PostgresDatabase, SQLiteDatabase } from "./db/client";
import * as postgresSchema from "./db/auth-schema";
import * as sqliteSchema from "./db/sqlite-schema";

import { accountSettingsSchema, DEFAULT_ACCOUNT_SETTINGS, type AccountSettings, type AccountSettingsPatch } from "./account-settings-model";
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
      processing: table.processing,
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
      const remote = { ...DEFAULT_ACCOUNT_SETTINGS.processing.remote, ...patch.processing?.remote };
      for (const key of ["summaryModel", "transcriptionModel", "reasoningEffort"] as const) {
        if (remote[key] === null) delete remote[key];
      }
      const values = {
        userId, outputLanguage: patch.outputLanguage ?? DEFAULT_ACCOUNT_SETTINGS.outputLanguage,
        analysisLanguages: patch.analysisLanguages ?? DEFAULT_ACCOUNT_SETTINGS.analysisLanguages,
        summary: { ...DEFAULT_ACCOUNT_SETTINGS.summary, ...patch.summary },
        processing: { location: patch.processing?.location ?? DEFAULT_ACCOUNT_SETTINGS.processing.location,
          remote: remote as AccountSettings["processing"]["remote"] },
      };
      // Update only supplied leaves against the locked current row, never a fetched snapshot.
      const documents = { summary: sql`${table.summary}`, processing: sql`${table.processing}` };
      const differences: SQL[] = [];
      const setLeaf = (document: keyof typeof documents, path: string[], value: string | null) => {
        const column = table[document];
        const current = documents[document];
        if (isPostgres) {
          const jsonPath = sql`ARRAY[${sql.join(path.map((part) => sql`${part}`), sql`, `)}]::text[]`;
          if (value === null) {
            differences.push(sql`${column} #> ${jsonPath} IS NOT NULL`);
            documents[document] = sql`${current} #- ${jsonPath}`;
          } else {
            differences.push(sql`${column} #>> ${jsonPath} IS DISTINCT FROM ${value}`);
            documents[document] = sql`jsonb_set(${current}, ${jsonPath}, ${JSON.stringify(value)}::jsonb)`;
          }
          return;
        }
        const jsonPath = "$." + path.join(".");
        if (value === null) {
          differences.push(sql`json_type(${column}, ${jsonPath}) IS NOT NULL`);
          documents[document] = sql`json_remove(${current}, ${jsonPath})`;
        } else {
          differences.push(sql`json_extract(${column}, ${jsonPath}) IS NOT ${value}`);
          documents[document] = sql`json_set(${current}, ${jsonPath}, ${value})`;
        }
      };
      if (patch.summary?.style !== undefined) setLeaf("summary", ["style"], patch.summary.style);
      if (patch.processing?.location !== undefined) setLeaf("processing", ["location"], patch.processing.location);
      for (const [key, value] of Object.entries(patch.processing?.remote ?? {})) setLeaf("processing", ["remote", key], value);
      if (patch.outputLanguage !== undefined) differences.push(sql`${table.outputLanguage} <> ${patch.outputLanguage}`);
      if (patch.analysisLanguages !== undefined) differences.push(isPostgres
        ? sql`${table.analysisLanguages} IS DISTINCT FROM ${JSON.stringify(patch.analysisLanguages)}::jsonb`
        : sql`json(${table.analysisLanguages}) <> json(${JSON.stringify(patch.analysisLanguages)})`);
      const changes = {
        ...(patch.outputLanguage !== undefined ? { outputLanguage: patch.outputLanguage } : {}),
        ...(patch.analysisLanguages !== undefined ? { analysisLanguages: patch.analysisLanguages } : {}),
        ...(patch.summary !== undefined ? { summary: documents.summary } : {}),
        ...(patch.processing !== undefined ? { processing: documents.processing } : {}),
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
