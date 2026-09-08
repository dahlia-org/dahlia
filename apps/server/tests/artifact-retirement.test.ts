import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

const sql = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

it("drops only Artifact data when upgrading a populated SQLite/D1 database", () => {
  const database = new DatabaseSync(":memory:");
  try {
    const retirementIndex = serverMigrationManifest.sqlite.files.findIndex((path) => path.includes("20260908013212_chief_enchantress"));
    expect(retirementIndex).toBeGreaterThan(0);
    for (const path of serverMigrationManifest.sqlite.files.slice(0, retirementIndex)) database.exec(sql(path));
    database.exec(`
      INSERT INTO user(id, name, email, updated_at) VALUES ('owner', 'Owner', 'owner@example.com', 1);
      INSERT INTO vaults(vault_id, name) VALUES ('vault', 'Vault');
      INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id)
        VALUES ('vault', 'user', 'owner', 'owner', 'owner');
      INSERT INTO meetings(meeting_id, vault_id, name, status, created_at, updated_at)
        VALUES ('meeting', 'vault', 'Meeting', 'READY', 1, 1);
      INSERT INTO files(file_id, vault_id, uri, size, content_type, checksum, name, metadata)
        VALUES ('file', 'vault', '/Volumes/test/files/file/original', 5, 'image/png', 'SHA-256:test', 'capture.png', '{"source":"screenshot"}');
      INSERT INTO meeting_files(id, vault_id, meeting_id, file_id) VALUES ('link', 'vault', 'meeting', 'file');
      INSERT INTO recordings(session_id, vault_id, meeting_id, number, started_at, ended_at, audio, created_at, updated_at)
        VALUES ('session', 'vault', 'meeting', 1, 1, 2, '{}', 1, 2);
      INSERT INTO artifact(id, owner_workspace_id, content_type, storage_key)
        VALUES ('retired', 'personal:owner', 'text/html', 'artifacts/retired/version.html');
    `);
    const tables = ["user", "vaults", "vault_permissions", "meetings", "files", "meeting_files", "recordings"];
    const before = tables.map((table) => database.prepare(`SELECT * FROM "${table}"`).all());
    const retirement = serverMigrationManifest.sqlite.files[retirementIndex]!;
    expect(sql(retirement).trim()).toBe('DROP TABLE `artifact`;');
    database.exec(sql(retirement));
    expect(database.prepare("SELECT name FROM sqlite_master WHERE name = 'artifact'").get()).toBeUndefined();
    expect(tables.map((table) => database.prepare(`SELECT * FROM "${table}"`).all())).toEqual(before);
    expect(database.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(sql(serverMigrationManifest.postgres.files.find((path) => path.includes("20260908013210_reflective_morg"))!).trim()).toBe('DROP TABLE "app"."artifact";');
  } finally { database.close(); }
});
