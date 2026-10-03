import { DEFAULT_WORKSPACE_GENERATION_SETTINGS } from "../src/workspace-generation-settings";
import { testUserID } from "./public-test-client";
import { oauthClientAssertion, session, user } from "../src/db/generated/postgres-auth-schema";
import { readFileSync } from "node:fs";
import { Client } from "pg";
import { expect, it } from "vitest";
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
    expect((await client.query("SELECT to_regclass('jobs.queue') AS queue")).rows).toEqual([{ queue: "jobs.queue" }]);
    expect((await client.query<{ tgname: string }>(`SELECT tgname FROM pg_trigger
      WHERE NOT tgisinternal AND tgname LIKE 'dispatch_%' ORDER BY tgname`)).rows.map(({ tgname }) => tgname)).toEqual([]);
    for (const name of ["jobs.image_analysis", "jobs.search_index", "jobs.storage_delete", "agent.memory_jobs"]) {
      expect((await client.query("SELECT to_regclass($1) AS retired", [name])).rows).toEqual([{ retired: null }]);
    }
    expect((await client.query("SELECT data_type FROM information_schema.columns WHERE table_schema = 'jobs' AND table_name = 'queue' AND column_name = 'id'")).rows)
      .toEqual([{ data_type: "uuid" }]);
    const owner = testUserID("owner");
    await client.query('INSERT INTO auth."user"(id, name, email) VALUES ($1, $2, $3)', [owner, "Owner", "owner@example.com"]);
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner]);
    expect((await client.query("SELECT to_regclass('app.account_settings') AS retired")).rows).toEqual([{ retired: null }]);
    await client.query("INSERT INTO auth.organization(id, name, slug, created_at) VALUES ($1, 'Team', $2, now())", [owner, `team-${owner}`]);
    await client.query("INSERT INTO auth.member(id, organization_id, user_id, role, created_at) VALUES ($1, $1, $1, 'owner', now())", [owner]);
    await client.query("INSERT INTO app.workspaces(workspace_id, organization_id, created_by, name) VALUES ($1, $1, $2, 'Workspace')", [owner, { id: owner, name: "Owner", email: "owner@example.com" }]);
    await client.query("INSERT INTO app.workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id) VALUES ($1, 'user', $1, 'admin', $1)", [owner]);
    expect((await client.query("SELECT generation_settings FROM app.workspaces")).rows).toEqual([{ generation_settings: DEFAULT_WORKSPACE_GENERATION_SETTINGS }]);
    expect((await client.query("SELECT id FROM app.server_settings")).rows).toEqual([]);
    const protectedTables = await client.query<{ relname: string; relforcerowsecurity: boolean }>(`SELECT relname, relforcerowsecurity FROM pg_class
      WHERE relnamespace IN ('app'::regnamespace, 'jobs'::regnamespace, 'search'::regnamespace, 'crypto'::regnamespace, 'agent'::regnamespace) AND relrowsecurity ORDER BY relname`);
    expect(protectedTables.rows.map((row) => row.relname)).toEqual([
      "ai_thread_runs", "document_presence", "document_recoveries", "document_updates", "documents", "documents", "files", "knowledge_pages", "live_contexts", "mastra_messages",
      "mastra_observational_memory", "mastra_resources", "mastra_threads", "meeting_attachments",
      "meeting_events", "meetings", "personal_memories", "projects",
      "recordings", "shared_memories", "summaries", "summary", "transaction_receipts",
      "transcript_patch_chunks", "transcript_segments", "transcripts", "workspace_keys", "workspace_transfers", "workspaces",
    ]);
    expect(protectedTables.rows.every((row) => row.relforcerowsecurity === true)).toBe(true);
    const membership = await client.query<{ condeferrable: boolean; condeferred: boolean }>(`SELECT condeferrable, condeferred FROM pg_constraint
      WHERE contype = 'f' AND cardinality(conkey) > 1 AND connamespace = 'app'::regnamespace`);
    expect(membership.rows.length).toBeGreaterThan(0);
    expect(membership.rows.every((row) => row.condeferrable && !row.condeferred)).toBe(true);
    expect((await client.query("SELECT * FROM app.meetings")).rows).toEqual([]);
    expect((await client.query("SELECT to_regclass('app.artifact') AS retired")).rows).toEqual([{ retired: null }]);
    // Non-superuser, forced RLS and realistic cardinality: verify the planner, not just index declarations.
    await client.query(`INSERT INTO app.documents(id, workspace_id, kind, generation, checkpoint, text, created_at, updated_at)
      SELECT md5('index-document-' || g)::uuid, $1, 'general', md5('generation-' || g)::uuid, 'AAA=', '', now(), now()
      FROM generate_series(1, 2000) g`, [owner]);
    await client.query(`INSERT INTO app.document_recoveries(id, document_id, workspace_id, blocks, reason, sequence, created_at)
      SELECT md5('recovery-' || g)::uuid, md5('index-document-' || (1 + g % 2000))::uuid, $1, '[]', 'concurrent_delete', g, now()
      FROM generate_series(1, 20000) g`, [owner]);
    await client.query(`INSERT INTO app.document_presence(id, document_id, workspace_id, user_id, expires_at)
      SELECT md5('presence-' || g)::uuid, md5('index-document-' || (1 + g % 2000))::uuid, $1, $1,
        now() + CASE WHEN g <= 10 THEN interval '-1 second' ELSE interval '15 seconds' END
      FROM generate_series(1, 10000) g`, [owner]);
    await client.query("ANALYZE app.documents; ANALYZE app.document_recoveries; ANALYZE app.document_presence");
    const documentID = (await client.query<{ id: string }>("SELECT md5('index-document-1')::uuid AS id")).rows[0]!.id;
    for (const [query, index, parameters] of [
      ["SELECT id FROM app.document_recoveries WHERE workspace_id = $1 AND document_id = $2 AND sequence > 0 AND sequence <= 20000 ORDER BY sequence LIMIT 101", "document_recoveries_document_cursor", [owner, documentID]],
      ["SELECT user_id FROM app.document_presence WHERE workspace_id = $1 AND document_id = $2 AND expires_at > $3", "document_presence_document_expiry", [owner, documentID, new Date().toISOString()]],
      ["SELECT id FROM app.document_presence WHERE workspace_id = $1 AND expires_at <= $2", "document_presence_workspace_expiry", [owner, new Date().toISOString()]],
    ] as const) {
      const plan = await client.query(`EXPLAIN (FORMAT JSON) ${query}`, [...parameters]);
      expect(JSON.stringify(plan.rows)).toContain(index);
    }
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

