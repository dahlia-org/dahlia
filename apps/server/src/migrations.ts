export interface MigrationSet {
  directories: readonly string[];
  files: readonly string[];
}

export interface MigrationManifest {
  postgres: MigrationSet;
  sqlite: MigrationSet;
}

export const serverMigrationManifest: MigrationManifest = {
  postgres: {
    directories: ["drizzle"],
    files: ["drizzle/0000_solid_ted_forrester.sql", "drizzle/0001_server.sql"],
  },
  sqlite: {
    directories: ["auth-migrations"],
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
