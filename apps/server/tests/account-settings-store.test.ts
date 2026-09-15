import { readFileSync } from "node:fs";
import { Pool } from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
import { afterAll, expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";
import { createAccountSettingsStore } from "../src/account-settings";

// Dedicated disposable database owned by a non-superuser; never point this at an application database.
const url = process.env.TEST_ACCOUNT_SETTINGS_DATABASE_URL;
const pool = url ? new Pool({ connectionString: url }) : undefined;
afterAll(async () => pool?.end());
it.runIf(url)("enforces PostgreSQL account isolation and conditional initialization", async () => {
  const db = drizzle({ client: pool! });
  const store = createAccountSettingsStore(db, true);
  const client = await pool!.connect();
  try {
    await client.query("BEGIN");
    for (const file of serverMigrationManifest.postgres.files) await client.query(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    await client.query(`INSERT INTO auth."user"(id, name, email, updated_at) VALUES ('01990ab0-0000-7000-8000-000000000101', 'Audio', 'audio@example.com', now()), ('01990ab0-0000-7000-8000-000000000102', 'New', 'new@example.com', now())`);
    await client.query("COMMIT");
  } catch (error) { await client.query("ROLLBACK"); throw error; }
  finally { client.release(); }
  const id = "01990ab0-0000-7000-8000-000000000101";
  const settings = { analysisLanguages: { scope: "selected" as const, identifiers: ["en"] } };
  await store.update(id, settings);
  expect(await store.get(id)).toEqual(settings);
  const revision = await store.getRevision(id);
  await store.update(id, settings);
  expect(await store.getRevision(id)).toBe(revision);
  await store.update(id, { analysisLanguages: { scope: "all", identifiers: [] } }, true);
  expect(await store.get(id)).toEqual(settings);
  expect(await store.get("01990ab0-0000-7000-8000-000000000102")).toBeNull();
});
