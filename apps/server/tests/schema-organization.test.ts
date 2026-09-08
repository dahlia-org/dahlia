import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

it.each(["sqlite", "d1"])("preserves populated records and pending jobs during schema organization (%s)", (dialect) => {
  const db = new DatabaseSync(":memory:");
  const read = (path: string) => readFileSync(new URL(`../${dialect === "d1"
    ? path.replace("drizzle/sqlite/", "drizzle/d1/").replace("/migration.sql", ".sql") : path}`, import.meta.url), "utf8");
  try {
    const files = serverMigrationManifest.sqlite.files;
    for (const file of files.slice(0, -1)) db.exec(read(file));
    db.exec(`
      INSERT INTO user(id, name, email, updated_at) VALUES ('owner', 'Owner', 'owner@example.com', 1);
      INSERT INTO vaults(vault_id, name) VALUES ('vault', 'Vault');
      INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id)
        VALUES ('vault', 'user', 'owner', 'owner', 'owner');
      INSERT INTO projects(project_id, vault_id, name, project_type, revision, created_at)
        VALUES ('project', 'vault', 'Project', 'undefined', 8, 1);
      INSERT INTO meetings(meeting_id, vault_id, project_id, name, status, created_at, updated_at)
        VALUES ('meeting', 'vault', 'project', 'Meeting', 'READY', 1, 1);
      INSERT INTO meeting_events(id, vault_id, owner_user_id, meeting_id, kind, occurred_at, received_at)
        VALUES ('event', 'vault', 'owner', 'meeting', 'meeting_created', 1, 1);
      INSERT INTO files(file_id, vault_id, uri, size, content_type, checksum, name, metadata)
        VALUES ('file', 'vault', 'files/file/original', 5, 'image/png', 'SHA-256:test', 'image.png', '{"source":"screenshot"}');
      INSERT INTO meeting_files(id, vault_id, meeting_id, file_id) VALUES ('link', 'vault', 'meeting', 'file');
      INSERT INTO recordings(session_id, vault_id, meeting_id, number, started_at, ended_at, audio, revision, created_at, updated_at)
        VALUES ('session', 'vault', 'meeting', 1, 1, 2, '{"mic":{"generation":"upload-token","active":false}}', 7, 1, 2);
      INSERT INTO account_settings(user_id, output_language, analysis_languages, change_version)
        VALUES ('owner', 'ja', '{"scope":"automatic"}', 19);
      INSERT INTO search_index_jobs(vault_id, document_id, owner_user_id, model, dimensions, generation, status, attempts, claimed_at)
        VALUES ('vault', 'document', 'owner', 'model', 32, 4, 'processing', 2, 123);
      INSERT INTO storage_delete_jobs(storage_key, status, attempts, claimed_at) VALUES ('old-file', 'processing', 3, 124);
      INSERT INTO image_analysis_jobs(file_id, vault_id, owner_user_id, model, status, attempts)
        VALUES ('file', 'vault', 'owner', 'vision', 'failed', 5);
      INSERT INTO summary_jobs(id, vault_id, meeting_id, owner_user_id, method, settings, output_language, status,
        created_at, available_at, summary_revision, input_version, request_hash)
        VALUES ('summary-job', 'vault', 'meeting', 'owner', 'transcript', '{"model":"saved"}', 'ja', 'pending', 1, 1, 3, 'input', 'request');
    `);
    const tables = { search_index_jobs: "jobs_search_index", storage_delete_jobs: "jobs_storage_delete",
      image_analysis_jobs: "jobs_image_analysis", summary_jobs: "jobs_summary" };
    const jobs = Object.keys(tables).map((table) => db.prepare(`SELECT * FROM ${table}`).all());
    const recording = db.prepare("SELECT * FROM recordings").get()!;
    delete recording.vault_id;
    db.exec(read(files.at(-1)!));
    expect(Object.values(tables).map((table) => db.prepare(`SELECT * FROM ${table}`).all())).toEqual(jobs);
    expect(db.prepare("SELECT * FROM recordings").get()).toEqual(recording);
    expect(db.prepare("SELECT revision FROM account_settings").get()).toEqual({ revision: 19 });
    expect(db.prepare("SELECT revision, icon, color FROM projects").get()).toEqual({ revision: 8, icon: null, color: null });
    expect(db.prepare("SELECT icon, color FROM vaults").get()).toEqual({ icon: null, color: null });
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    db.exec("DELETE FROM meetings WHERE meeting_id = 'meeting'");
    expect(db.prepare("SELECT * FROM recordings").all()).toEqual([]);
    expect(db.prepare("SELECT * FROM meeting_files").all()).toEqual([]);
    expect(db.prepare("SELECT count(*) AS count FROM files").get()).toEqual({ count: 1 });
    expect(db.prepare("SELECT count(*) AS count FROM meeting_events").get()).toEqual({ count: 1 });
    db.exec("DELETE FROM vaults WHERE vault_id = 'vault'");
    expect(db.prepare("SELECT * FROM meeting_events").all()).toEqual([]);
  } finally { db.close(); }
});
