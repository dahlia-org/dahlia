import { readFileSync } from "node:fs";
import { Client } from "pg";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

// Dedicated empty database owned by a non-superuser without BYPASSRLS.
it.runIf(process.env.TEST_MIGRATION_DATABASE_URL)("creates the complete PostgreSQL baseline with forced RLS and deferrable membership constraints", async () => {
  const client = new Client({ connectionString: process.env.TEST_MIGRATION_DATABASE_URL });
  await client.connect();
  try {
    expect((await client.query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).rows)
      .toEqual([{ rolsuper: false, rolbypassrls: false }]);
    await client.query("BEGIN");
    for (const file of serverMigrationManifest.postgres.files) {
      await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    }
    const protectedTables = await client.query<{ relname: string; relforcerowsecurity: boolean }>(`SELECT relname, relforcerowsecurity FROM pg_class
      WHERE relnamespace = 'app'::regnamespace AND relrowsecurity ORDER BY relname`);
    expect(protectedTables.rows.map((row) => row.relname)).toEqual([
      "account_settings", "files", "jobs_summary", "meeting_events", "meeting_files", "meetings", "projects",
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
  } finally {
    await client.query("ROLLBACK");
    await client.end();
  }
});
