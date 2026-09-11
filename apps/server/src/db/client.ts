import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { getLakebasePgConfig, type DriverTelemetry } from "@databricks/lakebase";
import { drizzle } from "drizzle-orm/node-postgres";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/pg-core/async/session";
import { readMigrationFiles, type MigrationConfig, type MigrationMeta } from "drizzle-orm/migrator";
import type { SQLiteAsyncDatabase } from "drizzle-orm/sqlite-core/async";
import type { Pool } from "pg";

import type { AppConfig } from "../config";
import { fileMetadataLimits } from "../files/model";
import { postgresMigrations, serverMigrationManifest, type PostgresMigrationDirectory } from "../migrations";
import { SEARCH_FIELDS } from "../search/settings-model";
import { createPostgresPool, POSTGRES_MIGRATION_SCHEMA } from "./postgres";

export type PostgresDatabase = NodePgDatabase & { $client: Pool };
export type SQLiteDatabase = SQLiteAsyncDatabase<"sync" | "async", unknown>;

const fileMetadataLimitMigration = "20260911023727_file-metadata-limits/migration.sql";
const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

function graphemePrefix(value: string, maximum: number): string {
  let codePoints = 0;
  for (const { index, segment } of graphemeSegmenter.segment(value)) {
    codePoints += Array.from(segment).length;
    if (codePoints > maximum) return value.slice(0, index);
  }
  return value;
}

interface OversizedFileText {
  field: "caption" | "caption_text" | "ocr_text";
  owner_id: string;
  record_id: string;
  target: "files" | "search_documents";
  value: string;
}

export async function stageFileMetadataLimitMigration(client: Pick<Pool, "query">): Promise<void> {
  const applied = await client.query<{ value: boolean }>(`SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = to_regclass('app.files') AND conname = 'files_metadata_ocr_text_length_check'
  ) AS value`);
  if (applied.rows[0]?.value) return;
  await client.query(`CREATE TEMP TABLE IF NOT EXISTS dahlia_file_metadata_limit_values (
    target text NOT NULL, record_id uuid NOT NULL, field_name text NOT NULL, owner_id uuid NOT NULL,
    original text NOT NULL, replacement text NOT NULL,
    PRIMARY KEY (target, record_id, field_name)
  )`);
  const tables = await client.query<{ files: string | null; documents: string | null }>(
    "SELECT to_regclass('app.files')::text AS files, to_regclass('search.documents')::text AS documents",
  );
  if (!tables.rows[0]?.files || !tables.rows[0]?.documents) return;

  const previousUser = await client.query<{ value: string | null }>(
    "SELECT current_setting('app.user_id', true) AS value",
  );
  try {
    const owners = await client.query<{ owner_id: string }>(
      "SELECT DISTINCT principal_id AS owner_id FROM app.vault_permissions WHERE principal_type = 'user' AND role = 'owner'",
    );
    for (const { owner_id } of owners.rows) {
      await client.query("SELECT set_config('app.user_id', $1, false)", [owner_id]);
      const oversized = await client.query<OversizedFileText>(`SELECT 'files' AS target, file_id AS record_id,
          'ocr_text' AS field, $1::uuid AS owner_id, metadata->>'ocr_text' AS value
        FROM app.files WHERE char_length(metadata->>'ocr_text') > $2
        UNION ALL SELECT 'files', file_id, 'caption', $1::uuid, metadata->>'caption'
        FROM app.files WHERE char_length(metadata->>'caption') > $3
        UNION ALL SELECT 'search_documents', document_id, 'ocr_text', $1::uuid, ocr_text
        FROM search.documents WHERE char_length(ocr_text) > $2
        UNION ALL SELECT 'search_documents', document_id, 'caption_text', $1::uuid, caption_text
        FROM search.documents WHERE char_length(caption_text) > $3`, [
        owner_id, fileMetadataLimits.postgres.ocrText, fileMetadataLimits.postgres.caption,
      ]);
      for (const row of oversized.rows) {
        const maximum = row.field === "caption" || row.field === "caption_text"
          ? fileMetadataLimits.postgres.caption : fileMetadataLimits.postgres.ocrText;
        await client.query(`INSERT INTO dahlia_file_metadata_limit_values
          (target, record_id, field_name, owner_id, original, replacement) VALUES ($1, $2, $3, $4, $5, $6)
          ON CONFLICT (target, record_id, field_name) DO UPDATE
          SET owner_id = excluded.owner_id, original = excluded.original, replacement = excluded.replacement`, [
          row.target, row.record_id, row.field, row.owner_id, row.value, graphemePrefix(row.value, maximum),
        ]);
      }
    }
  } finally {
    await client.query("SELECT set_config('app.user_id', $1, false)", [previousUser.rows[0]?.value ?? ""]);
  }
}

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
    return createPostgresPool(getLakebasePgConfig({
      database: database.database,
      endpoint: database.endpoint,
      host: database.host,
      max,
      port: database.port,
      sslMode: database.sslMode,
      user: database.username,
    }, noOpLakebaseTelemetry), max);
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
      migrationsSchema: POSTGRES_MIGRATION_SCHEMA,
      migrationsTable: `__dahlia_${id}_migrations`,
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
  migrationDirectories: readonly PostgresMigrationDirectory[] = postgresMigrations(serverMigrationManifest),
): Promise<void> {
  const pool = createDatabasePool(config, 1);
  try {
    const client = await pool.connect();
    let connectionError: Error | undefined;
    client.on("error", (error: Error) => { connectionError = error; });
    const database = drizzle({ client });
    const lockId = "75047176522049";
    let locked = false;
    try {
      // Advisory locks belong to a session; never reconnect midway through migration.
      await client.query("SELECT pg_advisory_lock($1)", [lockId]);
      locked = true;
      await client.query(`CREATE SCHEMA IF NOT EXISTS "${POSTGRES_MIGRATION_SCHEMA}"`);
      const migrationConfigs = postgresMigrationConfigs(migrationDirectories);
      for (const [index, migrationConfig] of migrationConfigs.entries()) {
        const files = migrationDirectories[index]?.files;
        const allowedNames = files && new Set(files.map((file) => file.split("/")[0]));
        const migrations = readPostgresMigrations(migrationConfig)
          .filter((migration) => !allowedNames || allowedNames.has(migration.name));
        if (files?.includes(fileMetadataLimitMigration)) await stageFileMetadataLimitMigration(client);
        await migrate(migrations, database, migrationConfig);
      }
      await ensureSearchIndexes(client, config);
      if (connectionError) throw connectionError;
    } finally {
      try {
        if (locked && !connectionError) await client.query("SELECT pg_advisory_unlock($1)", [lockId]);
      } finally {
        client.release(true);
      }
    }
  } finally {
    await pool.end();
  }
}

