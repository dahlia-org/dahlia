import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

export const POSTGRES_MIGRATION_SCHEMA = "drizzle";
export const POSTGRES_SEARCH_PATH = "app,auth";

export function createPostgresPool(connectionString: string, max: number): Pool {
  return new Pool({ connectionString, max, options: `-c search_path=${POSTGRES_SEARCH_PATH}` });
}

export function connectPostgresUrl(connectionString: string, max: number) {
  const pool = createPostgresPool(connectionString, max);
  return {
    db: drizzle({ client: pool }),
    pool,
    close: () => pool.end(),
  };
}
