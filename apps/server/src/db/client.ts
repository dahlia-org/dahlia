import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { getLakebasePgConfig, type DriverTelemetry } from "@databricks/lakebase";
import { drizzle } from "drizzle-orm/node-postgres";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/pg-core/async/session";
import { readMigrationFiles, type MigrationConfig, type MigrationMeta } from "drizzle-orm/migrator";
import type { SQLiteAsyncDatabase } from "drizzle-orm/sqlite-core/async";
import pg, { type Pool } from "pg";

import type { AppConfig } from "../config";
import type { PostgresMigrationDirectory } from "../migrations";
import { createPostgresPool } from "./postgres";

export type PostgresDatabase = NodePgDatabase;
export type SQLiteDatabase = SQLiteAsyncDatabase<"sync" | "async", unknown>;

const noOpSpan = {
  end() {},
  recordException() {},
  setAttribute() { return this; },
  setStatus() { return this; },
};
// Lakebase 0.5 instruments SQL even when telemetry is disabled; keep credential refresh without exporting DB content.
const noOpLakebaseTelemetry = {
  tracer: { startActiveSpan: (_name: string, _options: unknown, callback: (span: typeof noOpSpan) => unknown) => callback(noOpSpan) },
  meter: {},
  tokenRefreshDuration: { record() {} },
  queryDuration: { record() {} },
  poolErrors: { add() {} },
} as unknown as DriverTelemetry;

function createDatabasePool(config: AppConfig, max: number): Pool {
  if (config.databaseType === "lakebase") {
    if (!config.lakebaseDatabase) throw new Error("Lakebase configuration is incomplete");
    const database = config.lakebaseDatabase;
    return new pg.Pool(getLakebasePgConfig({
      database: database.database,
      endpoint: database.endpoint,
      host: database.host,
      max,
      port: database.port,
      sslMode: database.sslMode,
      user: database.username,
    }, noOpLakebaseTelemetry));
  }
  if (config.databaseType !== "postgres" || !config.databaseUrl) {
    throw new Error("Node storage supports DAHLIA_DATABASE_TYPE=sqlite, postgres, or lakebase");
  }
  return createPostgresPool(config.databaseUrl, max);
}

export function connectApplicationDatabase(config: AppConfig) {
  const pool = createDatabasePool(config, 5);
  return {
    db: drizzle({ client: pool }),
    close: () => pool.end(),
  };
}

export function postgresMigrationConfigs(migrationDirectories: readonly PostgresMigrationDirectory[]) {
  const ids = new Set<string>();
  return migrationDirectories.map(({ id, path }) => {
    if (!/^[a-z][a-z0-9_]{0,31}$/.test(id)) throw new Error(`Invalid PostgreSQL migration ledger ID: ${id}`);
    if (ids.has(id)) throw new Error(`Duplicate PostgreSQL migration ledger ID: ${id}`);
    ids.add(id);
    return {
      migrationsFolder: path,
      ...(id === "server" ? {} : { migrationsTable: `__dahlia_${id}_migrations` }),
    };
  });
}

interface LegacyJournal {
  dialect: string;
  entries: Array<{ breakpoints: boolean; tag: string; when: number }>;
}

export function readPostgresMigrations(config: MigrationConfig): MigrationMeta[] {
  const journalPath = join(config.migrationsFolder, "meta", "_journal.json");
  if (!existsSync(journalPath)) return readMigrationFiles(config);
  const journal = JSON.parse(readFileSync(journalPath, "utf8")) as LegacyJournal;
  if (journal.dialect !== "postgresql") throw new Error("PostgreSQL migration journal has the wrong dialect");
  return journal.entries.map((entry) => {
    const sql = readFileSync(join(config.migrationsFolder, `${entry.tag}.sql`), "utf8");
    return {
      sql: sql.split("--> statement-breakpoint").map((statement) => statement.trim()).filter(Boolean),
      folderMillis: entry.when,
      hash: createHash("sha256").update(sql).digest("hex"),
      bps: entry.breakpoints,
      name: entry.tag,
    };
  });
}

export async function migrateApplicationDatabase(
  config: AppConfig,
  migrationDirectories: readonly PostgresMigrationDirectory[] = [{ id: "server", path: "./drizzle" }],
): Promise<void> {
  const pool = createDatabasePool(config, 1);
  const database = drizzle({ client: pool });
  const lockId = "75047176522049";
  let locked = false;
  try {
    await pool.query("SELECT pg_advisory_lock($1)", [lockId]);
    locked = true;
    for (const migrationConfig of postgresMigrationConfigs(migrationDirectories)) {
      await migrate(readPostgresMigrations(migrationConfig), database, migrationConfig);
    }
  } finally {
    if (locked) await pool.query("SELECT pg_advisory_unlock($1)", [lockId]);
    await pool.end();
  }
}

/** @deprecated Use connectApplicationDatabase. */
export const connectAuthDatabase = connectApplicationDatabase;
/** @deprecated Use migrateApplicationDatabase. */
export const migrateAuthDatabase = migrateApplicationDatabase;
