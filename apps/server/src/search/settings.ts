import { eq } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { DEFAULT_SEARCH_SETTINGS, searchSettingsSchema, type SearchSettings } from "./settings-model";

export interface SearchSettingsStore {
  get(): Promise<SearchSettings>;
  update(settings: SearchSettings): Promise<SearchSettings>;
}

export function createSearchSettingsStore(database: PostgresDatabase | SQLiteDatabase | NodePgDatabase, isPostgres: boolean): SearchSettingsStore {
  const db = database as NodePgDatabase;
  const table = (isPostgres ? postgresSchema : sqliteSchema).serverSettings as typeof postgresSchema.serverSettings;
  return {
    async get() {
      const [row] = await db.select({ weights: table.searchWeights }).from(table).where(eq(table.id, 1));
      return row ? searchSettingsSchema.parse(row.weights) : { ...DEFAULT_SEARCH_SETTINGS };
    },
    async update(input) {
      const weights = searchSettingsSchema.parse(input);
      await db.insert(table).values({ id: 1, searchWeights: weights })
        .onConflictDoUpdate({ target: table.id, set: { searchWeights: weights } });
      return weights;
    },
  };
}
