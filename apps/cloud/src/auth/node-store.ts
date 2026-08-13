import { mkdirSync, readFileSync, readdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";

import type { AppConfig } from "../config";
import { connectAuthDatabase, migrateAuthDatabase } from "../db/client";
import { createPostgresAuthStore, createSqliteAuthStore, type AuthStore } from "./store";

export interface NodeAuthStore extends AuthStore {
  migrate(): Promise<void>;
}

export function createNodeAuthStore(config: AppConfig): NodeAuthStore {
  if (config.authDatabase === "postgres") {
    const connection = connectAuthDatabase(config);
    return {
      ...createPostgresAuthStore(connection.db),
      migrate: () => migrateAuthDatabase(config),
      close: connection.close,
    };
  }
  if (config.authDatabase !== "sqlite" || !config.authSqlitePath) {
    throw new Error("Node Better Auth supports DAHLIA_AUTH_DATABASE=sqlite or postgres");
  }

  mkdirSync(dirname(config.authSqlitePath), { recursive: true });
  const database = new DatabaseSync(config.authSqlitePath);
  database.exec("PRAGMA foreign_keys = ON");
  database.exec("PRAGMA journal_mode = WAL");
  database.exec("PRAGMA busy_timeout = 5000");
  const store = createSqliteAuthStore({
    database,
    first: <T>(query: string, values: Array<string | number | null>) => Promise.resolve(database.prepare(query).get(...values) as T | null),
    all: <T>(query: string, values: Array<string | number | null>) => Promise.resolve(database.prepare(query).all(...values) as T[]),
    run: (query, values) => Promise.resolve(Number(database.prepare(query).run(...values).changes)),
    close: () => {
      database.close();
      return Promise.resolve();
    },
  });
  return {
    ...store,
    migrate() {
      database.exec(`CREATE TABLE IF NOT EXISTS "_dahlia_auth_migrations" (
        "name" TEXT PRIMARY KEY NOT NULL, "appliedAt" TEXT NOT NULL
      )`);
      const migrations = readdirSync("auth-migrations")
        .filter((name) => name.endsWith(".sql"))
        .sort();
      for (const name of migrations) {
        const applied = database.prepare('SELECT 1 FROM "_dahlia_auth_migrations" WHERE "name" = ?').get(name);
        if (applied) continue;
        database.exec("BEGIN");
        try {
          database.exec(readFileSync(`auth-migrations/${name}`, "utf8"));
          database.prepare('INSERT INTO "_dahlia_auth_migrations" ("name", "appliedAt") VALUES (?, ?)')
            .run(name, new Date().toISOString());
          database.exec("COMMIT");
        } catch (error) {
          database.exec("ROLLBACK");
          throw error;
        }
      }
      return Promise.resolve();
    },
  };
}
