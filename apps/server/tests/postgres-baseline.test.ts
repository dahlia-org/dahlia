import { testUserID } from "./public-test-client";
import { oauthClientAssertion, session, user } from "../src/db/generated/postgres-auth-schema";
import { readFileSync } from "node:fs";
import { Client } from "pg";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

it("keeps OAuth replay hashes textual while entity IDs use UUID columns", () => {
  expect(oauthClientAssertion.id.getSQLType()).toBe("text");
  expect(user.id.getSQLType()).toBe("uuid");
  expect(session.impersonatedBy.getSQLType()).toBe("uuid");
  expect(session.activeOrganizationId.getSQLType()).toBe("uuid");
  expect(session.activeTeamId.getSQLType()).toBe("uuid");
});

// Dedicated empty database owned by a non-superuser without BYPASSRLS.
it.runIf(process.env.TEST_MIGRATION_DATABASE_URL)("creates the complete PostgreSQL baseline with forced RLS and deferrable membership constraints", async () => {
  const client = new Client({ connectionString: process.env.TEST_MIGRATION_DATABASE_URL });
  await client.connect();
  try {
    expect((await client.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).rows)
      .toEqual([{ rolsuper: false, rolbypassrls: false }]);
    await client.query("BEGIN");
    const files = serverMigrationManifest.postgres.files;
    const organizationIndex = files.findIndex((file) => file.includes("default_organization_initialization"));
    const summaryIndex = files.findIndex((file) => file.includes("damp_miss_america"));
    for (const file of files.slice(0, organizationIndex)) {
      await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    }
    await client.query("INSERT INTO auth.organization(id, name, slug, created_at) VALUES ('01990ab0-0000-7000-8000-000000000001', 'Custom name', 'external', to_timestamp(1))");
    for (const file of files.slice(organizationIndex, summaryIndex)) {
      await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    }
    for (const method of ["transcript", "cloudTranscription", "audio"] as const) {
      await client.query("INSERT INTO auth.\"user\"(id, name, email) VALUES ($1, $2, $3)", [testUserID(method), method, `${method}@example.com`]);
      await client.query("SELECT set_config('app.user_id', $1, true)", [testUserID(method)]);
      await client.query(`INSERT INTO app.account_settings(user_id, summary, output_language, analysis_languages)
        VALUES ($1, $2::jsonb, 'ja', '{}'::jsonb)`, [testUserID(method), JSON.stringify({
        method, detail: method === "audio" ? "standard" : "detailed", methodSettings: {
          transcript: { model: "saved-summary", reasoningEffort: "high" },
          audio: { model: "saved-audio", reasoningEffort: "low" },
        },
      })]);
    }
    for (const file of files.slice(summaryIndex)) {
      await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    }
    const expected = {
      audio: { summary: { style: "standard" }, processing: { location: "remote", remote: {
        workflow: "combined", summaryModel: "saved-audio", reasoningEffort: "low",
      } } },
      cloudTranscription: { summary: { style: "detailed" }, processing: { location: "remote", remote: {
        workflow: "transcribeThenSummarize", summaryModel: "saved-summary", reasoningEffort: "high", transcriptionModel: "saved-audio",
      } } },
      transcript: { summary: { style: "detailed" }, processing: { location: "local", remote: {
        workflow: "transcribeThenSummarize", summaryModel: "saved-summary", reasoningEffort: "high", transcriptionModel: "gemini-3-8-flash",
      } } },
    };
    for (const method of Object.keys(expected) as (keyof typeof expected)[]) {
      await client.query("SELECT set_config('app.user_id', $1, true)", [testUserID(method)]);
      expect((await client.query("SELECT summary, processing FROM app.account_settings WHERE user_id = $1", [testUserID(method)])).rows)
        .toEqual([expected[method]]);
    }
    expect((await client.query("SELECT name, initialized_at FROM app.server_initializations")).rows)
      .toEqual([{ name: "default_organization", initialized_at: new Date(1000) }]);
    expect((await client.query("SELECT name FROM auth.organization")).rows).toEqual([{ name: "Custom name" }]);
    expect((await client.query("SELECT * FROM auth.member")).rows).toEqual([]);
    await client.query("DELETE FROM auth.organization");
    expect((await client.query("SELECT count(*)::int AS count FROM app.server_initializations")).rows).toEqual([{ count: 1 }]);
    const protectedTables = await client.query<{ relname: string; relforcerowsecurity: boolean }>(`SELECT relname, relforcerowsecurity FROM pg_class
      WHERE relnamespace = 'app'::regnamespace AND relrowsecurity ORDER BY relname`);
    expect(protectedTables.rows.map((row) => row.relname)).toEqual([
      "account_settings", "files", "jobs_summary", "meeting_attachments", "meeting_events", "meetings", "projects",
      "recordings", "search_documents", "search_embeddings", "summaries", "transaction_receipts",
      "transcript_patch_chunks", "transcript_segments", "transcripts", "vault_transfers", "vaults",
    ]);
    expect(protectedTables.rows.every((row) => row.relforcerowsecurity === true)).toBe(true);
    const membership = await client.query<{ condeferrable: boolean; condeferred: boolean }>(`SELECT condeferrable, condeferred FROM pg_constraint
      WHERE contype = 'f' AND cardinality(conkey) > 1 AND connamespace = 'app'::regnamespace`);
    expect(membership.rows.length).toBeGreaterThan(0);
    expect(membership.rows.every((row) => row.condeferrable && !row.condeferred)).toBe(true);
    expect((await client.query("SELECT * FROM app.meetings")).rows).toEqual([]);
    expect((await client.query("SELECT to_regclass('app.artifact') AS retired")).rows).toEqual([{ retired: null }]);
    const digest = "abcdefghijklmnopqrstuvwxyz012345";
    await client.query("INSERT INTO auth.oauth_client_assertion(id, expires_at) VALUES ($1, now() + interval '1 minute')", [digest]);
    expect((await client.query("SELECT id FROM auth.oauth_client_assertion")).rows).toEqual([{ id: digest }]);
    await expect(client.query("INSERT INTO auth.oauth_client_assertion(id, expires_at) VALUES ($1, now())", [digest]))
      .rejects.toMatchObject({ code: "23505" });
  } finally {
    await client.query("ROLLBACK");
    await client.end();
  }
});
