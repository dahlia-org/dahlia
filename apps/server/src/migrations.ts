import { join } from "node:path";
import { fileURLToPath } from "node:url";

export interface MigrationDirectory {
  id: string;
  path: string;
}

export type PostgresMigrationDirectory = MigrationDirectory;

export type SQLiteMigrationDirectory = MigrationDirectory;

export interface MigrationSet<TDirectory = MigrationDirectory> {
  directories: readonly TDirectory[];
  files: readonly string[];
}

export interface MigrationManifest {
  postgres: MigrationSet<PostgresMigrationDirectory>;
  sqlite: MigrationSet<SQLiteMigrationDirectory>;
}

const packageDirectory = fileURLToPath(new URL(".", import.meta.resolve("@dahlia-ai/server/package.json")));

export const serverMigrationManifest: MigrationManifest = {
  postgres: {
    directories: [{ id: "server", path: join(packageDirectory, "drizzle/postgres") }],
    files: ["drizzle/postgres/20260830001527_open_blue_shield/migration.sql"],
  },
  sqlite: {
    directories: [{ id: "server", path: join(packageDirectory, "drizzle/sqlite") }],
    files: ["drizzle/sqlite/20260830001528_stiff_alex_power/migration.sql"],
  },
};

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
