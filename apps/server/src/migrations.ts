import { join } from "node:path";
import { fileURLToPath } from "node:url";

export interface MigrationDirectory {
  id: string;
  path: string;
}

export type PostgresMigrationDirectory = MigrationDirectory;

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

export const serverMigrationManifest: MigrationManifest = {
  postgres: {
    directories: [{ id: "server", path: join(packageDirectory, "drizzle") }],
    files: [
      "drizzle/20260828162616_baseline/migration.sql",
      "drizzle/20260828180826_stiff_natasha_romanoff/migration.sql",
      "drizzle/20260828182417_cool_cerebro/migration.sql",
    ],
  },
  sqlite: {
    directories: [{
      id: "server",
      path: join(packageDirectory, "auth-migrations"),
      files: ["0001_better_auth.sql", "0002_server.sql", "0003_artifact.sql", "0004_artifact_reservation.sql"],
    }],
    files: [
      "auth-migrations/0001_better_auth.sql",
      "auth-migrations/0002_server.sql",
      "auth-migrations/0003_artifact.sql",
      "auth-migrations/0004_artifact_reservation.sql",
    ],
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
