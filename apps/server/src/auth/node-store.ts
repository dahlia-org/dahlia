import { mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import type { AppConfig } from "../config";
import { connectAuthDatabase, migrateAuthDatabase } from "../db/client";
import { serverMigrationManifest, type MigrationManifest } from "../migrations";
import { createPostgresAuthStore, createSqliteAuthStore, type AuthStore } from "./store";

export interface NodeAuthStore extends AuthStore {
  migrate(): Promise<void>;
}

export function createNodeAuthStore(
  config: AppConfig,
  migrations: MigrationManifest = serverMigrationManifest,
): NodeAuthStore {
  if (config.authDatabase === "postgres") {
    const connection = connectAuthDatabase(config);
    return {
      ...createPostgresAuthStore(connection.db),
      migrate: () => migrateAuthDatabase(config, migrations.postgres.directories),
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
      const directoryIds = new Set<string>();
      const files = migrations.sqlite.directories.flatMap(({ id, path, files: declaredFiles }) => {
        if (!/^[a-z][a-z0-9_]{0,31}$/.test(id)) throw new Error(`Invalid SQLite migration ledger ID: ${id}`);
        if (directoryIds.has(id)) throw new Error(`Duplicate SQLite migration ledger ID: ${id}`);
        directoryIds.add(id);
        return declaredFiles.map((name) => {
          if (basename(name) !== name || !name.endsWith(".sql")) {
            throw new Error(`Invalid SQLite migration file: ${name}`);
          }
          return { id, path, name };
        });
      });
      const manifestNames = migrations.sqlite.files.map((file) => basename(file)).sort();
      const executionNames = files.map(({ name }) => name).sort();
      if (manifestNames.join("\0") !== executionNames.join("\0")) {
        throw new Error("SQLite migration directory files do not match the manifest");
      }
      for (const { id, path, name } of files) {
        const ledgerName = `${id}/${name}`;
        const applied = database.prepare('SELECT 1 FROM "_dahlia_auth_migrations" WHERE "name" = ?').get(ledgerName);
        if (applied) continue;
        database.exec("BEGIN");
        try {
          database.exec(readFileSync(join(path, name), "utf8"));
          database.prepare('INSERT INTO "_dahlia_auth_migrations" ("name", "appliedAt") VALUES (?, ?)')
            .run(ledgerName, new Date().toISOString());
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
