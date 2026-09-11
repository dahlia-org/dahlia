import { testUserID } from "./public-test-client";
import { oauthClientAssertion, session, user } from "../src/db/generated/postgres-auth-schema";
import { readFileSync } from "node:fs";
import { Client } from "pg";
import { expect, it } from "vitest";
import { stageFileMetadataLimitMigration } from "../src/db/client";
import { serverMigrationManifest } from "../src/migrations";
import { fileMetadataLimits } from "../src/files/model";

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
    for (const file of files) {
      await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    }
    const owner = testUserID("owner");
    await client.query('INSERT INTO auth."user"(id, name, email) VALUES ($1, $2, $3)', [owner, "Owner", "owner@example.com"]);
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner]);
    await client.query("INSERT INTO app.account_settings(user_id, output_language, analysis_languages) VALUES ($1, 'ja', '{}')", [owner]);
    expect((await client.query("SELECT summary, processing FROM app.account_settings")).rows).toEqual([{
      summary: { style: "detailed" }, processing: { location: "local", remote: { workflow: "transcribeThenSummarize" } },
    }]);
    expect((await client.query("SELECT * FROM app.server_initializations")).rows).toEqual([]);
    const protectedTables = await client.query<{ relname: string; relforcerowsecurity: boolean }>(`SELECT relname, relforcerowsecurity FROM pg_class
      WHERE relnamespace IN ('app'::regnamespace, 'jobs'::regnamespace) AND relrowsecurity ORDER BY relname`);
    expect(protectedTables.rows.map((row) => row.relname)).toEqual([
      "account_settings", "files", "meeting_attachments", "meeting_events", "meetings", "projects",
      "recordings", "summaries", "summary", "transaction_receipts",
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

it.runIf(process.env.TEST_MIGRATION_DATABASE_URL)("truncates legacy file text before enforcing PostgreSQL limits", async () => {
  const client = new Client({ connectionString: process.env.TEST_MIGRATION_DATABASE_URL });
  await client.connect();
  try {
    await client.query("BEGIN");
    const files = serverMigrationManifest.postgres.files;
    for (const file of files.slice(0, -1)) {
      await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    }
    const owner = testUserID("limit-owner");
    const vault = testUserID("limit-vault");
    const meeting = testUserID("limit-meeting");
    await client.query('INSERT INTO auth."user"(id, name, email) VALUES ($1, $2, $3)', [owner, "Owner", "limit@example.com"]);
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner]);
    await client.query("INSERT INTO app.vaults(vault_id, name) VALUES ($1, 'Vault')", [vault]);
    await client.query("INSERT INTO app.vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES ($1, 'user', $2, 'owner', $2)", [vault, owner]);
    await client.query("INSERT INTO app.meetings(meeting_id, vault_id, name, status, created_at, updated_at) VALUES ($1, $2, 'Meeting', 'READY', now(), now())", [meeting, vault]);
    const boundaries = [
      ["zwj", "👨‍👩‍👧‍👦", 3],
      ["combining", "e\u0301", 1],
      ["flag", "🇯🇵", 1],
      ["crlf", "\r\n", 1],
      ["indic", "क्ष", 2],
    ] as const;
    const records = [];
    for (const [name, cluster, remaining] of boundaries) {
      const file = testUserID(`limit-file-${name}`);
      const document = testUserID(`limit-document-${name}`);
      const expectedOCRText = "a".repeat(fileMetadataLimits.postgres.ocrText - remaining);
      const expectedCaption = "あ".repeat(fileMetadataLimits.postgres.caption - remaining);
      const ocrText = expectedOCRText + cluster + "tail";
      const caption = expectedCaption + cluster + "tail";
      await client.query("INSERT INTO app.files(file_id, vault_id, uri, size, content_type, checksum, name, metadata) VALUES ($1, $2, $3, 0, 'image/png', '', 'image', $4)", [
        file, vault, `file-${name}`, { source: "screenshot", ocr_text: ocrText, caption },
      ]);
      await client.query("INSERT INTO search.documents(document_id, vault_id, meeting_id, kind, ocr_text, caption_text) VALUES ($1, $2, $3, 'screenshot', $4, $5)", [
        document, vault, meeting, ocrText, caption,
      ]);
      records.push({ file, document, expectedOCRText, expectedCaption });
    }
    await stageFileMetadataLimitMigration(client);
    await client.query(readFileSync(new URL(`../${files.at(-1)!}`, import.meta.url), "utf8"));
    for (const record of records) {
      expect((await client.query(`SELECT metadata->>'ocr_text' AS ocr, metadata->>'caption' AS caption FROM app.files WHERE file_id = $1`, [record.file])).rows)
        .toEqual([{ ocr: record.expectedOCRText, caption: record.expectedCaption }]);
      expect((await client.query("SELECT ocr_text AS ocr, caption_text AS caption FROM search.documents WHERE document_id = $1", [record.document])).rows)
        .toEqual([{ ocr: record.expectedOCRText, caption: record.expectedCaption }]);
    }

    const rejectWrite = async (sql: string, values: unknown[], code: string) => {
      await client.query("SAVEPOINT rejected_write");
      try {
        await expect(client.query(sql, values)).rejects.toMatchObject({ code });
      } finally {
        await client.query("ROLLBACK TO SAVEPOINT rejected_write");
        await client.query("RELEASE SAVEPOINT rejected_write");
      }
    };
    await rejectWrite("UPDATE app.files SET metadata = jsonb_set(metadata, '{ocr_text}', to_jsonb($1::text)) WHERE file_id = $2", [
      "x".repeat(fileMetadataLimits.postgres.ocrText + 1), records[0]!.file,
    ], "23514");
    await rejectWrite("UPDATE app.files SET metadata = jsonb_set(metadata, '{caption}', to_jsonb($1::text)) WHERE file_id = $2", [
      "x".repeat(fileMetadataLimits.postgres.caption + 1), records[0]!.file,
    ], "23514");
    await rejectWrite("UPDATE search.documents SET ocr_text = $1 WHERE document_id = $2", [
      "x".repeat(fileMetadataLimits.postgres.ocrText + 1), records[0]!.document,
    ], "22001");
    await rejectWrite("UPDATE search.documents SET caption_text = $1 WHERE document_id = $2", [
      "x".repeat(fileMetadataLimits.postgres.caption + 1), records[0]!.document,
    ], "22001");
  } finally {
    await client.query("ROLLBACK");
    await client.end();
  }
});

