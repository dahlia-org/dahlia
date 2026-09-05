import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "pg";
import { expect, it } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { serverMigrationManifest } from "../src/migrations";

it.runIf(process.env.TEST_MIGRATION_DATABASE_URL)("preserves PostgreSQL receipt data while upgrading the predecessor schema", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-pg-upgrade-"));
  const baseline = serverMigrationManifest.postgres.directories[1]!.files![0]!;
  const original = serverMigrationManifest.postgres.directories[1]!;
  cpSync(join(original.path, baseline.split("/")[0]!), join(directory, baseline.split("/")[0]!), { recursive: true });
  const config = {
    authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "postgres" as const,
    databaseUrl: process.env.TEST_MIGRATION_DATABASE_URL, baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024,
  };
  const old = createNodeApplicationStore(config, {
    ...serverMigrationManifest,
    postgres: { directories: [serverMigrationManifest.postgres.directories[0]!, { ...original, path: directory, files: [baseline] }], files: [`drizzle/postgres/${baseline}`] },
  });
  const raw = new Client({ connectionString: config.databaseUrl });
  await raw.connect();
  const id = crypto.randomUUID();
  const vaultId = crypto.randomUUID();
  const userId = crypto.randomUUID();
  const receipt = { id, status: "committed", cursor: "old", records: [{ entity: "vault", id: vaultId, revision: 3, record: { name: "Preserved" } }] };
  try {
    await old.migrate();
    await old.ensureIdentityUser({ userId, workspaceId: `personal:${userId}`, source: "header" });
    await raw.query("BEGIN");
    await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
    await raw.query("INSERT INTO app.transaction_receipts(transaction_id, owner_user_id, vault_id, request_hash, response_json, cursor) VALUES ($1, $2, $3, 'hash', $4, 42)", [id, userId, vaultId, receipt]);
    await raw.query("COMMIT");
    const upgraded = createNodeApplicationStore(config);
    try { await upgraded.migrate(); } finally { await upgraded.close?.(); }
    await raw.query("BEGIN");
    await raw.query("SELECT set_config('app.user_id', $1, true)", [userId]);
    expect((await raw.query("SELECT response_json, results_json FROM app.transaction_receipts WHERE transaction_id = $1", [id])).rows)
      .toEqual([{ response_json: receipt, results_json: [{ entity: "vault", id: vaultId, revision: 3 }] }]);
    expect((await raw.query("SELECT latest_sequence, pruned_through FROM app.sync_vault_state WHERE vault_id = $1", [vaultId])).rows)
      .toEqual([{ latest_sequence: "42", pruned_through: "0" }]);
    await raw.query("COMMIT");
    expect((await raw.query("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'app.transaction_receipts'::regclass")).rows)
      .toEqual([{ relforcerowsecurity: true }]);
    expect((await raw.query("SELECT * FROM app.transaction_receipts WHERE transaction_id = $1", [id])).rows).toEqual([]);
  } finally {
    await raw.query("ROLLBACK");
    await raw.end();
    await old.close?.();
    rmSync(directory, { recursive: true, force: true });
  }
});
