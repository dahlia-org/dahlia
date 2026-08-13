import { join } from "node:path";
import { fileURLToPath } from "node:url";

export interface MigrationSet {
  directories: readonly string[];
  files: readonly string[];
}

export interface MigrationManifest {
  postgres: MigrationSet;
  sqlite: MigrationSet;
}

const packageDirectory = fileURLToPath(new URL(".", import.meta.resolve("dahlia-ai/package.json")));

export const serverMigrationManifest: MigrationManifest = {
  postgres: {
    directories: [join(packageDirectory, "drizzle")],
    files: ["drizzle/0000_solid_ted_forrester.sql", "drizzle/0001_server.sql"],
  },
  sqlite: {
    directories: [join(packageDirectory, "auth-migrations")],
    files: ["auth-migrations/0001_better_auth.sql", "auth-migrations/0002_server.sql"],
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
