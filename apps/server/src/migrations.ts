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
const postgresAgentPath = join(packageDirectory, "drizzle/postgres-agent");
const sqlitePath = join(packageDirectory, "drizzle/sqlite");
const postgresAuthBaseline = "20260912095619_initial/migration.sql";
const postgresFiles = [
  "20260912095620_initial/migration.sql",
  "20260912180000_runtime_support/migration.sql",
];
const postgresAgentFiles = [
  "20260919104547_dear_strong_guy/migration.sql",
  "20260919104548_force_rls/migration.sql",
];
const sqliteFiles = ["20260912095621_initial/migration.sql", "20260912180000_runtime_support/migration.sql"];

export const serverMigrationManifest: MigrationManifest = {
  postgres: {
    directories: [
      { id: "auth", path: postgresAuthPath, files: [postgresAuthBaseline] },
      { id: "server", path: postgresPath, files: postgresFiles },
      { id: "agent", path: postgresAgentPath, files: postgresAgentFiles },
    ],
    files: [`drizzle/postgres-auth/${postgresAuthBaseline}`, ...postgresFiles.map((file) => `drizzle/postgres/${file}`),
      ...postgresAgentFiles.map((file) => `drizzle/postgres-agent/${file}`)],
  },
  sqlite: {
    directories: [{ id: "server", path: sqlitePath, files: sqliteFiles }],
    files: sqliteFiles.map((file) => `drizzle/sqlite/${file}`),
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
