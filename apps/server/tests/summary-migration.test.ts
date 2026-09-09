import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

it.each(["sqlite", "d1"])("preserves active summary jobs and migrates all saved detail choices (%s)", (dialect) => {
  const db = new DatabaseSync(":memory:");
  const read = (file: string) => readFileSync(new URL(`../${dialect === "d1"
    ? file.replace("drizzle/sqlite/", "drizzle/d1/").replace("/migration.sql", ".sql") : file}`, import.meta.url), "utf8");
  const files = serverMigrationManifest.sqlite.files;
  const boundary = files.findIndex((file) => file.includes("20260909104405_lame_killraven"));
  try {
    expect(boundary).toBeGreaterThan(0);
    for (const file of files.slice(0, boundary)) db.exec(read(file));
    const oldDetails = ["concise", "standard", "detailed", "eventSession"];
    for (const detail of oldDetails) {
      db.prepare("INSERT INTO user(id, name, email, updated_at) VALUES (?, ?, ?, 1)").run(detail, detail, `${detail}@example.com`);
      db.prepare("INSERT INTO account_settings(user_id, summary, output_language, analysis_languages, revision) VALUES (?, ?, 'en', ?, 7)")
        .run(detail, JSON.stringify({ method: "audio", detail, methodSettings: { transcript: { model: "saved-text", reasoningEffort: "high" }, audio: { model: "saved-audio", reasoningEffort: "low" } } }), '{"scope":"all","identifiers":[]}');
    }
    db.exec(`INSERT INTO vaults(vault_id, name) VALUES ('vault', 'Vault');
      INSERT INTO meetings(meeting_id, vault_id, name, status, created_at, updated_at) VALUES ('meeting', 'vault', 'Meeting', 'READY', 1, 1);
      INSERT INTO jobs_summary(id, vault_id, meeting_id, owner_user_id, method, settings, output_language, status, attempts,
        created_at, available_at, claimed_at, lease_expires_at, summary_revision, input_version, request_hash)
      VALUES ('job', 'vault', 'meeting', 'concise', 'audio', '{"detail":"eventSession","model":"saved","reasoningEffort":"high"}',
        'en', 'processing', 2, 10, 11, 12, 13, 4, 'frozen-input', 'frozen-request');`);
    const job = db.prepare("SELECT * FROM jobs_summary").get();
    const accounts = db.prepare("SELECT * FROM account_settings ORDER BY user_id").all();
    for (const file of files.slice(boundary)) db.exec(read(file));
    expect(db.prepare("SELECT * FROM jobs_summary").get()).toEqual({ ...job, input: null, stage: null, transcript_revision: null, transcript_result: null });
    const mapped: Record<string, string> = { concise: "low", standard: "medium", detailed: "high", eventSession: "xhigh" };
    for (const account of accounts) {
      const summary = JSON.parse(String(account.summary)) as { detail: string };
      summary.detail = mapped[summary.detail]!;
      expect(db.prepare("SELECT * FROM account_settings WHERE user_id = ?").get(account.user_id!))
        .toEqual({ ...account, revision: 8, summary: JSON.stringify(summary) });
    }
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    db.exec("UPDATE jobs_summary SET status = 'cancelled' WHERE id = 'job'");
    expect(db.prepare("SELECT status FROM jobs_summary").get()).toEqual({ status: "cancelled" });
  } finally { db.close(); }
});
