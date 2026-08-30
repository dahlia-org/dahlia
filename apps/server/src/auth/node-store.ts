import { AsyncLocalStorage } from "node:async_hooks";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { drizzle } from "drizzle-orm/sqlite-proxy";
import { migrate as migrateSqlite } from "drizzle-orm/sqlite-proxy/migrator";

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
  const applyMigrationQueries = (queries: string[]) => {
    for (const query of queries) database.exec(query);
    return Promise.resolve();
  };
  const migrate = async () => {
    const directoryIds = new Set<string>();
    for (const { id, path } of migrations.sqlite.directories) {
      if (!/^[a-z][a-z0-9_]{0,31}$/.test(id)) throw new Error(`Invalid SQLite migration ledger ID: ${id}`);
      if (directoryIds.has(id)) throw new Error(`Duplicate SQLite migration ledger ID: ${id}`);
      directoryIds.add(id);
      database.exec("BEGIN IMMEDIATE");
      try {
        await migrateSqlite(transactionalSqlite, applyMigrationQueries, {
          migrationsFolder: path,
          ...(id === "server" ? {} : { migrationsTable: `__dahlia_${id}_migrations` }),
        });
        database.exec("COMMIT");
      } catch (error) {
        database.exec("ROLLBACK");
        throw error;
      }
    }
  };
  return {
    ...store,
    close: () => {
      database.close();
      return Promise.resolve();
    },
    migrate() {
      const result = pending.then(() => transaction.run(true, migrate));
      pending = result.then(() => undefined, () => undefined);
      return result;
    },
  };
}

/** @deprecated Use NodeApplicationStore. */
export type NodeAuthStore = NodeApplicationStore;
/** @deprecated Use createNodeApplicationStore. */
export const createNodeAuthStore = createNodeApplicationStore;
