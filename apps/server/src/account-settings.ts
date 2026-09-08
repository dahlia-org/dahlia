import { eq, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { z } from "zod";

import type { PostgresDatabase, SQLiteDatabase } from "./db/client";
import * as postgresSchema from "./db/auth-schema";
import * as sqliteSchema from "./db/sqlite-schema";

import { transcriptSettingsSchema } from "./summary/model";

const outputLanguage = z.enum(["ja", "en", "zh", "ko", "fr", "de", "es"]);
const analysisLanguages = z.object({
  scope: z.enum(["all", "selected"]),
  identifiers: z.array(z.string().regex(/^[a-z]{2,3}(?:-[A-Z][a-z]{3})?$/)).max(200)
    .transform((values) => [...new Set(values)].sort()),
}).strict().refine((value) => value.scope === "all" || value.identifiers.length > 0);

const summarySchema = z.object({
  method: z.enum(["transcript", "audio"]),
  methodSettings: z.object({ transcript: transcriptSettingsSchema, audio: transcriptSettingsSchema }).strict(),
}).strict();
export const accountSettingsSchema = z.object({ outputLanguage, analysisLanguages, summary: summarySchema }).strict();
export type AccountSettings = z.infer<typeof accountSettingsSchema>;
export const DEFAULT_ACCOUNT_SETTINGS: AccountSettings = {
  outputLanguage: "ja",
  summary: { method: "transcript", methodSettings: {
    transcript: { model: "gpt-5.4", reasoningEffort: "medium", detail: "detailed" },
    audio: { model: "gemini-3-8-flash", reasoningEffort: "medium", detail: "detailed" },
  } },
  analysisLanguages: { scope: "all", identifiers: [] },
};
export const accountSettingsPatchSchema = z.object({
  outputLanguage: outputLanguage.optional(), analysisLanguages: analysisLanguages.optional(),
  summary: z.object({
    method: z.enum(["transcript", "audio"]).optional(),
    methodSettings: z.object({ transcript: transcriptSettingsSchema.partial().optional(), audio: transcriptSettingsSchema.partial().optional() }).strict().optional(),
  }).strict().optional(),
  initialize: z.boolean().optional(),
}).strict().refine((value) => value.initialize
  ? value.outputLanguage !== undefined && value.analysisLanguages !== undefined
  : Object.keys(value).some((key) => key !== "initialize"));
export type AccountSettingsPatch = Omit<z.infer<typeof accountSettingsPatchSchema>, "initialize">;

export interface AccountSettingsStore {
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
      summaryMethod: table.summaryMethod,
      transcriptSummary: table.transcriptSummary,
      audioSummary: table.audioSummary,
      analysisLanguages: table.analysisLanguages,
    }).from(table).where(eq(table.userId, userId));
    return row ? accountSettingsSchema.parse({ outputLanguage: row.outputLanguage, analysisLanguages: row.analysisLanguages,
      summary: { method: row.summaryMethod, methodSettings: { transcript: row.transcriptSummary, audio: row.audioSummary } } }) : null;
  };
  return {
    get: (userId) => withUser(userId, (connection) => read(connection, userId)),
    update: (userId, patch, initialize = false) => withUser(userId, async (connection) => {
      const transcript = patch.summary?.methodSettings?.transcript;
      const audio = patch.summary?.methodSettings?.audio;
      const values = {
        userId, outputLanguage: patch.outputLanguage ?? DEFAULT_ACCOUNT_SETTINGS.outputLanguage,
        analysisLanguages: patch.analysisLanguages ?? DEFAULT_ACCOUNT_SETTINGS.analysisLanguages,
        summaryMethod: patch.summary?.method ?? DEFAULT_ACCOUNT_SETTINGS.summary.method,
        transcriptSummary: { ...DEFAULT_ACCOUNT_SETTINGS.summary.methodSettings.transcript, ...transcript },
        audioSummary: { ...DEFAULT_ACCOUNT_SETTINGS.summary.methodSettings.audio, ...audio },
      };
      const changes = {
        ...(patch.outputLanguage !== undefined ? { outputLanguage: patch.outputLanguage } : {}),
        ...(patch.analysisLanguages !== undefined ? { analysisLanguages: patch.analysisLanguages } : {}),
        ...(patch.summary?.method !== undefined ? { summaryMethod: patch.summary.method } : {}),
        ...(audio ? { audioSummary: isPostgres
          ? sql`${table.audioSummary} || ${JSON.stringify(audio)}::jsonb`
          : sql`json_patch(${table.audioSummary}, ${JSON.stringify(audio)})` } : {}),
        ...(transcript ? { transcriptSummary: isPostgres
          ? sql`${table.transcriptSummary} || ${JSON.stringify(transcript)}::jsonb`
          : sql`json_patch(${table.transcriptSummary}, ${JSON.stringify(transcript)})` } : {}),
      };
      const insert = connection.insert(table).values(values);
      if (initialize || !Object.keys(changes).length) await insert.onConflictDoNothing();
      else await insert.onConflictDoUpdate({ target: table.userId, set: changes });
      return (await read(connection, userId))!;
    }),
  };
}
