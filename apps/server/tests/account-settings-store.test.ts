import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { Pool } from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
import { afterAll, expect, it } from "vitest";
import { createAccountSettingsStore } from "../src/account-settings";

const migrations = {
  sqlite: ["20260908092914_massive_luke_cage", "20260908093013_account_settings_backfill", "20260908093035_stale_sue_storm"],
  postgres: ["20260908092913_fancy_cerise", "20260908093012_account_settings_backfill", "20260908093034_stormy_peter_quill"],
};
const transcript = { model: "saved-transcript", reasoningEffort: "high", detail: "concise" };
const audio = { model: "saved-audio", reasoningEffort: "medium", detail: "standard" };
const expectedSummary = (method: string) => ({ method, detail: method === "audio" ? "standard" : "concise",
  methodSettings: { transcript: { model: "saved-transcript", reasoningEffort: "high" }, audio: { model: "saved-audio", reasoningEffort: "medium" } },
});

it.each(["sqlite", "d1"])("migrates both selected methods and preserves jobs in %s", (dialect) => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec("CREATE TABLE account_settings(user_id TEXT PRIMARY KEY, output_language TEXT, analysis_languages TEXT, summary_method TEXT, transcript_summary TEXT, audio_summary TEXT); CREATE TABLE summary_jobs(settings TEXT); INSERT INTO summary_jobs VALUES ('immutable-job-settings')");
    for (const method of ["transcript", "audio"]) db.prepare("INSERT INTO account_settings VALUES (?, 'fr', ?, ?, ?, ?)")
      .run(method, '{"scope":"selected","identifiers":["fr"]}', method, JSON.stringify(transcript), JSON.stringify(audio));
    for (const name of migrations.sqlite) db.exec(readFileSync(new URL(`../drizzle/${dialect}/${name}${dialect === "d1" ? ".sql" : "/migration.sql"}`, import.meta.url), "utf8"));
    for (const method of ["transcript", "audio"]) {
      const row = db.prepare("SELECT * FROM account_settings WHERE user_id = ?").get(method)!;
      expect(JSON.parse(row.summary as string)).toEqual(expectedSummary(method));
      expect(row.output_language).toBe("fr");
      expect(row.analysis_languages).toBe('{"scope":"selected","identifiers":["fr"]}');
      expect(row.change_version).toBe(1);
      expect(row).not.toHaveProperty("transcript_summary");
    }
    expect(db.prepare("SELECT * FROM summary_jobs").get()).toEqual({ settings: "immutable-job-settings" });
  } finally { db.close(); }
});

// Dedicated disposable database owned by a non-superuser; never point this at an application database.
const url = process.env.TEST_ACCOUNT_SETTINGS_DATABASE_URL;
const pool = url ? new Pool({ connectionString: url }) : undefined;
afterAll(async () => pool?.end());
it.runIf(url)("migrates PostgreSQL under FORCE RLS and atomically merges concurrent leaves", async () => {
  const db = drizzle({ client: pool! });
  const store = createAccountSettingsStore(db, true);
  await pool!.query(`CREATE SCHEMA auth; CREATE SCHEMA app;
    CREATE TABLE auth."user"(id text PRIMARY KEY);
    INSERT INTO auth."user" VALUES ('transcript'), ('audio'), ('new'), ('other');
    CREATE TABLE app.account_settings(user_id text PRIMARY KEY REFERENCES auth."user"(id) ON DELETE CASCADE,
      output_language text NOT NULL, analysis_languages jsonb NOT NULL, summary_method text NOT NULL,
      transcript_summary jsonb NOT NULL, audio_summary jsonb NOT NULL);
    CREATE TABLE app.summary_jobs(settings text); INSERT INTO app.summary_jobs VALUES ('immutable-job-settings');`);
  for (const method of ["transcript", "audio"]) await pool!.query("INSERT INTO app.account_settings VALUES ($1, 'fr', $2, $1, $3, $4)",
    [method, '{"scope":"selected","identifiers":["fr"]}', transcript, audio]);
  await pool!.query(`ALTER TABLE app.account_settings ENABLE ROW LEVEL SECURITY;
    ALTER TABLE app.account_settings FORCE ROW LEVEL SECURITY;
    CREATE POLICY account_settings_owner ON app.account_settings FOR ALL
      USING (user_id = nullif(current_setting('app.user_id', true), ''))
      WITH CHECK (user_id = nullif(current_setting('app.user_id', true), ''));`);
  const client = await pool!.connect();
  try {
    await client.query("BEGIN");
    for (const name of migrations.postgres) await client.query(readFileSync(new URL(`../drizzle/postgres/${name}/migration.sql`, import.meta.url), "utf8"));
    const rename = readFileSync(new URL("../drizzle/postgres/20260908180425_schema_organization/migration.sql", import.meta.url), "utf8")
      .split("--> statement-breakpoint").find((statement) => statement.includes('RENAME COLUMN "change_version"'))!;
    await client.query(rename);
    await client.query(readFileSync(new URL("../drizzle/postgres/20260909104431_summary_detail_keys/migration.sql", import.meta.url), "utf8"));
    await client.query("COMMIT");
  } catch (error) { await client.query("ROLLBACK"); throw error; }
  finally { client.release(); }
  for (const method of ["transcript", "audio"]) expect((await store.get(method))?.summary).toEqual({ ...expectedSummary(method), detail: method === "audio" ? "medium" : "low" });
  expect((await pool!.query("SELECT * FROM app.account_settings")).rows).toEqual([]);
  expect((await pool!.query("SELECT * FROM app.summary_jobs")).rows).toEqual([{ settings: "immutable-job-settings" }]);
  expect(await store.get("other")).toBeNull();
  expect(await store.getRevision("audio")).toBe(2);
  await store.update("audio", { summary: { detail: "medium" } });
  expect(await store.getRevision("audio")).toBe(2);
  await Promise.all([
    store.update("audio", { summary: { methodSettings: { audio: { model: "changed" } } } }),
    store.update("audio", { summary: { methodSettings: { audio: { reasoningEffort: "high" } } } }),
    store.update("audio", { summary: { detail: "high" } }),
  ]);
  expect((await store.get("audio"))?.summary).toEqual({ ...expectedSummary("audio"), detail: "high", methodSettings: {
    ...expectedSummary("audio").methodSettings, audio: { model: "changed", reasoningEffort: "high" },
  } });
  expect(await store.getRevision("audio")).toBe(5);
  await store.update("audio", { summary: { detail: "low" } });
  await store.update("audio", { summary: { detail: "medium" } });
  expect((await store.get("audio"))?.summary.detail).toBe("medium");
  await Promise.all([store.update("new", { outputLanguage: "en" }, true), store.update("new", { outputLanguage: "ja" }, true)]);
  const initial = await store.get("new");
  expect(await store.getRevision("new")).toBe(1);
  expect(await store.update("new", { outputLanguage: "fr" }, true)).toEqual(initial);
});
