import { getTableConfig } from "drizzle-orm/pg-core";
import { getTableName } from "drizzle-orm";
import * as postgres from "../src/db/postgres-app-schema";
import * as sqlite from "../src/db/sqlite-app-schema";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

it("creates canonical tables, defaults, and cascading relationships on SQLite", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec("PRAGMA foreign_keys = ON");
    for (const file of serverMigrationManifest.sqlite.files) {
      const path = file;
      db.exec(readFileSync(new URL(`../${path}`, import.meta.url), "utf8"));
    }
    db.exec(`
      INSERT INTO user(id, name, email, updated_at) VALUES ('owner', 'Owner', 'owner@example.com', 1);
      INSERT INTO organization(id, name, slug, created_at) VALUES ('org', 'Team', 'team', 1);
      INSERT INTO vaults(vault_id, organization_id, created_by, name) VALUES ('vault', 'org', '{"id":"owner","name":"Owner","email":"owner@example.com"}', 'Vault');
      INSERT INTO vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id)
        VALUES ('vault', 'user', 'owner', 'admin', 'owner');
      INSERT INTO projects(project_id, vault_id, name, revision, created_at)
        VALUES ('project', 'vault', 'Project', 8, 1);
      INSERT INTO meetings(meeting_id, vault_id, project_id, name, status, created_at, updated_at)
        VALUES ('meeting', 'vault', 'project', 'Meeting', 'READY', 1, 1);
      INSERT INTO meeting_events(id, vault_id, owner_user_id, meeting_id, kind, occurred_at, received_at)
        VALUES ('event', 'vault', 'owner', 'meeting', 'meeting_created', 1, 1);
      INSERT INTO files(file_id, vault_id, uri, size, content_type, checksum, name, metadata)
        VALUES ('file', 'vault', 'files/file/original', 5, 'image/png', 'SHA-256:test', 'image.png', '{"source":"screenshot"}');
      INSERT INTO meeting_attachments(id, vault_id, meeting_id, file_id) VALUES ('link', 'vault', 'meeting', 'file');
      INSERT INTO recordings(session_id, meeting_id, number, started_at, ended_at, audio, revision, created_at, updated_at)
        VALUES ('session', 'meeting', 1, 1, 2, '{"mic":{"generation":"upload-token","active":false}}', 7, 1, 2);
      INSERT INTO account_settings(user_id, output_language, analysis_languages, revision)
        VALUES ('owner', 'ja', '{"scope":"automatic"}', 19);
      INSERT INTO jobs_search_index(vault_id, document_id, model, dimensions, generation, status, attempts, claimed_at)
        VALUES ('vault', 'document', 'model', 32, 4, 'processing', 2, 123);
      INSERT INTO jobs_storage_delete(storage_key, status, attempts, claimed_at) VALUES ('old-file', 'processing', 3, 124);
      INSERT INTO jobs_image_analysis(file_id, vault_id, owner_user_id, model, status, attempts)
        VALUES ('file', 'vault', 'owner', 'vision', 'failed', 5);
      INSERT INTO jobs_summary(id, vault_id, meeting_id, owner_user_id, method, settings, output_language, status,
        created_at, available_at, summary_revision, input_version, request_hash)
        VALUES ('summary-job', 'vault', 'meeting', 'owner', 'transcript', '{"model":"saved"}', 'ja', 'pending', 1, 1, 3, 'input', 'request');
    `);
    expect(db.prepare("SELECT name FROM sqlite_master WHERE name IN ('artifact', 'summary_versions', 'screenshots')").all()).toEqual([]);
    expect(db.prepare("SELECT revision, summary, processing FROM account_settings").get()).toEqual({
      revision: 19, summary: JSON.stringify({ style: "detailed" }),
      processing: JSON.stringify({ location: "local", remote: { workflow: "transcribeThenSummarize" } }),
    });
    expect(db.prepare("SELECT revision, icon, color FROM projects").get()).toEqual({ revision: 8, icon: null, color: null });
    expect(db.prepare("SELECT icon, color FROM vaults").get()).toEqual({ icon: null, color: null });
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    db.exec("DELETE FROM meetings WHERE meeting_id = 'meeting'");
    expect(db.prepare("SELECT * FROM recordings").all()).toEqual([]);
    expect(db.prepare("SELECT * FROM meeting_attachments").all()).toEqual([]);
    expect(db.prepare("SELECT count(*) AS count FROM files").get()).toEqual({ count: 1 });
    expect(db.prepare("SELECT count(*) AS count FROM meeting_events").get()).toEqual({ count: 1 });
    db.exec("DELETE FROM vaults WHERE vault_id = 'vault'");
    expect(db.prepare("SELECT * FROM meeting_events").all()).toEqual([]);
  } finally { db.close(); }
});

it("keeps OCR and caption database limits out of SQLite", () => {
  const sqlite = serverMigrationManifest.sqlite.files
    .map((file) => readFileSync(new URL(`../${file}`, import.meta.url), "utf8")).join("\n");
  const sql = sqlite;
    expect(sql).not.toContain("files_metadata_ocr_text_length_check");
    expect(sql).not.toContain("files_metadata_caption_length_check");
    expect(sql).not.toMatch(/(?:ocr_text|caption_text)[^\n]*varchar/i);
});

it.each([
  ["summaryJob", "summary"], ["imageAnalysisJob", "image_analysis"],
  ["searchIndexJob", "search_index"], ["storageDeleteJob", "storage_delete"],
] as const)("keeps %s physical names dialect-specific", (key, name) => {
  expect(getTableConfig(postgres[key])).toMatchObject({ schema: "jobs", name });
  expect(getTableName(sqlite[key])).toBe(`jobs_${name}`);
});

it("creates calendar metadata in the initial schema and preserves it through runtime setup", () => {
  const db = new DatabaseSync(":memory:");
  const files = serverMigrationManifest.sqlite.files;
  const migrate = (file: string) => db.exec(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
  try {
    for (const file of files.slice(0, -1)) migrate(file);
    db.exec(`INSERT INTO organization(id, name, slug, created_at) VALUES ('org', 'Team', 'team', 1);
      INSERT INTO vaults(vault_id, organization_id, created_by, name) VALUES ('vault', 'org', '{"id":"owner","name":"Owner","email":"owner@example.com"}', 'Vault')`);
    db.exec("INSERT INTO meetings(meeting_id, vault_id, name, status, created_at, updated_at) VALUES ('meeting', 'vault', 'Preserved', 'READY', 1, 2)");
    db.exec("UPDATE meetings SET ical_uid = 'shared@example.com', recurrence_id = '20260903T000000Z'");
    migrate(files.at(-1)!);
    expect(db.prepare("SELECT name, created_at, updated_at, ical_uid, recurrence_id, calendar_event FROM meetings").get())
      .toEqual({ name: "Preserved", created_at: 1, updated_at: 2, ical_uid: "shared@example.com", recurrence_id: "20260903T000000Z", calendar_event: null });
    db.exec("UPDATE meetings SET ical_uid = 'shared@example.com', recurrence_id = ''");
    expect(db.prepare("SELECT recurrence_id FROM meetings").get()).toEqual({ recurrence_id: "" });
  } finally { db.close(); }
});