it.runIf(process.env.TEST_MIGRATION_DATABASE_URL)("moves existing job rows and security metadata using the documented development procedure", async () => {
  const client = new Client({ connectionString: process.env.TEST_MIGRATION_DATABASE_URL });
  await client.connect();
  const names = ["summary", "image_analysis", "search_index", "storage_delete"];
  try {
    await client.query("BEGIN");
    // Reconstruct the previous physical layout from the same unchanged column contracts.
    for (const file of serverMigrationManifest.postgres.files) {
      let sql = readFileSync(new URL(`../${file}`, import.meta.url), "utf8")
        .replace('CREATE SCHEMA "jobs";', "");
      for (const name of names) sql = sql.replaceAll(`"jobs"."${name}"`, `"app"."jobs_${name}"`);
      await client.query(sql);
    }
    const owner = testUserID("move-owner"), vault = testUserID("move-vault"), meeting = testUserID("move-meeting");
    await client.query('INSERT INTO auth."user"(id, name, email) VALUES ($1, \'Owner\', \'move@example.com\')', [owner]);
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner]);
    await client.query("INSERT INTO app.vaults(vault_id, name) VALUES ($1, 'Vault')", [vault]);
    await client.query("INSERT INTO app.vault_permissions(vault_id, principal_type, principal_id, role, granted_by_user_id) VALUES ($1, 'user', $2, 'owner', $2)", [vault, owner]);
    await client.query("INSERT INTO app.meetings(meeting_id, vault_id, name, status, created_at, updated_at) VALUES ($1, $2, 'Meeting', 'READY', now(), now())", [meeting, vault]);
    await client.query(`INSERT INTO app.jobs_summary(id, vault_id, meeting_id, owner_user_id, method, settings, output_language,
      created_at, available_at, summary_revision, input_version, request_hash, encrypted_payload, status, attempts, claimed_at, lease_expires_at)
      VALUES ($1, $2, $3, $4, 'transcript', '{}', 'ja', now(), now(), 0, 'existing-hash', 'existing-request', 'opaque-ciphertext', 'processing', 2, now(), now())`, [testUserID("move-summary"), vault, meeting, owner]);
    await client.query("INSERT INTO app.files(file_id, vault_id, uri, size, content_type, checksum, name, metadata) VALUES ($1, $2, 'file', 0, 'image/png', '', 'image', '{}')", [testUserID("move-file"), vault]);
    await client.query("INSERT INTO app.jobs_image_analysis(file_id, vault_id, owner_user_id, model, status, attempts) VALUES ($1, $2, $3, 'model', 'failed', 3)", [testUserID("move-file"), vault, owner]);
    await client.query("INSERT INTO app.jobs_search_index(vault_id, document_id, owner_user_id, model, dimensions, attempts) VALUES ($1, $2, $3, 'model', 32, 1)", [vault, meeting, owner]);
    await client.query("INSERT INTO app.jobs_storage_delete(storage_key, attempts) VALUES ('existing-key', 2)");
    const rows = await Promise.all(names.map((name) => client.query(`SELECT * FROM app.jobs_${name}`)));
    const relations = (await client.query<{ oid: number }>("SELECT oid FROM pg_class WHERE relnamespace = 'app'::regnamespace AND relname = ANY($1)", [names.map((name) => `jobs_${name}`)])).rows.map(({ oid }) => oid);
    const metadata = () => client.query(`SELECT c.oid, c.relowner, c.relacl, c.relrowsecurity, c.relforcerowsecurity,
      (SELECT array_agg(oid ORDER BY oid) FROM pg_constraint WHERE conrelid = c.oid) AS constraints,
      (SELECT array_agg(indexrelid ORDER BY indexrelid) FROM pg_index WHERE indrelid = c.oid) AS indexes,
      (SELECT array_agg(oid ORDER BY oid) FROM pg_policy WHERE polrelid = c.oid) AS policies
      FROM pg_class c WHERE c.oid = ANY($1::oid[]) ORDER BY c.oid`, [relations]);
    const before = await metadata();
    const procedure = readFileSync(new URL("../docs/jobs-schema-move.md", import.meta.url), "utf8").split("```sql\n")[1]!.split("```")[0]!;
    await client.query(procedure.replace("BEGIN;", "").replace("COMMIT;", ""));
    expect((await metadata()).rows).toEqual(before.rows);
    for (const [index, name] of names.entries()) {
      expect((await client.query(`SELECT * FROM jobs.${name}`)).rows).toEqual(rows[index]!.rows);
      expect((await client.query("SELECT to_regclass($1) AS old", [`app.jobs_${name}`])).rows).toEqual([{ old: null }]);
    }
  } finally {
    await client.query("ROLLBACK");
    await client.end();
  }
});