it.runIf(process.env.TEST_MIGRATION_DATABASE_URL)("enforces file text limits in the PostgreSQL baseline", async () => {
  const client = new Client({ connectionString: process.env.TEST_MIGRATION_DATABASE_URL });
  await client.connect();
  try {
    await client.query("BEGIN");
    for (const file of serverMigrationManifest.postgres.files) {
      await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    }
    const owner = testUserID("limit-owner");
    const workspace = testUserID("limit-workspace");
    const meeting = testUserID("limit-meeting");
    const file = testUserID("limit-file");
    const document = testUserID("limit-document");
    await client.query('INSERT INTO auth."user"(id, name, email) VALUES ($1, $2, $3)', [owner, "Owner", "limit@example.com"]);
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner]);
    await client.query("INSERT INTO auth.organization(id, name, slug, created_at) VALUES ($1, 'Team', $2, now())", [owner, `team-${owner}`]);
    await client.query("INSERT INTO auth.member(id, organization_id, user_id, role, created_at) VALUES ($1, $1, $1, 'owner', now())", [owner]);
    await client.query("INSERT INTO app.workspaces(workspace_id, organization_id, created_by, name) VALUES ($1, $2, $3, 'Workspace')", [workspace, owner, { id: owner, name: "Owner", email: "limit@example.com" }]);
    await client.query("INSERT INTO app.workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id) VALUES ($1, 'user', $2, 'admin', $2)", [workspace, owner]);
    await client.query("INSERT INTO app.meetings(meeting_id, workspace_id, name, status, created_at, updated_at) VALUES ($1, $2, 'Meeting', 'READY', now(), now())", [meeting, workspace]);
    await client.query("INSERT INTO app.files(file_id, workspace_id, uri, size, content_type, checksum, name, metadata) VALUES ($1, $2, 'file', 0, 'image/png', '', 'image', $3)", [
      file, workspace, { source: "screenshot", ocr_text: "ocr", caption: "caption" },
    ]);
    await client.query("INSERT INTO search.documents(document_id, workspace_id, meeting_id, kind, ocr_text, caption_text) VALUES ($1, $2, $3, 'screenshot', 'ocr', 'caption')", [document, workspace, meeting]);

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
      "x".repeat(fileMetadataLimits.postgres.ocrText + 1), file,
    ], "23514");
    await rejectWrite("UPDATE app.files SET metadata = jsonb_set(metadata, '{caption}', to_jsonb($1::text)) WHERE file_id = $2", [
      "x".repeat(fileMetadataLimits.postgres.caption + 1), file,
    ], "23514");
    await rejectWrite("UPDATE search.documents SET ocr_text = $1 WHERE document_id = $2", [
      "x".repeat(fileMetadataLimits.postgres.ocrText + 1), document,
    ], "22001");
    await rejectWrite("UPDATE search.documents SET caption_text = $1 WHERE document_id = $2", [
      "x".repeat(fileMetadataLimits.postgres.caption + 1), document,
    ], "22001");
  } finally {
    await client.query("ROLLBACK");
    await client.end();
  }
});
