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
it.runIf(url)("enforces PostgreSQL FORCE RLS and atomically merges concurrent leaves", async () => {
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
  const expectedSummary = {
    mode: "remote",
    remote: { detail: "medium", model: "saved-audio", reasoningEffort: "medium", transcriptionModel: "saved-transcript" },
  } as const;
  await store.update("01990ab0-0000-7000-8000-000000000101", { summary: expectedSummary });
  expect((await pool!.query("SELECT * FROM app.account_settings")).rows).toEqual([]);
  expect(await store.get("01990ab0-0000-7000-8000-000000000103")).toBeNull();
  expect(await store.getRevision("01990ab0-0000-7000-8000-000000000101")).toBe(1);
  await store.update("01990ab0-0000-7000-8000-000000000101", { summary: { remote: { detail: "medium" } } });
  expect(await store.getRevision("01990ab0-0000-7000-8000-000000000101")).toBe(1);
  await Promise.all([
    store.update("01990ab0-0000-7000-8000-000000000101", { summary: { remote: { model: "changed" } } }),
    store.update("01990ab0-0000-7000-8000-000000000101", { summary: { remote: { reasoningEffort: "high" } } }),
    store.update("01990ab0-0000-7000-8000-000000000101", { summary: { remote: { detail: "high" } } }),
  ]);
  expect((await store.get("01990ab0-0000-7000-8000-000000000101"))?.summary).toEqual({ ...expectedSummary, remote: {
    ...expectedSummary.remote, detail: "high", model: "changed", reasoningEffort: "high",
  } });
  expect(await store.getRevision("01990ab0-0000-7000-8000-000000000101")).toBe(4);
  await store.update("01990ab0-0000-7000-8000-000000000101", { summary: { remote: { detail: "low" } } });
  await store.update("01990ab0-0000-7000-8000-000000000101", { summary: { remote: { detail: "medium" } } });
  expect((await store.get("01990ab0-0000-7000-8000-000000000101"))?.summary.remote.detail).toBe("medium");
  await store.update("01990ab0-0000-7000-8000-000000000101", { summary: { remote: { transcriptionModel: null } } });
  expect((await store.get("01990ab0-0000-7000-8000-000000000101"))?.summary.remote.transcriptionModel).toBeUndefined();
  await Promise.all([store.update("01990ab0-0000-7000-8000-000000000102", { outputLanguage: "en" }, true), store.update("01990ab0-0000-7000-8000-000000000102", { outputLanguage: "ja" }, true)]);
  const initial = await store.get("01990ab0-0000-7000-8000-000000000102");
  expect(await store.getRevision("01990ab0-0000-7000-8000-000000000102")).toBe(1);
  expect(await store.update("01990ab0-0000-7000-8000-000000000102", { outputLanguage: "fr" }, true)).toEqual(initial);
});