export async function ensureSearchIndexes(pool: Pick<Pool, "query">, config: AppConfig): Promise<void> {
  if (config.databaseType === "lakebase") {
    await pool.query("CREATE EXTENSION IF NOT EXISTS lakebase_text");
    await pool.query(
      "CREATE INDEX IF NOT EXISTS search_documents_search_bm25 ON search.documents USING lakebase_bm25 (search_vector)",
    );
    for (const field of SEARCH_FIELDS) {
      await pool.query(`CREATE INDEX IF NOT EXISTS search_documents_${field}_bm25 ON search.documents USING lakebase_bm25 (${field}_vector) WITH (k1 = 1.2, b = 0.75)`);
    }
  } else if (config.databaseType === "postgres") {
    await pool.query(
      "CREATE INDEX IF NOT EXISTS search_documents_search_gin ON search.documents USING gin (search_vector)",
    );
  }
  const embedding = config.searchEmbedding;
  if (!embedding || (config.databaseType !== "postgres" && config.databaseType !== "lakebase")) return;
  const extension = config.databaseType === "lakebase" ? "lakebase_vector CASCADE" : "vector";
  await pool.query(`CREATE EXTENSION IF NOT EXISTS ${extension}`);
  const modelLiteral = (await pool.query<{ value: string }>("select quote_literal($1) as value", [embedding.model])).rows[0]!.value;
  const suffix = createHash("sha256").update(embedding.model).digest("hex").slice(0, 8);
  const method = config.databaseType === "lakebase" ? "lakebase_ann" : "hnsw";
  const vectorType = config.databaseType === "lakebase" ? "vector" : "public.vector";
  const operatorClass = config.databaseType === "lakebase" ? "vector_cosine_ops" : "public.vector_cosine_ops";
  const indexName = `search_documents_${method}_${embedding.dimensions}_${suffix}`;
  await pool.query(`
    CREATE INDEX IF NOT EXISTS ${indexName}
    ON search.documents USING ${method}
      ((embedding::${vectorType}(${embedding.dimensions})) ${operatorClass})
    WHERE embedding_model = ${modelLiteral} AND cardinality(embedding) = ${embedding.dimensions}
  `);
}

/** @deprecated Use connectApplicationDatabase. */
export const connectAuthDatabase = connectApplicationDatabase;
/** @deprecated Use migrateApplicationDatabase. */
export const migrateAuthDatabase = migrateApplicationDatabase;
