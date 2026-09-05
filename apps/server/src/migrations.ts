import { join } from "node:path";
import { fileURLToPath } from "node:url";

export interface MigrationDirectory {
  id: string;
  path: string;
}

export interface PostgresMigrationDirectory extends MigrationDirectory {
  files?: readonly string[];
}

export interface SQLiteMigrationDirectory extends MigrationDirectory {
  files: readonly string[];
}

export interface MigrationSet<TDirectory = MigrationDirectory> {
  directories: readonly TDirectory[];
  files: readonly string[];
}

export interface MigrationManifest {
  postgres: MigrationSet<PostgresMigrationDirectory>;
  sqlite: MigrationSet<SQLiteMigrationDirectory>;
}

const packageDirectory = fileURLToPath(new URL(".", import.meta.resolve("@dahlia-ai/server/package.json")));
const postgresAuthPath = join(packageDirectory, "drizzle/postgres-auth");
const postgresPath = join(packageDirectory, "drizzle/postgres");
const sqlitePath = join(packageDirectory, "drizzle/sqlite");
const postgresAuthBaseline = "20260903034253_melodic_scalphunter/migration.sql";
const postgresBaseline = "20260903173551_bumpy_freak/migration.sql";
const postgresHistory = ["20260905172527_ancient_bedlam/migration.sql", "20260905172627_sync_history_backfill/migration.sql"];
const sqliteHistory = ["20260905172528_unique_marvel_zombies/migration.sql", "20260905172654_sync_history_backfill/migration.sql"];
const sqliteBaseline = "20260903173555_lying_slipstream/migration.sql";

export const serverMigrationManifest: MigrationManifest = {
  postgres: {
    directories: [
      {
        id: "auth",
        path: postgresAuthPath,
        files: [postgresAuthBaseline],
      },
      {
        id: "server",
        path: postgresPath,
        files: [postgresBaseline, ...postgresHistory],
      },
    ],
    files: [
      `drizzle/postgres-auth/${postgresAuthBaseline}`,
      `drizzle/postgres/${postgresBaseline}`,
      ...postgresHistory.map((file) => `drizzle/postgres/${file}`),
    ],
  },
  sqlite: {
    directories: [{
      id: "server",
      path: sqlitePath,
      files: [sqliteBaseline, ...sqliteHistory],
    }],
    files: [`drizzle/sqlite/${sqliteBaseline}`, ...sqliteHistory.map((file) => `drizzle/sqlite/${file}`)],
  },
};

export function postgresMigrations(
  manifest: MigrationManifest,
): readonly PostgresMigrationDirectory[] {
  return manifest.postgres.directories;
}

export function composeMigrationManifests(
  ...manifests: readonly MigrationManifest[]
): MigrationManifest {
  return {
    postgres: {
      directories: manifests.flatMap((manifest) => manifest.postgres.directories),
      files: manifests.flatMap((manifest) => manifest.postgres.files),
    },
    sqlite: {
      directories: manifests.flatMap((manifest) => manifest.sqlite.directories),
      files: manifests.flatMap((manifest) => manifest.sqlite.files),
    },
  };
}
