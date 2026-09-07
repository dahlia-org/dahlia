import { eq, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { z } from "zod";

import type { PostgresDatabase, SQLiteDatabase } from "./db/client";
import * as postgresSchema from "./db/auth-schema";
import * as sqliteSchema from "./db/sqlite-schema";

const outputLanguage = z.enum(["ja", "en", "zh", "ko", "fr", "de", "es"]);
const analysisLanguages = z.object({
  scope: z.enum(["all", "selected"]),
  identifiers: z.array(z.string().regex(/^[a-z]{2,3}(?:-[A-Z][a-z]{3})?$/)).max(200)
    .transform((values) => [...new Set(values)].sort()),
}).strict().refine((value) => value.scope === "all" || value.identifiers.length > 0);

export const accountSettingsSchema = z.object({ outputLanguage, analysisLanguages }).strict();
export type AccountSettings = z.infer<typeof accountSettingsSchema>;
export const DEFAULT_ACCOUNT_SETTINGS: AccountSettings = {
  outputLanguage: "ja",
  analysisLanguages: { scope: "all", identifiers: [] },
};
export const accountSettingsPatchSchema = accountSettingsSchema.partial().extend({
  initialize: z.boolean().optional(),
}).strict().refine((value) => value.initialize
  ? value.outputLanguage !== undefined && value.analysisLanguages !== undefined
  : value.outputLanguage !== undefined || value.analysisLanguages !== undefined);

export interface AccountSettingsStore {
  get(userId: string): Promise<AccountSettings | null>;
  update(userId: string, patch: Partial<AccountSettings>, initialize?: boolean): Promise<AccountSettings>;
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
      analysisLanguages: table.analysisLanguages,
    }).from(table).where(eq(table.userId, userId));
    return row ? accountSettingsSchema.parse(row) : null;
  };
  return {
    get: (userId) => withUser(userId, (connection) => read(connection, userId)),
    update: (userId, patch, initialize = false) => withUser(userId, async (connection) => {
      const values = { ...DEFAULT_ACCOUNT_SETTINGS, ...patch, userId };
      const insert = connection.insert(table).values(values);
      if (initialize) await insert.onConflictDoNothing();
      else await insert.onConflictDoUpdate({ target: table.userId, set: patch });
      return (await read(connection, userId))!;
    }),
  };
}
