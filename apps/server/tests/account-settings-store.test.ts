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
    await client.query(`INSERT INTO auth."user"(id, name, email, updated_at) VALUES ('audio', 'Audio', 'audio@example.com', now()), ('new', 'New', 'new@example.com', now())`);
    await client.query("COMMIT");
  } catch (error) { await client.query("ROLLBACK"); throw error; }
  finally { client.release(); }
  const expectedSummary = {
    method: "audio",
    detail: "medium",
    methodSettings: {
      transcript: { model: "saved-transcript", reasoningEffort: "high" },
      audio: { model: "saved-audio", reasoningEffort: "medium" },
    },
  } as const;
  await store.update("audio", { summary: expectedSummary });
  expect((await pool!.query("SELECT * FROM app.account_settings")).rows).toEqual([]);
  expect(await store.get("other")).toBeNull();
  expect(await store.getRevision("audio")).toBe(1);
  await store.update("audio", { summary: { detail: "medium" } });
  expect(await store.getRevision("audio")).toBe(1);
  await Promise.all([
    store.update("audio", { summary: { methodSettings: { audio: { model: "changed" } } } }),
    store.update("audio", { summary: { methodSettings: { audio: { reasoningEffort: "high" } } } }),
    store.update("audio", { summary: { detail: "high" } }),
  ]);
  expect((await store.get("audio"))?.summary).toEqual({ ...expectedSummary, detail: "high", methodSettings: {
    ...expectedSummary.methodSettings, audio: { model: "changed", reasoningEffort: "high" },
  } });
  expect(await store.getRevision("audio")).toBe(4);
  await store.update("audio", { summary: { detail: "low" } });
  await store.update("audio", { summary: { detail: "medium" } });
  expect((await store.get("audio"))?.summary.detail).toBe("medium");
  await Promise.all([store.update("new", { outputLanguage: "en" }, true), store.update("new", { outputLanguage: "ja" }, true)]);
  const initial = await store.get("new");
  expect(await store.getRevision("new")).toBe(1);
  expect(await store.update("new", { outputLanguage: "fr" }, true)).toEqual(initial);
});
