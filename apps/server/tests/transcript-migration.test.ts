import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { Client } from "pg";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

const sql = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const vaults = ["019d493d-f5f4-7b8b-a9da-8ef51975b171", "019d493d-f5f4-7b8b-a9da-8ef51975b172"];
const meetings = [1, 2, 3, 4].map((index) => `019d493e-0147-7cf6-b56c-b036960bba0${index}`);
const segmentId = "019d493e-063e-70ed-ab24-c86de735bca8";
const text = "既存の本文\n日本語 & <text>";

it.each(["sqlite", "d1"])("preserves populated transcripts through the %s upgrade with foreign keys enabled", (dialect) => {
  const db = new DatabaseSync(":memory:");
  const files = serverMigrationManifest.sqlite.files.map((path) => dialect === "sqlite" ? path
    : path.replace("/sqlite/", "/d1/").replace("/migration.sql", ".sql"));
  const boundary = files.findIndex((path) => path.includes("20260908144757"));
  try {
    db.exec("PRAGMA foreign_keys = ON; BEGIN IMMEDIATE");
    for (const file of files.slice(0, boundary)) db.exec(sql(file));
    db.exec("COMMIT");
    for (const vaultId of vaults) db.prepare("INSERT INTO vaults (vault_id, name) VALUES (?, 'Vault')").run(vaultId);
    for (const [index, meetingId] of meetings.entries()) {
      db.prepare(`INSERT INTO meetings (meeting_id, vault_id, name, status, created_at, updated_at, transcript_revision)
        VALUES (?, ?, 'Meeting', 'READY', 1700000000000, 1700000000000, ?)`).run(meetingId, vaults[index % 2]!, index < 3 ? index + 7 : 0);
    }
    for (const [index, meetingId] of meetings.slice(0, 2).entries()) {
      db.prepare(`INSERT INTO transcript_segments
        (vault_id, meeting_id, segment_id, start_time, end_time, text, is_confirmed, audio_source, speaker_label)
        VALUES (?, ?, ?, 1700000000123, 1700000000456, ?, 1, 'mic', 'Speaker')`).run(vaults[index]!, meetingId, segmentId, text);
    }
    // The real Node migrator runs all pending SQL inside BEGIN IMMEDIATE; foreign_keys=OFF is a no-op there.
    db.exec("BEGIN IMMEDIATE");
    for (const file of files.slice(boundary)) db.exec(sql(file));
    db.exec("COMMIT");
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(db.prepare("SELECT meeting_id, version, sync_revision, started_at, ended_at, metadata FROM transcripts ORDER BY meeting_id").all())
      .toEqual(meetings.slice(0, 3).map((meeting_id, index) => ({ meeting_id, version: 1, sync_revision: index + 7,
        started_at: null, ended_at: null, metadata: null })));
    expect(db.prepare(`SELECT t.meeting_id, s.segment_id, s.started_at, s.ended_at, s.text, s.audio_source, s.speaker_label
      FROM transcript_segments s JOIN transcripts t ON t.id = s.transcript_id ORDER BY t.meeting_id`).all())
      .toEqual(meetings.slice(0, 2).map((meeting_id) => ({ meeting_id, segment_id: segmentId, started_at: 1700000000123,
        ended_at: 1700000000456, text, audio_source: "mic", speaker_label: "Speaker" })));
    db.prepare("DELETE FROM meetings WHERE meeting_id = ?").run(meetings[0]!);
    expect(db.prepare("SELECT count(*) AS count FROM transcripts").get()).toEqual({ count: 2 });
    expect(db.prepare("SELECT count(*) AS count FROM transcript_segments").get()).toEqual({ count: 1 });
  } finally { db.close(); }
});

