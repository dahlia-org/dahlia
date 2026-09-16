import { drizzle } from "drizzle-orm/node-postgres";
import { Pool, type PoolConfig } from "pg";

export const POSTGRES_MIGRATION_SCHEMA = "drizzle";
export const POSTGRES_SEARCH_PATH = "app,auth,public";

type PostgresExtension = "vector" | "pg_trgm" | "lakebase_text" | "lakebase_vector";

export async function ensurePublicExtensions(database: Pick<Pool, "query">, extensions: readonly PostgresExtension[]): Promise<void> {
  if (!extensions.length) return;
  // Shared with apps/hindsight/scripts/start_databricks.py so first startup order does not matter.
  await database.query(`DO $$
    DECLARE extension_name text; extension_schema text;
    BEGIN
      PERFORM set_config('lock_timeout', '5s', true);
      PERFORM pg_advisory_xact_lock(75047176522050);
      FOREACH extension_name IN ARRAY ARRAY[${extensions.map((name) => `'${name}'`).join(", ")}] LOOP
        SELECT n.nspname INTO extension_schema FROM pg_extension e
          JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = extension_name;
        IF FOUND AND extension_schema <> 'public' THEN
          RAISE EXCEPTION 'extension_schema_mismatch: % must be installed in public', extension_name;
        END IF;
        EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I WITH SCHEMA public', extension_name);
      END LOOP;
    END $$`);
}

export function createPostgresPool(config: string | PoolConfig, max: number): Pool {
  const pool = new Pool({
    ...(typeof config === "string" ? { connectionString: config } : config),
    max,
    options: `-c search_path=${POSTGRES_SEARCH_PATH}`,
  });
  // pg removes failed idle clients; handle the event so a disconnect cannot terminate the server.
  pool.on("error", () => {
    console.error(JSON.stringify({ level: "error", event: "database_pool_idle_error" }));
  });
  return pool;
}

export function connectPostgresUrl(connectionString: string, max: number) {
  const pool = createPostgresPool(connectionString, max);
  return {
    db: drizzle({ client: pool }),
    pool,
    close: () => pool.end(),
  };
}
