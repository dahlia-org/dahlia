import { Client } from "pg";
import { expect, it } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { serverMigrationManifest } from "../src/migrations";

// A dedicated disposable database, separate from other integration suites.
const databaseUrl = process.env.TEST_SCHEMA_UPGRADE_DATABASE_URL;
it.runIf(databaseUrl)("upgrades populated PostgreSQL tables without losing jobs, revisions, or recording RLS", async () => {
  const config = { authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "postgres" as const,
    databaseUrl, baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024 };
  const previous = createNodeApplicationStore(config, {
    ...serverMigrationManifest,
    postgres: { ...serverMigrationManifest.postgres, directories: serverMigrationManifest.postgres.directories.map((directory) =>
      directory.id === "server" ? { ...directory, files: directory.files!.slice(0, -1) } : directory) },
  });
  const raw = new Client({ connectionString: databaseUrl });
  await raw.connect();
  const user = crypto.randomUUID();
  const vault = crypto.randomUUID();
  const meeting = crypto.randomUUID();
  const session = crypto.randomUUID();
  const job = crypto.randomUUID();
  try {
    await previous.migrate();
    await raw.query("BEGIN");
    await raw.query("SELECT set_config('app.user_id', $1, true)", [user]);
    await raw.query('INSERT INTO auth."user"(id, name, email) VALUES ($1, $1, $2)', [user, `${user}@example.com`]);
    await raw.query("INSERT INTO app.vaults(vault_id, name) VALUES ($1, 'Vault')", [vault]);
    await raw.query("INSERT INTO app.vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES ($1, 'user', $2, 'owner', $2)", [vault, user]);
    await raw.query("INSERT INTO app.meetings(meeting_id, vault_id, name, status, created_at, updated_at) VALUES ($1, $2, 'Meeting', 'READY', now(), now())", [meeting, vault]);
    await raw.query("INSERT INTO app.recordings(session_id, vault_id, meeting_id, number, started_at, ended_at, audio, revision, created_at, updated_at) VALUES ($1, $2, $3, 1, now(), now(), $4, 7, now(), now())",
      [session, vault, meeting, { mic: { generation: "upload-token", active: false } }]);
    await raw.query("INSERT INTO app.search_index_jobs(vault_id, document_id, owner_user_id, model, dimensions, generation, status, attempts) VALUES ($1, $2, $3, 'model', 32, 5, 'processing', 2)", [vault, job, user]);
    await raw.query("INSERT INTO app.storage_delete_jobs(storage_key, status, attempts) VALUES ('retained-key', 'failed', 3)");
    await raw.query("INSERT INTO app.summary_jobs(id, vault_id, meeting_id, owner_user_id, method, settings, output_language, created_at, available_at, summary_revision, input_version, request_hash) VALUES ($1, $2, $3, $4, 'transcript', $5, 'ja', now(), now(), 4, 'input', 'request')",
      [job, vault, meeting, user, { model: "saved" }]);
    await raw.query("INSERT INTO app.account_settings(user_id, output_language, analysis_languages, change_version) VALUES ($1, 'ja', $2, 19)", [user, { scope: "automatic" }]);
    const tables = { search_index_jobs: "jobs_search_index", storage_delete_jobs: "jobs_storage_delete", summary_jobs: "jobs_summary" };
    const jobs = await Promise.all(Object.keys(tables).map(async (table) => (await raw.query<Record<string, unknown>>(`SELECT * FROM app.${table}`)).rows));
    const recording = (await raw.query<Record<string, unknown>>("SELECT * FROM app.recordings WHERE session_id = $1", [session])).rows[0]!;
    delete recording.vault_id;
    await raw.query("COMMIT");
    const updated = createNodeApplicationStore(config);
    try { await updated.migrate(); } finally { await updated.close?.(); }
    expect((await raw.query<Record<string, unknown>>("SELECT * FROM app.recordings WHERE session_id = $1", [session])).rows).toEqual([]);
    await raw.query("BEGIN");
    await raw.query("SELECT set_config('app.user_id', $1, true)", [user]);
    expect((await raw.query<Record<string, unknown>>("SELECT * FROM app.recordings WHERE session_id = $1", [session])).rows).toEqual([recording]);
    expect(await Promise.all(Object.values(tables).map(async (table) => (await raw.query<Record<string, unknown>>(`SELECT * FROM app.${table}`)).rows))).toEqual(jobs);
    expect((await raw.query("SELECT revision FROM app.account_settings WHERE user_id = $1", [user])).rows).toEqual([{ revision: 19 }]);
    expect((await raw.query("SELECT icon, color FROM app.vaults WHERE vault_id = $1", [vault])).rows).toEqual([{ icon: null, color: null }]);
    await raw.query("DELETE FROM app.meetings WHERE meeting_id = $1", [meeting]);
    expect((await raw.query<Record<string, unknown>>("SELECT * FROM app.recordings WHERE session_id = $1", [session])).rows).toEqual([]);
    await raw.query("COMMIT");
    expect((await raw.query("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'app.recordings'::regclass")).rows).toEqual([{ relforcerowsecurity: true }]);
  } finally {
    await raw.query("ROLLBACK");
    await raw.end();
    await previous.close?.();
  }
});