// Use a disposable empty database owned by a non-superuser, without BYPASSRLS.
it.runIf(process.env.TEST_MIGRATION_DATABASE_URL)("backfills PostgreSQL transcript parents before enforcing identity and restores FORCE RLS", async () => {
  const client = new Client({ connectionString: process.env.TEST_MIGRATION_DATABASE_URL });
  await client.connect();
  try {
    expect((await client.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).rows)
      .toEqual([{ rolsuper: false, rolbypassrls: false }]);
    await client.query("BEGIN");
    const files = serverMigrationManifest.postgres.files;
    const boundary = files.findIndex((path) => path.includes("20260908144655"));
    for (const file of files.slice(0, boundary)) await client.query(sql(file));
    await client.query(`ALTER TABLE app.vaults NO FORCE ROW LEVEL SECURITY;
      ALTER TABLE app.meetings NO FORCE ROW LEVEL SECURITY;
      ALTER TABLE app.transcript_segments NO FORCE ROW LEVEL SECURITY`);
    for (const vaultId of vaults) await client.query("INSERT INTO app.vaults (vault_id, name) VALUES ($1, 'Vault')", [vaultId]);
    for (const [index, meetingId] of meetings.entries()) {
      await client.query(`INSERT INTO app.meetings (meeting_id, vault_id, name, status, created_at, updated_at, transcript_revision)
        VALUES ($1, $2, 'Meeting', 'READY', now(), now(), $3)`, [meetingId, vaults[index % 2], index < 3 ? index + 7 : 0]);
    }
    for (const [index, meetingId] of meetings.slice(0, 2).entries()) {
      await client.query(`INSERT INTO app.transcript_segments
        (vault_id, meeting_id, segment_id, start_time, end_time, text, is_confirmed, audio_source, speaker_label)
        VALUES ($1, $2, $3, '2023-11-14 22:13:20.123', '2023-11-14 22:13:20.456', $4, true, 'mic', 'Speaker')`,
      [vaults[index], meetingId, segmentId, text]);
    }
    await client.query(`ALTER TABLE app.vaults FORCE ROW LEVEL SECURITY;
      ALTER TABLE app.meetings FORCE ROW LEVEL SECURITY;
      ALTER TABLE app.transcript_segments FORCE ROW LEVEL SECURITY`);
    for (const file of files.slice(boundary)) await client.query(sql(file));
    expect((await client.query(`SELECT relname, relforcerowsecurity FROM pg_class
      WHERE oid IN ('app.transcripts'::regclass, 'app.transcript_segments'::regclass, 'app.meetings'::regclass)
      ORDER BY relname`)).rows).toEqual(["meetings", "transcript_segments", "transcripts"]
      .map((relname) => ({ relname, relforcerowsecurity: true })));
    expect((await client.query("SELECT * FROM app.transcript_segments")).rows).toEqual([]);
    await client.query(`ALTER TABLE app.meetings NO FORCE ROW LEVEL SECURITY;
      ALTER TABLE app.transcripts NO FORCE ROW LEVEL SECURITY;
      ALTER TABLE app.transcript_segments NO FORCE ROW LEVEL SECURITY`);
    expect((await client.query("SELECT meeting_id, version, sync_revision, started_at, ended_at, metadata FROM app.transcripts ORDER BY meeting_id")).rows)
      .toEqual(meetings.slice(0, 3).map((meeting_id, index) => ({ meeting_id, version: 1, sync_revision: index + 7,
        started_at: null, ended_at: null, metadata: null })));
    expect((await client.query(`SELECT t.meeting_id, s.segment_id, s.started_at::text, s.ended_at::text, s.text, s.audio_source, s.speaker_label
      FROM app.transcript_segments s JOIN app.transcripts t ON t.id = s.transcript_id ORDER BY t.meeting_id`)).rows)
      .toEqual(meetings.slice(0, 2).map((meeting_id) => ({ meeting_id, segment_id: segmentId, started_at: "2023-11-14 22:13:20.123",
        ended_at: "2023-11-14 22:13:20.456", text, audio_source: "mic", speaker_label: "Speaker" })));
    await client.query("DELETE FROM app.meetings WHERE meeting_id = $1", [meetings[0]]);
    expect((await client.query("SELECT count(*)::int AS count FROM app.transcript_segments")).rows).toEqual([{ count: 1 }]);
  } finally {
    await client.query("ROLLBACK");
    await client.end();
  }
});
