import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

export function createPostgresPool(connectionString: string, max: number): Pool {
  return new Pool({ connectionString, max });
}

export function connectPostgresUrl(connectionString: string, max: number) {
  const pool = createPostgresPool(connectionString, max);
  return {
    db: drizzle({ client: pool }),
    pool,
    close: () => pool.end(),
  };
}
