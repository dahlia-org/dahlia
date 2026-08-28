import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

export const POSTGRES_SCHEMA = "dahlia";

export function createPostgresPool(connectionString: string, max: number): Pool {
  return new Pool({ connectionString, max, options: `-c search_path=${POSTGRES_SCHEMA}` });
}

export function connectPostgresUrl(connectionString: string, max: number) {
  const pool = createPostgresPool(connectionString, max);
  return {
    db: drizzle({ client: pool }),
    pool,
    close: () => pool.end(),
  };
}
