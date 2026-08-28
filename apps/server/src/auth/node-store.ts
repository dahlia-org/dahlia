import { AsyncLocalStorage } from "node:async_hooks";
import { mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { drizzle } from "drizzle-orm/sqlite-proxy";

import type { AppConfig } from "../config";
import { connectApplicationDatabase, migrateApplicationDatabase } from "../db/client";
import { serverMigrationManifest, type MigrationManifest } from "../migrations";
import {
  createPostgresApplicationStore,
  createSqliteApplicationStore,
  type ApplicationStore,
} from "./store";

export interface NodeApplicationStore extends ApplicationStore {
  migrate(): Promise<void>;
}

export function createNodeApplicationStore(
  config: AppConfig,
  migrations: MigrationManifest = serverMigrationManifest,
): NodeApplicationStore {
  if (config.databaseType === "postgres" || config.databaseType === "lakebase") {
    const connection = connectApplicationDatabase(config);
    return {
      ...createPostgresApplicationStore(connection.db),
      migrate: () => migrateApplicationDatabase(config, migrations.postgres.directories),
      close: connection.close,
    };
  }
  if (config.databaseType !== "sqlite" || !config.databaseUrl) {
    throw new Error("Node storage supports DAHLIA_DATABASE_TYPE=sqlite, postgres, or lakebase");
  }

  const databasePath = fileURLToPath(new URL(config.databaseUrl, pathToFileURL(`${process.cwd()}/`)));
  mkdirSync(dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec("PRAGMA foreign_keys = ON");
  database.exec("PRAGMA journal_mode = WAL");
  database.exec("PRAGMA busy_timeout = 5000");
  const transaction = new AsyncLocalStorage<boolean>();
  let pending = Promise.resolve();
  const execute = async (sql: string, params: unknown[], method: "run" | "all" | "get" | "values") => {
    const query = () => {
      const statement = database.prepare(sql);
      statement.setReturnArrays(true);
      if (method === "run") {
        statement.run(...params as []);
        return { rows: [] };
      }
      if (method === "get") return { rows: statement.get(...params as []) as unknown as unknown[] };
      return { rows: statement.all(...params as []) as unknown[] };
    };
    if (transaction.getStore()) return query();
    const result = pending.then(query, query);
    pending = result.then(() => undefined, () => undefined);
    return result;
  };
  const sqlite = drizzle(execute);
  const transact = sqlite.transaction.bind(sqlite);
  const transactionalSqlite = new Proxy(sqlite, {
    get(target, property, receiver) {
      if (property !== "transaction") {
        const value: unknown = Reflect.get(target, property, receiver);
        return value;
      }
      return <T>(callback: Parameters<typeof transact<T>>[0]) => {
        const result = pending.then(() => transaction.run(true, () => transact(callback)));
        pending = result.then(() => undefined, () => undefined);
        return result;
      };
    },
  });
  const store = createSqliteApplicationStore(transactionalSqlite, true);
  return {
    ...store,
    close: () => {
      database.close();
      return Promise.resolve();
    },
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

/** @deprecated Use NodeApplicationStore. */
export type NodeAuthStore = NodeApplicationStore;
/** @deprecated Use createNodeApplicationStore. */
export const createNodeAuthStore = createNodeApplicationStore;
