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
const postgresHistory = ["20260905172527_ancient_bedlam/migration.sql", "20260905172627_sync_history_backfill/migration.sql", "20260906125708_colossal_stepford_cuckoos/migration.sql", "20260906142206_force_file_rls/migration.sql", "20260907070726_flimsy_banshee/migration.sql", "20260907071320_force_meeting_event_rls/migration.sql", "20260907091206_chunky_gideon/migration.sql", "20260907091230_force_account_settings_rls/migration.sql", "20260907131014_colorful_the_leader/migration.sql", "20260907131333_force_recording_rls/migration.sql", "20260907132433_violet_black_bird/migration.sql", "20260907172548_rainy_maddog/migration.sql", "20260907172710_force_summary_job_rls/migration.sql", "20260908013210_reflective_morg/migration.sql", "20260908040348_slim_nebula/migration.sql", "20260908040458_summary_version_backfill/migration.sql", "20260908080351_burly_lady_vermin/migration.sql", "20260908092913_fancy_cerise/migration.sql", "20260908093012_account_settings_backfill/migration.sql", "20260908093034_stormy_peter_quill/migration.sql", "20260908164224_brave_marvel_zombies/migration.sql", "20260908164318_force_summary_rls/migration.sql"];
const sqliteHistory = ["20260905172528_unique_marvel_zombies/migration.sql", "20260905172654_sync_history_backfill/migration.sql", "20260906125718_dashing_roughhouse/migration.sql", "20260907070728_dashing_sinister_six/migration.sql", "20260907091207_funny_black_bird/migration.sql", "20260907131015_big_excalibur/migration.sql", "20260907132433_stiff_slyde/migration.sql", "20260907172550_nice_starhawk/migration.sql", "20260908013212_chief_enchantress/migration.sql", "20260908040349_cuddly_brood/migration.sql", "20260908040515_summary_version_backfill/migration.sql", "20260908080352_zippy_aaron_stack/migration.sql", "20260908092914_massive_luke_cage/migration.sql", "20260908093013_account_settings_backfill/migration.sql", "20260908093035_stale_sue_storm/migration.sql", "20260908164304_spicy_lady_vermin/migration.sql"];
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
